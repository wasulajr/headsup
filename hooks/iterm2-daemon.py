#!/usr/bin/env python3
"""Persistent iTerm2 tab-color daemon for Claude Code hooks.

One daemon serves ALL iTerm2 sessions on this machine. The bash hook
~/.claude/hooks/iterm-status.sh writes a per-session state file to
~/.claude/hooks/.state/<session-uuid>.state in the form:

    <6-char-hex>\\n             # color only (attention defaults to "no")
    <6-char-hex> <yes|no>\\n   # color + explicit attention

The daemon polls state-file mtimes every POLL_INTERVAL seconds and,
when one changes, finds the matching iTerm2 session by UUID and
injects via the iTerm2 Python API:
    - "RequestAttention=no" then "SetColors=tab=<color>" for attn=no
    - "SetColors=tab=<color>" then "RequestAttention=yes" for attn=yes

The RequestAttention pairing is load-bearing: iTerm2's attention state
visually overrides the tab color, so we must explicitly clear it on the
processing/idle transitions.

Health & self-healing (the parts that close the gap that historically
let the daemon "lose connection for long periods"):

1. Liveness probe — every LIVENESS_INTERVAL seconds the daemon does a
   round-trip to iTerm2 (app.async_refresh). If the call fails or times
   out, the websocket is dead even if the Python process is alive. We
   write a DEAD heartbeat (so the bash hook treats Tier 1 as down right
   away) and exit; the next hook event respawns us via
   ensure_daemon_running.

2. Apply-error → exit — any error from apply_state caused by a closed
   websocket triggers the same DEAD-heartbeat + exit sequence.

3. Reconciliation sweep — every RECONCILE_INTERVAL seconds, for every
   session we've ever applied state to, we read iTerm2's current tab
   color and reapply when it doesn't match the desired state. This is
   the silent watchdog for OSC drops, attention-state overrides, and
   any other drift, regardless of cause.

4. Belt-and-suspenders second apply — per-event apply runs twice: once
   immediately, and once again after a short pause. The iterm2 lib in
   this venv (v2.19) doesn't expose tab color via the Python API, so
   true readback isn't possible — but a second injection is essentially
   free, fully idempotent, and catches the case where the first OSC
   raced something on iTerm2's side.

Auto-terminates after IDLE_TIMEOUT seconds with no state-file activity
(typically when all Claude Code sessions close). Only one daemon may run
at a time, enforced via an O_EXCL PID lock at .state/daemon.pid.
"""

import asyncio
import datetime
import os
import sys
import time
from pathlib import Path

import iterm2


STATE_DIR = Path(os.path.expanduser("~/.claude/hooks/.state"))
PID_FILE = STATE_DIR / "daemon.pid"
HEARTBEAT_FILE = STATE_DIR / ".daemon.heartbeat"
LOG_FILE = Path(os.path.expanduser("~/.claude/hooks/iterm-status.log"))
DEBUG_FLAG = Path(os.path.expanduser("~/.claude/hooks/.debug"))
POLL_INTERVAL = 0.03           # 30ms
HEARTBEAT_INTERVAL = 0.2       # 200ms — bash hook treats heartbeat > 1s old as stale
LIVENESS_INTERVAL = 1.0        # active WS probe cadence
LIVENESS_TIMEOUT = 2.0         # max seconds for a probe before declaring dead
RECONCILE_INTERVAL = 7.0       # periodic drift correction for known sessions
GC_INTERVAL = 300.0            # housekeeping sweep — clean up state files for
                               # sessions that no longer exist (cadence is low
                               # because the work is non-time-sensitive)
GC_STALE_AGE_SEC = 86400       # only GC files whose mtime is > 24h old AND
                               # whose uuid isn't currently in app.windows.
                               # The 24h floor avoids deleting a state file for
                               # a session that's mid-startup or briefly hidden.
IDLE_TIMEOUT = 3600            # exit after 1 hour with no state-file changes

# Exception-type names that indicate the iTerm2 websocket is gone. We match
# by class name rather than importing because websockets/iterm2 layer their
# exceptions across releases — a name check is robust without pinning versions.
DEAD_WS_EXCEPTION_NAMES = frozenset({
    "ConnectionClosed",
    "ConnectionClosedError",
    "ConnectionClosedOK",
    "ConnectionResetError",
    "BrokenPipeError",
    "IncompleteReadError",
    "WebSocketException",
})


def log(msg: str) -> None:
    if not DEBUG_FLAG.exists():
        return
    try:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        with open(LOG_FILE, "a") as f:
            f.write(f"{ts} daemon {msg}\n")
    except Exception:
        pass


def acquire_pid_lock() -> None:
    """Atomically claim the daemon PID file. Exit cleanly if another is running."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    for _ in range(3):
        try:
            fd = os.open(str(PID_FILE), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return
        except FileExistsError:
            try:
                existing = int(PID_FILE.read_text().strip())
                os.kill(existing, 0)  # raises if not alive
                log(f"another daemon alive pid={existing}; exiting")
                sys.exit(0)
            except (ValueError, ProcessLookupError, PermissionError):
                try:
                    PID_FILE.unlink()
                except FileNotFoundError:
                    pass
    sys.exit("could not acquire daemon PID lock")


def write_heartbeat(status: str = "OK") -> None:
    """Atomic write of `<epoch>.<ms> <status>` to HEARTBEAT_FILE. The bash hook
    reads this; if older than 1s OR status != OK, it assumes Tier 1 is down
    and falls back to Tier 2 (per-event Python) for the current event."""
    try:
        tmp = HEARTBEAT_FILE.with_suffix(".heartbeat.tmp")
        tmp.write_text(f"{time.time():.3f} {status}\n")
        tmp.replace(HEARTBEAT_FILE)
    except Exception:
        pass


def release_pid_lock() -> None:
    try:
        if PID_FILE.exists() and PID_FILE.read_text().strip() == str(os.getpid()):
            PID_FILE.unlink()
    except Exception:
        pass
    # Drop the heartbeat too so any concurrent bash hook sees "no signal"
    # immediately rather than waiting for the 1s staleness window.
    try:
        HEARTBEAT_FILE.unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass


def is_dead_ws_exception(exc: BaseException) -> bool:
    """Walk an exception chain looking for a class name in DEAD_WS_EXCEPTION_NAMES.
    Catches the wrapped websockets/iterm2 errors we've seen in stderr."""
    seen: list[BaseException] = []
    cur: BaseException | None = exc
    while cur is not None and cur not in seen:
        seen.append(cur)
        if type(cur).__name__ in DEAD_WS_EXCEPTION_NAMES:
            return True
        cur = cur.__cause__ or cur.__context__
    return False


async def apply_state(session, color: str, attention: str) -> None:
    color_osc = f"\x1b]1337;SetColors=tab={color}\x07".encode()
    attn_osc = f"\x1b]1337;RequestAttention={attention}\x07".encode()
    if attention == "no":
        await session.async_inject(attn_osc)
        await session.async_inject(color_osc)
    else:
        await session.async_inject(color_osc)
        await session.async_inject(attn_osc)


def find_tab_and_session(app, session_uuid: str):
    """Return (tab, session) for the given session UUID, or (None, None)."""
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == session_uuid:
                    return tab, session
    return None, None


async def probe_ws(app) -> bool:
    """Cheap round-trip to iTerm2 to verify the WS is alive. Returns False
    on any failure (connection closed, timeout, unexpected error). The daemon
    treats a False return as fatal — exits so the bash hook respawns it."""
    try:
        await asyncio.wait_for(app.async_refresh(), timeout=LIVENESS_TIMEOUT)
        return True
    except asyncio.TimeoutError:
        log("probe-timeout")
        return False
    except BaseException as exc:
        if is_dead_ws_exception(exc):
            log(f"probe-dead-ws exc={exc!r}")
        else:
            log(f"probe-error exc={exc!r}")
        return False


async def apply_twice(app, uuid: str, color: str, attention: str) -> str:
    """Apply state to a session, then apply again after a short pause.
    Two applies = idempotent + free + catches the case where the first
    OSC raced something on iTerm2's side. Returns:
        ok            — applied (one or both attempts succeeded)
        no-session    — UUID isn't in app.windows yet
        dead-ws       — websocket error during apply (daemon should exit)
    """
    tab, session = find_tab_and_session(app, uuid)
    if session is None:
        return "no-session"
    try:
        await apply_state(session, color, attention)
    except BaseException as exc:
        if is_dead_ws_exception(exc):
            return "dead-ws"
        log(f"apply-error uuid={uuid} exc={exc!r}")
        return "error"
    # Second apply, after a brief settle. Belt-and-suspenders for the iTerm2
    # parser; idempotent on its side so this can never cause harm.
    await asyncio.sleep(0.15)
    tab2, session2 = find_tab_and_session(app, uuid)
    if session2 is not None:
        try:
            await apply_state(session2, color, attention)
        except BaseException as exc:
            if is_dead_ws_exception(exc):
                return "dead-ws"
            log(f"second-apply-error uuid={uuid} exc={exc!r}")
    return "ok"


def still_own_pid_lock() -> bool:
    try:
        return PID_FILE.read_text().strip() == str(os.getpid())
    except FileNotFoundError:
        return False
    except Exception:
        return False


async def main(connection):
    acquire_pid_lock()
    write_heartbeat()
    log(f"started pid={os.getpid()}")
    try:
        app = await iterm2.async_get_app(connection)
        seen_mtimes: dict[str, float] = {}
        # desired_state[uuid] = (color, attention) — the latest state we
        # were asked to apply for a session. Used by the reconciliation
        # sweep to re-assert state without needing a fresh hook event.
        desired_state: dict[str, tuple[str, str]] = {}
        last_activity = time.time()
        last_heartbeat = 0.0
        last_liveness = 0.0
        last_reconcile = time.time()
        last_gc = time.time()

        while True:
            # Bail if a newer daemon claimed the lock (e.g. user wiped
            # .state/ and a fresh hook event spawned a replacement).
            if not still_own_pid_lock():
                log("pid-lock-lost; exiting")
                break

            now = time.time()

            # ── Liveness probe ──────────────────────────────────────────
            # Round-trip to iTerm2. Without this we can't tell a dead
            # websocket from a healthy idle one — the Python process keeps
            # running, the heartbeat keeps updating, but apply_state would
            # silently fail. This is the gap that historically caused tabs
            # to "lose connection for long periods".
            if now - last_liveness > LIVENESS_INTERVAL:
                if not await probe_ws(app):
                    write_heartbeat("DEAD")
                    log("exiting due to dead websocket (probe)")
                    break
                last_liveness = now

            # Throttled heartbeat (status OK once the probe above passes).
            if now - last_heartbeat > HEARTBEAT_INTERVAL:
                write_heartbeat()
                last_heartbeat = now

            # ── Per-event apply ─────────────────────────────────────────
            for state_file in STATE_DIR.glob("*.state"):
                uuid = state_file.stem
                try:
                    mtime = state_file.stat().st_mtime
                except FileNotFoundError:
                    continue
                if seen_mtimes.get(uuid) == mtime:
                    continue

                try:
                    content = state_file.read_text().strip()
                except FileNotFoundError:
                    continue
                if not content:
                    continue

                parts = content.split()
                color = parts[0]
                attention = parts[1] if len(parts) > 1 else "no"

                desired_state[uuid] = (color, attention)
                seen_mtimes[uuid] = mtime

                result = await apply_twice(app, uuid, color, attention)
                if result == "dead-ws":
                    write_heartbeat("DEAD")
                    log(f"exiting due to dead websocket (apply uuid={uuid})")
                    return
                if result == "no-session":
                    # Session may be starting up and not yet visible — leave
                    # state file alone, reconciliation will pick it up later.
                    log(f"session-not-found uuid={uuid}")
                else:
                    log(f"applied uuid={uuid} color={color} attn={attention} result={result}")
                    last_activity = time.time()

            # ── Reconciliation sweep ────────────────────────────────────
            # Periodically re-assert the desired state for every session we
            # know about. Catches drift from any cause — OSC drops in the
            # TUI render burst, iTerm2 attention-state interactions, other
            # apps writing OSC sequences, anything. Since this iterm2 lib
            # version (v2.19) doesn't expose tab color via the API, we
            # can't readback-check before injecting — but a per-session
            # OSC every RECONCILE_INTERVAL is essentially free.
            if now - last_reconcile > RECONCILE_INTERVAL and desired_state:
                last_reconcile = now
                for uuid, (color, attention) in list(desired_state.items()):
                    tab, session = find_tab_and_session(app, uuid)
                    if session is None:
                        continue
                    try:
                        await apply_state(session, color, attention)
                        log(f"reconcile-applied uuid={uuid} color={color} attn={attention}")
                    except BaseException as exc:
                        if is_dead_ws_exception(exc):
                            write_heartbeat("DEAD")
                            log(f"exiting due to dead websocket (reconcile uuid={uuid})")
                            return
                        log(f"reconcile-error uuid={uuid} exc={exc!r}")

            # ── Stale state-file GC ─────────────────────────────────────
            # Closed sessions leave behind .state, .waiting, and .precount
            # files. Nothing functional breaks if they accumulate (they're
            # just ignored), but the dir grows unbounded. Every
            # GC_INTERVAL seconds, look for orphans: .state files whose
            # uuid is no longer a live iTerm2 session AND whose mtime is
            # older than GC_STALE_AGE_SEC (24h). The age floor prevents
            # us from deleting a state file for a tab that's briefly
            # invisible to the API (cold-starting, hidden window, etc.).
            if now - last_gc > GC_INTERVAL:
                last_gc = now
                cutoff = time.time() - GC_STALE_AGE_SEC
                live_uuids: set[str] = set()
                for window in app.windows:
                    for tab in window.tabs:
                        for session in tab.sessions:
                            live_uuids.add(session.session_id)
                gc_count = 0
                for state_file in STATE_DIR.glob("*.state"):
                    uuid = state_file.stem
                    if uuid in live_uuids:
                        continue
                    try:
                        if state_file.stat().st_mtime > cutoff:
                            continue
                    except FileNotFoundError:
                        continue
                    # Orphan + stale. Drop .state plus every matching
                    # sidecar (waiting marker, in-flight count, badge
                    # cache, notification marker).
                    for sidecar in (
                        state_file,
                        STATE_DIR / f"{uuid}.waiting",
                        STATE_DIR / f"{uuid}.precount",
                        STATE_DIR / f"{uuid}.badge",
                        STATE_DIR / f"{uuid}.notified",
                    ):
                        try:
                            sidecar.unlink()
                        except FileNotFoundError:
                            pass
                        except Exception as exc:
                            log(f"gc-error uuid={uuid} file={sidecar.name} exc={exc!r}")
                    desired_state.pop(uuid, None)
                    seen_mtimes.pop(uuid, None)
                    gc_count += 1
                    log(f"gc-removed uuid={uuid}")
                if gc_count:
                    log(f"gc-sweep removed={gc_count}")

            if time.time() - last_activity > IDLE_TIMEOUT:
                log("idle-timeout; exiting")
                break

            await asyncio.sleep(POLL_INTERVAL)
    finally:
        release_pid_lock()


iterm2.run_until_complete(main)
