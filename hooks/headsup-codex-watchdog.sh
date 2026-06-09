#!/bin/bash
# Periodic safety net for headsup Codex iTerm2 state.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
VENV_PYTHON="$HOOK_DIR/iterm2-venv/bin/python"
DAEMON_SCRIPT="$HOOK_DIR/iterm2-daemon.py"
ONESHOT_SCRIPT="$HOOK_DIR/iterm2-apply-once.py"
LOG_FILE="$STATE_ROOT/headsup-status.log"
export HEADSUP_HOOK_DIR="$HOOK_DIR"
export HEADSUP_STATE_DIR="$STATE_DIR"

[ -f "$HOOK_DIR/.disabled" ] && exit 0

log_msg() {
    [ -f "$HOOK_DIR/.debug" ] || return 0
    printf '%s codex-watchdog %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

recent_state=$(find "$STATE_DIR" -maxdepth 1 -name '*.state' -mtime -1 2>/dev/null | head -1)
if [ -z "$recent_state" ]; then
    log_msg "nothing-to-do reason=no-recent-state"
    [ -x "$HOOK_DIR/headsup-codex-notify-waiting.sh" ] && "$HOOK_DIR/headsup-codex-notify-waiting.sh" 2>/dev/null || true
    exit 0
fi

daemon_healthy=0
if [ -f "$PID_FILE" ] && [ -f "$HEARTBEAT_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1)
        hb_ts=$(printf '%s' "$hb" | awk '{print $1}')
        hb_status=$(printf '%s' "$hb" | awk '{print $2}')
        if [ -n "$hb_ts" ] && { [ -z "$hb_status" ] || [ "$hb_status" = "OK" ]; }; then
            now=$(date +%s)
            hb_int="${hb_ts%.*}"
            [ -n "$hb_int" ] && [ "$((now - hb_int))" -le 3 ] && daemon_healthy=1
        fi
    fi
fi

if [ "$daemon_healthy" = "1" ]; then
    log_msg "nothing-to-do reason=daemon-healthy"
    [ -x "$HOOK_DIR/headsup-codex-notify-waiting.sh" ] && "$HOOK_DIR/headsup-codex-notify-waiting.sh" 2>/dev/null || true
    exit 0
fi

log_msg "daemon-respawn"
if [ -x "$VENV_PYTHON" ] && [ -f "$DAEMON_SCRIPT" ]; then
    nohup "$VENV_PYTHON" "$DAEMON_SCRIPT" >> "$STATE_DIR/daemon.stderr" 2>&1 < /dev/null &
    disown 2>/dev/null || true
fi

if [ -x "$VENV_PYTHON" ] && [ -f "$ONESHOT_SCRIPT" ]; then
    find "$STATE_DIR" -maxdepth 1 -name '*.state' -mtime -1 2>/dev/null | while read -r f; do
        uuid=$(basename "$f" .state)
        content=$(cat "$f" 2>/dev/null | head -1)
        color=$(printf '%s' "$content" | awk '{print $1}')
        attention=$(printf '%s' "$content" | awk '{print $2}')
        [ -z "$attention" ] && attention=no
        if printf '%s' "$color" | grep -qE '^[0-9a-fA-F]{6}$' \
           && { [ "$attention" = "no" ] || [ "$attention" = "yes" ]; } \
           && [ -n "$uuid" ]; then
            log_msg "tier2-fire uuid=$uuid color=$color attention=$attention"
            nohup "$VENV_PYTHON" "$ONESHOT_SCRIPT" "$color" "$attention" "$uuid" \
                >> "$STATE_DIR/oneshot.stderr" 2>&1 < /dev/null &
            disown 2>/dev/null || true
        fi
    done
fi

[ -x "$HOOK_DIR/headsup-codex-notify-waiting.sh" ] && "$HOOK_DIR/headsup-codex-notify-waiting.sh" 2>/dev/null || true
