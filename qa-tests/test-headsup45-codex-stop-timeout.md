# Test: Codex Stop hook no longer times out (headsup#45 / PR#46)

## Instructions for an AI QA agent (infra-qa)
Execute the cases below in order, read-only except for a throwaway fake-cliff script and a temp dir under /tmp. Fill in the PASS/FAIL table and report it. This grades the EXACT branch head; do not amend it.

- Repo: wasulajr/headsup, branch `fix/codex-status-hook-timeout` (PR#46), fixes #45.
- Under test: `hooks/headsup-codex-status.sh`, function `block_codex_stop_for_cliff_if_needed`.
- Base for the control: `origin/main` (the unbounded version).

## What changed
The Stop hook looped `cliff.sh inbox` per slug synchronously; cliff.sh inbox hits Agent Office (~3.5s, spiking), so the loop overran the 5s hook budget and the hook was killed every turn. The fix bounds each read at the REMAINING budget and breaks the whole loop once the budget is spent (default budget 2s, per-call cap CODEX_STOP_CLIFF_CALL_TIMEOUT default 3s, both env-tunable), failing open thereafter.

## History (why the head moved)
The first candidate (`01984bca`) capped each call at a FIXED `_call_to` and infra-qa graded it FAIL: `$SECONDS` is integer and its tick is unrelated to `_t0`, so the guard could read low (e.g. 2 at 2.9s elapsed) and then admit a fresh fixed-3s call, pushing worst-case elapsed to ~budget+call_to (measured 2/24 overruns, max 6.49s). This head caps each call at the remaining budget instead, holding total elapsed at ~budget. Case 7 below is the phase-randomized sweep that catches this class of defect (the old one-shot Case 3 did not).

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

## Case 7 [CORE] phase-randomized sweep: max elapsed stays under budget
This is the discriminating case: a call that takes just under the budget (2.9s) with the loop start phase randomized against `$SECONDS`. The FIXED-cap predecessor (`01984bca`) went red here ~2/24 with max 6.49s; the remaining-budget fix holds.
```
rm -f ~/.claude/coordination/stop-seen/* 2>/dev/null; MAX=0; OVER=0
for i in $(seq 1 24); do
  # randomize sub-second phase so the guard's integer read lands at varying offsets
  python3 -c "import time,random;time.sleep(random.random())"
  rm -f ~/.claude/coordination/stop-seen/* 2>/dev/null; t0=$(ms)
  ( cd /tmp/nabu && FAKE_CLIFF_SLEEP=2.9 CLIFF_BIN="$FAKE" CODEX_CLIFF_SLUGS="nabu janus power" timeout 15 "$NEW" Stop </dev/null >/dev/null 2>&1 ); t1=$(ms)
  d=$((t1-t0)); [ "$d" -gt "$MAX" ] && MAX=$d; [ "$d" -gt 5000 ] && OVER=$((OVER+1))
done
echo "overruns=$OVER max=${MAX}ms"
```
**Expected:** `overruns=0` and `max` < 5000ms (observed ~4.56s worst case). Any overrun is a FAIL: the fixed-cap defect is back. (Set `CODEX_CLIFF_SLUGS` to whatever the runner uses if the env var name differs; the point is >=2 slugs so the loop iterates.)

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
| 7 phase sweep | overruns=0, max<5000 | | |
| Regression | fast, exit 0 | | |

On full PASS: merge PR#46 per the verified-equals-merge consent; then deploy is nabu's step. On FAIL: back to nabu (owner) on the same branch.
