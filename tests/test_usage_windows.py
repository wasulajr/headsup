"""Tests for hooks/headsup-usage-windows.py.

The reference for correctness is the ORIGINAL full-scan aggregate(), copied verbatim below
(from headsup origin/main before the incremental rewrite). Every totals check compares the
new incremental result with that function over the same fixture files.

Run:  python3 -m unittest discover -s tests -v
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "hooks" / "headsup-usage-windows.py"
NOW = datetime(2026, 10, 28, 12, 0, 0, tzinfo=timezone.utc)   # a Wednesday
# session block start 07:40Z today; week start Monday 10/26 21:00Z


def load_module(config_dir, state_dir, home):
    """Import the script fresh with its env-derived constants pointing at temp dirs."""
    saved = {k: os.environ.get(k) for k in ("CLAUDE_CONFIG_DIR", "HEADSUP_USAGE_STATE_DIR", "HOME",
                                             "HEADSUP_USAGE_DISABLE", "HEADSUP_USAGE_TTL")}
    os.environ.update({"CLAUDE_CONFIG_DIR": str(config_dir), "HEADSUP_USAGE_STATE_DIR": str(state_dir),
                       "HOME": str(home)})
    os.environ.pop("HEADSUP_USAGE_DISABLE", None)
    os.environ.pop("HEADSUP_USAGE_TTL", None)
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
def aggregate(s_start: datetime, w_start: datetime):
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


def legacy_totals(mod, s_start, w_start):
    ns = {"PROJECTS_DIR": mod.PROJECTS_DIR, "json": json, "datetime": datetime, "prices_for": mod.prices_for}
    exec(LEGACY_SRC, ns)
    return ns["aggregate"](s_start, w_start)


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


def assistant(ts, model="claude-sonnet-5-5", out=100, inp=10, cr=1000, cw=50):
    return {"type": "assistant", "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
            "message": {"model": model, "usage": {"output_tokens": out, "input_tokens": inp,
                                                    "cache_read_input_tokens": cr,
                                                    "cache_creation_input_tokens": cw}}}


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

    def write(self, name, items, final_newline=True, mode="w"):
        path = self.proj / name
        body = "\n".join(i if isinstance(i, str) else json.dumps(i) for i in items)
        if final_newline and items:
            body += "\n"
        with open(path, mode + "b") as fh:
            fh.write(body.encode("utf-8", "surrogateescape"))
        self.touch(path)
        return path

    def touch(self, path, when=NOW):
        os.utime(path, (when.timestamp(), when.timestamp()))

    def assert_matches_legacy(self, now=NOW):
        s_start, w_start = self.mod.block_start(now), self.mod.week_start(now)
        ls, lw = legacy_totals(self.mod, s_start, w_start)
        idx = self.mod.load_index()
        ns, nw = self.mod.window_totals(idx["slots"], s_start, w_start)
        self.assertEqual(ns["out"], ls["out"], "session output tokens")
        self.assertEqual(nw["out"], lw["out"], "week output tokens")
        self.assertAlmostEqual(ns["cost"], ls["cost"], places=6)
        self.assertAlmostEqual(nw["cost"], lw["cost"], places=6)
        return ns, nw


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

    def test_files_older_than_the_week_are_ignored(self):
        p = self.write("old.jsonl", [assistant(NOW - timedelta(minutes=1), out=777)])
        self.touch(p, NOW - timedelta(days=9))
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 0)


class Incremental(Base):
    def spy(self):
        calls = []
        real = self.mod.scan_file
        def wrapped(path, off, slots, tick):
            calls.append((Path(path).name, off))
            return real(path, off, slots, tick)
        self.mod.scan_file = wrapped
        return calls

    def test_only_appended_bytes_are_read(self):
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=5)])
        self.write("quiet.jsonl", [assistant(NOW - timedelta(minutes=8), out=6)])
        self.mod.refresh(NOW)
        size1 = p.stat().st_size
        calls = self.spy()
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=3), out=50)], mode="a")
        self.mod.refresh(NOW)
        self.assertEqual(calls, [("a.jsonl", size1)], "unchanged file skipped, changed file read from its offset")
        self.assert_matches_legacy()

    def test_partial_trailing_line_is_deferred_then_counted_once(self):
        full = json.dumps(assistant(NOW - timedelta(minutes=4), out=40))
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=5)])
        with open(p, "ab") as fh:
            fh.write(full[: len(full) // 2].encode())          # writer is mid-line
        self.touch(p)
        self.mod.refresh(NOW)
        s, w = self.mod.window_totals(self.mod.load_index()["slots"], self.mod.block_start(NOW), self.mod.week_start(NOW))
        self.assertEqual(w["out"], 5, "the half line is not counted yet")
        with open(p, "ab") as fh:
            fh.write(full[len(full) // 2:].encode() + b"\n")
        self.touch(p)
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
        self.touch(p)
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 32)

    def test_truncated_file_forces_a_clean_rebuild(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=500), assistant(NOW - timedelta(minutes=8), out=400)])
        self.mod.refresh(NOW)
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=7), out=3)])       # rewritten shorter
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 3)

    def test_deleted_in_week_file_forces_a_rebuild(self):
        p = self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=500)])
        self.write("b.jsonl", [assistant(NOW - timedelta(minutes=8), out=4)])
        self.mod.refresh(NOW)
        p.unlink()
        self.mod.refresh(NOW)
        ns, nw = self.assert_matches_legacy()
        self.assertEqual(nw["out"], 4)

    def test_buckets_older_than_the_week_are_pruned(self):
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=9), out=1)])
        self.mod.refresh(NOW)
        later = NOW + timedelta(days=8)
        p = self.proj / "a.jsonl"
        self.touch(p, later)
        with open(p, "ab") as fh:
            fh.write(json.dumps(assistant(later - timedelta(minutes=1), out=2)).encode() + b"\n")
        self.touch(p, later)
        self.mod.refresh(later)
        idx = self.mod.load_index()
        cutoff = int(self.mod.week_start(later).timestamp()) // self.mod.BUCKET_SEC
        self.assertTrue(all(k >= cutoff for k in idx["slots"]))


class SingleFlightAndCaching(Base):
    def setUp(self):
        super().setUp()
        self.popen_calls = []
        class FakePopen:
            def __init__(inner, *a, **k):
                self.popen_calls.append(a)
        patcher = mock.patch.object(self.mod.subprocess, "Popen", FakePopen)
        patcher.start()
        self.addCleanup(patcher.stop)
        argv = mock.patch.object(sys, "argv", ["x"])
        argv.start()
        self.addCleanup(argv.stop)
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

    def test_lock_has_one_holder_and_stale_locks_are_reclaimed(self):
        self.assertTrue(self.mod.acquire_lock())
        self.assertFalse(self.mod.acquire_lock())
        past = time.time() - self.mod.LOCK_STALE_SEC - 5
        os.utime(self.mod.LOCK_DIR, (past, past))
        self.assertTrue(self.mod.acquire_lock(), "a lock with no heartbeat past the limit is reclaimed")
        self.mod.release_lock()
        self.assertFalse(self.mod.LOCK_DIR.exists())

    def test_dead_holder_is_reclaimed_after_the_grace_period(self):
        self.assertTrue(self.mod.acquire_lock())
        (self.mod.LOCK_DIR / "pid").write_text("999999")     # no such process
        self.assertFalse(self.mod.acquire_lock(), "inside the grace period the lock still holds")
        past = time.time() - 30
        os.utime(self.mod.LOCK_DIR, (past, past))
        self.assertTrue(self.mod.acquire_lock())

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

    def test_corrupt_cache_and_index_are_logged_not_fatal(self):
        self.mod.CACHE_FILE.write_text("{not json")
        self.mod.INDEX_FILE.write_text("garbage")
        self.mod.main()                                      # must not raise
        self.assertEqual(len(self.popen_calls), 1)
        self.write("a.jsonl", [assistant(NOW - timedelta(minutes=2), out=9)])
        self.mod.refresh(NOW)                                # rebuilds past the corrupt index
        self.assert_matches_legacy()
        log = self.mod.ERROR_LOG.read_text()
        self.assertIn("cache-read", log)
        self.assertIn("index-load", log)

    def test_a_failed_refresh_is_logged_keeps_the_cache_and_frees_the_lock(self):
        self.write_cache(120, output="SESSION_PCT=42")
        def boom(*a, **k):
            raise OSError("disk on fire")
        self.mod.update_index = boom
        self.assertEqual(self.mod.run_refresh(sync=False), 1)
        self.assertIn("disk on fire", self.mod.ERROR_LOG.read_text())
        self.assertEqual(json.loads(self.mod.CACHE_FILE.read_text())["output"], "SESSION_PCT=42")
        self.assertFalse(self.mod.LOCK_DIR.exists())


class EndToEnd(Base):
    """Real processes: the status-line call returns at once and the detached worker fills the cache."""
    def env(self):
        e = dict(os.environ)
        e.update({"CLAUDE_CONFIG_DIR": str(self.config), "HEADSUP_USAGE_STATE_DIR": str(self.state),
                  "HOME": str(self.home)})
        e.pop("HEADSUP_USAGE_DISABLE", None)
        return e

    def run_script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env(), capture_output=True,
                              text=True, timeout=60)

    def test_sync_prints_the_expected_line(self):
        now = datetime.now(timezone.utc)
        self.write("a.jsonl", [assistant(now, out=250)])
        self.touch(self.proj / "a.jsonl", now)
        r = self.run_script("--sync")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WEEK_USED=250", r.stdout)
        self.assertIn("SESSION_USED=250", r.stdout)

    def test_detached_worker_fills_the_cache_and_releases_the_lock(self):
        now = datetime.now(timezone.utc)
        self.write("a.jsonl", [assistant(now, out=250)])
        self.touch(self.proj / "a.jsonl", now)
        started = time.monotonic()
        r = self.run_script()
        self.assertEqual(r.stdout, "", "first call has no cache and prints nothing")
        self.assertLess(time.monotonic() - started, 5, "the call must not wait for the scan")
        cache = next(self.state.glob("headsup_usage_cache_*.json"), None)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and (cache is None or not cache.exists()):
            time.sleep(0.2)
            cache = next(self.state.glob("headsup_usage_cache_*.json"), None)
        self.assertIsNotNone(cache, "the detached refresher never wrote the cache")
        while time.monotonic() < deadline and any(self.state.glob("headsup_usage_lock_*")):
            time.sleep(0.2)
        self.assertFalse(any(self.state.glob("headsup_usage_lock_*")), "lock left behind")
        r2 = self.run_script()
        self.assertIn("WEEK_USED=250", r2.stdout)
        self.assertFalse(list(self.state.glob("headsup_usage_errors_*")), "unexpected errors logged")


if __name__ == "__main__":
    unittest.main()
