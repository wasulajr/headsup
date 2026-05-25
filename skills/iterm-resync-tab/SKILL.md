---
name: iterm-resync-tab
description: Force-resync the iTerm2 tab color for a Claude Code session whose hook chain has fallen out of sync. Use when a tab's color is visibly stuck on a stale state (e.g., still orange after the user replied, still white after Claude started processing) — that means Claude Code's automatic PreToolUse/PostToolUse/UserPromptSubmit/etc. events aren't reaching the hook. This skill bypasses the automatic path entirely and writes the desired state directly via `~/.claude/hooks/iterm-resync.sh`, then fires the Tier 2 one-shot Python (and the daemon picks it up too) for triple-redundancy. Two invocation forms — current tab, or any tab by UUID.
---

# Resync iTerm2 tab color

Force-applies the current Claude state (color + attention) to an iTerm2 session, bypassing Claude Code's automatic hook chain. Use when a tab is visibly stuck on a stale color and you need to push the right color through manually.

## Two ways to invoke

- `/iterm-resync-tab` — resync the **current tab** (the one this Claude session is running in). Default for "I just noticed my own tab is out of sync".
- `/iterm-resync-tab <UUID>` — resync **a specific tab** by its iTerm2 session UUID, regardless of which tab the user is currently in. Default for "tab 8884B62B is stuck orange, fix it from here". UUID can be the bare uuid OR the full `wXtYpZ:UUID` form — both work.

## What to do when invoked

Run the resync script. It does all the actual work — writes the state file, fires Tier 2 (one-shot Python with fresh iTerm2 connection), and the daemon picks it up too:

```bash
~/.claude/hooks/iterm-resync.sh [<uuid>]
```

If the user supplied a UUID argument, pass it through. Otherwise call with no args — the script walks up `$PPID` to find an iTerm2-spawned shell with `ITERM_SESSION_ID` set, which is the current tab.

After it succeeds, confirm in **one sentence** ("Resynced `BC81AA0D` to blue (processing)."). Don't explain the three-tier internals unless the user asks — they typed `/iterm-resync-tab` because they wanted the tab fixed, not a tutorial.

## When the auto-banner protocol runs this for you

Per the master memory's banner protocol, this skill is invoked automatically at the start of each response — so the current tab's state stays fresh even when Claude Code's in-process hook chain has drifted. In that auto-invocation, suppress the confirmation message entirely (the user doesn't want to see "Resynced …" on every response). The fact that the bash script runs is enough; its stderr goes to `~/.claude/hooks/.state/oneshot.stderr` if anything fails.

## What this skill DOESN'T fix

It pushes the color through. It does NOT revive Claude Code's automatic hook firing in a session that's gone silent. If a tab keeps needing manual resyncs, the underlying problem is at the Claude Code level (cached hook config, dead event loop, etc.) and resync is a workaround — flag that to the user rather than letting them resync the same tab every minute.

## Where the supporting files live

- `~/.claude/hooks/iterm-resync.sh` — the actual implementation
- `~/.claude/hooks/iterm2-apply-once.py` — Tier 2 one-shot, invoked by the script
- `~/.claude/hooks/iterm2-daemon.py` — Tier 1 daemon, the script writes state for it to pick up
- `~/.claude/hooks/iterm-status.conf` — color customization (PROCESS_COLOR etc.); the script honors overrides

All four are under version control at `github.com/wasulajr/lookout`.
