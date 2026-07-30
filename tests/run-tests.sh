#!/bin/bash
# run-tests.sh - run the whole headsup suite.
#
# Usage: bash tests/run-tests.sh [results-file]
#
# Exit 0 when every CORE case passes. Exit 1 on any CORE failure. EDGE
# failures are reported and counted but never block the verdict, per the
# verdict discipline in the QA persona charter.
#
# Owned by apt-qa (AI Power Term QA persona). Product code is never modified.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${1:-$HERE/../.headsup-test-results.tsv}"

# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"
# shellcheck source=test_syntax.sh
. "$HERE/test_syntax.sh"
# shellcheck source=test_window_id.sh
. "$HERE/test_window_id.sh"
# shellcheck source=test_headsup_state.sh
. "$HERE/test_headsup_state.sh"

hs_init "$RESULTS"

printf '\n--- suite: syntax (every shipped script parses) ---\n'
run_syntax_suite

printf '\n--- suite: window-id.sh (fleet slug resolution) ---\n'
run_window_id_suite

printf '\n--- suite: headsup-state.sh (idle/waiting declaration) ---\n'
run_state_suite

hs_summary
