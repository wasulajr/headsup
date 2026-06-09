#!/bin/bash
# Force-apply a headsup Codex tab state to an iTerm2 session.

set -eu

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
export HEADSUP_HOOK_DIR="$HOOK_DIR"
export HEADSUP_STATE_DIR="$STATE_DIR"

UUID_ARG="${1:-}"
if [ -n "$UUID_ARG" ]; then
    UUID="${UUID_ARG#*:}"
else
    SESSION_FROM_ENV=""
    pid="$PPID"
    for _ in 1 2 3 4 5 6; do
        [ -z "$pid" ] && break; [ "$pid" = "0" ] && break; [ "$pid" = "1" ] && break
        candidate=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | head -1 | cut -d= -f2-)
        if [ -n "$candidate" ]; then
            SESSION_FROM_ENV="$candidate"
            break
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")
    done
    [ -z "$SESSION_FROM_ENV" ] && SESSION_FROM_ENV="${ITERM_SESSION_ID:-}"
    if [ -z "$SESSION_FROM_ENV" ]; then
        echo "headsup-codex-resync: ITERM_SESSION_ID not found in any ancestor shell" >&2
        exit 1
    fi
    UUID="${SESSION_FROM_ENV#*:}"
fi
[ -n "$UUID" ] || { echo "headsup-codex-resync: empty UUID after parsing" >&2; exit 1; }

PROCESS_COLOR="3a82f5"
IDLE_COLOR="ffffff"
WAIT_COLOR="e67e22"
CONFIG_FILE="$HOOK_DIR/headsup-status.conf"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true

COLOR="${2:-$PROCESS_COLOR}"
ATTENTION="${3:-no}"

if ! printf '%s' "$COLOR" | grep -qE '^[0-9a-fA-F]{6}$'; then
    echo "headsup-codex-resync: color must be 6-char hex, got '$COLOR'" >&2
    exit 1
fi
if [ "$ATTENTION" != "no" ] && [ "$ATTENTION" != "yes" ]; then
    echo "headsup-codex-resync: attention must be 'no' or 'yes', got '$ATTENTION'" >&2
    exit 1
fi

mkdir -p "$STATE_DIR" 2>/dev/null
TMP="$STATE_DIR/.${UUID}.tmp.$$"
FINAL="$STATE_DIR/${UUID}.state"
printf '%s %s\n' "$COLOR" "$ATTENTION" > "$TMP"
mv "$TMP" "$FINAL"

VENV_PYTHON="$HOOK_DIR/iterm2-venv/bin/python"
ONESHOT_SCRIPT="$HOOK_DIR/iterm2-apply-once.py"
if [ -x "$VENV_PYTHON" ] && [ -f "$ONESHOT_SCRIPT" ]; then
    nohup "$VENV_PYTHON" "$ONESHOT_SCRIPT" "$COLOR" "$ATTENTION" "$UUID" \
        >> "$STATE_DIR/oneshot.stderr" 2>&1 < /dev/null &
    disown 2>/dev/null || true
fi

LOG_FILE="$STATE_ROOT/headsup-status.log"
if [ -f "$HOOK_DIR/.debug" ]; then
    printf '%s codex-resync color=%s attention=%s uuid=%s\n' \
        "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" \
        "$COLOR" "$ATTENTION" "$UUID" >> "$LOG_FILE" 2>/dev/null || true
fi

printf 'resynced %s -> %s %s\n' "${UUID:0:8}" "$COLOR" "$ATTENTION"
