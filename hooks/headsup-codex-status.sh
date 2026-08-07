#!/bin/bash
# iTerm2 status indicator adapter for Codex CLI sessions.
#
# Codex exposes lifecycle hooks that overlap with Claude Code's hook names,
# but Codex does not use ~/.claude/settings.json or Claude's statusLine JSON.
# This adapter maps Codex hook events onto the existing headsup state-file
# protocol consumed by iterm2-daemon.py:
#
#   SessionStart      -> idle
#   UserPromptSubmit  -> working
#   PreToolUse        -> working
#   PermissionRequest -> waiting
#   PostToolUse       -> working
#   Stop              -> waiting
#
# Hook invocation:
#   ~/.codex/hooks/headsup-codex-status.sh <event>

EVENT="$1"
RAW_EVENT="$EVENT"
HOOK_PAYLOAD="$(cat 2>/dev/null || true)"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
export HEADSUP_HOOK_DIR="$HOOK_DIR"
export HEADSUP_STATE_DIR="$STATE_DIR"

# Kill switch — separate from Claude's ~/.claude/hooks/.disabled so either
# tool can be disabled without affecting the other.
[ -f "$HOOK_DIR/.disabled" ] && exit 0

LOG_FILE="$STATE_ROOT/headsup-status.log"
LOG_MAX_BYTES=5242880
if [ -f "$LOG_FILE" ]; then
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$log_size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
fi

log_msg() {
    [ -f "$HOOK_DIR/.debug" ] || return 0
    printf '%s codex-hook %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

IDLE_COLOR="ffffff"
PROCESS_COLOR="3a82f5"
WAIT_COLOR="e67e22"

TERMINAL_PROVIDER=""
TERMINAL_ID=""
SESSION_KEY=""
if [ -n "${AI_POWER_TERM_SESSION_ID:-}${STEVE_TABS_SESSION_ID:-}" ]; then
    TERMINAL_PROVIDER="ai-power-term"
    TERMINAL_ID="${AI_POWER_TERM_SESSION_ID:-$STEVE_TABS_SESSION_ID}"
    SESSION_KEY=$(printf '%s' "apt-$TERMINAL_ID" | tr -c '[:alnum:]-' '_')
elif [ -n "${ITERM_SESSION_ID:-}" ]; then
    TERMINAL_PROVIDER="iterm"
    TERMINAL_ID="${ITERM_SESSION_ID#*:}"
    SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
fi

headsup_badge_text() { basename "$PWD"; }
headsup_title_text() { printf 'Codex · %s' "$1"; }

CONFIG_FILE="$HOOK_DIR/headsup-status.conf"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
# The shared config may come from the Claude install and define
# `Claude · <project>`. Keep its colors/project functions, but restore the
# Codex default title unless the per-session config below overrides it.
headsup_title_text() { printf 'Codex · %s' "$1"; }

if [ -n "$SESSION_KEY" ]; then
    SESSION_CONFIG_FILE="$HOOK_DIR/headsup-status.d/${SESSION_KEY}.conf"
    # shellcheck source=/dev/null
    [ -f "$SESSION_CONFIG_FILE" ] && source "$SESSION_CONFIG_FILE"
fi

if declare -f headsup_project_idle_color >/dev/null 2>&1; then
    override=$(headsup_project_idle_color 2>/dev/null)
    [ -n "$override" ] && IDLE_COLOR="$override"
fi
if declare -f headsup_project_process_color >/dev/null 2>&1; then
    override=$(headsup_project_process_color 2>/dev/null)
    [ -n "$override" ] && PROCESS_COLOR="$override"
fi
if declare -f headsup_project_wait_color >/dev/null 2>&1; then
    override=$(headsup_project_wait_color 2>/dev/null)
    [ -n "$override" ] && WAIT_COLOR="$override"
fi

find_parent_tty() {
    local pid=$PPID tty
    for _ in 1 2 3 4 5; do
        { [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ]; } && break
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$tty" ] && [ "$tty" != "??" ]; then
            printf '/dev/%s' "$tty"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

TARGET_TTY=$(find_parent_tty)
write_osc() {
    [ -n "$TARGET_TTY" ] || return 0
    printf '%s' "$1" > "$TARGET_TTY" 2>/dev/null || true
}

post_ai_power_term_event() {
    local hook_url
    [ "$TERMINAL_PROVIDER" = "ai-power-term" ] || return 1
    hook_url="${AI_POWER_TERM_HOOK_URL:-${STEVE_TABS_HOOK_URL:-}}"
    if [ -z "$hook_url" ] && [ -f "$HOME/.ai-power-term/server.json" ]; then
        hook_url=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"] + "/hook")' "$HOME/.ai-power-term/server.json" 2>/dev/null)
    fi
    [ -n "$hook_url" ] || { log_msg "apt-skip reason=no-hook-url"; return 1; }
    curl -fsS -m 1 -X POST \
        -H 'Content-Type: application/json' \
        --data "{\"session_id\":\"$TERMINAL_ID\",\"event\":\"$EVENT\"}" \
        "$hook_url" >/dev/null 2>&1 || true
    log_msg "apt-hook event=$EVENT session=$TERMINAL_ID"
    return 0
}

attention_for_event() {
    case "$1" in
        PermissionRequest|Stop) printf 'yes' ;;
        *)                      printf 'no'  ;;
    esac
}

ensure_daemon_running() {
    [ -x "$VENV_PYTHON" ] && [ -f "$DAEMON_SCRIPT" ] || return 0
    local pid_file="$STATE_DIR/daemon.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    log_msg "daemon-start"
    mkdir -p "$STATE_DIR" 2>/dev/null
    nohup "$VENV_PYTHON" "$DAEMON_SCRIPT" \
        >> "$STATE_DIR/daemon.stderr" 2>&1 < /dev/null &
    disown 2>/dev/null || true
}

daemon_heartbeat_stale() {
    [ -f "$HEARTBEAT_FILE" ] || return 0
    local hb hb_ts hb_status now hb_int
    hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1)
    [ -n "$hb" ] || return 0
    hb_ts=$(printf '%s' "$hb" | awk '{print $1}')
    hb_status=$(printf '%s' "$hb" | awk '{print $2}')
    if [ -n "$hb_status" ] && [ "$hb_status" != "OK" ]; then
        return 0
    fi
    [ -n "$hb_ts" ] || return 0
    now=$(date +%s)
    hb_int="${hb_ts%.*}"
    [ -n "$hb_int" ] || return 0
    [ "$((now - hb_int))" -gt "$HEARTBEAT_MAX_AGE_SEC" ]
}

spawn_oneshot_apply() {
    [ -x "$VENV_PYTHON" ] && [ -f "$ONESHOT_SCRIPT" ] || return 0
    local color="$1" attention="$2" uuid="$3"
    nohup "$VENV_PYTHON" "$ONESHOT_SCRIPT" "$color" "$attention" "$uuid" \
        >> "$STATE_DIR/oneshot.stderr" 2>&1 < /dev/null &
    disown 2>/dev/null || true
}

slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9-' '-' \
        | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

append_slug() {
    local s
    s=$(slugify "$1")
    [ -n "$s" ] || return 0
    case " ${CODEX_CLIFF_SLUGS:-} " in
        *" $s "*) ;;
        *) CODEX_CLIFF_SLUGS="${CODEX_CLIFF_SLUGS:+$CODEX_CLIFF_SLUGS }$s" ;;
    esac
}

# The tab LABEL is a deliberate identity, so it is taken as-is. basename($PWD) is only a
# GUESS that the folder name is also an identity (it is how a karen tab in the whoseeswhat
# repo still picks up mail addressed to "whoseeswhat"). A wrong guess is not merely useless,
# it is expensive: cliff.sh hydrate scopes with startswith(slug + "-"), so the org name
# "digadop-ai" -- what basename($PWD) yields for EVERY tab in the monorepo -- matches every
# digadop-ai-* window and drags in the whole org's mail. Measured scopes: nabu 0.82s,
# jupiter 1.00s, digadop-ai 5.28s, which alone overruns the 5s hook budget.
#
# So: validate the GUESS against the roster, never the label. Validating the label too would
# silently drop live non-roster windows (react-client, dbserver) whose own inbox injection is
# guaranteed by CLIFF.md -- the roster guard gates auto-WAKE, not a live window's own inbox.
# roster_persona_has is the persona-only check (wong, 2026-07-15); roster_has/roster_canon are
# delivery-token oriented and must NOT be used here. Fails OPEN: with roster.sh missing or the
# roster empty we keep the old pass-through, so a roster outage costs a slow hook, never mail.
_ROSTER_LIB="${CLIFF_COORD_DIR:-$HOME/.claude/coordination}/lib/roster.sh"
[ -f "$_ROSTER_LIB" ] && . "$_ROSTER_LIB" 2>/dev/null

append_derived_slug() { # append a GUESSED slug only if the roster says it is a real persona
    local s
    s=$(slugify "$1")
    [ -n "$s" ] || return 0
    if command -v roster_persona_has >/dev/null 2>&1 && [ -n "$(roster_tokens 2>/dev/null)" ]; then
        roster_persona_has "$s" || return 0
    fi
    append_slug "$s"
}

build_codex_cliff_slugs() {
    CODEX_CLIFF_SLUGS=""
    local label
    label=$(headsup_badge_text 2>/dev/null || true)
    # Is that label deliberate, or just the basename($PWD) default wearing a label's clothes?
    # The per-session conf on disk is the signal, NOT string equality: a real conf may legitimately
    # name the tab after its folder (the react-client window does exactly that), and comparing
    # strings would silently drop it.
    if [ -n "$label" ]; then
        if [ -n "${SESSION_CONFIG_FILE:-}" ] && [ -f "${SESSION_CONFIG_FILE:-}" ]; then
            append_slug "$label"          # deliberate identity: take it as-is
        else
            append_derived_slug "$label"  # no conf: this is the basename default, so validate it
        fi
    fi
    append_derived_slug "$(basename "$PWD")"

    # Brand/repo transition aliases, kept in sync with cliff-inbox-inject.sh.
    case " $CODEX_CLIFF_SLUGS " in
        *" jobuna "*) append_slug "pursuit" ;;
        *" pursuit "*) append_slug "jobuna" ;;
    esac
    case " $CODEX_CLIFF_SLUGS " in
        *" pursuit-sidebar-detail "*) append_slug "pursuit--sidebar-detail" ;;
        *" pursuit--sidebar-detail "*) append_slug "pursuit-sidebar-detail" ;;
    esac
}

block_codex_stop_for_cliff_if_needed() {
    [ "$RAW_EVENT" = "Stop" ] || return 0
    case "$HOOK_PAYLOAD" in *'"stop_hook_active":true'*) return 0 ;; esac

    local cliff="${CLIFF_BIN:-$HOME/.claude/coordination/lib/cliff.sh}"
    [ -x "$cliff" ] || return 0

    build_codex_cliff_slugs
    [ -n "${CODEX_CLIFF_SLUGS:-}" ] || return 0

    local seen_key="${SESSION_KEY:-${TERMINAL_ID:-$(slugify "$PWD")}}"
    seen_key=$(printf '%s' "codex-$seen_key" | tr -c '[:alnum:]-' '_')
    local seen_dir="$HOME/.claude/coordination/stop-seen"
    local seen="$seen_dir/$seen_key"
    mkdir -p "$seen_dir" 2>/dev/null || return 0
    [ -f "$seen" ] || : > "$seen" 2>/dev/null || return 0

    local threshold="${CLIFF_STOP_BLOCK_AGE_MIN:-0}"
    local inbox id from to blk safe acked age ask eff promoted
    local all_ids="" new_block=""

    # Bound the per-slug Cliff reads so this Stop hook can NEVER blow its 5s budget.
    # cliff.sh inbox hits Agent Office and is routinely ~3.5s (spiking higher), so an
    # unbounded loop over multiple slugs overruns the hook deadline; the hook is then
    # KILLED, which loses the warning entirely AND logs a failure. Instead cap each read
    # and the whole loop, and FAIL OPEN (skip the block) once the budget is spent: the
    # same messages still surface via the UserPromptSubmit inbox inject (15s budget) and
    # the window's own inbox, so a bounded skip is strictly better than a killed hook.
    # Tunable via CODEX_STOP_CLIFF_CALL_TIMEOUT / CODEX_STOP_CLIFF_BUDGET (seconds).
    local _to_bin=""
    if command -v timeout >/dev/null 2>&1; then _to_bin="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then _to_bin="gtimeout"; fi
    local _call_to="${CODEX_STOP_CLIFF_CALL_TIMEOUT:-3}"
    local _budget="${CODEX_STOP_CLIFF_BUDGET:-2}"
    local _t0=$SECONDS
    local _rem _this
    for slug in $CODEX_CLIFF_SLUGS; do
        # Cap each call at the REMAINING budget, not a fixed _call_to. $SECONDS is
        # integer and its tick is unrelated to _t0, so a fixed cap admitted after the
        # guard read low could push total elapsed to ~budget+_call_to (~6s, measured
        # 2/24 overruns max 6.49s by infra-qa on headsup#45). Bounding by remaining
        # budget holds total elapsed at ~budget (0/24 overruns, max 4.56s).
        _rem=$(( _budget - (SECONDS - _t0) ))
        [ "$_rem" -le 0 ] && break
        if [ -n "$_to_bin" ]; then
            _this=$_call_to
            [ "$_rem" -lt "$_this" ] && _this=$_rem
            inbox=$(CLIFF_SLUG="$slug" "$_to_bin" "$_this" "$cliff" inbox --porcelain 2>/dev/null || true)
        else
            inbox=$(CLIFF_SLUG="$slug" "$cliff" inbox --porcelain 2>/dev/null || true)
        fi
        [ -n "$inbox" ] || continue
        while IFS=$'\t' read -r id from to blk safe acked age ask; do
            [ -n "$id" ] || continue
            case " $all_ids " in *" $id "*) continue ;; esac
            all_ids="$all_ids $id"
            [ "$acked" = "acked-by-you" ] && continue
            eff=no
            [ "$blk" = "yes" ] && eff=yes
            if [ "$eff" = "no" ] && [ "${age:-0}" -ge "$threshold" ] 2>/dev/null; then
                eff=yes
            fi
            [ "$eff" = "yes" ] || continue
            grep -qxF "$id" "$seen" 2>/dev/null && continue
            promoted=""
            [ "$blk" != "yes" ] && promoted=" (auto-promoted: unanswered ${age:-0}m)"
            new_block="${new_block}  [${id}] to ${to} via ${slug} from ${from}${promoted} :: ${ask}
"
        done <<EOF
$inbox
EOF
    done

    if [ -n "$all_ids" ]; then
        local tmp
        tmp=$(mktemp) || return 0
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            case " $all_ids " in *" $id "*) printf '%s\n' "$id" ;; esac
        done < "$seen" > "$tmp"
        mv "$tmp" "$seen" 2>/dev/null || rm -f "$tmp"
    fi

    [ -n "$new_block" ] || return 0
    printf '%s' "$new_block" | sed -nE 's/^  \[([^]]+)\].*/\1/p' >> "$seen"

    local reason
    reason="Cliff: message(s) are waiting on this Codex window - handle them before going idle:
${new_block}
Act per the Cliff protocol. Default is DO IT if reversible + within mandate. Reply --resolution need-steve only at a hard gate: money, prod deploy/prod-data write, external/irreversible send or publish, cross-product contract change, granting access, or exposing a secret.

Close each thread with:
  CLIFF_SLUG=<shown-slug> ~/.claude/coordination/lib/cliff.sh reply <id> --resolution done|rejected|need-steve \"<text>\""

    set_tab_color "$WAIT_COLOR"
    python3 - "$reason" <<'PY'
import json
import sys
print(json.dumps({"decision": "block", "reason": sys.argv[1]}))
PY
    exit 0
}

apply_declared_idle_marker() {
    [ "$TERMINAL_PROVIDER" = "ai-power-term" ] || return 0
    [ -n "$TERMINAL_ID" ] || return 0
    local idle_mark="$HOME/.claude/hooks/.state/apt-declared-idle-$TERMINAL_ID"
    case "$RAW_EVENT" in
        UserPromptSubmit|SessionStart) rm -f "$idle_mark" 2>/dev/null || true ;;
        Stop) [ -f "$idle_mark" ] && EVENT="SessionStart" ;;
    esac
}

set_tab_color() {
    local color="$1"
    local attention
    attention=$(attention_for_event "$EVENT")

    if [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
        post_ai_power_term_event
        return 0
    fi

    [ -n "$TERMINAL_ID" ] || { log_msg "skip color=$color reason=no-session-id"; return 0; }
    local uuid="$TERMINAL_ID"
    [ -n "$uuid" ] || { log_msg "skip color=$color reason=bad-session-id"; return 0; }

    mkdir -p "$STATE_DIR" 2>/dev/null
    local tmp="$STATE_DIR/.${uuid}.tmp.$$"
    local final="$STATE_DIR/${uuid}.state"
    printf '%s %s\n' "$color" "$attention" > "$tmp" 2>/dev/null && mv "$tmp" "$final" 2>/dev/null
    log_msg "state event=$EVENT color=$color attention=$attention uuid=$uuid"
    ensure_daemon_running

    if [ "$attention" = "no" ]; then
        write_osc "$(printf '\033]1337;RequestAttention=no\007\033]1337;SetColors=tab=%s\007' "$color")"
    else
        write_osc "$(printf '\033]1337;SetColors=tab=%s\007\033]1337;RequestAttention=yes\007' "$color")"
    fi

    if daemon_heartbeat_stale; then
        log_msg "tier2-spawn reason=daemon-heartbeat-stale"
        spawn_oneshot_apply "$color" "$attention" "$uuid"
    fi
}

VENV_PYTHON="$HOOK_DIR/iterm2-venv/bin/python"
DAEMON_SCRIPT="$HOOK_DIR/iterm2-daemon.py"
ONESHOT_SCRIPT="$HOOK_DIR/iterm2-apply-once.py"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
HEARTBEAT_MAX_AGE_SEC=1

if [ -n "$TERMINAL_ID" ]; then
    _badge_for_sidecar=$(headsup_badge_text 2>/dev/null)
    _uuid_for_sidecar="$TERMINAL_ID"
    if [ -n "$_badge_for_sidecar" ] && [ -n "$_uuid_for_sidecar" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null
        printf '%s\n' "$_badge_for_sidecar" > "$STATE_DIR/${_uuid_for_sidecar}.badge" 2>/dev/null || true
    fi
fi

block_codex_stop_for_cliff_if_needed
apply_declared_idle_marker

case "$EVENT" in
    SessionStart)
        BADGE=$(headsup_badge_text)
        BADGE_B64=$(printf '%s' "$BADGE" | base64)
        TITLE=$(headsup_title_text "$BADGE")
        if [ "$TERMINAL_PROVIDER" = "iterm" ]; then
            write_osc "$(printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$BADGE_B64" "$TITLE")"
        fi
        set_tab_color "$IDLE_COLOR"
        ;;
    UserPromptSubmit|PreToolUse|PostToolUse|PreCompact|PostCompact|SubagentStart|SubagentStop)
        set_tab_color "$PROCESS_COLOR"
        ;;
    PermissionRequest|Stop)
        set_tab_color "$WAIT_COLOR"
        ;;
    *)
        log_msg "ignored event=${EVENT:-unset}"
        ;;
esac
