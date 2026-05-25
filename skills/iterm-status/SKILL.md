---
name: iterm-status
description: Print a health snapshot for the iterm-config hook stack — daemon PID + heartbeat status, launchd watchdog state, active sessions and their current colors, count of stray PostToolUse events suppressed today, and token usage for the current Claude Code session ($PWD). Use when the user asks "is this still working", "how's the iterm tab thing", "show me the iterm hook status", or invokes /iterm-status directly. Read-only — does not modify any state.
---

# iTerm hook stack status

Print a one-shot health snapshot for the whole iterm-config stack.

## What to do when invoked

Run the report script and let its output stand on its own. The script is read-only — no side effects.

```bash
~/.claude/hooks/iterm-status-report.sh
```

After printing, **don't summarize or explain the output line-by-line** unless the user asks. The format is designed to be self-explanatory (green check = good, yellow `!` = warning, red `✗` = broken). If the user explicitly asks a follow-up like "what does the waiting marker mean," then explain.

## What the sections mean

- **Daemon** — Tier 1's persistent process. `alive` + fresh heartbeat = healthy. A stale heartbeat with `DEAD` status means the daemon detected its own websocket failure and is about to exit (next hook event respawns it).
- **Watchdog** — the `claude-code.iterm-watchdog` LaunchAgent. Runs every 30s, respawns the daemon if dead.
- **Sessions** — live `*.state` files modified in the last hour, with the current color and any in-flight tool count. Useful for "which tab is in which state right now."
- **Recent PostToolUse suppressions** — count of stray end-of-turn events the marker logic correctly squashed today (vs yesterday). Non-zero here is normal; zero means either no recent turns or the suppression heuristic isn't catching any strays.
- **This session** — token totals from the latest Claude Code session JSONL for `$PWD`. Driven by `iterm-session-cost.py`.

## When something looks wrong

- Daemon not running and no recent events → fine, will spawn on next event
- Daemon alive but heartbeat status != OK → daemon will exit + respawn within ~1s
- Watchdog not loaded → run `setup.sh` or `launchctl load ~/Library/LaunchAgents/claude-code.iterm-watchdog.plist`
- No sessions in the last hour → expected if no Claude Code is running
- All sessions on the same color → expected if you only have one tab open

The diagnostic that *actively exercises* the stack (vs just observing it) is `/iterm-diagnose`.

## Where the supporting files live

- `~/.claude/hooks/iterm-status-report.sh` — this script
- `~/.claude/hooks/iterm-session-cost.py` — the token usage helper
- `~/.claude/hooks/.state/` — daemon / watchdog state files
- `~/.claude/hooks/iterm-status.log` — event + suppression log (when `.debug` is touched)

All under version control at `github.com/wasulajr/lookout`.
