"""Tests for hooks/headsup-usage-windows.py.

The reference for correctness is the ORIGINAL full-scan aggregate(), copied verbatim below
(from headsup origin/main before the incremental rewrite). Every totals check compares the
new incremental result with that function over the same fixture files, except where the
original crashes or the new behavior is a documented, deliberate difference (those tests
assert explicit expected values instead).

Run:  python3 -m unittest discover -s tests -v
"""

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "hooks" / "headsup-usage-windows.py"
NOW = datetime(2026, 10, 28, 12, 0, 0, tzinfo=timezone.utc)       # a Wednesday
# session block start 07:40Z today; week start Monday 10/26 21:00Z
MON = datetime(2026, 10, 26, 22, 0, 0, tzinfo=timezone.utc)       # session block (19:40Z) starts BEFORE the week (21:00Z)


def load_module(config_dir, state_dir, home):
    """Import the script fresh with its env-derived constants pointing at temp dirs."""
    keys = ("CLAUDE_CONFIG_DIR", "HEADSUP_USAGE_STATE_DIR", "HOME", "HEADSUP_USAGE_DISABLE", "HEADSUP_USAGE_TTL",
            "HEADSUP_USAGE_LOCK_FD")
    saved = {k: os.environ.get(k) for k in keys}
    os.environ.update({"CLAUDE_CONFIG_DIR": str(config_dir), "HEADSUP_USAGE_STATE_DIR": str(state_dir),
                       "HOME": str(home)})
    for k in ("HEADSUP_USAGE_DISABLE", "HEADSUP_USAGE_TTL", "HEADSUP_USAGE_LOCK_FD"):
        os.environ.pop(k, None)
    try:
        spec = importlib.util.spec_from_file_location(f"usage_{uuid.uuid4().hex}", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# ---- reference implementation: the original aggregate(), verbatim -------------------------
LEGACY_SRC = '''def aggregate(s_start: datetime, w_start: datetime):
    """Single-pass scan over all recent JSONL files."""
    week_ts = w_start.timestamp()
    s = {"out": 0, "cost": 0.0}
    w = {"out": 0, "cost": 0.0}

    for jsonl in PROJECTS_DIR.rglob("*.jsonl"):
        try:
            if jsonl.stat().st_mtime < week_ts:
                continue
        except OSError:
            continue
        try:
            with jsonl.open(errors="replace") as fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if d.get("type") != "assistant":
                        continue
                    ts_str = d.get("timestamp")
                    msg    = d.get("message", {})
                    usage  = msg.get("usage")
                    if not ts_str or not usage:
                        continue
                    try:
                        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    except ValueError:
                        continue

                    out = usage.get("output_tokens", 0)
                    inp = usage.get("input_tokens", 0)
                    cr  = usage.get("cache_read_input_tokens", 0)
                    cw  = usage.get("cache_creation_input_tokens", 0)
                    p   = prices_for(msg.get("model", ""))
                    cost = (inp * p["inp"] + out * p["out"] +
                            cr  * p["cr"]  + cw  * p["cw"]) / 1_000_000

                    if ts >= s_start:
                        s["out"]  += out
                        s["cost"] += cost
                    if ts >= w_start:
                        w["out"]  += out
                        w["cost"] += cost
        except OSError:
            continue

    return s, w
'''


def legacy_totals(mod, s_start, w_start):
    ns = {"PROJECTS_DIR": mod.PROJECTS_DIR, "json": json, "datetime": datetime, "prices_for": mod.prices_for}
    exec(LEGACY_SRC, ns)
    return ns["aggregate"](s_start, w_start)


def assistant(ts, model="claude-sonnet-5-5", out=100, inp=10, cr=1000, cw=50):
    return {"type": "assistant", "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
            "message": {"model": model, "usage": {"output_tokens": out, "input_tokens": inp,
                                                    "cache_read_input_tokens": cr,
                                                    "cache_creation_input_tokens": cw}}}


def raw_line(ts, usage_json, model="m"):
    """A hand-built line so odd or invalid usage values survive serialisation."""
    stamp = ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return '{"type":"assistant","timestamp":"%s","message":{"model":"%s","usage":%s}}' % (stamp, model, usage_json)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.config, self.state, self.home = t / "config", t / "state", t / "home"
        for d in (self.config / "projects" / "proj", self.state, self.home):
            d.mkdir(parents=True)
        self.mod = load_module(self.config, self.state, self.home)
        self.proj = self.config / "projects" / "proj"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, items, final_newline=True, mode="w", when=NOW):
        path = self.proj / name
        path.parent.mkdir(parents=True, exist_ok=True)
        body = "\n".join(i if isinstance(i, str) else json.dumps(i) for i in items)
        if final_newline and items:
            body += "\n"
        with open(path, mode + "b") as fh:
            fh.write(body.encode("utf-8", "surrogateescape"))
        self.touch(path, when)
        return path

    def touch(self, path, when=NOW):
        os.utime(path, (when.timestamp(), when.timestamp()))

    def totals(self, now=NOW):
        idx = self.mod.load_index()
        return self.mod.window_totals(idx["slots"], self.mod.block_start(now), self.mod.week_start(now))

    def assert_matches_legacy(self, now=NOW):
        ls, lw = legacy_totals(self.mod, self.mod.block_start(now), self.mod.week_start(now))
        ns, nw = self.totals(now)
        self.assertEqual(ns["out"], ls["out"], "session output tokens")
        self.assertEqual(nw["out"], lw["out"], "week output tokens")
        self.assertAlmostEqual(ns["cost"], ls["cost"], places=6)
        self.assertAlmostEqual(nw["cost"], lw["cost"], places=6)
        return ns, nw

    def error_log(self):
        return self.mod.ERROR_LOG.read_text() if self.mod.ERROR_LOG.exists() else ""


class TotalsMatchLegacy(Base):
    def test_mixed_fixture(self):
        t = lambda **k: NOW - timedelta(**k)
        self.write("a.jsonl", [
            assistant(t(minutes=5), model="claude-opus-5-5", out=500),
            assistant(t(hours=2), model="claude-haiku-5-5", out=70),
            assistant(t(hours=30), out=900),
            {"type": "user", "timestamp": "2026-10-28T11:00:00Z", "message": {"usage": {"output_tokens": 9}}},
            {"type": "assistant", "timestamp": "2026-10-28T11:00:00Z", "message": {"model": "x"}},
            "this is not json",
            '{"type": "assistant", "message": {"usage": {"output_tokens": 5}}}',
            assistant(t(minutes=1), model="mystery-model", out=11),
        ])
        self.write("b.jsonl", [assistant(t(days=1, hours=3), out=33), assistant(t(minutes=30), out=44)])
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertGreater(ns["out"], 0)
        self.assertGreater(nw["out"], ns["out"])

    def test_invalid_utf8_line_still_counted(self):
        good = json.dumps(assistant(NOW - timedelta(minutes=2), out=123))
        bad = good[:-1] + ', "junk": "\udcff"}'          # \udcff is written as the raw invalid byte 0xFF
        self.write("c.jsonl", [good, bad])
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 246, "both lines count, as the original errors=replace read did")

    def test_window_boundaries_are_exact(self):
        s_start = datetime(2026, 10, 28, 7, 40, tzinfo=timezone.utc)
        w_start = datetime(2026, 10, 26, 21, 0, tzinfo=timezone.utc)
        eps = timedelta(milliseconds=1)
        self.write("edge.jsonl", [
            assistant(s_start - eps, out=1),            # just before the session block: week only
            assistant(s_start, out=10),                 # exactly at the block start: session + week
            assistant(w_start - eps, out=100),          # just before the week: neither
            assistant(w_start, out=1000),               # exactly at the week start: week only
        ])
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(ns["out"], 10)
        self.assertEqual(nw["out"], 1 + 10 + 1000)

    def test_session_keeps_events_before_the_week_start_on_monday_evening(self):
        # Review finding 3: between Monday 19:40Z and 21:00Z the session block starts before the week.
        self.write("m.jsonl", [assistant(datetime(2026, 10, 26, 20, 0, tzinfo=timezone.utc), out=1000),
                                assistant(datetime(2026, 10, 26, 21, 30, tzinfo=timezone.utc), out=1000)], when=MON)
        self.mod.refresh(MON)
        ns, nw = self.assert_matches_legacy(MON)
        self.assertEqual((ns["out"], nw["out"]), (2000, 1000))

    def test_files_older_than_the_week_are_ignored(self):
        self.write("old.jsonl", [assistant(NOW - timedelta(minutes=1), out=777)], when=NOW - timedelta(days=9))
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 0)

    def test_subagent_transcripts_are_counted(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=4), out=5)])
        self.write("sess-1/subagents/agent-x.jsonl", [assistant(NOW - timedelta(minutes=3), out=7)])
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 12)

    def test_tool_results_directories_are_not_walked_a_documented_difference(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=4), out=5)])
        self.write("sess-1/tool-results/big.jsonl", [assistant(NOW - timedelta(minutes=3), out=1000)])
        self.mod.refresh(NOW)
        ns, nw = self.totals()
        self.assertEqual(nw["out"], 5, "persisted tool output is not a transcript; the old full scan would have counted 1005")

    def test_directory_symlinks_are_not_followed(self):
        other = Path(self.tmp.name) / "elsewhere"
        (other / "p").mkdir(parents=True)
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=4), out=5)])
        (other / "p" / "z.jsonl").write_text(json.dumps(assistant(NOW - timedelta(minutes=2), out=999)) + "\n")
        os.symlink(other, self.config / "projects" / "linked")
        (self.proj / "dir.jsonl").mkdir()             # a directory named like a transcript
        self.mod.refresh(NOW)
        ns, nw = self.totals()
        self.assertEqual(nw["out"], 5)
        self.assertEqual(self.error_log(), "", "a directory named x.jsonl must be skipped silently")


class Incremental(Base):
    def spy(self):
        calls = []
        real = self.mod.scan_file
        def wrapped(key, st, off, expect_fp, idx, checkpoint, stats):
            calls.append((Path(key).name, off))
            return real(key, st, off, expect_fp, idx, checkpoint, stats)
        self.mod.scan_file = wrapped
        return calls

    def test_only_appended_bytes_are_read(self):
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=5)])
        self.write("quiet.jsonl", [assistant(NOW - timedelta(minutes=8), out=6)])
        self.mod.refresh(NOW)
        size1 = p.stat().st_size
        calls = self.spy()
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=3), out=50)], mode="a", when=NOW + timedelta(seconds=5))
        self.mod.refresh(NOW)
        self.assertEqual(calls, [("a.jsonl", size1)], "unchanged file skipped, changed file read from its offset")
        self.assert_matches_legacy()

    def test_partial_trailing_line_is_deferred_then_counted_once(self):
        full = json.dumps(assistant(NOW - timedelta(minutes=4), out=40))
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=5)])
        with open(p, "ab") as fh:
            fh.write(full[: len(full) // 2].encode())          # writer is mid-line
        self.touch(p, NOW + timedelta(seconds=1))
        self.mod.refresh(NOW)
        s, w = self.totals()
        self.assertEqual(w["out"], 5, "the half line is not counted yet")
        with open(p, "ab") as fh:
            fh.write(full[len(full) // 2:].encode() + b"\n")
        self.touch(p, NOW + timedelta(seconds=2))
        self.mod.refresh(NOW)
        self.assert_matches_legacy()
        self.mod.refresh(NOW)           # a third refresh must not recount it
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 45)

    def test_complete_final_line_without_newline_is_counted_once(self):
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=5),
                                    assistant(NOW - timedelta(minutes=2), out=7)], final_newline=False)
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 12)
        with open(p, "ab") as fh:
            fh.write(b"\n" + json.dumps(assistant(NOW - timedelta(minutes=1), out=20)).encode() + b"\n")
        self.touch(p, NOW + timedelta(seconds=3))
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 32)

    def test_truncated_file_forces_a_clean_rebuild(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=500), assistant(NOW - timedelta(minutes=8), out=400)])
        self.mod.refresh(NOW)
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=7), out=3)], when=NOW + timedelta(seconds=4))
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 3)
        self.assertIn("replaced-or-truncated", self.error_log())

    def test_deleted_in_week_file_forces_a_rebuild(self):
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=500)])
        self.write("b.jsonl", [assistant(NOW - timedelta(minutes=8), out=4)])
        self.mod.refresh(NOW)
        p.unlink()
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 4)

    def test_in_place_rewrite_with_more_content_is_detected(self):
        # Review finding 5: same inode, rewritten larger, so size and inode alone look like an append.
        p = self.write("a.jsonl", [raw_line(NOW - timedelta(minutes=9), '{"input_tokens":1,"output_tokens":100}')])
        self.mod.refresh(NOW)
        new = [raw_line(NOW - timedelta(minutes=8), '{"input_tokens":1,"output_tokens":7}'),
               raw_line(NOW - timedelta(minutes=7), '{"input_tokens":1,"output_tokens":8}'),
               raw_line(NOW - timedelta(minutes=6), '{"input_tokens":1,"output_tokens":9}')]
        with open(p, "r+b") as fh:
            fh.write(("\n".join(new) + "\n").encode())
        self.touch(p, NOW + timedelta(seconds=6))
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 24)
        self.assertIn("fingerprint", self.error_log())

    def test_same_size_edit_with_a_new_mtime_is_detected(self):
        p = self.write("a.jsonl", [raw_line(NOW - timedelta(minutes=9), '{"input_tokens":1,"output_tokens":100}')])
        self.mod.refresh(NOW)
        text = p.read_text().replace('"output_tokens":100', '"output_tokens":900')
        p.write_text(text)
        self.touch(p, NOW + timedelta(seconds=7))
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 900)

    def test_mtime_going_backwards_forces_a_rebuild(self):
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=300)])
        self.mod.refresh(NOW)
        self.touch(p, NOW - timedelta(hours=2))          # still inside the week, but earlier than recorded
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 300, "not counted twice")
        self.assertIn("mtime-regressed", self.error_log())

    def test_a_file_aging_out_and_returning_is_not_double_counted(self):
        # Review finding 5b: mtime moved out of the week window and then restored.
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=300)])
        self.mod.refresh(NOW)
        self.touch(p, NOW - timedelta(days=9))
        self.mod.refresh(NOW)
        self.touch(p, NOW)
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 300)

    def test_the_index_is_rebuilt_once_a_day(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=5)])
        self.mod.refresh(NOW)
        idx = self.mod.load_index()
        idx["built_at"] = time.time() - self.mod.REBUILD_SEC - 10
        self.mod.save_index(idx)
        calls = self.spy()
        self.mod.refresh(NOW)
        self.assertEqual(calls, [("a.jsonl", 0)], "everything is read again from byte 0")
        self.assertIn("periodic", self.error_log())
        self.assert_matches_legacy()

    def test_buckets_older_than_the_week_are_pruned(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=1)])
        self.mod.refresh(NOW)
        later = NOW + timedelta(days=8)
        p = self.proj / "a.jsonl"
        with open(p, "ab") as fh:
            fh.write(json.dumps(assistant(later - timedelta(minutes=1), out=2)).encode() + b"\n")
        self.touch(p, later)
        self.mod.refresh(later)
        idx = self.mod.load_index()
        cutoff = int(min(self.mod.week_start(later), self.mod.block_start(later)).timestamp()) // self.mod.BUCKET_SEC
        self.assertTrue(all(k >= cutoff for k in idx["slots"]))


class Atomicity(Base):
    """Review finding 1: a failure or kill part-way through a file must not double count."""
    def lines(self, n=50):
        return [assistant(NOW - timedelta(minutes=60 - i), out=10) for i in range(n)]

    def failing_parse(self, at, exc):
        real = self.mod.parse_usage_line
        state = {"n": 0}
        def wrapped(line):
            state["n"] += 1
            if state["n"] == at:
                raise exc
            return real(line)
        self.mod.parse_usage_line = wrapped
        return real

    def test_a_read_error_part_way_through_a_file_adds_nothing_twice(self):
        p = self.write("a.jsonl", self.lines())
        real = self.failing_parse(30, OSError("EIO"))
        self.mod.refresh(NOW)                                  # the error is logged, the file is skipped
        ns, nw = self.totals()
        self.assertLessEqual(nw["out"], 500)
        self.assertNotEqual(nw["out"], 290, "no half-merged counts from the failed attempt")
        self.mod.parse_usage_line = real
        self.touch(p, NOW + timedelta(seconds=9))              # the file changes, so it is retried
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 500)
        self.assertIn("EIO", self.error_log())

    def test_a_kill_after_a_checkpoint_resumes_without_double_counting(self):
        self.write("a.jsonl", self.lines())
        self.mod.CHECKPOINT_SEC = 0                            # checkpoint on every line
        self.failing_parse(30, KeyboardInterrupt())            # stands in for SIGKILL: nothing after it runs
        with self.assertRaises(KeyboardInterrupt):
            self.mod.refresh(NOW)
        fresh = load_module(self.config, self.state, self.home)   # a new process reading the saved checkpoint
        fresh.refresh(NOW)
        s, w = fresh.window_totals(fresh.load_index()["slots"], fresh.block_start(NOW), fresh.week_start(NOW))
        self.assertEqual(w["out"], 500, "the resumed build counts every line exactly once")

    def test_poison_numbers_drop_the_record_not_the_refresh(self):
        # Review finding 6. The original crashes on these; the new code drops and counts them.
        t = NOW - timedelta(minutes=5)
        self.write("a.jsonl", [
            raw_line(t, '{"output_tokens":10}'),
            raw_line(t, '{"output_tokens":NaN}'),
            raw_line(t, '{"output_tokens":1e999}'),
            raw_line(t, '{"output_tokens":-Infinity}'),
            raw_line(t, '{"output_tokens":"5"}'),
            raw_line(t, '{"output_tokens":' + "9" * 400 + '}'),
            raw_line(t, '{"output_tokens":true}'),
        ])
        self.mod.refresh(NOW)
        ns, nw = self.totals()
        self.assertEqual(nw["out"], 10)
        self.assertIn('"bad-records"', self.error_log())
        self.assertIn('"count": 6', self.error_log())


class SingleFlightAndCaching(Base):
    def setUp(self):
        super().setUp()
        self.popen_calls, self.kept = [], []
        outer = self
        class FakePopen:
            def __init__(inner, *a, **k):
                outer.popen_calls.append((a, k))
                # the child inherits the lock through pass_fds; keep a duplicate alive like it would
                outer.kept.extend(os.dup(fd) for fd in k.get("pass_fds", ()))
        import subprocess as sp
        self.real_popen = sp.Popen            # tests that need a genuine child use this
        p = mock.patch.object(sp, "Popen", FakePopen)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(lambda: [os.close(fd) for fd in self.kept])
        argv = mock.patch.object(sys, "argv", ["x"])
        argv.start()
        self.addCleanup(argv.stop)
        nice = mock.patch.object(os, "nice", lambda n: 0)
        nice.start()
        self.addCleanup(nice.stop)
        self.out = []
        self.mod.print = lambda s="", **k: self.out.append(s)   # capture what the status line would eval

    def write_cache(self, age, output="SESSION_PCT=1"):
        self.mod.atomic_write(self.mod.CACHE_FILE, json.dumps({"ts": time.time() - age, "output": output}))

    def test_fresh_cache_prints_and_does_not_spawn(self):
        self.write_cache(5)
        self.mod.main()
        self.assertEqual(self.out, ["SESSION_PCT=1"])
        self.assertEqual(self.popen_calls, [])

    def test_stale_cache_prints_stale_and_a_burst_spawns_one_refresher(self):
        self.write_cache(120)
        for _ in range(8):                      # eight windows refreshing at once
            self.mod.main()
        self.assertEqual(self.out, ["SESSION_PCT=1"] * 8, "stale-while-revalidate: every caller still gets output")
        self.assertEqual(len(self.popen_calls), 1, "single-flight: one worker, not one per window")

    def test_no_cache_prints_nothing_and_spawns(self):
        self.mod.main()
        self.assertEqual(self.out, [])
        self.assertEqual(len(self.popen_calls), 1)

    def test_very_stale_cache_is_not_shown(self):
        self.write_cache(self.mod.MAX_STALE_SEC + 60)
        self.mod.main()
        self.assertEqual(self.out, [])
        self.assertEqual(len(self.popen_calls), 1)

    def test_future_dated_cache_is_not_trusted(self):
        self.write_cache(-86400)                 # a clock stepped backwards
        self.mod.main()
        self.assertEqual(self.out, [])
        self.assertEqual(len(self.popen_calls), 1)

    def test_a_cached_line_that_is_not_plain_key_value_pairs_is_never_printed(self):
        # Review finding 9: the caller evals this line, and /tmp is writable by other local users.
        for evil in ("SESSION_PCT=1; touch /tmp/pwned #", "$(id)", "A=1\nB=2", "SESSION_PCT=`id`", ""):
            self.out.clear()
            self.write_cache(5, output=evil)
            self.mod.main()
            self.assertEqual(self.out, [], repr(evil))
        self.assertIn("invalid-fields", self.error_log())

    def test_non_object_json_in_cache_or_index_is_corrupt_not_a_crash(self):
        # Review finding 4.
        for junk in ("[]", "null", "123", '"x"'):
            self.mod.CACHE_FILE.write_text(junk)
            self.mod.INDEX_FILE.write_text(junk)
            self.out.clear()
            self.assertEqual(self.mod.main(), 0, junk)
            self.assertEqual(self.out, [])
            self.assertEqual(self.mod.load_index()["files"], {})
        self.assertIn("not-an-object", self.error_log())

    def test_corrupt_cache_and_index_are_logged_not_fatal(self):
        self.mod.CACHE_FILE.write_text("{not json")
        self.mod.INDEX_FILE.write_text("garbage")
        self.mod.main()
        self.assertEqual(len(self.popen_calls), 1)
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=2), out=9)])
        self.mod.refresh(NOW)
        self.assert_matches_legacy()
        log = self.error_log()
        self.assertIn("cache-read", log)
        self.assertIn("index-load", log)

    def test_lock_has_one_holder_and_is_free_again_after_release(self):
        fd = self.mod.try_lock()
        self.assertIsNotNone(fd)
        self.assertIsNone(self.mod.try_lock())
        os.close(fd)
        fd2 = self.mod.try_lock()
        self.assertIsNotNone(fd2)
        os.close(fd2)

    def test_a_killed_holder_releases_the_lock_immediately(self):
        # Review finding 7: no stale-lock guessing. The kernel drops the flock when the holder dies.
        code = ("import fcntl,os,sys,time;fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR);"
                "fcntl.flock(fd,fcntl.LOCK_EX);print('held',flush=True);time.sleep(60)")
        proc = self.real_popen([sys.executable, "-c", code, str(self.mod.LOCK_FILE)], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(proc.stdout.readline().strip(), "held")
            self.assertIsNone(self.mod.try_lock(), "held while the holder lives")
            proc.send_signal(signal.SIGKILL)
            proc.wait(timeout=10)
            fd = self.mod.try_lock()
            self.assertIsNotNone(fd, "free the moment the holder is dead")
            os.close(fd)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.stdout.close()

    def test_kill_switch_env_and_flag(self):
        self.write_cache(120)
        self.mod.os.environ["HEADSUP_USAGE_DISABLE"] = "1"
        try:
            self.mod.main()
        finally:
            del self.mod.os.environ["HEADSUP_USAGE_DISABLE"]
        self.assertEqual((self.out, self.popen_calls), ([], []))
        flag = self.config / "hooks" / ".headsup-usage-disabled"
        flag.parent.mkdir(parents=True)
        flag.touch()
        self.mod.main()
        self.assertEqual((self.out, self.popen_calls), ([], []))

    def test_a_failed_refresh_is_logged_keeps_the_cache_frees_the_lock_and_backs_off(self):
        self.write_cache(120, output="SESSION_PCT=42")
        def boom(*a, **k):
            raise OSError("disk on fire")
        self.mod.update_index = boom
        self.assertEqual(self.mod.run_refresh(sync=False), 1)
        self.assertIn("disk on fire", self.error_log())
        self.assertEqual(json.loads(self.mod.CACHE_FILE.read_text())["output"], "SESSION_PCT=42")
        fd = self.mod.try_lock()
        self.assertIsNotNone(fd, "lock released after the failure")
        os.close(fd)
        self.assertGreater(self.mod.backoff_remaining(), 0)
        self.out.clear()
        for _ in range(40):                       # review finding 2: no retry on every status-line call
            self.mod.main()
        self.assertEqual(self.popen_calls, [], "backing off: no refresher spawned")
        self.assertEqual(self.out, ["SESSION_PCT=42"] * 40, "the last good line is still served")
        self.mod.atomic_write(self.mod.BACKOFF_FILE, json.dumps({"n": 1, "until": time.time() - 1}))
        self.mod.main()
        self.assertEqual(len(self.popen_calls), 1, "after the backoff expires it tries again")

    def test_backoff_grows_and_a_success_clears_it(self):
        for expected in (60, 120, 240):
            self.mod.note_failure()
            self.assertAlmostEqual(self.mod.backoff_remaining(), expected, delta=5)
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=2), out=9)])
        self.assertEqual(self.mod.run_refresh(sync=False), 0)
        self.assertEqual(self.mod.backoff_remaining(), 0)

    def test_atomic_write_never_leaves_a_temp_file_behind(self):
        target = self.state / "cachedir"
        target.mkdir()
        for _ in range(3):
            with self.assertRaises(OSError):
                self.mod.atomic_write(target, "x")       # os.replace onto a directory fails
        self.assertEqual(list(self.state.glob("*.tmp")), [])

    def test_the_state_dir_is_created_when_missing(self):
        gone = Path(self.tmp.name) / "no" / "such" / "dir"
        mod = load_module(self.config, gone, self.home)
        import subprocess as sp
        with mock.patch.object(sp, "Popen", lambda *a, **k: None):
            mod.main()
        self.assertTrue(gone.is_dir())

    def test_state_files_are_private(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=2), out=9)])
        self.mod.refresh(NOW)
        for f in (self.mod.CACHE_FILE, self.mod.INDEX_FILE):
            self.assertEqual(f.stat().st_mode & 0o077, 0, f"{f.name} must not be group or world accessible")


class EndToEnd(Base):
    """Real processes: the status-line call returns at once and the detached worker fills the cache."""
    def env(self):
        e = dict(os.environ)
        e.update({"CLAUDE_CONFIG_DIR": str(self.config), "HEADSUP_USAGE_STATE_DIR": str(self.state),
                  "HOME": str(self.home)})
        e.pop("HEADSUP_USAGE_DISABLE", None)
        e.pop("HEADSUP_USAGE_LOCK_FD", None)
        return e

    def run_script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env(), capture_output=True,
                              text=True, timeout=60)

    def test_sync_prints_the_expected_line(self):
        now = datetime.now(timezone.utc)
        self.write("a.jsonl", [assistant(now, out=250)], when=now)
        r = self.run_script("--sync")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WEEK_USED=250", r.stdout)
        self.assertIn("SESSION_USED=250", r.stdout)

    def test_sync_while_another_refresh_holds_the_lock_says_so_and_exits_cleanly(self):
        fd = self.mod.try_lock()
        try:
            r = self.run_script("--sync")
        finally:
            os.close(fd)
        self.assertEqual(r.returncode, 0)
        self.assertIn("another refresh holds the lock", r.stderr)

    def test_detached_worker_fills_the_cache_and_releases_the_lock(self):
        now = datetime.now(timezone.utc)
        self.write("a.jsonl", [assistant(now, out=250)], when=now)
        started = time.monotonic()
        r = self.run_script()
        self.assertEqual(r.stdout, "", "first call has no cache and prints nothing")
        self.assertLess(time.monotonic() - started, 5, "the call must not wait for the scan")
        cache = self.mod.CACHE_FILE
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not cache.exists():
            time.sleep(0.2)
        self.assertTrue(cache.exists(), "the detached refresher never wrote the cache")
        fd = None
        while time.monotonic() < deadline and fd is None:
            fd = self.mod.try_lock()
            if fd is None:
                time.sleep(0.2)
        self.assertIsNotNone(fd, "the worker never released the lock")
        os.close(fd)
        r2 = self.run_script()
        self.assertIn("WEEK_USED=250", r2.stdout)
        self.assertEqual(self.error_log(), "", "unexpected errors logged")


if __name__ == "__main__":
    unittest.main()
