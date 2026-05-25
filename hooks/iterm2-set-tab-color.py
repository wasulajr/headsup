#!/usr/bin/env python3
"""Set the current iTerm2 session's tab color via the iTerm2 Python API.

Invoked by ~/.claude/hooks/iterm-status.sh. Bypasses the pty entirely:
sends the SetColors=tab=... OSC sequence directly into iTerm2's parser
for this session, so the Claude Code TUI's concurrent writes on the
same tty can't tear or drop it.

Usage:
    iterm2-set-tab-color.py <hex>    # 6-char hex, no leading #

Reads ITERM_SESSION_ID from the environment to identify the target.
"""

import datetime
import os
import sys

import iterm2


LOG_PATH = os.path.expanduser("~/.claude/hooks/iterm-status.log")
DEBUG_FLAG = os.path.expanduser("~/.claude/hooks/.debug")


def log(msg: str) -> None:
    if not os.path.exists(DEBUG_FLAG):
        return
    try:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        event = os.environ.get("HOOK_EVENT", "?")
        with open(LOG_PATH, "a") as f:
            f.write(f"{ts} py event={event} {msg}\n")
    except Exception:
        pass


def session_id_from_env() -> str:
    raw = os.environ.get("ITERM_SESSION_ID", "")
    if not raw:
        log("error reason=ITERM_SESSION_ID-unset")
        sys.exit("ITERM_SESSION_ID is not set")
    return raw.split(":", 1)[1] if ":" in raw else raw


async def main(connection):
    if len(sys.argv) != 2:
        sys.exit("usage: iterm2-set-tab-color.py <6-char-hex>")
    hex_color = sys.argv[1].lstrip("#").strip()
    if len(hex_color) != 6:
        log(f"error reason=bad-hex arg={sys.argv[1]!r}")
        sys.exit(f"expected 6-char hex, got: {sys.argv[1]!r}")

    session_id = session_id_from_env()
    # Pair the tab color with a RequestAttention= signal so we explicitly
    # clear iTerm2's "needs attention" state when going to a processing/idle
    # color. Without the clear, iTerm2 keeps the tab in attention mode
    # visually even after we set a new tab color, which manifests as the
    # tab still looking orange after the user answers an AskUserQuestion.
    event = os.environ.get("HOOK_EVENT", "")
    if event in ("Notification", "Stop"):
        attention = "yes"
    else:
        attention = "no"

    log(f"connected color={hex_color} attention={attention} session={session_id}")
    app = await iterm2.async_get_app(connection)
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == session_id:
                    # Clear-attention-before-color when going to processing/idle
                    # (so the new color isn't overridden by attention state);
                    # set-color-before-attention when going to wait (so the
                    # color lands cleanly before iTerm2 marks attention).
                    color_osc = f"\x1b]1337;SetColors=tab={hex_color}\x07"
                    attn_osc = f"\x1b]1337;RequestAttention={attention}\x07"
                    if attention == "no":
                        await session.async_inject(attn_osc.encode("utf-8"))
                        await session.async_inject(color_osc.encode("utf-8"))
                    else:
                        await session.async_inject(color_osc.encode("utf-8"))
                        await session.async_inject(attn_osc.encode("utf-8"))
                    log(f"injected color={hex_color} attention={attention}")
                    return
    log(f"error reason=session-not-found session={session_id}")
    sys.exit(f"session not found: {session_id}")


try:
    # retry=True so a momentarily busy iTerm2 API server doesn't make us
    # fail the apply outright.
    iterm2.run_until_complete(main, retry=True)
except SystemExit:
    raise
except BaseException as exc:
    log(f"error reason=exception type={type(exc).__name__} msg={exc!r}")
    raise
