#!/bin/bash
# iTerm2 Claude-Code-hook watchdog — runs periodically via a LaunchAgent
# (every 30s) as the outermost safety net.
#
# Purpose: keep tab colors correct even when Claude Code's hook chain stops
# firing entirely (e.g., a long-stuck tool call, a wedged Claude process, or
# any other scenario where Pre/PostToolUse events dry up). The bash hook
# itself fires per-event, and the daemon already self-reconciles every ~7s,
# but BOTH of those depend on something inside the session being alive.
# This watchdog runs from launchd, completely independent of Claude Code.
#
# Strategy:
#
#   1. If no .state files in the last 24h → nothing to do (no recent Claude
#      Code sessions on this machine). Exit fast.
#
#   2. If the daemon's PID is alive AND its heartbeat is fresh + OK → nothing
#      to do (the daemon is handling reconciliation already on its 7s
#      cadence). Exit fast.
#
#   3. Otherwise — daemon is missing, crashed, or marked DEAD:
#        a. Respawn the daemon (the next event would do this too, but we
#           can't wait for "next event" if events have stopped firing).
#        b. Fire Tier 2 (per-session one-shot Python) for each recent state
#           file as defense-in-depth — covers the gap between "daemon spawned"
#           and "daemon completes its first reconcile pass" (up to ~7s).
#
# The watchdog itself is dirt cheap (a few stats + file reads) on the no-op
# path, which is the steady state when everything is working. The expensive
# Python paths only fire when the daemon is actually down.

set -u

STATE_DIR="$HOME/.claude/hooks/.state"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
VENV_PYTHON="$HOME/.claude/hooks/iterm2-venv/bin/python"
DAEMON_SCRIPT="$HOME/.claude/hooks/iterm2-daemon.py"
ONESHOT_SCRIPT="$HOME/.claude/hooks/iterm2-apply-once.py"
LOG_FILE="$HOME/.claude/hooks/headsup-status.log"

# Kill switch — same convention as the hook itself.
[ -f "$HOME/.claude/hooks/.disabled" ] && exit 0

log_msg() {
    [ -f "$HOME/.claude/hooks/.debug" ] || return 0
    printf '%s watchdog %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 1. Bail unless there's at least one recent state file ────────────────
[ -d "$STATE_DIR" ] || exit 0
recent_state=$(find "$STATE_DIR" -maxdepth 1 -name '*.state' -mtime -1 2>/dev/null | head -1)
if [ -z "$recent_state" ]; then
    log_msg "nothing-to-do reason=no-recent-state"
    exit 0
fi

# ── 2. If daemon is healthy, do nothing ──────────────────────────────────
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
            if [ -n "$hb_int" ] && [ "$((now - hb_int))" -le 3 ]; then
                daemon_healthy=1
            fi
        fi
    fi
fi

if [ "$daemon_healthy" = "1" ]; then
    log_msg "nothing-to-do reason=daemon-healthy"
    # Daemon healthy → still run the wait-notifier sweep on this cadence.
    # It's cheap (a few stats + at most a `find -mmin`) and produces zero
    # output when no notifications are due, so it doesn't matter that we
    # take the "nothing to do" path here.
    [ -x "$HOME/.claude/hooks/headsup-notify-waiting.sh" ] && \
        "$HOME/.claude/hooks/headsup-notify-waiting.sh" 2>/dev/null || true
    exit 0
fi

# ── 3a. Respawn daemon ────────────────────────────────────────────────────
log_msg "daemon-respawn"
mkdir -p "$STATE_DIR" 2>/dev/null
if [ -x "$VENV_PYTHON" ] && [ -f "$DAEMON_SCRIPT" ]; then
    nohup "$VENV_PYTHON" "$DAEMON_SCRIPT" \
        >> "$STATE_DIR/daemon.stderr" 2>&1 < /dev/null &
    disown 2>/dev/null || true
fi

# ── 3b. Fire Tier 2 for each recent state file ───────────────────────────
# Covers the gap between "spawned daemon" and "daemon's first reconcile".
#
# Backpressure guard: NEVER pile a fresh batch on top of one that's still
# draining. Each one-shot is a ~33MB Python proc; if a previous batch is
# blocked on a contended iTerm2 API and we keep adding ~one-per-recent-state
# every 30s, it snowballs into hundreds of stuck procs that wedge iTerm2
# (and contend the API further, keeping the daemon heartbeat stale, which
# keeps us in this branch — a runaway loop). If the previous batch hasn't
# cleared, skip this round and let it drain; the respawned daemon (3a) is
# the real recovery path anyway.
if [ -x "$VENV_PYTHON" ] && [ -f "$ONESHOT_SCRIPT" ]; then
    inflight=$(pgrep -f "iterm2-apply-once.py" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${inflight:-0}" -gt 8 ]; then
        log_msg "tier2-skip reason=backlog inflight=$inflight"
        # Fall through to the wait-notifier sweep; do not fan out.
        [ -x "$HOME/.claude/hooks/headsup-notify-waiting.sh" ] && \
            "$HOME/.claude/hooks/headsup-notify-waiting.sh" 2>/dev/null || true
        exit 0
    fi
    find "$STATE_DIR" -maxdepth 1 -name '*.state' -mtime -1 2>/dev/null | while read -r f; do
        uuid=$(basename "$f" .state)
        content=$(cat "$f" 2>/dev/null | head -1)
        color=$(printf '%s' "$content" | awk '{print $1}')
        attention=$(printf '%s' "$content" | awk '{print $2}')
        [ -z "$attention" ] && attention=no
        # Skip malformed entries silently.
        if printf '%s' "$color" | grep -qE '^[0-9a-fA-F]{6}$' \
           && { [ "$attention" = "no" ] || [ "$attention" = "yes" ]; } \
           && [ -n "$uuid" ]; then
            log_msg "tier2-fire uuid=$uuid color=$color attention=$attention"
            nohup "$VENV_PYTHON" "$ONESHOT_SCRIPT" "$color" "$attention" "$uuid" \
                >/dev/null 2>&1 < /dev/null &
            disown 2>/dev/null || true
        fi
    done
fi

# ── 4. Run wait-notifier sweep ───────────────────────────────────────────
# Fires macOS notifications for any tab that's been waiting > THRESHOLD_MIN.
# Always runs (independent of daemon health) — even if the daemon is down,
# the user still wants to know Claude is waiting on them.
[ -x "$HOME/.claude/hooks/headsup-notify-waiting.sh" ] && \
    "$HOME/.claude/hooks/headsup-notify-waiting.sh" 2>/dev/null || true

exit 0
