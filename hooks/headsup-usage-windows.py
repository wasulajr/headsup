#!/usr/bin/env python3
"""headsup-usage-windows.py — approximate Claude session and week usage.

Reads ~/.claude/projects/**/*.jsonl, summing output tokens (the primary
compute metric) across two windows:

  Session  current 6-hour block; blocks reset at 01:40 07:40 13:40 19:40 UTC
  Week     current week: Monday 17:00 ET (21:00 UTC) to following Monday

Limits are approximate (reverse-engineered from /status percentages).
Override via env vars or ~/.claude/hooks/headsup-status.conf:
  HEADSUP_SESSION_LIMIT   default 17_000_000 output tokens per 6h block
  HEADSUP_WEEK_LIMIT      default 140_000_000 output tokens per week

Outputs shell-eval-able assignment string, one line:
  SESSION_PCT=9 WEEK_PCT=15 SESSION_RESET=9:40am

Results are cached in /tmp/headsup_usage_cache.json for CACHE_TTL_SEC so
the statusLine hook stays fast on every tool call.
"""

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"
CACHE_FILE   = Path("/tmp/headsup_usage_cache.json")
CACHE_TTL_SEC = 60

SESSION_LIMIT = int(os.environ.get("HEADSUP_SESSION_LIMIT", 17_000_000))
WEEK_LIMIT    = int(os.environ.get("HEADSUP_WEEK_LIMIT",   140_000_000))

# UTC (hour, minute) of each 6-hour session block boundary
SESSION_RESETS_UTC = [(1, 40), (7, 40), (13, 40), (19, 40)]


def block_start(now: datetime) -> datetime:
    """Start of the current 6-hour session block (UTC)."""
    base = now.replace(second=0, microsecond=0)
    # Check yesterday + today to handle the 01:40 UTC boundary
    candidates = []
    for day_offset in (-1, 0):
        day = base.replace(hour=0, minute=0) + timedelta(days=day_offset)
        for h, m in SESSION_RESETS_UTC:
            t = day.replace(hour=h, minute=m)
            if t <= now:
                candidates.append(t)
    return max(candidates)


def block_next_reset(now: datetime) -> datetime:
    """Next session block reset after now (UTC)."""
    base = now.replace(second=0, microsecond=0)
    candidates = []
    for day_offset in (0, 1):
        day = base.replace(hour=0, minute=0) + timedelta(days=day_offset)
        for h, m in SESSION_RESETS_UTC:
            t = day.replace(hour=h, minute=m)
            if t > now:
                candidates.append(t)
    return min(candidates)


def week_start(now: datetime) -> datetime:
    """Last Monday at 21:00 UTC (5pm ET/EDT)."""
    # weekday(): Monday=0
    monday = now.replace(hour=21, minute=0, second=0, microsecond=0) \
             - timedelta(days=now.weekday())
    if monday > now:
        monday -= timedelta(weeks=1)
    return monday


def aggregate(session_start: datetime, week_start_: datetime, now: datetime):
    """Single-pass scan: return (session_output_tokens, week_output_tokens)."""
    session_ts = session_start.timestamp()
    week_ts    = week_start_.timestamp()
    s_tokens   = 0
    w_tokens   = 0

    for jsonl in PROJECTS_DIR.rglob("*.jsonl"):
        try:
            if jsonl.stat().st_mtime < week_ts:
                continue  # file untouched since before the week window
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
                    usage  = d.get("message", {}).get("usage")
                    if not ts_str or not usage:
                        continue
                    try:
                        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    out = usage.get("output_tokens", 0)
                    if ts >= session_start:
                        s_tokens += out
                    if ts >= week_start_:
                        w_tokens += out
        except OSError:
            continue

    return s_tokens, w_tokens


def main():
    now = datetime.now(timezone.utc)

    # Cache check
    try:
        if CACHE_FILE.exists():
            cached = json.loads(CACHE_FILE.read_text())
            if now.timestamp() - cached.get("ts", 0) < CACHE_TTL_SEC:
                print(cached["output"])
                return
    except Exception:
        pass

    s_start   = block_start(now)
    w_start   = week_start(now)
    nxt_reset = block_next_reset(now)

    s_tok, w_tok = aggregate(s_start, w_start, now)

    s_pct = min(100, int(s_tok * 100 / SESSION_LIMIT))
    w_pct = min(100, int(w_tok * 100 / WEEK_LIMIT))

    # Reset time in local clock (no pytz needed — just shift the UTC time)
    local_reset = nxt_reset.astimezone()
    hour = local_reset.hour % 12 or 12
    ampm = "am" if local_reset.hour < 12 else "pm"
    reset_str = f"{hour}:{local_reset.minute:02d}{ampm}"

    output = f"SESSION_PCT={s_pct} WEEK_PCT={w_pct} SESSION_RESET={reset_str}"

    try:
        CACHE_FILE.write_text(json.dumps({"ts": now.timestamp(), "output": output}))
    except Exception:
        pass

    print(output)


if __name__ == "__main__":
    main()
