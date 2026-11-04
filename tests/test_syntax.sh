#!/bin/bash
# test_syntax.sh - every shipped script must parse.
#
# CORE rationale: headsup ships as scripts that a user's shell sources or
# executes directly. A parse error is not a subtle defect, it is a hook that
# silently does nothing on every invocation, and the tab color simply stops
# tracking reality. There is no runtime that would surface it.
#
# Owned by apt-qa. Observes only; never edits product code.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"

run_syntax_suite() {
  local f rel out rc

  # Bash scripts.
  while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    out=$(bash -n "$f" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
      hs_record CORE "bash -n $rel" PASS ""
    else
      hs_record CORE "bash -n $rel" FAIL "$(printf '%s' "$out" | head -1)"
    fi
  done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/tests/*' | sort)

  # Python scripts.
  if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r f; do
      rel="${f#"$ROOT"/}"
      out=$(python3 -m py_compile "$f" 2>&1)
      rc=$?
      if [ $rc -eq 0 ]; then
        hs_record CORE "py_compile $rel" PASS ""
      else
        hs_record CORE "py_compile $rel" FAIL "$(printf '%s' "$out" | tail -1)"
      fi
    done < <(find "$ROOT" -name '*.py' -not -path '*/.git/*' -not -path '*/tests/*' | sort)
  else
    hs_record CORE "python3 available" FAIL "python3 not on PATH"
  fi

  # Node scripts.
  if command -v node >/dev/null 2>&1; then
    while IFS= read -r f; do
      rel="${f#"$ROOT"/}"
      out=$(node --check "$f" 2>&1)
      rc=$?
      if [ $rc -eq 0 ]; then
        hs_record CORE "node --check $rel" PASS ""
      else
        hs_record CORE "node --check $rel" FAIL "$(printf '%s' "$out" | head -1)"
      fi
    done < <(find "$ROOT" \( -name '*.mjs' -o -name '*.js' \) -not -path '*/.git/*' -not -path '*/tests/*' | sort)
  else
    hs_record EDGE "node available" FAIL "node not on PATH; .mjs hooks unchecked"
  fi

  # Executable bit: a hook the installer symlinks must be runnable.
  while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    if [ -x "$f" ]; then
      hs_record EDGE "executable $rel" PASS ""
    else
      hs_record EDGE "executable $rel" FAIL "not executable"
    fi
  done < <(find "$ROOT/hooks" -name '*.sh' | sort)
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hs_init "${1:-/tmp/headsup-syntax-results.tsv}"
  run_syntax_suite
  hs_summary
fi
