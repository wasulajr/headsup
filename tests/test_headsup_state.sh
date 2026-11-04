#!/bin/bash
# test_headsup_state.sh - contract tests for hooks/headsup-state.sh.
#
# Why this is CORE-critical: this script is how a window declares WHY it
# stopped, which decides whether its tab dims to white (idle, nothing needed)
# or turns orange (waiting on Steve). Steve triages the fleet by scanning tab
# colors. A window that goes white while actually blocked is invisible work,
# and a window that goes orange while idle is a false alarm that trains him to
# ignore the signal.
#
# The stated contract, from the script's own header:
#   idle    -> drop a sticky marker, exit 0
#   waiting -> clear the marker, exit 0
#   working -> same as waiting, exit 0
#   anything else -> usage on stderr, exit 2
#   outside an AI Power Term session -> silent no-op, exit 0
#
# Owned by apt-qa. Observes only; never edits product code.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"

STATE_SUT="$ROOT/hooks/headsup-state.sh"

run_state_suite() {
  local home rc out mark sid

  if [ ! -f "$STATE_SUT" ]; then
    hs_record CORE "headsup-state.sh exists" FAIL "not found at $STATE_SUT"
    return
  fi
  hs_record CORE "headsup-state.sh exists" PASS ""

  sid="apt-test-session"

  # --- CORE: idle drops the marker ---
  home="$(mktemp -d)"
  mark="$home/.claude/hooks/.state/apt-declared-idle-$sid"
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" idle >/dev/null 2>&1
  rc=$?
  hs_assert_eq CORE "idle exits 0" "0" "$rc"
  if [ -f "$mark" ]; then
    hs_record CORE "idle creates the declared-idle marker" PASS ""
  else
    hs_record CORE "idle creates the declared-idle marker" FAIL "marker absent at $mark"
  fi

  # --- CORE: waiting clears the marker ---
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" waiting >/dev/null 2>&1
  rc=$?
  hs_assert_eq CORE "waiting exits 0" "0" "$rc"
  if [ ! -f "$mark" ]; then
    hs_record CORE "waiting clears the marker" PASS ""
  else
    hs_record CORE "waiting clears the marker" FAIL "marker still present"
  fi

  # --- CORE: working also clears the marker ---
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" idle >/dev/null 2>&1
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" working >/dev/null 2>&1
  rc=$?
  hs_assert_eq CORE "working exits 0" "0" "$rc"
  if [ ! -f "$mark" ]; then
    hs_record CORE "working clears the marker" PASS ""
  else
    hs_record CORE "working clears the marker" FAIL "marker still present"
  fi
  rm -rf "$home"

  # --- CORE: an unknown state is rejected with exit 2 ---
  home="$(mktemp -d)"
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" banana >/dev/null 2>&1
  rc=$?
  hs_assert_eq CORE "unknown state exits 2" "2" "$rc"
  out=$(HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" banana 2>&1 >/dev/null)
  hs_assert_contains CORE "unknown state prints usage on stderr" "usage:" "$out"

  # --- CORE: no session id is a silent no-op, not a failure ---
  ( unset AI_POWER_TERM_SESSION_ID STEVE_TABS_SESSION_ID
    HOME="$home" bash "$STATE_SUT" idle >/dev/null 2>&1 )
  rc=$?
  hs_assert_eq CORE "no session id exits 0 (no-op)" "0" "$rc"

  # --- CORE: the legacy STEVE_TABS_SESSION_ID fallback still works ---
  ( unset AI_POWER_TERM_SESSION_ID
    HOME="$home" STEVE_TABS_SESSION_ID="legacy-sid" bash "$STATE_SUT" idle >/dev/null 2>&1 )
  if [ -f "$home/.claude/hooks/.state/apt-declared-idle-legacy-sid" ]; then
    hs_record CORE "STEVE_TABS_SESSION_ID fallback honored" PASS ""
  else
    hs_record CORE "STEVE_TABS_SESSION_ID fallback honored" FAIL "marker not created for legacy sid"
  fi
  rm -rf "$home"

  # --- EDGE: idle is idempotent ---
  home="$(mktemp -d)"
  mark="$home/.claude/hooks/.state/apt-declared-idle-$sid"
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" idle >/dev/null 2>&1
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" idle >/dev/null 2>&1
  rc=$?
  hs_assert_eq EDGE "idle twice exits 0" "0" "$rc"
  if [ -f "$mark" ]; then
    hs_record EDGE "idle is idempotent" PASS ""
  else
    hs_record EDGE "idle is idempotent" FAIL "marker lost on second idle"
  fi

  # --- EDGE: clearing a marker that was never set is not an error ---
  rm -f "$mark"
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" waiting >/dev/null 2>&1
  rc=$?
  hs_assert_eq EDGE "waiting with no marker exits 0" "0" "$rc"

  # --- EDGE: a missing argument is rejected, not silently treated as idle ---
  HOME="$home" AI_POWER_TERM_SESSION_ID="$sid" bash "$STATE_SUT" >/dev/null 2>&1
  rc=$?
  hs_assert_eq EDGE "missing argument exits 2" "2" "$rc"

  # --- EDGE: two sessions keep independent markers ---
  HOME="$home" AI_POWER_TERM_SESSION_ID="sid-a" bash "$STATE_SUT" idle >/dev/null 2>&1
  HOME="$home" AI_POWER_TERM_SESSION_ID="sid-b" bash "$STATE_SUT" idle >/dev/null 2>&1
  HOME="$home" AI_POWER_TERM_SESSION_ID="sid-a" bash "$STATE_SUT" waiting >/dev/null 2>&1
  if [ ! -f "$home/.claude/hooks/.state/apt-declared-idle-sid-a" ] \
     && [ -f "$home/.claude/hooks/.state/apt-declared-idle-sid-b" ]; then
    hs_record EDGE "per-session markers are independent" PASS ""
  else
    hs_record EDGE "per-session markers are independent" FAIL "one session's state leaked into another"
  fi

  # --- EDGE: a session id carrying path separators must not escape .state ---
  # The marker path is built by interpolating the session id, so a value with
  # a traversal component would place the file outside the state directory.
  HOME="$home" AI_POWER_TERM_SESSION_ID="../../escaped" bash "$STATE_SUT" idle >/dev/null 2>&1
  if [ -f "$home/.claude/escaped" ] || [ -f "$home/escaped" ]; then
    hs_record EDGE "session id cannot escape the state dir" FAIL "marker written outside .state"
  else
    hs_record EDGE "session id cannot escape the state dir" PASS ""
  fi
  rm -rf "$home"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hs_init "${1:-/tmp/headsup-state-results.tsv}"
  run_state_suite
  hs_summary
fi
