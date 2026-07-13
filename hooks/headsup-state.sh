#!/bin/bash
# headsup-state.sh — let THIS window declare WHY it is stopping, so the APT tab
# color means something: orange = waiting on Steve, blue = working, white = idle
# (nothing to do). (digadop-ai#903, dim-not-close, 2026-07-12)
#
# Usage: headsup-state.sh idle|waiting|working
#
#   idle     Drop a sticky "declared idle" marker. When this turn ends, the
#            Stop event is reported as idle (white) instead of waiting (orange).
#            The marker survives across quiet Stops and is cleared the moment a
#            new prompt arrives (UserPromptSubmit), so a window that gets work
#            goes blue, and if it then stops needing Steve it goes orange again.
#   waiting  Clear the marker: the default Stop -> orange behavior resumes.
#            Use when stopping at a needs-Steve gate / open question.
#   working  Same as waiting (clears the marker); provided for symmetry.
#
# Fail-safe: outside an AI Power Term session this is a silent no-op.
# The marker is consumed by ai-power-term/hooks/status.sh (the per-event hook).
set -u

STATE="${1:-}"
SID="${AI_POWER_TERM_SESSION_ID:-${STEVE_TABS_SESSION_ID:-}}"
if [ -z "$SID" ]; then
  echo "headsup-state: not an AI Power Term session; no-op"
  exit 0
fi

DIR="$HOME/.claude/hooks/.state"
mkdir -p "$DIR" 2>/dev/null || true
MARK="$DIR/apt-declared-idle-$SID"

case "$STATE" in
  idle)
    : > "$MARK"
    echo "headsup-state: declared idle ($SID) — tab dims to white when this turn ends"
    ;;
  waiting|working)
    rm -f "$MARK" 2>/dev/null || true
    echo "headsup-state: cleared idle declaration ($SID) — default colors resume"
    ;;
  *)
    echo "usage: headsup-state.sh idle|waiting|working" >&2
    exit 2
    ;;
esac
exit 0
