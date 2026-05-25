---
name: iterm-diagnose
description: Actively exercise the iterm-config hook stack end-to-end. Flashes the three tab colors (idle → processing → waiting) on the current tab and verifies each round-trips through the daemon. Use when the user asks "is the iterm thing actually working", "test the iterm hooks", "/iterm-diagnose", or wants confirmation after a change. Different from /iterm-status (passive snapshot) — this skill performs writes and briefly changes the visible tab color. Add the `--restart` arg to also kill the daemon and verify the launchd watchdog respawns it (~30s extra).
---

# iTerm hook stack diagnose

Active end-to-end test. Flashes colors on the current tab, verifies each pushes through to iTerm2 via the daemon, and reports pass/fail per step.

## When to use

- "Test the iterm tab hooks"
- "Is the iterm stack actually working"
- "Run iterm diagnose"
- "/iterm-diagnose"
- After installing/upgrading anything in the iterm-config stack — confirm the install actually works before declaring done

## Heads-up to the user before invoking

Brief warning is enough: "Going to flash white → blue → orange on this tab over ~3s, then restore. OK?" Only ask if the user invoked you in a context where unexpected color changes might be confusing. For an explicit `/iterm-diagnose` invocation, just run it.

## What to do when invoked

Run the diagnose script. Default mode (no `--restart`) is fast (~3s) and only flashes colors. Pass `--restart` ONLY if the user explicitly asked for "deep" / "full" / "include daemon respawn" — that one adds ~30s while the watchdog re-spawns the daemon.

```bash
~/.claude/hooks/iterm-diagnose.sh             # color flash test only
~/.claude/hooks/iterm-diagnose.sh --restart   # also test daemon respawn
```

Let the script's output speak for itself. It prints per-step pass/fail with the same green-check/red-cross convention as `/iterm-status`. Don't restate or interpret unless asked.

## What gets tested

1. **Prereqs** — venv python, daemon script, resync script exist; UUID resolved
2. **Daemon health** — PID alive, heartbeat status=OK
3. **Watchdog** — LaunchAgent loaded
4. **Cost helper** — iterm-session-cost.py runs cleanly
5–7. **Color round-trip** — push idle / processing / waiting, verify state file is written AND daemon's "applied" log line lands within 2s
8. **(--restart only)** — kill the daemon, verify the watchdog respawns it within 35s

Original tab state is restored on exit (whatever color/attention it was before the test).

## Exit code

`0` on all-pass, `1` on any fail. Useful for scripting.

## If something fails

- Step 1 failures → run `setup.sh` to reinstall scripts
- Step 2 failures → daemon should respawn on next event; check `~/.claude/hooks/.state/daemon.stderr`
- Step 3 → `launchctl load ~/Library/LaunchAgents/claude-code.iterm-watchdog.plist`
- Step 5–7 → the daemon's API connection might be dead; check `~/.claude/hooks/.state/daemon.stderr` for websocket errors
- Step 8 → the watchdog didn't fire or the daemon respawn path is broken; check `~/.claude/hooks/.state/watchdog.stderr`

## Where the supporting files live

- `~/.claude/hooks/iterm-diagnose.sh` — this script
- `~/.claude/hooks/iterm-resync.sh` — how each color push lands
- `~/.claude/hooks/iterm-session-cost.py` — the cost helper that gets smoke-tested

All under version control at `github.com/wasulajr/lookout`.
