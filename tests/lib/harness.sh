#!/bin/bash
# harness.sh - minimal dependency-free test harness for the headsup suite.
#
# Owned by apt-qa (the AI Power Term QA persona). Product code is never
# modified by these tests; the suite only observes shipped behavior.
#
# Verdict discipline (Steve, 2026-07-30): every case is tagged CORE or EDGE at
# authoring time. The suite FAILS only on a CORE failure. An EDGE failure is
# reported, counted, and filed as its own issue, but does not block a pass.
#
# Results stream as each case completes and are appended to the results file
# immediately, so a crash partway through preserves the cases already run.

set -u

HS_PASS=0
HS_CORE_FAIL=0
HS_EDGE_FAIL=0
HS_TOTAL=0
HS_RESULTS="${HS_RESULTS:-}"

hs_init() {
  HS_RESULTS="${1:?results file required}"
  : > "$HS_RESULTS"
  printf '# headsup test results\n# started %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$HS_RESULTS"
}

# hs_record <tier> <name> <status> <detail>
hs_record() {
  local tier="$1" name="$2" status="$3" detail="${4:-}"
  HS_TOTAL=$((HS_TOTAL + 1))
  case "$status" in
    PASS) HS_PASS=$((HS_PASS + 1)) ;;
    FAIL)
      if [ "$tier" = "CORE" ]; then
        HS_CORE_FAIL=$((HS_CORE_FAIL + 1))
      else
        HS_EDGE_FAIL=$((HS_EDGE_FAIL + 1))
      fi
      ;;
  esac
  # Stream immediately and persist immediately (job-durability rule).
  printf '[%s] %-6s %-52s %s\n' "$status" "$tier" "$name" "$detail"
  printf '%s\t%s\t%s\t%s\n' "$status" "$tier" "$name" "$detail" >> "$HS_RESULTS"
}

# hs_assert_eq <tier> <name> <expected> <actual>
hs_assert_eq() {
  local tier="$1" name="$2" expected="$3" actual="$4"
  if [ "$expected" = "$actual" ]; then
    hs_record "$tier" "$name" PASS ""
  else
    hs_record "$tier" "$name" FAIL "expected [$expected] got [$actual]"
  fi
}

# hs_assert_contains <tier> <name> <needle> <haystack>
hs_assert_contains() {
  local tier="$1" name="$2" needle="$3" haystack="$4"
  case "$haystack" in
    *"$needle"*) hs_record "$tier" "$name" PASS "" ;;
    *) hs_record "$tier" "$name" FAIL "missing [$needle] in [$haystack]" ;;
  esac
}

hs_summary() {
  local verdict
  if [ "$HS_CORE_FAIL" -gt 0 ]; then
    verdict="FAIL"
  else
    verdict="PASS"
  fi
  printf '\n=====================================================\n'
  printf 'VERDICT: %s\n' "$verdict"
  printf 'total=%s pass=%s core_fail=%s edge_fail=%s\n' \
    "$HS_TOTAL" "$HS_PASS" "$HS_CORE_FAIL" "$HS_EDGE_FAIL"
  if [ "$HS_EDGE_FAIL" -gt 0 ] && [ "$HS_CORE_FAIL" -eq 0 ]; then
    printf 'Core passed. %s edge finding(s) to file as non-blocking issues.\n' "$HS_EDGE_FAIL"
  fi
  printf '=====================================================\n'
  printf 'VERDICT=%s total=%s pass=%s core_fail=%s edge_fail=%s\n' \
    "$verdict" "$HS_TOTAL" "$HS_PASS" "$HS_CORE_FAIL" "$HS_EDGE_FAIL" >> "$HS_RESULTS"
  [ "$HS_CORE_FAIL" -eq 0 ]
}
