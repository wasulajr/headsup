#!/bin/bash
# window-id.sh — print the current iTerm2 session's headsup label, a filename
# slug for it, the cwd, and a timestamp. Used by the /sfl skill to key its
# live checkpoint entry (one file per window, newest overwrites).
#
# Output (KEY=value lines, easy for the skill to parse):
#   LABEL=<headsup tab label, or cwd basename if no label set>
#   SLUG=<filename-safe slug of LABEL>
#   CWD=<absolute working directory>
#   STAMP=<absolute local timestamp>
#
# Always exits 0.

CONF_DIR="$HOME/.claude/hooks/headsup-status.d"
label=""

if [ -n "${ITERM_SESSION_ID:-}" ]; then
    # Same session-key derivation headsup-set-label.sh uses.
    key=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
    conf="$CONF_DIR/$key.conf"
    if [ -f "$conf" ]; then
        # The conf defines headsup_title_text() / headsup_badge_text().
        # Prefer the title; fall back to the badge.
        label=$(
            # shellcheck disable=SC1090
            . "$conf" 2>/dev/null
            if declare -f headsup_title_text >/dev/null 2>&1; then
                headsup_title_text
            elif declare -f headsup_badge_text >/dev/null 2>&1; then
                headsup_badge_text
            fi
        )
    fi
fi

# Fallback: a window with no explicit headsup label keys off its cwd basename.
[ -n "$label" ] || label=$(basename "$PWD")

slug=$(printf '%s' "$label" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$slug" ] || slug="window"

printf 'LABEL=%s\n' "$label"
printf 'SLUG=%s\n'  "$slug"
printf 'CWD=%s\n'   "$PWD"
printf 'STAMP=%s\n' "$(date '+%Y-%m-%d %H:%M %Z')"
exit 0
