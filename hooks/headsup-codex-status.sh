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

# Declared-idle (digadop-ai#903): APT tabs can explicitly mark a Stop as
# "nothing to do" via ~/.claude/hooks/headsup-state.sh idle. Codex owns its
# own hook chain, so mirror APT's hooks/status.sh marker handling here instead
# of installing a second APT status hook that would double-post lifecycle
# events for Codex sessions.
if [ "$TERMINAL_PROVIDER" = "ai-power-term" ] && [ -n "$TERMINAL_ID" ]; then
    IDLE_MARK="$HOME/.claude/hooks/.state/apt-declared-idle-$TERMINAL_ID"
    case "$EVENT" in
        UserPromptSubmit|SessionStart) rm -f "$IDLE_MARK" 2>/dev/null || true ;;
        Stop) [ -f "$IDLE_MARK" ] && EVENT="SessionStart" ;;
    esac
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
