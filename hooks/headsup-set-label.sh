#!/bin/bash
# headsup-set-label.sh — set or clear the headsup per-session label (iTerm2
# badge + window/tab title) from inside the target iTerm2 session.
#
# Usage: headsup-set-label.sh <label...>
#        headsup-set-label.sh --clear
#
# Two callers:
#   1. The "New Claude Tab" Finder Quick Action runs it in a fresh tab
#      before `claude` launches (stdout IS the tty there).
#   2. The /headsup-label skill runs it from inside a Claude Code session,
#      where stdout is a pipe — so we walk up the process tree to find the
#      real tty and write the OSC escapes there instead. Keeping the whole
#      flow inside this one script means a single permission allowlist rule
#      (Bash(~/.claude/hooks/headsup-set-label.sh:*)) covers every label
#      change with no prompt.
#
# Writes the same per-session override that /headsup-label manages:
#   ~/.claude/hooks/headsup-status.d/<session-key>.conf  (sourced by headsup-status.sh)
#   ~/.claude/hooks/.state/<uuid>.badge                  (read by the waiting notifier)
#
# Always exits 0 so callers can safely chain `... && claude`.

if [ -z "${ITERM_SESSION_ID:-}" ]; then
    echo "headsup-set-label: ITERM_SESSION_ID unset (not inside iTerm2?) — label skipped" >&2
    exit 0
fi

SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
UUID="${ITERM_SESSION_ID##*:}"
CONF_DIR="$HOME/.claude/hooks/headsup-status.d"
STATE_DIR="$HOME/.claude/hooks/.state"

# Apply badge + title via OSC escapes. If stdout is the tty (Quick Action
# path) write straight to it; otherwise (Claude Code Bash tool — stdout is
# a pipe) walk up the process tree until an ancestor has a real tty.
apply_osc() {  # $1 = badge text, $2 = title text
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
    echo "headsup-set-label: no tty found — label saved, tab updates on the next hook event" >&2
    return 1
}

# ── --clear: remove the override and revert to the global default ───────────
if [ "$1" = "--clear" ]; then
    rm -f "$CONF_DIR/${SESSION_KEY}.conf" "$STATE_DIR/${UUID}.badge"
    # Recompute the default badge/title from the global conf and re-apply,
    # mirroring the fallbacks in headsup-status.sh.
    headsup_badge_text() { basename "$PWD"; }
    headsup_title_text() { printf 'Claude · %s' "$1"; }
    [ -f "$HOME/.claude/hooks/headsup-status.conf" ] && . "$HOME/.claude/hooks/headsup-status.conf"
    BADGE=$(headsup_badge_text)
    TITLE=$(headsup_title_text "$BADGE")
    apply_osc "$BADGE" "$TITLE"
    echo "headsup-set-label: per-session label cleared — reverted to '$TITLE'"
    exit 0
fi

LABEL="$*"
[ -n "$LABEL" ] || exit 0

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

apply_osc "$LABEL" "$LABEL"
echo "headsup-set-label: label set to '$LABEL'"

exit 0
