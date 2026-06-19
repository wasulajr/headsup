#!/bin/bash
# headsup-notify-waiting.sh — fire a macOS notification when a Claude tab
# has been in the orange (waiting) state for longer than THRESHOLD_MIN
# minutes without the user responding.
#
# Called from the launchd watchdog (every 30s). Reads
# ~/.claude/hooks/headsup-notifications.conf for ENABLED and
# THRESHOLD_MIN. Idempotent: tracks per-session `.notified` markers so
# each wait period notifies at most once.
#
# State file mtime is the source-of-truth for "how long Claude has been
# waiting" — the daemon's reconciliation sweep reads the state file but
# never writes it, so its mtime is exactly the timestamp of the last
# bash hook event.
#
# .notified marker lifecycle:
#   - touched when we fire a notification for a session
#   - if .notified is OLDER than .state, we treat it as stale (the wait
#     state restarted) and fire a new notification
#   - cleaned up by the daemon's GC sweep alongside the other sidecars

set -u

STATE_DIR="$HOME/.claude/hooks/.state"
CONFIG="$HOME/.claude/hooks/headsup-notifications.conf"
LOG_FILE="$HOME/.claude/hooks/headsup-status.log"
DEBUG_FLAG="$HOME/.claude/hooks/.debug"
DISABLED_FLAG="$HOME/.claude/hooks/.disabled"
STATUS_CONFIG="$HOME/.claude/hooks/headsup-status.conf"

# Kill switch — same convention as the main hook.
[ -f "$DISABLED_FLAG" ] && exit 0

# Defaults if conf is missing (preserves behavior if user uninstalled it).
ENABLED=1
THRESHOLD_MIN=5
NOTIFICATION_SOUND="Glass"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG" 2>/dev/null

[ "$ENABLED" = "1" ] || exit 0

# Need to know which hex = "waiting" to identify orange state files.
# Default to the documented WAIT_COLOR; honor the user's headsup-status.conf
# override if present.
WAIT_COLOR="e67e22"
# shellcheck source=/dev/null
[ -f "$STATUS_CONFIG" ] && source "$STATUS_CONFIG" 2>/dev/null

log_msg() {
    [ -f "$DEBUG_FLAG" ] || return 0
    printf '%s notifier %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# Path to the bundled headsup-notifier.app, installed by setup.sh.
# Posting notifications from inside this bundle is the only reliable way
# to get OUR icon to render in macOS Notification Center — terminal-
# notifier's -appIcon and osascript both ignore custom icons since
# macOS Big Sur.
NOTIFIER_BIN="$HOME/Library/Application Support/headsup/headsup-notifier.app/Contents/MacOS/headsup-notifier"

# Fire a macOS notification. Uses the bundled headsup-notifier (Swift
# binary that calls UNUserNotificationCenter from inside our .app
# bundle) so notifications carry our icon. Falls back to osascript
# (Script Editor icon, no custom icon) if the notifier isn't installed.
#
# macOS displays the three slots as:
#   title    — bold first line (the most prominent piece)
#   subtitle — smaller bold second line
#   body     — regular text third line
fire_notification() {
    local title="$1" subtitle="$2" body="$3" group_id="${4:-default}"
    if [ -x "$NOTIFIER_BIN" ]; then
        "$NOTIFIER_BIN" "$title" "$subtitle" "$body" "$group_id" >/dev/null 2>&1 || true
        return
    fi
    # Fallback: osascript (Script Editor icon, NOTIFICATION_SOUND only)
    local script="display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\""
    if [ -n "$subtitle" ]; then
        script="$script subtitle \"${subtitle//\"/\\\"}\""
    fi
    if [ -n "$NOTIFICATION_SOUND" ]; then
        script="$script sound name \"${NOTIFICATION_SOUND//\"/\\\"}\""
    fi
    osascript -e "$script" 2>/dev/null || true
}

# Resolve a friendly name for a session UUID — uses the per-session
# badge sidecar if the bash hook wrote one at SessionStart, falls back
# to the short UUID.
session_label() {
    local uuid="$1"
    local badge_file="$STATE_DIR/${uuid}.badge"
    if [ -f "$badge_file" ]; then
        local b
        b=$(cat "$badge_file" 2>/dev/null | head -1)
        if [ -n "$b" ]; then
            printf '%s' "$b"
            return
        fi
    fi
    printf '%s' "${uuid:0:8}"
}

[ -d "$STATE_DIR" ] || exit 0

VENV_PYTHON="$HOME/.claude/hooks/iterm2-venv/bin/python"

# find -mmin +N matches files whose mtime is older than N minutes.
# Gather candidates up front so we resolve liveness at most once per sweep.
candidates=$(find "$STATE_DIR" -maxdepth 1 -name '*.state' -mmin "+$THRESHOLD_MIN" 2>/dev/null)
[ -z "$candidates" ] && exit 0

# ── Liveness gate ─────────────────────────────────────────────────────────
# A window closed while Claude was in the orange "waiting" state leaves a
# stale .state whose mtime never advances, so without this check the sweep
# fires a ghost "Claude is waiting" notification for a tab that no longer
# exists. Resolve the set of live iTerm2 sessions and, in the loop, skip +
# reap any candidate that isn't live. Use the iTerm2 Python API: osascript
# session enumeration is unreliable on some setups, and the API reports the
# same session_id that keys the .state files. Runs at most once per sweep
# and only when a candidate exists, so the sub-second call never touches the
# steady-state (nothing-waiting) path. The SIGALRM cap keeps a wedged API
# from stalling the 30s watchdog. If we can't reach the API we cannot prove
# a session is dead, so we fall back to firing (old behavior) rather than
# risk suppressing a real notification.
LIVE_SESSIONS=""
LIVENESS_KNOWN=0
if [ -x "$VENV_PYTHON" ]; then
    LIVE_SESSIONS=$("$VENV_PYTHON" - <<'PY' 2>/dev/null
import signal, os, iterm2
def _bail(*_): os._exit(3)
signal.signal(signal.SIGALRM, _bail); signal.alarm(10)
async def main(c):
    app = await iterm2.async_get_app(c)
    # Without an explicit refresh app.windows can come back empty right
    # after connect; that false "zero sessions" would make us reap/suppress
    # live tabs. Refresh, and if we still enumerate zero, exit 2 (no "OK")
    # so bash treats liveness as unknown and falls back to firing.
    try:
        await app.async_refresh()
    except Exception:
        pass
    ids = [s.session_id for w in app.windows for t in w.tabs for s in t.sessions]
    if not ids:
        os._exit(2)
    print("OK")
    for i in ids:
        print(i)
try:
    iterm2.run_until_complete(main, retry=False)
except SystemExit:
    raise
except BaseException:
    os._exit(1)
PY
)
    # A leading "OK" line means we enumerated successfully (even if zero
    # sessions); anything else (connect failure / timeout) leaves liveness
    # unknown and we fall back to firing.
    if [ "$(printf '%s\n' "$LIVE_SESSIONS" | head -1)" = "OK" ]; then
        LIVENESS_KNOWN=1
        LIVE_SESSIONS=$(printf '%s\n' "$LIVE_SESSIONS" | tail -n +2)
    fi
fi

# Remove every sidecar marker for a closed session so stale state can't
# re-trigger and the .state dir self-cleans over time.
reap_markers() {
    local u="$1"
    rm -f "$STATE_DIR/$u.state" "$STATE_DIR/$u.waiting" "$STATE_DIR/$u.notified" \
          "$STATE_DIR/$u.badge" "$STATE_DIR/$u.precount" 2>/dev/null || true
}

notify_count=0
while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    uuid=$(basename "$state_file" .state)

    # Liveness gate — if we know the live set and this session isn't in it,
    # it's a closed tab: reap its stale markers and never notify for it.
    if [ "$LIVENESS_KNOWN" = "1" ] && ! printf '%s\n' "$LIVE_SESSIONS" | grep -qxF "$uuid"; then
        reap_markers "$uuid"
        log_msg "skip+reaped uuid=$uuid reason=not-live"
        continue
    fi

    # Color check — only orange state files trigger notifications.
    state_content=$(cat "$state_file" 2>/dev/null | head -1)
    color=$(printf '%s' "$state_content" | awk '{print $1}')
    [ "$color" = "$WAIT_COLOR" ] || continue

    # Already-notified check: skip if .notified exists AND is newer than
    # .state (we've already notified for this wait period). If state was
    # written more recently, the wait period restarted → re-notify.
    notified_file="$STATE_DIR/${uuid}.notified"
    if [ -f "$notified_file" ] && [ ! "$state_file" -nt "$notified_file" ]; then
        continue
    fi

    label=$(session_label "$uuid")
    # Three-slot layout — put the project/badge in the bold title so it's
    # the first thing the user sees:
    #   title:    <badge>            (e.g., "headsup")
    #   subtitle: Claude is waiting
    #   body:     Idle for over <N>m
    fire_notification \
        "$label" \
        "Claude is waiting" \
        "Idle for over ${THRESHOLD_MIN}m" \
        "$uuid"
    : > "$notified_file" 2>/dev/null || true
    log_msg "notified uuid=$uuid label=$label threshold_min=$THRESHOLD_MIN"
    notify_count=$((notify_count + 1))
done < <(printf '%s\n' "$candidates")

[ "$notify_count" -gt 0 ] && log_msg "sweep fired=$notify_count threshold_min=$THRESHOLD_MIN"
exit 0
