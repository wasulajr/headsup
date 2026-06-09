#!/bin/bash
# Manage Codex wait-notification config.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
CONFIG="$HOOK_DIR/headsup-notifications.conf"

ENABLED=1
THRESHOLD_MIN=5
NOTIFICATION_SOUND="Glass"
[ -f "$CONFIG" ] && source "$CONFIG"

if [ -t 1 ]; then
    G=$'\033[32m' Y=$'\033[33m' DIM=$'\033[2m' RST=$'\033[0m'
else
    G='' Y='' DIM='' RST=''
fi

write_conf() {
    mkdir -p "$HOOK_DIR"
    cat > "$CONFIG" <<EOF
# iTerm-notifications config for headsup Codex.
# Edit via the headsup-notifications skill or by hand.

ENABLED=$ENABLED
THRESHOLD_MIN=$THRESHOLD_MIN
NOTIFICATION_SOUND="$NOTIFICATION_SOUND"
EOF
}

show_state() {
    if [ "$ENABLED" = "1" ]; then
        printf '  %s✓%s notifications enabled\n' "$G" "$RST"
    else
        printf '  %s!%s notifications DISABLED\n' "$Y" "$RST"
    fi
    printf '  %sthreshold:%s %d minute(s)\n' "$DIM" "$RST" "$THRESHOLD_MIN"
    if [ -n "$NOTIFICATION_SOUND" ]; then
        printf '  %ssound:    %s%s\n' "$DIM" "$RST" "$NOTIFICATION_SOUND"
    else
        printf '  %ssound:    %ssilent\n' "$DIM" "$RST"
    fi
    printf '  %sconfig:   %s%s\n' "$DIM" "$RST" "$CONFIG"
}

session_label() {
    local uuid="$1" badge_file="$STATE_DIR/${uuid}.badge" b
    if [ -f "$badge_file" ]; then
        b=$(cat "$badge_file" 2>/dev/null | head -1)
        [ -n "$b" ] && { printf '%s' "$b"; return; }
    fi
    printf 'Codex'
}

fire_test() {
    local uuid="default" label="Codex" body="This is a test (no real waiting tab)."
    if [ -n "${ITERM_SESSION_ID:-}" ]; then
        uuid="${ITERM_SESSION_ID#*:}"
        label=$(session_label "$uuid")
    fi
    local notifier="$HOME/Library/Application Support/headsup/headsup-notifier.app/Contents/MacOS/headsup-notifier"
    if [ -x "$notifier" ]; then
        "$notifier" "$label" "Codex is waiting" "$body" "headsup-codex-test-$uuid" >/dev/null 2>&1 || true
        printf '  %s✓%s test notification fired via headsup-notifier\n' "$G" "$RST"
        return
    fi
    local script="display notification \"$body\" with title \"$label\" subtitle \"Codex is waiting\""
    [ -n "$NOTIFICATION_SOUND" ] && script="$script sound name \"$NOTIFICATION_SOUND\""
    if osascript -e "$script" 2>/dev/null; then
        printf '  %s✓%s test notification fired via osascript\n' "$G" "$RST"
    else
        printf '  %s!%s osascript failed — check macOS notification permissions\n' "$Y" "$RST"
    fi
}

changed=0
case "${1:-}" in
    "")
        show_state; exit 0 ;;
    test)
        fire_test; exit 0 ;;
    sound)
        [ -n "${2:-}" ] || { echo "  usage: $(basename "$0") sound <name|none>" >&2; exit 2; }
        case "$2" in none|off|silent) NOTIFICATION_SOUND="" ;; *) NOTIFICATION_SOUND="$2" ;; esac
        changed=1 ;;
    on)
        ENABLED=1; changed=1 ;;
    off)
        ENABLED=0; changed=1 ;;
    [0-9]*)
        if [ "$1" -lt 1 ] 2>/dev/null; then
            echo "  threshold must be a positive integer (minutes)" >&2
            exit 2
        fi
        THRESHOLD_MIN="$1"; changed=1
        case "${2:-}" in on) ENABLED=1 ;; off) ENABLED=0 ;; "") : ;; *) echo "  second arg must be 'on' or 'off'" >&2; exit 2 ;; esac
        ;;
    *)
        cat >&2 <<EOF
  unknown command: $1

  usage:
    headsup-codex-notifications.sh
    headsup-codex-notifications.sh on|off
    headsup-codex-notifications.sh <N> [on|off]
    headsup-codex-notifications.sh test
    headsup-codex-notifications.sh sound <name|none>
EOF
        exit 2 ;;
esac

if [ "$changed" = "1" ]; then
    write_conf
    printf '  %s✓%s updated %s\n\n' "$G" "$RST" "$CONFIG"
    show_state
fi
