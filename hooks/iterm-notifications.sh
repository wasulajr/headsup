#!/bin/bash
# iterm-notifications.sh — manage the wait-notifier config.
#
# Invoked by the /iterm-notifications skill. Edits
# ~/.claude/hooks/iterm-notifications.conf in place and prints the
# resulting state.
#
# Usage:
#   iterm-notifications.sh                — show current state
#   iterm-notifications.sh on             — enable notifications
#   iterm-notifications.sh off            — disable notifications
#   iterm-notifications.sh <N>            — set THRESHOLD_MIN to N
#   iterm-notifications.sh <N> on|off     — set threshold AND toggle
#   iterm-notifications.sh test           — fire a test notification now
#   iterm-notifications.sh sound <name>   — set NOTIFICATION_SOUND
#   iterm-notifications.sh sound none     — silence

set -u

CONFIG="$HOME/.claude/hooks/iterm-notifications.conf"

# Defaults if conf missing.
ENABLED=1
THRESHOLD_MIN=5
NOTIFICATION_SOUND="Glass"

if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

if [ -t 1 ]; then
    G=$'\033[32m' Y=$'\033[33m' DIM=$'\033[2m' RST=$'\033[0m'
else
    G='' Y='' DIM='' RST=''
fi

write_conf() {
    cat > "$CONFIG" <<EOF
# iTerm-notifications config — sourced by iterm-notify-waiting.sh.
#
# Edit via /iterm-notifications skill (recommended) or by hand. The
# launchd watchdog picks up changes on its next run (within 30s) — no
# restart needed.

# 1 = send a macOS notification when Claude has been waiting on the user
#     for longer than THRESHOLD_MIN minutes
# 0 = no notifications (the tab still goes orange, dock still bounces;
#     this just suppresses the OS notification banner)
ENABLED=$ENABLED

# Minutes Claude must be waiting before we notify. Watchdog cadence is
# 30s, so actual notification time is THRESHOLD_MIN + up to 30s.
THRESHOLD_MIN=$THRESHOLD_MIN

# Sound to play with the notification. Set to "" to silence. macOS
# system sound names: Basso, Blow, Bottle, Frog, Funk, Glass, Hero,
# Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink.
NOTIFICATION_SOUND="$NOTIFICATION_SOUND"
EOF
}

show_state() {
    if [ "$ENABLED" = "1" ]; then
        printf '  %s✓%s notifications enabled\n' "$G" "$RST"
    else
        printf '  %s✗%s notifications DISABLED\n' "$Y" "$RST"
    fi
    printf '  %sthreshold:%s %d minute(s)\n' "$DIM" "$RST" "$THRESHOLD_MIN"
    if [ -n "$NOTIFICATION_SOUND" ]; then
        printf '  %ssound:    %s%s\n' "$DIM" "$RST" "$NOTIFICATION_SOUND"
    else
        printf '  %ssound:    %ssilent\n' "$DIM" "$RST"
    fi
    printf '  %sconfig:   %s%s\n' "$DIM" "$RST" "$CONFIG"
}

fire_test() {
    # Mirror the live notifier's title/subtitle/body layout so the test
    # accurately previews what real notifications will look like. Use
    # the current tab's badge (or "test" as a placeholder) for the title.
    local label="test"
    if [ -n "${ITERM_SESSION_ID:-}" ]; then
        local uuid="${ITERM_SESSION_ID#*:}"
        local bf="$HOME/.claude/hooks/.state/${uuid}.badge"
        if [ -f "$bf" ]; then
            local b
            b=$(cat "$bf" 2>/dev/null | head -1)
            [ -n "$b" ] && label="$b"
        fi
    fi
    local script="display notification \"This is a test (no real waiting tab).\" with title \"$label\" subtitle \"Claude is waiting\""
    if [ -n "$NOTIFICATION_SOUND" ]; then
        script="$script sound name \"$NOTIFICATION_SOUND\""
    fi
    osascript -e "$script" 2>/dev/null && \
        printf '  %s✓%s test notification fired (check Notification Center)\n' "$G" "$RST" || \
        printf '  %s✗%s osascript failed — macOS may be blocking Script Editor notifications. Check System Settings → Notifications → Script Editor.\n' "$Y" "$RST"
}

# ── Arg parsing ───────────────────────────────────────────────────────────
# Forms:
#   (no args) → show state
#   "on" | "off" → set ENABLED, keep threshold
#   <N> → set THRESHOLD_MIN, keep ENABLED
#   <N> "on"|"off" → set both
#   "test" → send a test notification (does not modify config)
#   "sound" <name|none> → set NOTIFICATION_SOUND
changed=0
case "${1:-}" in
    "")
        show_state
        exit 0
        ;;
    test)
        fire_test
        exit 0
        ;;
    sound)
        if [ -z "${2:-}" ]; then
            echo "  usage: $(basename "$0") sound <name|none>" >&2
            exit 2
        fi
        if [ "$2" = "none" ] || [ "$2" = "off" ] || [ "$2" = "silent" ]; then
            NOTIFICATION_SOUND=""
        else
            NOTIFICATION_SOUND="$2"
        fi
        changed=1
        ;;
    on)
        ENABLED=1; changed=1
        ;;
    off)
        ENABLED=0; changed=1
        ;;
    [0-9]*)
        # Threshold (and optional on/off)
        if [ "$1" -lt 1 ] 2>/dev/null; then
            echo "  threshold must be a positive integer (minutes)" >&2
            exit 2
        fi
        THRESHOLD_MIN="$1"
        changed=1
        case "${2:-}" in
            on)  ENABLED=1 ;;
            off) ENABLED=0 ;;
            "")  : ;;
            *)   echo "  second arg (if given) must be 'on' or 'off'" >&2; exit 2 ;;
        esac
        ;;
    *)
        cat >&2 <<EOF
  unknown command: $1

  usage:
    iterm-notifications.sh                — show current state
    iterm-notifications.sh on             — enable
    iterm-notifications.sh off            — disable
    iterm-notifications.sh <N>            — set threshold to N minutes
    iterm-notifications.sh <N> on|off     — set threshold + toggle
    iterm-notifications.sh test           — fire a test notification
    iterm-notifications.sh sound <name>   — set sound (or "none")
EOF
        exit 2
        ;;
esac

if [ "$changed" = "1" ]; then
    write_conf
    printf '  %s✓%s updated %s\n\n' "$G" "$RST" "$CONFIG"
    show_state
fi
