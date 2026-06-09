#!/bin/bash
# Set or clear the headsup label for this Codex iTerm2 session.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
CONF_DIR="$HOOK_DIR/headsup-status.d"

if [ -z "${ITERM_SESSION_ID:-}" ]; then
    echo "headsup-codex-set-label: ITERM_SESSION_ID unset (not inside iTerm2?) — label skipped" >&2
    exit 0
fi

SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
UUID="${ITERM_SESSION_ID##*:}"

apply_osc() {
    local badge_b64 out pid tty
    badge_b64=$(printf '%s' "$1" | base64)
    if [ -t 1 ]; then
        printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$badge_b64" "$2"
        return 0
    fi
    pid=$$
    while [ -n "$pid" ] && [ "$pid" != "1" ]; do
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$tty" ] && [ "$tty" != "??" ] && [ -w "/dev/$tty" ]; then
            out="/dev/$tty"
            printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$badge_b64" "$2" > "$out"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo "headsup-codex-set-label: no tty found — label saved, tab updates on the next hook event" >&2
    return 1
}

if [ "${1:-}" = "--clear" ]; then
    rm -f "$CONF_DIR/${SESSION_KEY}.conf" "$STATE_DIR/${UUID}.badge"
    headsup_badge_text() { basename "$PWD"; }
    headsup_title_text() { printf 'Codex · %s' "$1"; }
    [ -f "$HOOK_DIR/headsup-status.conf" ] && . "$HOOK_DIR/headsup-status.conf"
    headsup_title_text() { printf 'Codex · %s' "$1"; }
    BADGE=$(headsup_badge_text)
    TITLE=$(headsup_title_text "$BADGE")
    apply_osc "$BADGE" "$TITLE"
    echo "headsup-codex-set-label: per-session label cleared — reverted to '$TITLE'"
    exit 0
fi

LABEL="$*"
[ -n "$LABEL" ] || exit 0

mkdir -p "$CONF_DIR" "$STATE_DIR"
ESCAPED=$(printf '%s' "$LABEL" | sed "s/'/'\\\\''/g")
cat > "$CONF_DIR/${SESSION_KEY}.conf" <<EOF
# Per-iTerm2-session override for this Codex pane.
# Written by headsup-codex-set-label.sh. Local-only.

headsup_badge_text() { printf '%s' '$ESCAPED'; }
headsup_title_text() { printf '%s' '$ESCAPED'; }
EOF

printf '%s\n' "$LABEL" > "$STATE_DIR/${UUID}.badge"
apply_osc "$LABEL" "$LABEL"
echo "headsup-codex-set-label: label set to '$LABEL'"
