#!/usr/bin/env python3
"""Tier 2 fallback: per-event one-shot tab-color application.

The bash hook (`iterm-status.sh`) spawns this only when the persistent
daemon's heartbeat is stale (missing, > 1s old, or status != OK) —
meaning the daemon is dead, stuck, or its iTerm2 API connection has
gone bad. We connect fresh to iTerm2, find the session by UUID, inject
the OSC sequences, and exit.

Cold start is ~440ms (Python boot + iterm2 import + websocket handshake).
That's why this is Tier 2 not Tier 1 — we only pay it when the
fast-path daemon isn't working. On the daemon's healthy path this script
is never invoked.

Hardening (items 7+8 of the resilience plan):
- run_until_complete(retry=True) so iTerm2 momentarily refusing the
  Python API doesn't fail the apply outright.
- If the session isn't visible in app.windows on the first pass, do one
  short in-process retry (after a brief sleep + refresh) — covers the
  race where a fresh iTerm2 session hasn't propagated to the API yet.

Usage:
    iterm2-apply-once.py <hex-color> <attention> <session-uuid>

Args:
    hex-color    6-char hex, no leading #
    attention    "yes" or "no" — paired with SetColors=tab= per the
                 daemon's apply_state logic
    session-uuid the iTerm2 session UUID (no `wXtYpZ:` prefix)
"""

import asyncio
import datetime
import os
import sys

import iterm2


LOG_PATH = os.path.expanduser("~/.claude/hooks/iterm-status.log")
DEBUG_FLAG = os.path.expanduser("~/.claude/hooks/.debug")

# Retry budget for the session-not-found case. The first call to
# app.windows might miss a brand-new session if the iTerm2 API hasn't
# yet broadcast it; one short wait + refresh usually catches it.
SESSION_LOOKUP_ATTEMPTS = 4
SESSION_LOOKUP_DELAY = 0.5


def log(msg: str) -> None:
    if not os.path.exists(DEBUG_FLAG):
        return
    try:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S.%f"
        )[:-3] + "Z"
        with open(LOG_PATH, "a") as f:
            f.write(f"{ts} tier2 {msg}\n")
    except Exception:
        pass


def parse_args() -> tuple[str, str, str]:
    if len(sys.argv) != 4:
        log(f"error reason=bad-args argv={sys.argv!r}")
        sys.exit("usage: iterm2-apply-once.py <hex-color> <yes|no> <session-uuid>")
    color = sys.argv[1].lstrip("#").strip()
    attention = sys.argv[2].strip()
    uuid = sys.argv[3].strip()
    if len(color) != 6:
        log(f"error reason=bad-hex arg={sys.argv[1]!r}")
        sys.exit(f"expected 6-char hex, got: {sys.argv[1]!r}")
    if attention not in ("yes", "no"):
        log(f"error reason=bad-attention arg={sys.argv[2]!r}")
        sys.exit(f"attention must be 'yes' or 'no', got: {sys.argv[2]!r}")
    if not uuid:
        log("error reason=empty-uuid")
        sys.exit("session-uuid must not be empty")
    return color, attention, uuid


def find_session(app, uuid: str):
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == uuid:
                    return session
    return None


async def main(connection):
    color, attention, uuid = parse_args()
    log(f"connected color={color} attention={attention} uuid={uuid}")

    app = await iterm2.async_get_app(connection)
    # Session-lookup retry budget — catches the race where iTerm2 hasn't
    # yet propagated a brand-new session to the API.
    session = find_session(app, uuid)
    for attempt in range(1, SESSION_LOOKUP_ATTEMPTS):
        if session is not None:
            break
        log(f"session-not-found-retry attempt={attempt} uuid={uuid}")
        await asyncio.sleep(SESSION_LOOKUP_DELAY)
        try:
            await app.async_refresh()
        except Exception as exc:
            log(f"refresh-error attempt={attempt} exc={exc!r}")
        session = find_session(app, uuid)

    if session is None:
        log(f"error reason=session-not-found uuid={uuid} attempts={SESSION_LOOKUP_ATTEMPTS}")
        # Don't sys.exit non-zero — the bash hook fires us async and any noisy
        # error here would just clutter the log. We log and exit silently.
        return

    # Match the daemon's apply_state ordering exactly:
    #   attn=no → RequestAttention=no FIRST, then SetColors
    #   attn=yes → SetColors FIRST, then RequestAttention=yes
    # The first form clears any stuck attention state before
    # writing the new color (without this, iTerm2 keeps the
    # tab visually orange even after color = blue).
    color_osc = f"\x1b]1337;SetColors=tab={color}\x07".encode()
    attn_osc = f"\x1b]1337;RequestAttention={attention}\x07".encode()
    if attention == "no":
        await session.async_inject(attn_osc)
        await session.async_inject(color_osc)
    else:
        await session.async_inject(color_osc)
        await session.async_inject(attn_osc)
    log(f"applied color={color} attention={attention} uuid={uuid}")


try:
    # retry=True so a momentarily busy iTerm2 API server doesn't make us
    # fail the apply outright — iterm2 will keep trying to connect rather
    # than raising.
    iterm2.run_until_complete(main, retry=True)
except SystemExit:
    raise
except BaseException as exc:
    log(f"error reason=exception type={type(exc).__name__} msg={exc!r}")
    # Same reasoning — fail silent (still log) so the user's terminal doesn't
    # get noise from a fallback that was best-effort anyway.
