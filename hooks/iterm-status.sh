#!/bin/bash
# iTerm2 status indicator for Claude Code sessions.
#
# Solid-color state machine:
#   SessionStart      → solid IDLE_COLOR    (idle / fresh session)
#   UserPromptSubmit  → solid PROCESS_COLOR (Claude is processing)
#   Stop|Notification → solid WAIT_COLOR    (Claude is waiting on you)
#
# Two output channels:
#   1. Tab color → iTerm2 Python API via iterm2-set-tab-color.py.
#      Bypasses the pty entirely (injects bytes into iTerm2's parser
#      over its websocket API), which avoids the tear/drop problem the
#      previous OSC-via-tty approach had with the Claude Code TUI's
#      render burst on the same tty.
#   2. Badge / title / dock attention → OSC sequences written to the
#      parent process's tty. Badge + title fire once at SessionStart;
#      dock attention is a separate iTerm2 channel that doesn't drop.
#      No retries needed.
#
# Colors, title, and badge text are configurable via
#   ~/.claude/hooks/iterm-status.conf
# (sourced if present). The /iterm-colors and /iterm-label skills are
# the friendly editors. Defaults below apply when the conf file is
# missing.
#
# Hook invocation:
#   ~/.claude/hooks/iterm-status.sh <event>

EVENT="$1"

# Kill switch — touch ~/.claude/hooks/.disabled to neuter the hook
# without editing settings.json. Used for testing alternative paths
# without hook interference.
[ -f "$HOME/.claude/hooks/.disabled" ] && exit 0

# Peek at the PreToolUse / PostToolUse JSON payload on stdin to detect
# tools that put Claude into a "waiting on user" state. Currently just
# AskUserQuestion — when Claude calls it, we want the tab to go orange
# *immediately* (rather than waiting for the later Notification event
# that fires when the question actually displays, which Claude Code can
# delay by several seconds).
if [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "PostToolUse" ]; then
    HOOK_PAYLOAD=$(cat 2>/dev/null)
    if printf '%s' "$HOOK_PAYLOAD" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"AskUserQuestion"'; then
        if [ "$EVENT" = "PreToolUse" ]; then
            EVENT="PreToolUseWaitForUser"
        else
            EVENT="PostToolUseFromWait"
        fi
    fi
fi

# Debug log — only writes when ~/.claude/hooks/.debug exists.
# Tail with `tail -f ~/.claude/hooks/iterm-status.log` to see what's
# firing (or not). Touch ~/.claude/hooks/.debug to enable.
#
# Size-based rotation: when the log exceeds LOG_MAX_BYTES, rename to
# .log.1 (overwriting any previous rotation) and start fresh. Single
# check per hook invocation so the cost is negligible. We keep one
# rotation file — enough for "what happened in the recent past" forensics
# without unbounded growth.
LOG_FILE="$HOME/.claude/hooks/iterm-status.log"
LOG_MAX_BYTES=5242880   # 5 MB
if [ -f "$LOG_FILE" ]; then
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$log_size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
fi
log_msg() {
    [ -f "$HOME/.claude/hooks/.debug" ] || return 0
    printf '%s sh %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}
log_msg "fire event=$EVENT session=${ITERM_SESSION_ID:-unset} ppid=$PPID"

# Defaults — every value here can be overridden in the conf file below.
IDLE_COLOR="ffffff"     # white  — fresh session / idle
PROCESS_COLOR="3a82f5"  # blue   — Claude is processing
WAIT_COLOR="ffcc00"     # yellow — Claude is waiting on you

iterm_badge_text() { basename "$PWD"; }
iterm_title_text() { printf 'Claude · %s' "$1"; }

CONFIG_FILE="$HOME/.claude/hooks/iterm-status.conf"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

if [ -n "$ITERM_SESSION_ID" ]; then
    SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
    SESSION_CONFIG_FILE="$HOME/.claude/hooks/iterm-status.d/${SESSION_KEY}.conf"
    # shellcheck source=/dev/null
    [ -f "$SESSION_CONFIG_FILE" ] && source "$SESSION_CONFIG_FILE"
fi

# Per-project color overrides — call optional functions defined in the
# conf file. Each gets no args, sees $PWD, returns either a 6-char hex
# or empty (= no override). Order of precedence: per-session conf >
# per-project function > global default.
if declare -f iterm_project_idle_color >/dev/null 2>&1; then
    override=$(iterm_project_idle_color 2>/dev/null)
    [ -n "$override" ] && IDLE_COLOR="$override"
fi
if declare -f iterm_project_process_color >/dev/null 2>&1; then
    override=$(iterm_project_process_color 2>/dev/null)
    [ -n "$override" ] && PROCESS_COLOR="$override"
fi
if declare -f iterm_project_wait_color >/dev/null 2>&1; then
    override=$(iterm_project_wait_color 2>/dev/null)
    [ -n "$override" ] && WAIT_COLOR="$override"
fi

# Defined here (early) so the badge-sidecar write below can use it.
# Other path constants live in the "Tab color via three-tier" block
# further down — they're only needed by set_tab_color.
STATE_DIR="$HOME/.claude/hooks/.state"

# Persist the current badge text to a sidecar on EVERY event (not just
# SessionStart) so out-of-band callers like iterm-notify-waiting.sh can
# show a friendly project name instead of a raw UUID — and so existing
# tabs that started before this code existed also pick up a sidecar
# on their next event. The write is cheap (<50 bytes) and idempotent.
if [ -n "$ITERM_SESSION_ID" ]; then
    _badge_for_sidecar=$(iterm_badge_text 2>/dev/null)
    _uuid_for_sidecar="${ITERM_SESSION_ID#*:}"
    if [ -n "$_badge_for_sidecar" ] && [ -n "$_uuid_for_sidecar" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null
        printf '%s\n' "$_badge_for_sidecar" > "$STATE_DIR/${_uuid_for_sidecar}.badge" 2>/dev/null || true
    fi
fi

# Tab color via three-tier fallback chain — each event fans out to all
# three so the fastest working path wins. iTerm2 silently ignores OSC
# writes in some cases (attention-state vs tab-color interaction, stale
# session references after iTerm2 restart, etc.), so we don't trust any
# single path to always succeed.
#
#   Tier 1: persistent daemon → iTerm2 Python API (<50ms, fast path)
#       The bash hook writes a per-session state file; the daemon polls
#       and injects via the iTerm2 websocket API.
#
#   Tier 2: per-event Python → iTerm2 Python API (~440ms, conditional)
#       Spawned ONLY when the daemon's heartbeat is stale (> 1s old),
#       which means the daemon is dead or its API connection is broken.
#       A fresh Python connects to iTerm2, applies, and exits.
#
#   Tier 3: direct OSC sequence to parent tty (always, best-effort)
#       Lossy in Claude Code's TUI (concurrent render writes can eat the
#       sequence) but free and independent of the Python API. Tier 3
#       fires on every event so on days when Tier 1 and 2 both fail it
#       at least has a chance.
#
# All three fire in parallel where possible — first to land wins, the
# others are redundant no-ops on the iTerm2 side because they're setting
# the same color/attention.
VENV_PYTHON="$HOME/.claude/hooks/iterm2-venv/bin/python"
DAEMON_SCRIPT="$HOME/.claude/hooks/iterm2-daemon.py"
ONESHOT_SCRIPT="$HOME/.claude/hooks/iterm2-apply-once.py"
# STATE_DIR is defined earlier (the badge-sidecar write needs it).
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
HEARTBEAT_MAX_AGE_SEC=1  # daemon writes heartbeat every 200ms; > 1s = stuck

# Map an event to its attention state — "no" clears the iTerm2 attention
# indicator (processing/idle), "yes" sets it (waiting on user, dock bounce).
attention_for_event() {
    case "$1" in
        Notification|Stop|PreToolUseWaitForUser) printf 'yes' ;;
        *)                                        printf 'no'  ;;
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

# Tier 2 trigger check. Returns 0 (true, "stale") when the daemon's
# heartbeat is missing, older than HEARTBEAT_MAX_AGE_SEC, OR carries a
# status field other than OK (DEAD means the daemon detected its own
# websocket failure and is about to exit).
#
# Heartbeat file format:
#   "<epoch>.<ms> <status>\n"  — daemon writes 200ms cadence, status=OK
#                                 normally, DEAD when WS probe/apply failed
#
# Compares the heartbeat's content (a float epoch) against the current
# epoch rather than using the file's mtime — that gives us sub-second
# precision and is robust to filesystems with coarse mtime granularity.
daemon_heartbeat_stale() {
    [ -f "$HEARTBEAT_FILE" ] || return 0
    local hb hb_ts hb_status now hb_int
    hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1)
    [ -n "$hb" ] || return 0
    hb_ts=$(printf '%s' "$hb" | awk '{print $1}')
    hb_status=$(printf '%s' "$hb" | awk '{print $2}')
    # Any non-OK / non-empty status (DEAD, STALE, …) → treat as stale so
    # Tier 2 fires immediately rather than waiting for the age window.
    # Empty status is legacy (older daemons wrote epoch only) → accept it.
    if [ -n "$hb_status" ] && [ "$hb_status" != "OK" ]; then
        return 0
    fi
    [ -n "$hb_ts" ] || return 0
    now=$(date +%s)
    hb_int="${hb_ts%.*}"
    [ -n "$hb_int" ] || return 0
    [ "$((now - hb_int))" -gt "$HEARTBEAT_MAX_AGE_SEC" ]
}

# Tier 2 spawn — async, fire-and-forget. Cold start ~440ms but only paid
# when Tier 1's daemon is stuck; on healthy days this never runs.
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

    [ -n "$ITERM_SESSION_ID" ] || { log_msg "skip color=$color reason=no-session-id"; return 0; }
    local uuid="${ITERM_SESSION_ID#*:}"
    [ -n "$uuid" ] || { log_msg "skip color=$color reason=bad-session-id"; return 0; }

    # ── Tier 1: state file → persistent daemon ──────────────────────────
    mkdir -p "$STATE_DIR" 2>/dev/null
    # Two-step rename so the daemon never sees a torn read.
    local tmp="$STATE_DIR/.${uuid}.tmp.$$"
    local final="$STATE_DIR/${uuid}.state"
    printf '%s %s\n' "$color" "$attention" > "$tmp" 2>/dev/null && mv "$tmp" "$final" 2>/dev/null
    log_msg "state color=$color attention=$attention uuid=$uuid"
    ensure_daemon_running

    # ── Tier 3: direct OSC to parent tty (always, best-effort) ──────────
    # Pair the color and attention writes so iTerm2's "needs attention"
    # state doesn't visually override the new tab color:
    #   attn=no  → clear attention FIRST, then set color
    #   attn=yes → set color FIRST, then request attention
    # The Claude Code TUI's render burst can eat these (the daemon path is
    # the reliable one), but it's free to attempt.
    if [ "$attention" = "no" ]; then
        write_osc "$(printf '\033]1337;RequestAttention=no\007\033]1337;SetColors=tab=%s\007' "$color")"
    else
        write_osc "$(printf '\033]1337;SetColors=tab=%s\007\033]1337;RequestAttention=yes\007' "$color")"
    fi
    log_msg "tier3-tty-osc color=$color attention=$attention"

    # ── Tier 2: per-event Python (only when daemon heartbeat is stale) ──
    # Heartbeat staleness ≈ "daemon isn't actually doing its job right
    # now". Fan out a fresh one-shot Python that connects directly to
    # iTerm2 and applies the same state. ~440ms cost, paid only when
    # needed.
    if daemon_heartbeat_stale; then
        log_msg "tier2-spawn reason=daemon-heartbeat-stale"
        spawn_oneshot_apply "$color" "$attention" "$uuid"
    fi
}

# Badge, title, and dock attention still go through the parent tty via
# OSC writes — single fire, no drop issue in practice.
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

# ── Waiting marker + in-flight-tool counter ──────────────────────────────
# Two per-session files in ~/.claude/hooks/.state/:
#   <uuid>.waiting  — present when the tab is in the orange (waiting) state
#   <uuid>.precount — integer; count of PreToolUse events that haven't
#                     been matched with a PostToolUse yet (i.e., tools
#                     currently in flight on this session)
#
# Combined, these let us distinguish two superficially-identical
# PostToolUse events:
#
#   (A) Stray end-of-turn PostToolUse — fires 1–8s AFTER Notification/Stop
#       when there are no in-flight tools. We want to SUPPRESS this so
#       the tab stays orange instead of flickering back to blue and then
#       back to orange when Stop fires properly.
#
#   (B) Legit post-permission PostToolUse — fires after a Notification
#       (e.g., a mid-tool permission prompt) is resolved. Here the tab
#       SHOULD flip back to blue because the tool actually finished and
#       Claude is processing again.
#
# Rule: PostToolUse → if there's a waiting marker AND no in-flight tools
# (count == 0), suppress (case A). Otherwise, set blue (case B or the
# normal between-tools case).
MARKER_UUID=""
if [ -n "${ITERM_SESSION_ID:-}" ]; then
    MARKER_UUID="${ITERM_SESSION_ID#*:}"
fi
WAITING_MARKER=""
PRECOUNT_FILE=""
if [ -n "$MARKER_UUID" ]; then
    WAITING_MARKER="$STATE_DIR/${MARKER_UUID}.waiting"
    PRECOUNT_FILE="$STATE_DIR/${MARKER_UUID}.precount"
fi

set_waiting_marker() {
    [ -n "$WAITING_MARKER" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null
    : > "$WAITING_MARKER" 2>/dev/null || true
}
clear_waiting_marker() {
    [ -n "$WAITING_MARKER" ] && rm -f "$WAITING_MARKER" 2>/dev/null
    return 0
}
is_waiting() {
    [ -n "$WAITING_MARKER" ] && [ -f "$WAITING_MARKER" ]
}

# Counter helpers. Integer-only writes; reads default to 0 on missing /
# malformed file. Negative reads are clamped to 0 so the counter can't
# drift below zero from a stray PostToolUse that consumed a slot for a
# Pre/Post pair we never observed.
read_precount() {
    local n
    [ -n "$PRECOUNT_FILE" ] && [ -f "$PRECOUNT_FILE" ] || { echo 0; return; }
    n=$(cat "$PRECOUNT_FILE" 2>/dev/null | head -1 | tr -dc '0-9-')
    [ -z "$n" ] && { echo 0; return; }
    [ "$n" -lt 0 ] 2>/dev/null && { echo 0; return; }
    echo "$n"
}
write_precount() {
    [ -n "$PRECOUNT_FILE" ] || return 0
    local n="$1"
    [ "$n" -lt 0 ] 2>/dev/null && n=0
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%d\n' "$n" > "$PRECOUNT_FILE" 2>/dev/null || true
}

case "$EVENT" in
    SessionStart)
        clear_waiting_marker
        write_precount 0
        BADGE=$(iterm_badge_text)
        BADGE_B64=$(printf '%s' "$BADGE" | base64)
        TITLE=$(iterm_title_text "$BADGE")
        write_osc "$(printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$BADGE_B64" "$TITLE")"
        # (Badge sidecar gets written above for every event; no per-Case
        # logic needed here.)
        set_tab_color "$IDLE_COLOR"
        ;;
    UserPromptSubmit|PostToolUseFromWait)
        # Definite start-of-processing signal: user just submitted, or
        # AskUserQuestion just resolved. Reset everything.
        clear_waiting_marker
        write_precount 0
        set_tab_color "$PROCESS_COLOR"
        ;;
    PreToolUse)
        # Tool starting → in-flight count increases, marker is moot.
        clear_waiting_marker
        write_precount $(( $(read_precount) + 1 ))
        set_tab_color "$PROCESS_COLOR"
        ;;
    PostToolUse)
        # Tool finishing. Match against the in-flight counter:
        #   count > 0 → legit completion, decrement + blue
        #   count == 0 AND waiting marker present → stray end-of-turn
        #     delivery, SUPPRESS so the tab stays orange
        #   count == 0 AND no marker → unusual but harmless, blue
        precount=$(read_precount)
        if [ "$precount" -le 0 ] && is_waiting; then
            log_msg "suppress event=PostToolUse reason=no-inflight-tools-and-waiting uuid=$MARKER_UUID"
            exit 0
        fi
        [ "$precount" -gt 0 ] && write_precount $(( precount - 1 ))
        set_tab_color "$PROCESS_COLOR"
        ;;
    Notification|Stop|PreToolUseWaitForUser)
        # User attention requested. Set the waiting marker; DO NOT touch
        # the precount — tools may still be in flight (e.g., Notification
        # mid-tool for a permission prompt). The PostToolUse rule above
        # uses the count to distinguish stray-vs-legit completion.
        #
        # PreToolUseWaitForUser front-runs the Notification event for
        # AskUserQuestion — by the time Claude actually displays the
        # question, the tab is already orange.
        set_waiting_marker
        set_tab_color "$WAIT_COLOR"
        ;;
esac
