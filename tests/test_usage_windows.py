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
        self.assertEqual(sum(o for o, _ in idx["slots"].values()), 2, "the recent event survives, the old one is gone")


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
        self.assertEqual(self.error_log(), "", "the status-line path never writes the error log")
        self.mod.refresh(NOW)                      # the refresher is what reports the bad cache, once
        self.assertEqual(self.error_log().count("invalid-fields"), 1)

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


class Rev3Support(Base):
    """Shared fixtures for the review-driven test classes: a fake Popen that exits at once, a
    50-line transcript, and an open() that fails a set number of times for one path."""
    def setUp(self):
        super().setUp()
        self.popen_calls = []
        outer = self
        class FakePopen:             # a child that exits at once: it never keeps the lock
            def __init__(inner, *a, **k):
                outer.popen_calls.append((a, k))
        import subprocess as sp
        p = mock.patch.object(sp, "Popen", FakePopen)
        p.start()
        self.addCleanup(p.stop)
        for target, val in ((sys, {"argv": ["x"]}), ):
            pa = mock.patch.dict(vars(target), val)
            pa.start()
            self.addCleanup(pa.stop)
        nice = mock.patch.object(os, "nice", lambda n: 0)
        nice.start()
        self.addCleanup(nice.stop)

    def lines(self, n=50):
        return [assistant(NOW - timedelta(minutes=60 - i), out=10) for i in range(n)]

    def flaky_open(self, path, fail_times):
        calls = {"n": 0}
        real_open = open
        def flaky(file, *a, **k):
            if str(file) == str(path):
                calls["n"] += 1
                if calls["n"] <= fail_times:
                    raise OSError(5, "EIO")
            return real_open(file, *a, **k)
        return calls, flaky


class Revision3(Rev3Support):
    """Second independent review (adversarial pass on e7a11dd): each finding, plus the behaviours
    that review showed had no test at all."""
    # -- finding 1: the watchdog must reach run_refresh ---------------------------------------
    def test_the_watchdog_is_not_swallowed_by_the_scan_handlers(self):
        self.write("a.jsonl", self.lines(3))
        self.mod.MAX_RUN_SEC = 1
        real = self.mod.parse_usage_line
        def hang(line):
            time.sleep(5)            # inside scan_file's `except OSError`: TimeoutError would be swallowed here
            return real(line)
        self.mod.parse_usage_line = hang
        t0 = time.monotonic()
        self.assertEqual(self.mod.run_refresh(sync=False), 1)
        self.assertLess(time.monotonic() - t0, 3.5, "stopped by the alarm, not after the sleep")
        self.assertIn("RefreshTimeout", self.error_log())
        self.assertGreater(self.mod.backoff_remaining(), 0)

    # -- finding 2: the lock must not sit on a standard descriptor -----------------------------
    def test_the_lock_never_lands_on_stdin_or_stdout(self):
        for std in (0, 1):
            saved = os.dup(std)
            os.close(std)
            try:
                fd = self.mod.try_lock()
            finally:
                os.dup2(saved, std)
                os.close(saved)
            self.assertIsNotNone(fd)
            self.assertGreaterEqual(fd, 3, f"lock opened while fd {std} was closed")
            os.close(fd)

    def test_an_inherited_descriptor_must_be_this_accounts_lock_file(self):
        real = self.mod.try_lock()
        other = os.open(self.state / "other", os.O_CREAT | os.O_RDWR)
        try:
            with mock.patch.dict(os.environ, {"HEADSUP_USAGE_LOCK_FD": str(other)}):
                self.assertIsNone(self.mod.inherited_lock_fd())
            with mock.patch.dict(os.environ, {"HEADSUP_USAGE_LOCK_FD": str(real)}):
                self.assertEqual(self.mod.inherited_lock_fd(), real)
        finally:
            os.close(other)
            os.close(real)

    # -- finding 3: a transient error must not become a lasting undercount ----------------------
    def test_a_transient_read_error_is_retried_on_the_next_refresh(self):
        p = self.write("a.jsonl", self.lines())
        calls, flaky = self.flaky_open(p, 1)
        with mock.patch("builtins.open", flaky):
            self.mod.refresh(NOW)
            self.assertEqual(self.totals()[1]["out"], 0)
            self.mod.refresh(NOW)                       # same mtime: it is retried anyway
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 500)

    def test_a_file_that_keeps_failing_is_parked_until_it_changes(self):
        p = self.write("a.jsonl", self.lines())
        calls, flaky = self.flaky_open(p, 99)
        with mock.patch("builtins.open", flaky):
            for _ in range(self.mod.FILE_ERROR_MAX + 3):
                self.mod.refresh(NOW)
        self.assertEqual(calls["n"], self.mod.FILE_ERROR_MAX, "parked after FILE_ERROR_MAX failures in a row")
        self.touch(p, NOW + timedelta(seconds=9))        # the file changes: retried
        self.mod.refresh(NOW)
        self.assertEqual(self.assert_matches_legacy()[1]["out"], 500)

    def test_a_checkpoint_save_failure_fails_the_refresh_and_never_parks_the_file(self):
        self.write("a.jsonl", self.lines())
        self.mod.CHECKPOINT_SEC = 0
        real_save, state = self.mod.save_index, {"n": 0}
        def save(idx):
            state["n"] += 1
            if state["n"] == 1:
                raise OSError(28, "No space left on device")
            return real_save(idx)
        self.mod.save_index = save
        with self.assertRaises(self.mod.CheckpointError):
            self.mod.refresh(NOW)
        self.assertEqual(self.mod.load_index()["errors"], {}, "the file is not blamed for a full disk")
        self.mod.refresh(NOW)
        self.assertEqual(self.assert_matches_legacy()[1]["out"], 500)

    def test_malformed_parked_entries_in_a_saved_index_are_dropped(self):
        self.write("a.jsonl", self.lines(3))
        self.mod.refresh(NOW)
        d = json.loads(self.mod.INDEX_FILE.read_text())
        d["errors"] = {"x": 5, "y": [1, "z"], "z": [1, 2]}
        self.mod.INDEX_FILE.write_text(json.dumps(d))
        self.assertEqual(self.mod.load_index()["errors"], {"z": [1, 2]})

    # -- finding 4: a vanished file whose only record is a checkpoint -------------------------
    def test_a_file_that_vanishes_after_a_checkpoint_is_not_left_in_the_totals(self):
        p = self.write("a.jsonl", self.lines())
        self.mod.CHECKPOINT_SEC = 0
        real, state = self.mod.parse_usage_line, {"n": 0}
        def failing(line):
            state["n"] += 1
            if state["n"] == 30:
                raise OSError(5, "EIO")
            return real(line)
        self.mod.parse_usage_line = failing
        self.mod.refresh(NOW)
        self.assertEqual(self.totals()[1]["out"], 290, "29 lines committed before the failure")
        p.unlink()
        self.mod.parse_usage_line = real
        self.mod.refresh(NOW)
        self.assertEqual(self.assert_matches_legacy()[1]["out"], 0)

    # -- finding 5: backoff clamp, and a throttle that needs no disk space -------------------
    def test_a_far_future_backoff_is_clamped(self):
        self.mod.atomic_write(self.mod.BACKOFF_FILE, json.dumps({"n": 9, "until": time.time() + 10 ** 9}))
        self.assertLessEqual(self.mod.backoff_remaining(), self.mod.MAX_BACKOFF_SEC)

    def test_relaunches_stay_throttled_when_the_backoff_file_cannot_be_written(self):
        def boom(*a, **k):
            raise OSError("disk on fire")
        self.mod.update_index = boom
        with mock.patch.object(self.mod, "atomic_write", side_effect=OSError(28, "No space left on device")):
            self.assertEqual(self.mod.run_refresh(sync=False), 1)
        self.assertFalse(self.mod.BACKOFF_FILE.exists(), "the premise: no backoff could be recorded")
        for _ in range(30):
            self.mod.main()
        self.assertEqual(len(self.popen_calls), 1, "one launch per SPAWN_GAP_SEC, not one per call")

    def test_the_first_launch_is_not_throttled_by_a_fresh_lock_file(self):
        self.mod.main()
        self.assertEqual(len(self.popen_calls), 1)

    # -- finding 6: log hygiene -----------------------------------------------------------------
    def test_the_status_line_path_never_logs_a_corrupt_cache(self):
        self.mod.CACHE_FILE.write_text("{not json")
        for _ in range(50):
            self.mod.main()
        self.assertEqual(self.error_log(), "")

    def test_a_trimmed_error_log_keeps_whole_newest_lines(self):
        prev, trimmed_at = 0, None
        for i in range(300):
            self.mod.log_error("spam", reason="x" * 1000, i=i)
            size = self.mod.ERROR_LOG.stat().st_size
            if size < prev and trimmed_at is None:
                trimmed_at = i
            prev = size
        self.assertIsNotNone(trimmed_at, "the log was trimmed at some point")
        log = self.error_log()
        self.assertLess(len(log), self.mod.ERROR_LOG_MAX + 2000)
        self.assertIn('"i": 299', log)
        self.assertIn(f'"i": {trimmed_at - 1}', log, "the line written just before the trim is kept")
        for line in log.splitlines():
            json.loads(line)         # no line was cut in half

    # -- finding 7: a directory left at the old lock name ------------------------------------
    def test_a_leftover_lock_directory_from_the_earlier_iteration_does_not_wedge_us(self):
        (self.state / f"headsup_usage_lock_{self.mod._ACCT_KEY}").mkdir()
        self.mod.main()
        self.assertEqual(len(self.popen_calls), 1)

    # -- finding 8: the walk survives an error part-way through a listing ----------------------
    def test_a_directory_listing_that_fails_part_way_keeps_what_it_has(self):
        for n in ("a", "b", "c"):
            self.write(f"{n}.jsonl", self.lines(2))
        real_scandir = os.scandir
        def flaky(path):
            it = real_scandir(path)
            class Wrapper:
                sent = 0
                def __enter__(s):
                    it.__enter__()
                    return s
                def __exit__(s, *a):
                    return it.__exit__(*a)
                def __iter__(s):
                    return s
                def __next__(s):
                    if s.sent >= 1:
                        raise OSError(5, "EIO")
                    s.sent += 1
                    return next(it)
            return Wrapper()
        reported = []
        with mock.patch.object(os, "scandir", flaky):
            found = list(self.mod.iter_transcripts(self.mod.PROJECTS_DIR, lambda d, e: reported.append(d)))
        self.assertEqual(len(found), 1)
        self.assertEqual(len(reported), 2, "both directories that stopped listing are reported")

    # -- finding 9: a week rollover must agree with the original scan -----------------------------
    def test_the_week_rolling_over_rebuilds_so_an_aged_out_file_stops_counting(self):
        before = datetime(2026, 10, 26, 20, 45, tzinfo=timezone.utc)    # still last week
        self.write("a.jsonl", [assistant(datetime(2026, 10, 26, 20, 0, tzinfo=timezone.utc), out=1000)],
                   when=datetime(2026, 10, 26, 20, 30, tzinfo=timezone.utc))
        self.mod.refresh(before)
        self.mod.refresh(MON)                                           # week start 21:00Z has passed
        ns, nw = self.assert_matches_legacy(MON)
        self.assertEqual(ns["out"], 0, "the original ignores a file idle since before the week")
        self.assertIn('"week-rolled"', self.error_log())

    # -- behaviours the review showed untested ----------------------------------------------------
    def test_only_the_nine_known_keys_may_be_evaled(self):
        for bad in ("PATH=.", "IFS=", "SESSION_PCT=1 PATH=.", "LD_PRELOAD=x"):
            self.assertIsNone(self.mod.OUTPUT_RE.fullmatch(bad), bad)
        good = self.mod.build_output(NOW, {"out": 5, "cost": 0.0}, {"out": 9, "cost": 1.0})
        self.assertIsNotNone(self.mod.OUTPUT_RE.fullmatch(good), good)

    def test_a_state_file_owned_by_someone_else_is_refused(self):
        self.mod.atomic_write(self.mod.CACHE_FILE, json.dumps({"ts": time.time(), "output": "SESSION_PCT=1"}))
        with mock.patch.object(os, "getuid", return_value=os.getuid() + 1):
            self.assertIsNone(self.mod.read_json_file(self.mod.CACHE_FILE, "t"))
        self.assertIn("not-owned", self.error_log())

    def _edit_and_append(self, offset_from):
        p = self.write("a.jsonl", self.lines())
        self.mod.refresh(NOW)
        data = bytearray(p.read_bytes())
        i = offset_from if offset_from >= 0 else len(data) + offset_from
        data[i] = data[i] + 1 if data[i] < 126 else data[i] - 1         # same size, still a printable byte
        data += (json.dumps(assistant(NOW - timedelta(minutes=1), out=10)) + "\n").encode()
        p.write_bytes(bytes(data))
        self.touch(p, NOW + timedelta(seconds=30))
        self.mod.refresh(NOW)

    def test_an_edit_inside_the_head_is_caught_by_the_fingerprint(self):
        self._edit_and_append(10)
        self.assertIn('"fingerprint"', self.error_log())

    def test_an_edit_inside_the_tail_before_the_offset_is_caught_by_the_fingerprint(self):
        self._edit_and_append(-6)
        self.assertIn('"fingerprint"', self.error_log())


class Revision4(Rev3Support):
    """Third review (on 5dfa71d): its three new findings, and the behaviours it showed still untested."""
    # -- A: a launch stamp from the future (the clock was stepped back) must not starve refreshes --
    def test_a_future_dated_launch_stamp_does_not_block_a_refresh(self):
        os.close(self.mod.try_lock())
        tomorrow = time.time() + 86400
        os.utime(self.mod.LOCK_FILE, (tomorrow, tomorrow))
        self.mod.main()
        self.assertEqual(len(self.popen_calls), 1)

    # -- B: a checkpoint during a rebuild already carries this week, so a restart resumes ----------
    def test_a_checkpoint_saved_during_a_rebuild_survives_a_restart(self):
        self.write("a.jsonl", self.lines())
        self.mod.CHECKPOINT_SEC = 0
        real, state = self.mod.parse_usage_line, {"n": 0}
        def dying(line):
            state["n"] += 1
            if state["n"] == 30:
                raise KeyboardInterrupt()           # stands in for a kill
            return real(line)
        self.mod.parse_usage_line = dying
        with self.assertRaises(KeyboardInterrupt):
            self.mod.refresh(NOW)
        self.assertEqual(self.mod.load_index()["week"], self.mod.week_start(NOW).timestamp())
        fresh = load_module(self.config, self.state, self.home)
        fresh.refresh(NOW)
        self.assertNotIn("week-rolled", self.error_log(), "the restart resumed instead of rebuilding")
        s, w = fresh.window_totals(fresh.load_index()["slots"], fresh.block_start(NOW), fresh.week_start(NOW))
        self.assertEqual(w["out"], 500)

    # -- C: a directory that cannot be listed is reported, and existing counts are kept -------------
    def scandir_failing_for(self, bad):
        real = os.scandir
        def flaky(path):
            if str(path) == str(bad):
                raise OSError(5, "EIO")
            return real(path)
        return flaky

    def test_an_unlistable_directory_is_logged_once_per_pass_with_a_count(self):
        self.write("a.jsonl", self.lines(3))
        with mock.patch.object(os, "scandir", self.scandir_failing_for(self.proj)):
            self.mod.refresh(NOW)
        self.assertEqual(self.error_log().count('"walk"'), 1)
        self.assertIn('"count": 1', self.error_log())

    def test_a_transient_listing_failure_after_a_good_build_loses_nothing(self):
        self.write("a.jsonl", self.lines())
        self.mod.refresh(NOW)
        with mock.patch.object(os, "scandir", self.scandir_failing_for(self.proj)):
            self.mod.refresh(NOW)
        self.assertEqual(self.assert_matches_legacy()[1]["out"], 500)
        self.assertIn('"walk"', self.error_log())

    # -- error entries: cleared by a success, restarted by a changed mtime -------------------------
    def test_a_successful_scan_clears_the_files_error_entry(self):
        p = self.write("a.jsonl", self.lines())
        calls, flaky = self.flaky_open(p, 1)
        with mock.patch("builtins.open", flaky):
            self.mod.refresh(NOW)
            self.assertIn(str(p), self.mod.load_index()["errors"])
            self.mod.refresh(NOW)
        self.assertEqual(self.mod.load_index()["errors"], {})

    def test_the_failure_count_restarts_when_the_files_mtime_changes(self):
        p = self.write("a.jsonl", self.lines())
        calls, flaky = self.flaky_open(p, 3)
        with mock.patch("builtins.open", flaky):
            self.mod.refresh(NOW)
            self.mod.refresh(NOW)
            self.assertEqual(self.mod.load_index()["errors"][str(p)][1], 2)
            self.touch(p, NOW + timedelta(seconds=9))
            self.mod.refresh(NOW)
        mtime_ns, count = self.mod.load_index()["errors"][str(p)]
        self.assertEqual(count, 1, "a changed file starts counting again")
        self.assertEqual(mtime_ns, os.stat(p).st_mtime_ns)

    # -- backoff file: quiet on the status path, reported by the refresher ----------------------------
    def test_a_corrupt_backoff_file_is_silent_on_the_status_path_and_logged_by_the_refresher(self):
        self.mod.BACKOFF_FILE.write_text("{not json")
        for _ in range(20):
            self.mod.main()
        self.assertEqual(self.error_log(), "")
        self.mod.refresh(NOW)
        self.assertEqual(self.error_log().count("backoff-read"), 1)

    # -- temp files and the lock file are never followed through a symlink -------------------------
    def test_atomic_write_replaces_a_planted_symlink_instead_of_writing_through_it(self):
        victim = self.state / "victim"
        victim.write_text("keep")
        tmp = self.mod.CACHE_FILE.with_name(f"{self.mod.CACHE_FILE.name}.{os.getpid()}.tmp")
        tmp.symlink_to(victim)
        self.mod.atomic_write(self.mod.CACHE_FILE, "new")
        self.assertEqual(self.mod.CACHE_FILE.read_text(), "new")
        self.assertEqual(victim.read_text(), "keep")

    def test_the_lock_file_is_not_followed_through_a_symlink(self):
        victim = self.state / "victim"
        victim.write_text("keep")
        self.mod.LOCK_FILE.symlink_to(victim)
        with self.assertRaises(OSError):
            self.mod.try_lock()
        self.assertEqual(victim.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
