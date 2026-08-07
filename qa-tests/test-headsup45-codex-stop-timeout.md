# Test: Codex Stop hook no longer times out (headsup#45 / PR#46)

## Instructions for an AI QA agent (infra-qa)
Execute the cases below in order, read-only except for a throwaway fake-cliff script and a temp dir under /tmp. Fill in the PASS/FAIL table and report it. This grades the EXACT branch head; do not amend it.

- Repo: wasulajr/headsup, branch `fix/codex-status-hook-timeout` (PR#46), fixes #45.
- Under test: `hooks/headsup-codex-status.sh`, function `block_codex_stop_for_cliff_if_needed`.
- Base for the control: `origin/main` (the unbounded version).

## What changed
The Stop hook looped `cliff.sh inbox` per slug synchronously; cliff.sh inbox hits Agent Office (~3.5s, spiking), so the loop overran the 5s hook budget and the hook was killed every turn. The fix bounds each read and the whole loop (default 3s each, env-tunable CODEX_STOP_CLIFF_CALL_TIMEOUT / CODEX_STOP_CLIFF_BUDGET) and fails open once the budget is spent.

## Setup (run once)
```
NEW=<checkout>/hooks/headsup-codex-status.sh          # the PR branch head
OLD=$(git -C <checkout> show origin/main:hooks/headsup-codex-status.sh)  # or a base checkout
FAKE=/tmp/fakecliff.sh
cat > "$FAKE" <<'X'
#!/bin/bash
if [ "$1" = "inbox" ]; then sleep "${FAKE_CLIFF_SLEEP:-5}"; printf 'ID1\tsomepeer\t%s\tyes\t-\tno\t0\ttest ask\n' "${CLIFF_SLUG:-nabu}"; fi
X
chmod +x "$FAKE"; mkdir -p /tmp/nabu
ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }
```

## Case 1 [CORE] bash -n clean
`bash -n "$NEW"` -> **Expected:** exit 0, no output.

## Case 2 [CORE] control: OLD overruns budget (proves the defect reproduces)
```
rm -f ~/.claude/coordination/stop-seen/*; t0=$(ms)
( cd /tmp/nabu && FAKE_CLIFF_SLEEP=5 CLIFF_BIN="$FAKE" timeout 15 <OLD base version> Stop </dev/null >/dev/null 2>&1 ); t1=$(ms)
echo $((t1-t0))
```
**Expected:** > 5000 ms (overruns the 5s hook budget). If it does NOT exceed 5000ms the premise is not reproduced -> report BLOCKED, not PASS.

## Case 3 [CORE] fix: NEW is bounded under budget
```
rm -f ~/.claude/coordination/stop-seen/*; t0=$(ms)
( cd /tmp/nabu && FAKE_CLIFF_SLEEP=5 CLIFF_BIN="$FAKE" timeout 15 "$NEW" Stop </dev/null >/dev/null 2>&1 ); t1=$(ms)
echo $((t1-t0))
```
**Expected:** < 5000 ms (approx 3000-3600 ms). This is the fix.

## Case 4 [CORE] mutation: bound removed -> must go red
Temporarily raise the budget so the bound is inert: rerun Case 3 with `CODEX_STOP_CLIFF_BUDGET=20 CODEX_STOP_CLIFF_CALL_TIMEOUT=20`.
**Expected:** now > 5000 ms (proves the bound, not something else, is what keeps Case 3 under budget).

## Case 5 [CORE] functionality preserved: fast cliff still warns
```
rm -f ~/.claude/coordination/stop-seen/*
( cd /tmp/nabu && FAKE_CLIFF_SLEEP=0 CLIFF_BIN="$FAKE" "$NEW" Stop </dev/null 2>/dev/null )
```
**Expected:** output contains `"decision": "block"` (the Cliff warning still fires when cliff is fast).

## Case 6 [EDGE] no timeout binary: graceful fallback
Run Case 3 with `PATH` trimmed so `timeout`/`gtimeout` are absent (e.g. `PATH=/usr/bin`). **Expected:** no crash; behaves like OLD (may exceed budget, that is the documented fallback), exit 0.

## Regression [CORE]: non-Stop events unaffected
`( cd /tmp/nabu && "$NEW" PostToolUse </dev/null >/dev/null 2>&1; echo $? )` -> **Expected:** fast (<500ms), exit 0 (the cliff block only runs on Stop).

## Results
| Case | Expected | Actual | PASS/FAIL |
|---|---|---|---|
| 1 bash -n | exit 0 | | |
| 2 OLD control | >5000ms | | |
| 3 NEW bounded | <5000ms | | |
| 4 mutation | >5000ms | | |
| 5 fast warns | decision:block | | |
| 6 fallback | no crash | | |
| Regression | fast, exit 0 | | |

On full PASS: merge PR#46 per the verified-equals-merge consent; then deploy is nabu's step. On FAIL: back to nabu (owner) on the same branch.
