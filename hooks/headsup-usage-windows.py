#!/usr/bin/env python3
"""headsup-usage-windows.py: approximate Claude session and week usage.

Reads $CLAUDE_CONFIG_DIR/projects/**/*.jsonl (default ~/.claude/projects) across
two time windows. Usage is per-account, so the config dir must be honored:

  Session  current 6-hour block; blocks reset at 01:40 07:40 13:40 19:40 UTC
  Week     current week: Monday 17:00 ET (21:00 UTC) to following Monday

Usage metric: output tokens (primary compute signal, used for % calculation).
Cost metric: all token types weighted by API prices per model.

Limits are approximate (reverse-engineered from /status percentages).
Override via env vars:
  HEADSUP_SESSION_LIMIT   default 17_000_000 output tokens per 6h block
  HEADSUP_WEEK_LIMIT      default 140_000_000 output tokens per week

Outputs shell-eval-able assignments on one line:
  SESSION_PCT=9 SESSION_USED=1.5M SESSION_LIMIT=17M SESSION_COST=2.34
  WEEK_PCT=20 WEEK_USED=21M WEEK_LIMIT=140M WEEK_COST=15.67
  SESSION_RESET=9:40am

HOW IT STAYS CHEAP. The status line runs this in every window, and the transcripts it
reads are many GiB, so it must never do a scan on the caller's path:

  * A call prints the last cached result and returns. When that result is older than
    HEADSUP_USAGE_TTL (60s) it starts ONE detached, niced refresher and still returns
    immediately (stale-while-revalidate).
  * Single-flight: the refresher holds an atomic lock directory (with a heartbeat), so a
    burst of windows hitting an expired cache starts one refresh, not one per window.
  * Incremental: a per-file byte-offset index means only bytes appended since the last
    refresh are read. A line is JSON-parsed only if it contains "usage".
  * Totals are kept in one-minute buckets, so any window is a sum over buckets. That is
    exact because the session and week boundaries fall on whole minutes.
  * First run (no cache yet): prints nothing while the refresher builds the index, which
    checkpoints as it goes. A result older than an hour is not shown (blank beats wrong).
  * Failures are appended to headsup_usage_errors_<acct>.log in the state dir; the last
    good result keeps being served.
  * Kill switch: HEADSUP_USAGE_DISABLE=1, or a file named hooks/.headsup-usage-disabled
    under the config dir (or ~/.claude), makes it print nothing and do nothing.

State (cache, index, lock, error log) is regenerable scratch in /tmp, keyed by account;
HEADSUP_USAGE_STATE_DIR overrides the directory. `--sync` runs one refresh in the
foreground and prints the result (for tests and benchmarking); `--refresh` is the
detached worker.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Account-namespaced: Claude Code writes transcripts under $CLAUDE_CONFIG_DIR,
# so a hardcoded ~/.claude/projects makes every non-default account read the
# WRONG account's usage (zeros for session, another account's totals for week).
CONFIG_DIR    = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
PROJECTS_DIR  = CONFIG_DIR / "projects"

# Everything is keyed by account too. A single shared file lets concurrent windows on
# different accounts overwrite each other's totals.
_ACCT_KEY      = hashlib.sha256(str(PROJECTS_DIR.resolve()).encode()).hexdigest()[:8]
STATE_DIR      = Path(os.environ.get("HEADSUP_USAGE_STATE_DIR") or "/tmp")
CACHE_FILE     = STATE_DIR / f"headsup_usage_cache_{_ACCT_KEY}.json"
INDEX_FILE     = STATE_DIR / f"headsup_usage_index_{_ACCT_KEY}.json"
LOCK_DIR       = STATE_DIR / f"headsup_usage_lock_{_ACCT_KEY}"
ERROR_LOG      = STATE_DIR / f"headsup_usage_errors_{_ACCT_KEY}.log"

CACHE_TTL_SEC  = int(os.environ.get("HEADSUP_USAGE_TTL", 60))
MAX_STALE_SEC  = 3600     # an older cached result is not shown at all
LOCK_STALE_SEC = 600      # no heartbeat for this long: the holder is presumed dead
BUCKET_SEC     = 60       # window starts must be whole-minute aligned (they are)
INDEX_VERSION  = 1
CHECKPOINT_SEC = 20       # how often a long build saves the index and beats the lock

KILL_FLAGS = (
    CONFIG_DIR / "hooks" / ".headsup-usage-disabled",
    Path.home() / ".claude" / "hooks" / ".headsup-usage-disabled",
)

SESSION_LIMIT = int(os.environ.get("HEADSUP_SESSION_LIMIT", 17_000_000))
WEEK_LIMIT    = int(os.environ.get("HEADSUP_WEEK_LIMIT",   140_000_000))

SESSION_RESETS_UTC = [(1, 40), (7, 40), (13, 40), (19, 40)]

# API prices per million tokens (used for cost estimation)
# Keyed by model substring; last entry is the fallback.
MODEL_PRICES = [
    ("claude-opus",   {"inp": 15.0, "out": 75.0,  "cr": 1.50, "cw": 18.75}),
    ("claude-haiku",  {"inp":  0.8, "out":  4.0,  "cr": 0.08, "cw":  1.00}),
    ("claude-sonnet", {"inp":  3.0, "out": 15.0,  "cr": 0.30, "cw":  3.75}),
    ("",              {"inp":  3.0, "out": 15.0,  "cr": 0.30, "cw":  3.75}),  # fallback
]


def prices_for(model: str) -> dict:
    for key, p in MODEL_PRICES:
        if key in model:
            return p
    return MODEL_PRICES[-1][1]


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def fmt_limit(n: int) -> str:
    """Format a limit as a round number (no decimal for clean limits)."""
    if n >= 1_000_000:
        v = n / 1_000_000
        return f"{v:.0f}M" if v == int(v) else f"{v:.1f}M"
    if n >= 1_000:
        v = n / 1_000
        return f"{v:.0f}k" if v == int(v) else f"{v:.1f}k"
    return str(n)


def block_start(now: datetime) -> datetime:
    candidates = []
    for day_offset in (-1, 0):
        day = now.replace(hour=0, minute=0, second=0, microsecond=0) \
              + timedelta(days=day_offset)
        for h, m in SESSION_RESETS_UTC:
            t = day.replace(hour=h, minute=m)
            if t <= now:
                candidates.append(t)
    return max(candidates)


def block_next_reset(now: datetime) -> datetime:
    candidates = []
    for day_offset in (0, 1):
        day = now.replace(hour=0, minute=0, second=0, microsecond=0) \
              + timedelta(days=day_offset)
        for h, m in SESSION_RESETS_UTC:
            t = day.replace(hour=h, minute=m)
            if t > now:
                candidates.append(t)
    return min(candidates)


def week_start(now: datetime) -> datetime:
    monday = now.replace(hour=21, minute=0, second=0, microsecond=0) \
             - timedelta(days=now.weekday())
    if monday > now:
        monday -= timedelta(weeks=1)
    return monday



def disabled() -> bool:
    if os.environ.get("HEADSUP_USAGE_DISABLE") == "1":
        return True
    return any(p.exists() for p in KILL_FLAGS)


def log_error(stage: str, exc: BaseException = None, **extra) -> None:
    """Append one JSON line to ERROR_LOG. Never raises: the logger has nowhere to report
    its own failure, so that one swallow is deliberate."""
    try:
        rec = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "stage": stage, "pid": os.getpid()}
        if exc is not None:
            rec["error"] = f"{type(exc).__name__}: {exc}"
            rec["trace"] = traceback.format_exc()[-1500:]
        rec.update(extra)
        if ERROR_LOG.exists() and ERROR_LOG.stat().st_size > 262144:
            ERROR_LOG.write_text("")
        with ERROR_LOG.open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
    except Exception:  # noqa: BLE001 (deliberate, see docstring)
        pass


def atomic_write(path: Path, text: str) -> None:
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


# ── lock (single-flight) ─────────────────────────────────────────────────────

def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lock_is_stale() -> bool:
    try:
        age = time.time() - LOCK_DIR.stat().st_mtime
    except OSError:
        return False  # gone already
    if age > LOCK_STALE_SEC:
        return True
    try:
        pid = int((LOCK_DIR / "pid").read_text().strip())
    except (OSError, ValueError):
        return age > 10   # the creator is mid-write; give it a moment
    # A dead holder is only stale after a short grace: a parent hands the lock to its child.
    return (not _pid_alive(pid)) and age > 10


def acquire_lock() -> bool:
    for _ in (0, 1):
        try:
            os.mkdir(LOCK_DIR)
        except FileExistsError:
            if lock_is_stale():
                aside = LOCK_DIR.with_name(f"{LOCK_DIR.name}.stale.{os.getpid()}")
                try:
                    os.rename(LOCK_DIR, aside)   # only one reclaimer's rename can win
                    shutil.rmtree(aside, ignore_errors=True)
                except OSError:
                    pass
                continue
            return False
        except OSError as e:
            log_error("lock-acquire", e)
            return False
        try:
            (LOCK_DIR / "pid").write_text(str(os.getpid()))
        except OSError as e:
            log_error("lock-pid", e)
        return True
    return False


def adopt_lock() -> bool:
    """The detached worker takes over a lock its parent created, or acquires a fresh one."""
    if LOCK_DIR.is_dir():
        try:
            (LOCK_DIR / "pid").write_text(str(os.getpid()))
            os.utime(LOCK_DIR)
            return True
        except OSError as e:
            log_error("lock-adopt", e)
            return False
    return acquire_lock()


def beat_lock() -> None:
    try:
        os.utime(LOCK_DIR)
    except OSError:
        pass  # a failed heartbeat only risks an early reclaim; the next beat retries


def release_lock() -> None:
    try:
        if (LOCK_DIR / "pid").read_text().strip() != str(os.getpid()):
            return
        for p in LOCK_DIR.iterdir():
            p.unlink()
        LOCK_DIR.rmdir()
    except OSError as e:
        log_error("lock-release", e)


# ── incremental index ────────────────────────────────────────────────────────

def fresh_index() -> dict:
    return {"v": INDEX_VERSION, "files": {}, "slots": {}}


def load_index() -> dict:
    try:
        d = json.loads(INDEX_FILE.read_text())
        if d.get("v") == INDEX_VERSION and isinstance(d.get("files"), dict) \
                and isinstance(d.get("slots"), dict):
            d["slots"] = {int(k): v for k, v in d["slots"].items()}
            return d
    except FileNotFoundError:
        pass
    except (OSError, ValueError, TypeError) as e:
        log_error("index-load", e)
    return fresh_index()


def save_index(idx: dict) -> None:
    out = {"v": idx["v"], "files": idx["files"],
           "slots": {str(k): v for k, v in idx["slots"].items()}}
    atomic_write(INDEX_FILE, json.dumps(out, separators=(",", ":")))


def parse_usage_line(line: bytes):
    """One transcript line -> (bucket, output_tokens, cost), or None when it does not count.
    Same acceptance rules as the original scan: an assistant entry with a timestamp and usage."""
    try:
        d = json.loads(line)
    except ValueError:
        try:
            d = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            return None
    if not isinstance(d, dict) or d.get("type") != "assistant":
        return None
    ts_str = d.get("timestamp")
    msg = d.get("message", {})
    usage = msg.get("usage") if isinstance(msg, dict) else None
    if not ts_str or not usage or not isinstance(usage, dict):
        return None
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    try:
        out = usage.get("output_tokens") or 0
        inp = usage.get("input_tokens") or 0
        cr  = usage.get("cache_read_input_tokens") or 0
        cw  = usage.get("cache_creation_input_tokens") or 0
        p   = prices_for(msg.get("model", "") or "")
        cost = (inp * p["inp"] + out * p["out"] + cr * p["cr"] + cw * p["cw"]) / 1_000_000
    except (TypeError, ValueError):
        return None
    return int(ts.timestamp()) // BUCKET_SEC, out, cost


def scan_file(path: str, off: int, slots: dict, tick) -> int:
    """Add the usage in path[off:] to slots; return the byte offset consumed.
    A trailing line without a newline is counted only if it already parses as a complete
    record; otherwise it is left for the next refresh (the writer is mid-line)."""
    consumed = off
    with open(path, "rb") as fh:
        fh.seek(off)
        for line in fh:
            tick()
            has_nl = line.endswith(b"\n")
            if b'"usage"' not in line:
                if not has_nl:
                    break
                consumed += len(line)
                continue
            rec = parse_usage_line(line)
            if rec is None and not has_nl:
                break
            consumed += len(line)
            if rec is None:
                continue
            bucket, out, cost = rec
            cur = slots.get(bucket)
            if cur is None:
                slots[bucket] = [out, cost]
            else:
                cur[0] += out
                cur[1] += cost
    return consumed


def update_index(idx: dict, w_ts: float, tick) -> bool:
    """Bring idx up to date with the transcripts. Returns True when the index cannot be
    corrected in place (a file shrank or was replaced, or an in-week file vanished) and must
    be rebuilt from scratch."""
    files, slots = idx["files"], idx["slots"]
    seen = set()
    for jsonl in PROJECTS_DIR.rglob("*.jsonl"):
        try:
            st = jsonl.stat()
        except OSError:
            continue
        if st.st_mtime < w_ts:
            continue
        key = str(jsonl)
        seen.add(key)
        rec = files.get(key)
        start = 0
        if rec is not None:
            if st.st_ino != rec[0] or st.st_size < rec[1]:
                return True
            if st.st_size == rec[1]:
                continue
            start = rec[1]
        try:
            consumed = scan_file(key, start, slots, tick)
        except OSError as e:
            log_error("scan", e, path=key)
            continue
        files[key] = [st.st_ino, consumed, st.st_size, st.st_mtime]
    for key in list(files):
        if key in seen:
            continue
        try:
            st = os.stat(key)
        except OSError:
            if files[key][3] >= w_ts:
                return True          # an in-week file disappeared: its past usage cannot be subtracted
            del files[key]
            continue
        if st.st_mtime < w_ts:
            del files[key]           # aged out of the week window; its events are older than the window
    cutoff = int(w_ts) // BUCKET_SEC
    for k in [k for k in slots if k < cutoff]:
        del slots[k]
    return False


def window_totals(slots: dict, s_start: datetime, w_start: datetime):
    if s_start.timestamp() % BUCKET_SEC or w_start.timestamp() % BUCKET_SEC:
        raise ValueError("window start is not aligned to the bucket size")
    s0 = int(s_start.timestamp()) // BUCKET_SEC
    w0 = int(w_start.timestamp()) // BUCKET_SEC
    s = {"out": 0, "cost": 0.0}
    w = {"out": 0, "cost": 0.0}
    for k, (o, c) in slots.items():
        if k >= w0:
            w["out"] += o
            w["cost"] += c
        if k >= s0:
            s["out"] += o
            s["cost"] += c
    return s, w


def build_output(now: datetime, s: dict, w: dict) -> str:
    s_pct = min(100, int(s["out"] * 100 / SESSION_LIMIT))
    w_pct = min(100, int(w["out"] * 100 / WEEK_LIMIT))

    local_reset = block_next_reset(now).astimezone()
    hour = local_reset.hour % 12 or 12
    ampm = "am" if local_reset.hour < 12 else "pm"
    reset_str = f"{hour}:{local_reset.minute:02d}{ampm}"

    return " ".join([
        f"SESSION_PCT={s_pct}",
        f"SESSION_USED={fmt_tokens(s['out'])}",
        f"SESSION_LIMIT_FMT={fmt_limit(SESSION_LIMIT)}",
        f"SESSION_COST={s['cost']:.2f}",
        f"WEEK_PCT={w_pct}",
        f"WEEK_USED={fmt_tokens(w['out'])}",
        f"WEEK_LIMIT_FMT={fmt_limit(WEEK_LIMIT)}",
        f"WEEK_COST={w['cost']:.2f}",
        f"SESSION_RESET={reset_str}",
    ])


def refresh(now: datetime = None) -> str:
    """Update the index, write it and the output cache atomically, return the output line."""
    now = now or datetime.now(timezone.utc)
    s_start, w_start = block_start(now), week_start(now)
    w_ts = w_start.timestamp()

    state = {"last": time.monotonic()}

    def tick():
        if time.monotonic() - state["last"] >= CHECKPOINT_SEC:
            state["last"] = time.monotonic()
            beat_lock()
            save_index(idx)   # consistent at any line boundary: a restart resumes from here

    idx = load_index()
    if update_index(idx, w_ts, tick):
        idx = fresh_index()
        if update_index(idx, w_ts, tick):
            raise RuntimeError("index still inconsistent after a clean rebuild")

    s, w = window_totals(idx["slots"], s_start, w_start)
    output = build_output(now, s, w)
    save_index(idx)
    atomic_write(CACHE_FILE, json.dumps({"ts": now.timestamp(), "output": output}))
    return output


# ── entry points ─────────────────────────────────────────────────────────────

def read_cache():
    try:
        d = json.loads(CACHE_FILE.read_text())
        if isinstance(d.get("ts"), (int, float)) and isinstance(d.get("output"), str):
            return d
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        log_error("cache-read", e)
    return None


def start_refresher() -> None:
    """Spawn the detached worker unless a live one already holds the lock."""
    if LOCK_DIR.exists() and not lock_is_stale():
        return
    if not acquire_lock():
        return
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--refresh"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, close_fds=True,
            env={**os.environ, "HEADSUP_USAGE_LOCK_HANDOFF": "1"},
        )
    except OSError as e:
        log_error("spawn", e)
        release_lock()


def run_refresh(sync: bool) -> int:
    held = adopt_lock() if os.environ.get("HEADSUP_USAGE_LOCK_HANDOFF") == "1" else acquire_lock()
    if not held:
        if sync:
            print("headsup-usage-windows: another refresh holds the lock", file=sys.stderr)
        return 0
    try:
        try:
            os.nice(10)
        except OSError:
            pass  # lowering priority is a courtesy; the refresh is still correct without it
        output = refresh()
    except Exception as e:  # noqa: BLE001 (logged; the last good cache keeps being served)
        log_error("refresh", e)
        if sync:
            print(f"headsup-usage-windows: refresh failed: {e}", file=sys.stderr)
        return 1
    finally:
        release_lock()
    if sync:
        print(output)
    return 0


def main() -> int:
    if disabled():
        return 0
    if len(sys.argv) > 1 and sys.argv[1] in ("--refresh", "--sync"):
        return run_refresh(sync=sys.argv[1] == "--sync")
    cached = read_cache()
    if cached is not None:
        age = time.time() - cached["ts"]
        if age < MAX_STALE_SEC:
            print(cached["output"])
        if age < CACHE_TTL_SEC:
            return 0
    start_refresher()
    return 0


if __name__ == "__main__":
    sys.exit(main())
