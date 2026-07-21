#!/bin/bash
# headsup-newtab-gate.sh: weekly-utilization gate for the New Claude Tab
# Quick Action (headsup#33).
#
# Prints NOTHING and exits 0 when launching is fine. When the account the new
# tab would use is at or over NEWTAB_WEEK_LIMIT% of its weekly subscription
# limit, prints a one-line human-readable warning (the Quick Action shows it in
# a Cancel / Open Anyway dialog) and exits 0. Exits 0 on every internal failure
# too: the gate must never be the reason a tab cannot open.
#
# Truth source: `claude -p /usage` (server-side subscription state), NOT the
# local transcript aggregation used by the status line. Local aggregation only
# sees this machine and missed a real 100%-exhausted week (2026-07-21 outage).
# The probe costs ~10s, so results are cached for GATE_CACHE_TTL_SEC.
#
# Config (in ~/.claude/hooks/headsup-status.conf):
#   NEWTAB_WEEK_LIMIT=95      # warn at or above this weekly %
#   NEWTAB_GATE_DISABLED=1    # skip the gate entirely

set -uo pipefail

LIMIT=95
GATE_CACHE_TTL_SEC=300
CONF="$HOME/.claude/hooks/headsup-status.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
LIMIT="${NEWTAB_WEEK_LIMIT:-$LIMIT}"
[ "${NEWTAB_GATE_DISABLED:-0}" = "1" ] && exit 0

# The Quick Action launches `claude` with no CLAUDE_CONFIG_DIR, so the account
# under test is whatever this environment resolves (ambient by default).
ACCT_KEY="$(printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" | /usr/bin/shasum -a 256 2>/dev/null | /usr/bin/cut -c1-8)"
CACHE="${TMPDIR:-/tmp}/headsup_newtab_gate_${ACCT_KEY:-default}.txt"

usage_line=""
if [ -f "$CACHE" ]; then
    now=$(date +%s)
    mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
    if [ $((now - mtime)) -lt "$GATE_CACHE_TTL_SEC" ]; then
        usage_line="$(cat "$CACHE" 2>/dev/null)"
    fi
fi

if [ -z "$usage_line" ]; then
    claude_bin="$(command -v claude || echo "$HOME/.local/bin/claude")"
    # Capture output even on a nonzero exit: a logged-out CLI prints its
    # "Not logged in" line and MAY exit 1, and that case must reach the check
    # below rather than silently passing the gate.
    raw="$("$claude_bin" -p "/usage" --output-format text --no-session-persistence 2>/dev/null)" || true
    # "Current week (all models): 87% used · resets ..."
    usage_line="$(printf '%s\n' "$raw" | grep -i 'Current week (all models)' | head -1)"
    # A logged-out account prints no usage lines at all: that is its own problem,
    # surface it instead of silently letting a doomed tab open.
    if [ -z "$usage_line" ]; then
        if printf '%s' "$raw" | grep -qi 'not logged in'; then
            echo "This account is NOT LOGGED IN (claude /usage: not logged in). The new tab will not be able to run turns."
        elif printf '%s' "$raw" | grep -q 'Total cost:' && ! printf '%s' "$raw" | grep -qi 'Current week'; then
            # Logged-out (or API-key) CLI prints the cost-report shape with
            # exit 0 and no subscription lines at all (observed 2026-07-21).
            echo "This account has NO subscription login (claude /usage returned the cost report, not subscription usage). The new tab likely cannot run turns."
        fi
        exit 0
    fi
    printf '%s' "$usage_line" > "$CACHE" 2>/dev/null || true
fi

pct="$(printf '%s' "$usage_line" | /usr/bin/sed -nE 's/.*: *([0-9]+)% used.*/\1/p')"
[ -n "$pct" ] || exit 0

if [ "$pct" -ge "$LIMIT" ]; then
    reset="$(printf '%s' "$usage_line" | /usr/bin/sed -nE 's/.*(resets [^(]*(\([^)]*\))?).*/\1/p')"
    echo "This account is at ${pct}% of its WEEKLY limit${reset:+ (${reset})}. New sessions will hit the limit almost immediately."
fi
exit 0
