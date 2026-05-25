#!/bin/bash
# iterm-notify-waiting.sh — fire a macOS notification when a Claude tab
# has been in the orange (waiting) state for longer than THRESHOLD_MIN
# minutes without the user responding.
#
# Called from the launchd watchdog (every 30s). Reads
# ~/.claude/hooks/iterm-notifications.conf for ENABLED and
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
CONFIG="$HOME/.claude/hooks/iterm-notifications.conf"
LOG_FILE="$HOME/.claude/hooks/iterm-status.log"
DEBUG_FLAG="$HOME/.claude/hooks/.debug"
DISABLED_FLAG="$HOME/.claude/hooks/.disabled"
STATUS_CONFIG="$HOME/.claude/hooks/iterm-status.conf"

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
# Default to the documented WAIT_COLOR; honor the user's iterm-status.conf
# override if present.
WAIT_COLOR="e67e22"
# shellcheck source=/dev/null
[ -f "$STATUS_CONFIG" ] && source "$STATUS_CONFIG" 2>/dev/null

log_msg() {
    [ -f "$DEBUG_FLAG" ] || return 0
    printf '%s notifier %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# Fire a macOS notification via osascript. First time per user, macOS
# will prompt them to allow notifications from "Script Editor"; after
# that it's silent. macOS displays the three slots as:
#   title    — bold first line (the most prominent piece)
#   subtitle — smaller bold second line
#   body     — regular text third line
fire_notification() {
    local title="$1" subtitle="$2" body="$3"
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

# find -mmin +N matches files whose mtime is older than N minutes.
# Iterate those candidates rather than scanning all state files.
notify_count=0
while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    uuid=$(basename "$state_file" .state)

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
    #   title:    <badge>            (e.g., "iterm-config")
    #   subtitle: Claude is waiting
    #   body:     Idle for over <N>m
    fire_notification \
        "$label" \
        "Claude is waiting" \
        "Idle for over ${THRESHOLD_MIN}m"
    : > "$notified_file" 2>/dev/null || true
    log_msg "notified uuid=$uuid label=$label threshold_min=$THRESHOLD_MIN"
    notify_count=$((notify_count + 1))
done < <(find "$STATE_DIR" -maxdepth 1 -name '*.state' -mmin "+$THRESHOLD_MIN" 2>/dev/null)

[ "$notify_count" -gt 0 ] && log_msg "sweep fired=$notify_count threshold_min=$THRESHOLD_MIN"
exit 0
