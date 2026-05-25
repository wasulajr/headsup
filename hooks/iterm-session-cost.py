#!/usr/bin/env python3
"""Aggregate token usage from a Claude Code session JSONL transcript.

Claude Code writes one JSONL per session under:
    ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl

Each "assistant" entry's `message.usage` includes input/output/cache
token counts. This helper sums them across the file and prints a brief
summary, suitable for embedding in an iTerm2 badge or surfacing in the
/iterm-status skill.

No USD cost calculation — pricing depends on model + context size and
the table would need maintenance. Tokens are the durable signal.

Usage:
    iterm-session-cost.py [--cwd PATH] [--jsonl PATH] [--format FORMAT]

Defaults: --cwd $PWD --format short
Formats:  short (single line), long (multi-line breakdown), json
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path


PROJECTS_DIR = Path(os.path.expanduser("~/.claude/projects"))


def encode_cwd(cwd: str) -> str:
    """Mirror Claude Code's PWD → project-dir encoding: every non-alnum,
    non-underscore, non-dash character becomes `-`. Multiple consecutive
    specials become multiple consecutive dashes (matching what Claude Code
    actually writes on disk under ~/.claude/projects/)."""
    return re.sub(r"[^a-zA-Z0-9_-]", "-", cwd)


def find_latest_jsonl_for_cwd(cwd: str) -> Path | None:
    project_dir = PROJECTS_DIR / encode_cwd(cwd)
    if not project_dir.is_dir():
        return None
    jsonls = list(project_dir.glob("*.jsonl"))
    if not jsonls:
        return None
    return max(jsonls, key=lambda p: p.stat().st_mtime)


def aggregate(path: Path) -> dict:
    totals = {
        "input": 0,
        "output": 0,
        "cache_creation": 0,
        "cache_read": 0,
        "messages": 0,
        "models": [],
    }
    seen_models: set[str] = set()
    try:
        with path.open() as f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") != "assistant":
                    continue
                msg = d.get("message", {})
                usage = msg.get("usage", {})
                if not usage:
                    continue
                totals["input"] += usage.get("input_tokens", 0)
                totals["output"] += usage.get("output_tokens", 0)
                totals["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
                totals["cache_read"] += usage.get("cache_read_input_tokens", 0)
                totals["messages"] += 1
                model = msg.get("model")
                if model and model not in seen_models:
                    seen_models.add(model)
                    totals["models"].append(model)
    except FileNotFoundError:
        pass
    return totals


def fmt_tokens(n: int) -> str:
    """Compact human format: 1234567 -> "1.2M", 4500 -> "4.5K", 42 -> "42"."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cwd", default=os.getcwd(),
                    help="Find latest JSONL for the project at this cwd (default: $PWD)")
    ap.add_argument("--jsonl",
                    help="Direct path to a JSONL — overrides --cwd")
    ap.add_argument("--format", choices=["short", "long", "json"], default="short")
    args = ap.parse_args()

    if args.jsonl:
        path = Path(args.jsonl)
    else:
        path = find_latest_jsonl_for_cwd(args.cwd)

    if path is None or not path.exists():
        # Silent: badge updates fire on every event and we don't want to log
        # noise when a directory just doesn't have a Claude Code session.
        sys.exit(0)

    t = aggregate(path)

    if args.format == "json":
        print(json.dumps({**t, "jsonl": str(path)}))
    elif args.format == "long":
        print(f"jsonl: {path.name}")
        print(f"messages: {t['messages']}")
        print(f"input:          {fmt_tokens(t['input']):>8}  ({t['input']:>12,})")
        print(f"output:         {fmt_tokens(t['output']):>8}  ({t['output']:>12,})")
        print(f"cache_read:     {fmt_tokens(t['cache_read']):>8}  ({t['cache_read']:>12,})")
        print(f"cache_creation: {fmt_tokens(t['cache_creation']):>8}  ({t['cache_creation']:>12,})")
        if t["models"]:
            print(f"models: {', '.join(t['models'])}")
    else:  # short
        if t["messages"] == 0:
            sys.exit(0)
        print(f"{fmt_tokens(t['input'])} in / {fmt_tokens(t['output'])} out")


if __name__ == "__main__":
    main()
