#!/usr/bin/env python3
"""headsup-usage-windows.py — approximate Claude session and week usage.

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

Results cached in /tmp/headsup_usage_cache.json for 60s.
"""

import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Account-namespaced: Claude Code writes transcripts under $CLAUDE_CONFIG_DIR,
# so a hardcoded ~/.claude/projects makes every non-default account read the
# WRONG account's usage (zeros for session, another account's totals for week).
CONFIG_DIR    = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
PROJECTS_DIR  = CONFIG_DIR / "projects"

# Cache is keyed by account too. A single shared cache file lets concurrent
# windows on different accounts overwrite each other's totals for the TTL.
_ACCT_KEY     = hashlib.sha256(str(PROJECTS_DIR.resolve()).encode()).hexdigest()[:8]
CACHE_FILE    = Path(f"/tmp/headsup_usage_cache_{_ACCT_KEY}.json")
CACHE_TTL_SEC = 60

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


def main():
    now = datetime.now(timezone.utc)

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

    s, w = aggregate(s_start, w_start)

    s_pct = min(100, int(s["out"] * 100 / SESSION_LIMIT))
    w_pct = min(100, int(w["out"] * 100 / WEEK_LIMIT))

    local_reset = nxt_reset.astimezone()
    hour = local_reset.hour % 12 or 12
    ampm = "am" if local_reset.hour < 12 else "pm"
    reset_str = f"{hour}:{local_reset.minute:02d}{ampm}"

    parts = [
        f"SESSION_PCT={s_pct}",
        f"SESSION_USED={fmt_tokens(s['out'])}",
        f"SESSION_LIMIT_FMT={fmt_limit(SESSION_LIMIT)}",
        f"SESSION_COST={s['cost']:.2f}",
        f"WEEK_PCT={w_pct}",
        f"WEEK_USED={fmt_tokens(w['out'])}",
        f"WEEK_LIMIT_FMT={fmt_limit(WEEK_LIMIT)}",
        f"WEEK_COST={w['cost']:.2f}",
        f"SESSION_RESET={reset_str}",
    ]
    output = " ".join(parts)

    try:
        CACHE_FILE.write_text(json.dumps({"ts": now.timestamp(), "output": output}))
    except Exception:
        pass

    print(output)


if __name__ == "__main__":
    main()
