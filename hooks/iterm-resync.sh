#!/bin/bash
# iTerm2 tab-color resync — external entry point that force-applies the
# desired state to a session, bypassing Claude Code's automatic hook
# chain. Designed for two callers:
#
#   1. The /resync-tab skill — user-invoked when a tab has drifted out of
#      sync (e.g., stuck orange when Claude is actively processing).
#
#   2. Claude itself, run automatically at the start of each response
#      (per the master memory's banner protocol) as belt-and-suspenders
#      coverage for the current tab.
#
# Bypasses iterm-status.sh's event-driven path because that path depends
# on Claude Code firing PreToolUse/PostToolUse/etc. — which is the very
# thing that goes stale in long-running sessions. We write the state file
# DIRECTLY and fire Tier 2 (one-shot Python) regardless of daemon state.
#
# Usage:
#   iterm-resync.sh                 — resync current tab (resolves
#                                     ITERM_SESSION_ID from parent shell)
#   iterm-resync.sh <UUID>          — resync a specific tab by its iTerm2
#                                     session UUID (with or without the
#                                     `wXtYpZ:` prefix)
#   iterm-resync.sh <UUID> <color>  — force a specific color (6-char hex)
#   iterm-resync.sh <UUID> <color> <attention>
#                                     — force a specific (color, attention) pair

set -eu

# ── 1. Resolve target UUID ────────────────────────────────────────────────
UUID_ARG="${1:-}"
if [ -n "$UUID_ARG" ]; then
    UUID="${UUID_ARG#*:}"
else
    # The skill (and Claude itself) doesn't have ITERM_SESSION_ID directly
    # in its env — it lives on the iTerm2-spawned shell up the process
    # tree. Walk PPID until we find one.
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
    if [ -z "$SESSION_FROM_ENV" ]; then
        SESSION_FROM_ENV="${ITERM_SESSION_ID:-}"
    fi
    if [ -z "$SESSION_FROM_ENV" ]; then
        echo "iterm-resync: ITERM_SESSION_ID not found in any ancestor shell" >&2
        exit 1
    fi
    UUID="${SESSION_FROM_ENV#*:}"
fi
if [ -z "$UUID" ]; then
    echo "iterm-resync: empty UUID after parsing" >&2
    exit 1
fi

# ── 2. Resolve desired (color, attention) ─────────────────────────────────
# Default: "Claude is processing" (since this script is most often called
# while Claude is actively doing work). Caller can override via args 2-3.
PROCESS_COLOR="3a82f5"
IDLE_COLOR="ffffff"
WAIT_COLOR="ffcc00"

CONFIG_FILE="$HOME/.claude/hooks/iterm-status.conf"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true

COLOR="${2:-$PROCESS_COLOR}"
ATTENTION="${3:-no}"

# Basic validation — fail fast if a caller passes garbage.
if ! printf '%s' "$COLOR" | grep -qE '^[0-9a-fA-F]{6}$'; then
    echo "iterm-resync: color must be 6-char hex, got '$COLOR'" >&2
    exit 1
fi
if [ "$ATTENTION" != "no" ] && [ "$ATTENTION" != "yes" ]; then
    echo "iterm-resync: attention must be 'no' or 'yes', got '$ATTENTION'" >&2
    exit 1
fi

# ── 3. Write state file (Tier 1 path — daemon will pick it up) ────────────
STATE_DIR="$HOME/.claude/hooks/.state"
mkdir -p "$STATE_DIR" 2>/dev/null
TMP="$STATE_DIR/.${UUID}.tmp.$$"
FINAL="$STATE_DIR/${UUID}.state"
printf '%s %s\n' "$COLOR" "$ATTENTION" > "$TMP"
mv "$TMP" "$FINAL"

# ── 4. Fire Tier 2 unconditionally (defense in depth) ─────────────────────
# Unlike iterm-status.sh which only fires Tier 2 when the daemon heartbeat
# is stale, this script ALWAYS fires Tier 2 because it's the "manual
# override" path — we don't trust the daemon when the caller is invoking
# us. ~440ms cost; runs async, doesn't block.
VENV_PYTHON="$HOME/.claude/hooks/iterm2-venv/bin/python"
ONESHOT_SCRIPT="$HOME/.claude/hooks/iterm2-apply-once.py"
if [ -x "$VENV_PYTHON" ] && [ -f "$ONESHOT_SCRIPT" ]; then
    nohup "$VENV_PYTHON" "$ONESHOT_SCRIPT" "$COLOR" "$ATTENTION" "$UUID" \
        >> "$STATE_DIR/oneshot.stderr" 2>&1 < /dev/null &
    disown 2>/dev/null || true
fi

# Debug log — same file iterm-status.sh writes to.
LOG_FILE="$HOME/.claude/hooks/iterm-status.log"
if [ -f "$HOME/.claude/hooks/.debug" ]; then
    printf '%s sh resync color=%s attention=%s uuid=%s\n' \
        "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" \
        "$COLOR" "$ATTENTION" "$UUID" >> "$LOG_FILE" 2>/dev/null || true
fi

printf 'resynced %s → %s %s\n' "${UUID:0:8}" "$COLOR" "$ATTENTION"
