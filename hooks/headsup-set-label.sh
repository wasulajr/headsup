#!/bin/bash
# headsup-set-label.sh — set the headsup per-session label (iTerm2 badge +
# window/tab title) from INSIDE the target iTerm2 session.
#
# Usage: headsup-set-label.sh <label...>
#
# Designed to run in a freshly opened iTerm2 tab before `claude` launches
# (the "New Claude Tab" Finder Quick Action calls it — see the
# headsup-new-tab-shortcut skill), but works any time you're inside an
# iTerm2 pane. Writes the same per-session override that /headsup-label
# manages:
#   ~/.claude/hooks/headsup-status.d/<session-key>.conf  (sourced by headsup-status.sh)
#   ~/.claude/hooks/.state/<uuid>.badge                  (read by the waiting notifier)
# then applies the badge + title immediately via OSC escapes on stdout
# (no tty walk needed — when run inside the session, stdout IS the tty).
#
# Always exits 0 so callers can safely chain `... && claude`.

LABEL="$*"
[ -n "$LABEL" ] || exit 0
if [ -z "${ITERM_SESSION_ID:-}" ]; then
    echo "headsup-set-label: ITERM_SESSION_ID unset (not inside iTerm2?) — label skipped" >&2
    exit 0
fi

SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
UUID="${ITERM_SESSION_ID##*:}"
CONF_DIR="$HOME/.claude/hooks/headsup-status.d"
STATE_DIR="$HOME/.claude/hooks/.state"
mkdir -p "$CONF_DIR" "$STATE_DIR"

# Single-quote the label inside the conf, escaping embedded single quotes,
# so special characters round-trip through the sourced file untouched.
ESCAPED=$(printf '%s' "$LABEL" | sed "s/'/'\\\\''/g")
cat > "$CONF_DIR/${SESSION_KEY}.conf" <<EOF
# Per-iTerm2-session override for this pane.
# Written by headsup-set-label.sh. Local-only — headsup-status.d/ is gitignored.
# ITERM_SESSION_ID changes across iTerm2 restarts, so this becomes stale.

headsup_badge_text() { printf '%s' '$ESCAPED'; }
headsup_title_text() { printf '%s' '$ESCAPED'; }
EOF

# Badge sidecar so the waiting-notification script picks up the label
# without waiting for the next hook event.
printf '%s\n' "$LABEL" > "$STATE_DIR/${UUID}.badge"

# Apply badge + title immediately.
BADGE_B64=$(printf '%s' "$LABEL" | base64)
printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$BADGE_B64" "$LABEL"

exit 0
