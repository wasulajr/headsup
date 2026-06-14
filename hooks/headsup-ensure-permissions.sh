#!/bin/bash
# headsup-ensure-permissions.sh: idempotently ensure the permissions.allow rules
# the headsup skills need are present in settings.json, so /headsup-config and
# the focused skills run without a permission prompt.
#
# Shared by setup.sh (fresh install) and headsup-update.sh (update), so BOTH
# installs and updates converge on the correct rules. Additive and idempotent:
# it only ever appends missing rules, never removes or reorders anything else.
#
# Usage: headsup-ensure-permissions.sh [SETTINGS_JSON]
#   SETTINGS_JSON defaults to ~/.claude/settings.json
#
# The rules use the tilde form because the skills invoke the scripts via their
# ~/.claude/hooks/... path, which is what Claude Code matches against.

set -euo pipefail

SETTINGS="${1:-$HOME/.claude/settings.json}"

# Canonical list: every headsup helper a skill runs via the Bash tool.
RULES=(
    'Bash(~/.claude/hooks/headsup-set-label.sh:*)'       # /headsup-label, New Claude Tab label step
    'Bash(~/.claude/hooks/headsup-newtab-args.sh:*)'     # /headsup-config newtabs
    'Bash(~/.claude/hooks/headsup-notifications.sh:*)'   # /headsup-config notify, /headsup-notifications
)

if ! command -v jq >/dev/null 2>&1; then
    echo "headsup-ensure-permissions: jq not found; skipping (skills will prompt on first use)" >&2
    exit 0
fi

# Ensure the file exists and is valid JSON before touching it.
if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    printf '{}\n' > "$SETTINGS"
fi
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "headsup-ensure-permissions: $SETTINGS is not valid JSON; not modifying it" >&2
    exit 0
fi

added=0
for rule in "${RULES[@]}"; do
    if jq -e --arg r "$rule" '.permissions.allow // [] | index($r) != null' "$SETTINGS" >/dev/null 2>&1; then
        continue
    fi
    if jq --arg r "$rule" '.permissions.allow = ((.permissions.allow // []) + [$r])' "$SETTINGS" > "$SETTINGS.tmp" 2>/dev/null \
        && mv -f "$SETTINGS.tmp" "$SETTINGS"; then
        echo "added allow rule: $rule"
        added=$((added + 1))
    else
        rm -f "$SETTINGS.tmp" 2>/dev/null || true
        echo "warning: could not add allow rule: $rule" >&2
    fi
done

if [ "$added" -eq 0 ]; then
    echo "headsup allow rules already present in $SETTINGS"
else
    echo "headsup: added $added allow rule(s) to $SETTINGS"
fi
exit 0
