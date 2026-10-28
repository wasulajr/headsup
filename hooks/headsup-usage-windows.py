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
  * Single-flight by flock: the refresher holds an exclusive flock on a lock file that the
    parent hands to it. The kernel drops the lock when the holder dies, however it dies, so
    there is no stale-lock guessing. A worker still running after 30 minutes is stopped by a
    SIGALRM watchdog. That cannot interrupt a read stuck in the kernel (a hung network volume):
    callers then keep serving the last cache until it is an hour old, and print nothing after.
  * Incremental: a per-file byte-offset index means only bytes appended since the last
    refresh are read. A line is JSON-parsed only if it contains "usage". Counts and the
    offset that produced them are committed together (and checkpointed during a long
    build), so a failure or kill part-way through a file never double counts.
  * Totals are kept in one-minute buckets, so any window is a sum over buckets. That is
    exact because the session and week boundaries fall on whole minutes. Buckets are kept
    back to the EARLIER of the two window starts (the session block can start before the week).
  * The index is rebuilt from scratch when a file shrinks, is replaced, vanishes, goes back in
    time, or no longer matches its head/tail fingerprint, and once a day regardless, which
    bounds any drift an in-place edit could cause.
  * The walk skips tool-results directories (persisted tool output; about 85% of the files
    under projects/ and none of the transcripts), instead of rglob over everything.
  * First run (no cache yet): prints nothing while the refresher builds the index. A cached
    line older than an hour, or one that is not a plain KEY=value line, is not printed.
  * A file whose read fails is retried on the next refreshes and parked only after 3 failures in
    a row at the same mtime. A failure to save the index fails the whole refresh instead.
  * A failed refresh is logged (headsup_usage_errors_<acct>.log in the state dir), keeps the
    last good cache, and backs off exponentially (1 minute up to 1 hour) instead of retrying
    on every status-line call. A malformed record is dropped and counted, not fatal.
  * Kill switch: HEADSUP_USAGE_DISABLE=1, or a file named hooks/.headsup-usage-disabled
    under the config dir (or ~/.claude), makes it print nothing and do nothing.

Known differences from the old full scan: a bare carriage return between records is not a
record separator, an escaped "usage" key is not matched by the prefilter, and a .jsonl file
inside a tool-results directory is not read. None of these occur in Claude Code transcripts.

State (cache, index, lock, backoff, error log) is regenerable scratch in /tmp, keyed by
account; HEADSUP_USAGE_STATE_DIR overrides the directory. `--sync` runs one refresh in the
foreground and prints the result (for tests and benchmarking); `--refresh` is the detached worker.
"""

import hashlib
import json
import math
import os
import re
import sys
import time
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
# "flock", not "lock": an earlier iteration made a DIRECTORY named headsup_usage_lock_<acct>.
LOCK_FILE      = STATE_DIR / f"headsup_usage_flock_{_ACCT_KEY}"
BACKOFF_FILE   = STATE_DIR / f"headsup_usage_backoff_{_ACCT_KEY}.json"
ERROR_LOG      = STATE_DIR / f"headsup_usage_errors_{_ACCT_KEY}.log"

CACHE_TTL_SEC   = int(os.environ.get("HEADSUP_USAGE_TTL", 60))
MAX_STALE_SEC   = 3600    # an older cached result is not shown at all
BUCKET_SEC      = 60      # window starts must be whole-minute aligned (they are)
INDEX_VERSION   = 2
CHECKPOINT_SEC  = 20      # how often a long build commits and saves the index
REBUILD_SEC     = 86400   # full rebuild at least this often (bounds any undetected drift)
MAX_RUN_SEC     = 1800    # a worker still running after this is killed
MAX_BACKOFF_SEC = 3600
SPAWN_GAP_SEC   = 20      # least time between worker launches, stamped on the lock file itself
FILE_ERROR_MAX  = 3       # failed reads of one file, in a row, before it is parked
ERROR_LOG_MAX   = 262144
ERROR_LOG_KEEP  = 65536   # a truncated log keeps this much of its tail
SKIP_DIRS       = {"tool-results"}   # persisted tool output, never a transcript

# The only shape the status line may eval: KEY=value pairs of plain characters.
_KEYS = ("SESSION_PCT|SESSION_USED|SESSION_LIMIT_FMT|SESSION_COST|WEEK_PCT|WEEK_USED|"
         "WEEK_LIMIT_FMT|WEEK_COST|SESSION_RESET")
OUTPUT_RE = re.compile(rf"(?:{_KEYS})=[A-Za-z0-9.:%-]*(?: (?:{_KEYS})=[A-Za-z0-9.:%-]*)*")

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
            import traceback
            rec["error"] = f"{type(exc).__name__}: {exc}"
            rec["trace"] = traceback.format_exc()[-1500:]
        rec.update(extra)
        if ERROR_LOG.exists() and ERROR_LOG.stat().st_size > ERROR_LOG_MAX:
            with ERROR_LOG.open("rb") as old:
                old.seek(-ERROR_LOG_KEEP, os.SEEK_END)
                tail = old.read().split(b"\n", 1)[-1]      # drop the cut first line
            ERROR_LOG.write_bytes(tail)
        with ERROR_LOG.open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
    except Exception:  # noqa: BLE001 (deliberate, see docstring)
        pass


def atomic_write(path: Path, text: str) -> None:
    """Write 0600 to a temp name and rename over path; the temp file never outlives a failure."""
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        try:
            os.unlink(tmp)      # a leftover from a killed run with a recycled pid
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass  # nothing to clean up if the temp file was never created
        raise


def read_json_file(path: Path, stage: str, quiet: bool = False):
    """Parsed JSON object from a file this user owns, or None. Corruption is logged, except on
    the status-line path (quiet): that runs on every call, and the refresher logs it instead."""
    try:
        if os.stat(path).st_uid != os.getuid():
            if not quiet:
                log_error(stage, reason="not-owned", path=str(path))
            return None
        d = json.loads(Path(path).read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        if not quiet:
            log_error(stage, e)
        return None
    if not isinstance(d, dict):
        if not quiet:
            log_error(stage, reason="not-an-object", path=str(path))
        return None
    return d


# ── single-flight (flock) ────────────────────────────────────────────────────

def try_lock():
    """Take the exclusive refresh lock without blocking; return its fd, or None if held.
    flock belongs to the open file description, so it survives being handed to a child and
    is released by the kernel when the last holder exits or dies."""
    import fcntl
    flags = os.O_RDWR | os.O_NOFOLLOW
    try:
        fd = os.open(LOCK_FILE, flags | os.O_CREAT | os.O_EXCL, 0o600)
        os.utime(fd, (0, 0))        # never launched: SPAWN_GAP_SEC must not throttle the first launch
    except FileExistsError:
        fd = os.open(LOCK_FILE, flags)
    if fd < 3:
        # stdin/stdout/stderr may be closed in an odd launch context; the child's DEVNULL
        # redirects would then land on the lock and silently drop it.
        moved = fcntl.fcntl(fd, getattr(fcntl, "F_DUPFD_CLOEXEC", fcntl.F_DUPFD), 3)
        os.close(fd)
        fd = moved
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def inherited_lock_fd():
    raw = os.environ.get("HEADSUP_USAGE_LOCK_FD")
    if not raw:
        return None
    try:
        fd = int(raw)
        held, named = os.fstat(fd), os.stat(LOCK_FILE)
        if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
            return None             # an unrelated descriptor, not this account's lock
        return fd
    except (ValueError, OSError):
        return None


# ── failure backoff ──────────────────────────────────────────────────────────

def backoff_remaining(quiet: bool = False) -> float:
    d = read_json_file(BACKOFF_FILE, "backoff-read", quiet=quiet)
    until = d.get("until") if d else None
    if isinstance(until, bool) or not isinstance(until, (int, float)):
        return 0.0
    return max(0.0, min(float(MAX_BACKOFF_SEC), until - time.time()))   # a wrong clock cannot ban us for years


def note_failure() -> None:
    try:
        prev = read_json_file(BACKOFF_FILE, "backoff-read") or {}
        n = prev.get("n", 0) if isinstance(prev.get("n", 0), int) else 0
        n += 1
        wait = min(MAX_BACKOFF_SEC, 60 * 2 ** min(n - 1, 6))
        atomic_write(BACKOFF_FILE, json.dumps({"n": n, "until": time.time() + wait}))
    except Exception as e:  # noqa: BLE001
        log_error("backoff-write", e)


def clear_backoff() -> None:
    try:
        os.unlink(BACKOFF_FILE)
    except FileNotFoundError:
        pass
    except OSError as e:
        log_error("backoff-clear", e)


# ── incremental index ────────────────────────────────────────────────────────

def fresh_index() -> dict:
    return {"v": INDEX_VERSION, "built_at": time.time(), "week": None, "files": {}, "slots": {}, "errors": {}}


def load_index() -> dict:
    d = read_json_file(INDEX_FILE, "index-load")
    if d is not None:
        try:
            if d.get("v") == INDEX_VERSION and isinstance(d.get("files"), dict) \
                    and isinstance(d.get("slots"), dict) and isinstance(d.get("errors", {}), dict) \
                    and isinstance(d.get("built_at"), (int, float)):
                slots = {int(k): [v[0], v[1]] for k, v in d["slots"].items()}
                for rec in d["files"].values():
                    if len(rec) != 5:
                        raise ValueError("bad file record")
                errors = {k: v for k, v in d.get("errors", {}).items()
                          if isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) for x in v)}
                return {"v": d["v"], "built_at": d["built_at"], "week": d.get("week"), "files": d["files"],
                        "slots": slots, "errors": errors}
        except (ValueError, TypeError, IndexError, KeyError) as e:
            log_error("index-load", e)
    return fresh_index()


def save_index(idx: dict) -> None:
    out = {"v": idx["v"], "built_at": idx["built_at"], "week": idx.get("week"), "files": idx["files"],
           "slots": {str(k): v for k, v in idx["slots"].items()}, "errors": idx["errors"]}
    atomic_write(INDEX_FILE, json.dumps(out, separators=(",", ":")))


def iter_transcripts(root):
    """Yield (path, stat) for every *.jsonl file under root, like rglob("*.jsonl") but without
    descending into SKIP_DIRS and without following directory symlinks."""
    stack = [str(root)]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            while True:
                try:
                    e = next(it)
                except (StopIteration, OSError):
                    break               # end of listing, or it became unreadable part-way: keep what we have
                try:
                    if e.is_dir(follow_symlinks=False):
                        if e.name not in SKIP_DIRS:
                            stack.append(e.path)
                    elif e.name.endswith(".jsonl") and e.is_file():
                        yield e.path, e.stat()
                except OSError:
                    continue


class BadRecord(Exception):
    """A usage record whose numbers cannot be summed; it is dropped and counted."""


def _num(v):
    if v is None:
        return 0
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise BadRecord()
    if isinstance(v, float) and not math.isfinite(v):
        raise BadRecord()
    return v


def parse_usage_line(line: bytes):
    """One transcript line -> (bucket, output_tokens, cost), or None when it does not count.
    Same acceptance rules as the original scan: an assistant entry with a timestamp and usage.
    Raises BadRecord when the usage numbers themselves are unusable."""
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
        out = _num(usage.get("output_tokens"))
        inp = _num(usage.get("input_tokens"))
        cr  = _num(usage.get("cache_read_input_tokens"))
        cw  = _num(usage.get("cache_creation_input_tokens"))
        p   = prices_for(msg.get("model", "") or "")
        cost = (inp * p["inp"] + out * p["out"] + cr * p["cr"] + cw * p["cw"]) / 1_000_000
        if not math.isfinite(cost):
            raise BadRecord()
    except (TypeError, ValueError, ArithmeticError):
        raise BadRecord()
    return int(ts.timestamp()) // BUCKET_SEC, out, cost


def fingerprint(fd: int, off: int) -> str:
    """Cheap identity of a file's content around a committed offset: its first 128 bytes and
    the 64 bytes just before the offset. Detects an in-place rewrite without rereading it."""
    if off <= 0:
        return ""
    head = os.pread(fd, min(128, off), 0)
    tail = os.pread(fd, min(64, off), max(0, off - 64))
    return hashlib.blake2b(head + tail, digest_size=8).hexdigest()


def scan_file(key: str, st, off: int, expect_fp: str, idx: dict, checkpoint, stats: dict):
    """Add the usage in key[off:] to idx. Counts and the offset that produced them are
    committed to the index TOGETHER (at checkpoints and at the end), so an error or a kill
    part-way through leaves the index consistent. A trailing line without a newline is
    counted only if it already parses as a complete record; otherwise it is left for the
    next refresh (the writer is mid-line). Returns a rebuild reason, or None."""
    files, slots = idx["files"], idx["slots"]
    delta = {}
    consumed = off
    fd = None

    def commit(final: bool) -> None:
        for b, (o, c) in delta.items():
            cur = slots.get(b)
            if cur is None:
                slots[b] = [o, c]
            else:
                cur[0] += o
                cur[1] += c
        delta.clear()
        # A mid-file checkpoint records size and mtime that can never match the file, so a
        # restart rescans from the committed offset; only a finished scan can be skipped later.
        files[key] = [st.st_ino, consumed,
                      st.st_size if final else consumed,
                      st.st_mtime_ns if final else 0,
                      fingerprint(fd, consumed)]

    try:
        with open(key, "rb") as fh:
            fd = fh.fileno()
            if off and fingerprint(fd, off) != expect_fp:
                return "fingerprint"
            fh.seek(off)
            next_ck = time.monotonic() + CHECKPOINT_SEC
            for line in fh:
                has_nl = line.endswith(b"\n")
                if b'"usage"' not in line:
                    if not has_nl:
                        break
                    consumed += len(line)
                else:
                    try:
                        rec = parse_usage_line(line)
                    except BadRecord:
                        stats["bad"] += 1
                        rec = None
                    if rec is None and not has_nl:
                        break
                    consumed += len(line)
                    if rec is not None:
                        bucket, out, cost = rec
                        cur = delta.get(bucket)
                        if cur is None:
                            delta[bucket] = [out, cost]
                        else:
                            cur[0] += out
                            cur[1] += cost
                if time.monotonic() >= next_ck:
                    commit(False)
                    checkpoint()
                    next_ck = time.monotonic() + CHECKPOINT_SEC
            commit(True)
        idx["errors"].pop(key, None)
    except OSError as e:
        log_error("scan", e, path=key)
        prev = idx["errors"].get(key)
        n = prev[1] + 1 if prev and prev[0] == st.st_mtime_ns else 1
        idx["errors"][key] = [st.st_mtime_ns, n]    # parked once n reaches FILE_ERROR_MAX
    return None


def update_index(idx: dict, w_ts: float, keep_ts: float, checkpoint, stats: dict):
    """Bring idx up to date with the transcripts. Returns None, or a reason string when the
    index cannot be corrected in place and must be rebuilt from scratch."""
    files, slots, errors = idx["files"], idx["slots"], idx["errors"]
    seen = set()
    for key, st in iter_transcripts(PROJECTS_DIR):
        if st.st_mtime < w_ts:
            continue
        seen.add(key)
        parked = errors.get(key)
        if parked and parked[0] == st.st_mtime_ns and parked[1] >= FILE_ERROR_MAX:
            continue                # failed repeatedly; retried only when the file changes
        rec = files.get(key)
        start, expect = 0, ""
        if rec is not None:
            if st.st_ino != rec[0] or st.st_size < rec[1]:
                return "replaced-or-truncated"
            if st.st_mtime_ns < rec[3]:
                return "mtime-regressed"
            if st.st_size == rec[2] and st.st_mtime_ns == rec[3]:
                continue
            start, expect = rec[1], rec[4]
        reason = scan_file(key, st, start, expect, idx, checkpoint, stats)
        if reason:
            return reason
    for key in list(files):
        if key in seen:
            continue
        try:
            st = os.stat(key)
        except OSError:
            if files[key][3] == 0 or files[key][3] / 1e9 >= w_ts:     # 0: only a checkpoint was saved
                return "in-week-file-vanished"    # its past usage cannot be subtracted
            del files[key]
            continue
        if st.st_mtime_ns < files[key][3]:
            return "mtime-regressed"
        if st.st_mtime < w_ts:
            del files[key]           # aged out of the week window; its events are older than the window
    for key in [k for k in errors if k not in seen]:
        del errors[key]
    cutoff = int(keep_ts) // BUCKET_SEC
    for k in [k for k in slots if k < cutoff]:
        del slots[k]
    return None


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


class CheckpointError(Exception):
    """The index could not be saved part-way through a build: the refresh fails (and backs off),
    which is not the transcript's fault and must not park the file being read."""


def refresh(now: datetime = None) -> str:
    """Update the index, write it and the output cache atomically, return the output line."""
    now = now or datetime.now(timezone.utc)
    s_start, w_start = block_start(now), week_start(now)
    w_ts = w_start.timestamp()
    keep_ts = min(w_ts, s_start.timestamp())   # the session block can start before the week does
    stats = {"bad": 0}

    def checkpoint():
        try:
            save_index(idx)
        except OSError as e:
            raise CheckpointError(f"could not save the index at a checkpoint: {e}") from e

    read_cache(quiet=False)         # the status line reads quietly; a corrupt cache is logged here, once per run

    idx = load_index()
    reason = "periodic" if time.time() - idx["built_at"] > REBUILD_SEC else None
    if reason is None and idx["files"] and idx.get("week") != w_ts:
        reason = "week-rolled"      # files that aged out of the week still hold slots the old scan ignored
    if reason is None:
        reason = update_index(idx, w_ts, keep_ts, checkpoint, stats)
    if reason:
        log_error("rebuild", reason=reason)
        idx = fresh_index()
        stats["bad"] = 0
        reason = update_index(idx, w_ts, keep_ts, checkpoint, stats)
        if reason:
            raise RuntimeError(f"index still inconsistent after a clean rebuild: {reason}")

    s, w = window_totals(idx["slots"], s_start, w_start)
    output = build_output(now, s, w)
    if not OUTPUT_RE.fullmatch(output):
        raise RuntimeError("refusing to cache an output line that is not plain KEY=value pairs")
    idx["week"] = w_ts
    save_index(idx)
    atomic_write(CACHE_FILE, json.dumps({"ts": now.timestamp(), "output": output}))
    if stats["bad"]:
        log_error("bad-records", count=stats["bad"])
    return output


# ── entry points ─────────────────────────────────────────────────────────────

def read_cache(quiet: bool = True):
    d = read_json_file(CACHE_FILE, "cache-read", quiet=quiet)
    if d is None:
        return None
    ts, out = d.get("ts"), d.get("output")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)) or not math.isfinite(ts) \
            or not isinstance(out, str) or not OUTPUT_RE.fullmatch(out):
        if not quiet:
            log_error("cache-read", reason="invalid-fields")
        return None
    return d


def start_refresher() -> None:
    """Spawn the detached worker unless one already holds the lock or we are backing off."""
    if backoff_remaining(quiet=True) > 0:
        return
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        fd = try_lock()
    except OSError as e:
        log_error("lock", e)
        return
    if fd is None:
        return
    try:
        # The backoff file lives on the disk a failing refresh may be unable to write, so this
        # throttle needs no disk space: the last launch time is the lock file's own mtime.
        if time.time() - os.fstat(fd).st_mtime < SPAWN_GAP_SEC:
            return
        os.utime(fd)
        import subprocess
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--refresh"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, close_fds=True, pass_fds=(fd,),
            env={**os.environ, "HEADSUP_USAGE_LOCK_FD": str(fd)},
        )
    except OSError as e:
        log_error("spawn", e)
    finally:
        os.close(fd)     # the child keeps the lock through its inherited copy


class RefreshTimeout(BaseException):
    """The watchdog fired. A BaseException on purpose: the `except OSError`/`except Exception`
    handlers on the scan path must not swallow it (TimeoutError is an OSError and would be)."""


def run_refresh(sync: bool) -> int:
    import signal
    fd = inherited_lock_fd()
    if fd is None:
        try:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            fd = try_lock()
        except OSError as e:
            log_error("lock", e)
            return 1
    if fd is None:
        if sync:
            print("headsup-usage-windows: another refresh holds the lock", file=sys.stderr)
        return 0

    def on_alarm(signum, frame):
        raise RefreshTimeout(f"refresh still running after {MAX_RUN_SEC}s")

    try:
        signal.signal(signal.SIGALRM, on_alarm)
        signal.alarm(MAX_RUN_SEC)
        try:
            os.nice(10)
        except OSError:
            pass  # lowering priority is a courtesy; the refresh is still correct without it
        output = refresh()
        clear_backoff()
    except (Exception, RefreshTimeout) as e:  # noqa: BLE001 (logged; the last good cache keeps being served)
        log_error("refresh", e)
        note_failure()
        if sync:
            print(f"headsup-usage-windows: refresh failed: {e}", file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        os.close(fd)
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
        if -60 <= age < MAX_STALE_SEC:     # a future-dated cache beyond clock skew is not trusted
            print(cached["output"])
            if 0 <= age < CACHE_TTL_SEC:
                return 0
    start_refresher()
    return 0


if __name__ == "__main__":
    sys.exit(main())
