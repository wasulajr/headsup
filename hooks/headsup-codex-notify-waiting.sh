#!/bin/bash
# Fire macOS notifications for Codex tabs waiting longer than threshold.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
CONFIG="$HOOK_DIR/headsup-notifications.conf"
STATUS_CONFIG="$HOOK_DIR/headsup-status.conf"
LOG_FILE="$STATE_ROOT/headsup-status.log"

[ -f "$HOOK_DIR/.disabled" ] && exit 0

ENABLED=1
THRESHOLD_MIN=5
NOTIFICATION_SOUND="Glass"
[ -f "$CONFIG" ] && source "$CONFIG" 2>/dev/null
[ "$ENABLED" = "1" ] || exit 0

WAIT_COLOR="e67e22"
[ -f "$STATUS_CONFIG" ] && source "$STATUS_CONFIG" 2>/dev/null

log_msg() {
    [ -f "$HOOK_DIR/.debug" ] || return 0
    printf '%s codex-notifier %s\n' "$(date -u '+%FT%T.%3NZ' 2>/dev/null || date -u '+%FT%TZ')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

fire_notification() {
    local title="$1" subtitle="$2" body="$3" group_id="${4:-default}"
    local notifier="$HOME/Library/Application Support/headsup/headsup-notifier.app/Contents/MacOS/headsup-notifier"
    if [ -x "$notifier" ]; then
        "$notifier" "$title" "$subtitle" "$body" "codex-$group_id" >/dev/null 2>&1 || true
        return
    fi
    local script="display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\""
    [ -n "$subtitle" ] && script="$script subtitle \"${subtitle//\"/\\\"}\""
    [ -n "$NOTIFICATION_SOUND" ] && script="$script sound name \"${NOTIFICATION_SOUND//\"/\\\"}\""
    osascript -e "$script" 2>/dev/null || true
}

session_label() {
    local uuid="$1" badge_file="$STATE_DIR/${uuid}.badge" b
    if [ -f "$badge_file" ]; then
        b=$(cat "$badge_file" 2>/dev/null | head -1)
        [ -n "$b" ] && { printf '%s' "$b"; return; }
    fi
    printf '%s' "${uuid:0:8}"
}

[ -d "$STATE_DIR" ] || exit 0

notify_count=0
while IFS= read -r state_file; do
    [ -f "$state_file" ] || continue
    uuid=$(basename "$state_file" .state)
    state_content=$(cat "$state_file" 2>/dev/null | head -1)
    color=$(printf '%s' "$state_content" | awk '{print $1}')
    [ "$color" = "$WAIT_COLOR" ] || continue

    notified_file="$STATE_DIR/${uuid}.notified"
    if [ -f "$notified_file" ] && [ ! "$state_file" -nt "$notified_file" ]; then
        continue
    fi

    label=$(session_label "$uuid")
    fire_notification "$label" "Codex is waiting" "Idle for over ${THRESHOLD_MIN}m" "$uuid"
    : > "$notified_file" 2>/dev/null || true
    log_msg "notified uuid=$uuid label=$label threshold_min=$THRESHOLD_MIN"
    notify_count=$((notify_count + 1))
done < <(find "$STATE_DIR" -maxdepth 1 -name '*.state' -mmin "+$THRESHOLD_MIN" 2>/dev/null)

[ "$notify_count" -gt 0 ] && log_msg "sweep fired=$notify_count threshold_min=$THRESHOLD_MIN"
