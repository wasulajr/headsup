---
name: nil
description: "now is later: the companion to /sfl. Reopen every window saved for later: read the live checkpoints in ~/.claude/sfl/, archive them all at launch, and open one iTerm2 tab per entry (cd to its dir, restore its headsup label, launch claude pointed at the archived checkpoint). After a run the live list is empty, so nothing relaunches twice. Use when the user types /nil, \"now is later\", \"reopen my windows\", \"restore my tabs\", or \"bring my saved windows back\". Requires iTerm2."
---

# /nil: now is later

The inverse of `/sfl`. Where `sfl` saved each window for later, `/nil` says later is now: it reopens them.

## Requirements

- **macOS with iTerm2 running.** The opener drives iTerm2 via AppleScript.
- **macOS Automation permission** for controlling iTerm2 (the first run triggers a prompt: allow it; if denied later, re-enable under System Settings > Privacy & Security > Automation).
- **`claude` on the login-shell PATH** (each new tab runs `cd ... && headsup-set-label.sh ... && claude ...`).

## What it does

For every live checkpoint in `~/.claude/sfl/*.md` (one per saved window), open a new iTerm2 tab that:
1. `cd`s into the window's recorded `cwd`,
2. restores the window's headsup label (badge + title) via `headsup-set-label.sh`,
3. launches `claude` with a resume prompt pointing at that window's **archived** entry file.

**`/nil` archives every entry itself, at launch time.** `nil-open.sh` moves all live entries into `~/.claude/sfl/archive/` before the tabs open and points each resume prompt at the archived path, so after a successful run the live list is EMPTY and a later `/nil` can never relaunch the same window twice. (An earlier design had each child tab archive its own entry; entries leaked whenever a tab was closed before resuming, and stale windows got relaunched.) If the AppleScript fails, the script rolls the moves back so nothing is lost. Each reopened tab then **self-resumes**: its `claude` runs `/sfl` resume mode, reads the archived entry plus its `gov_memory` reference, and gives a 3-5 line catch-up; it does NOT need to archive anything.

## Steps

1. **List what will be reopened.** Show the user the plan before spawning anything. Use the opener's `--list` mode (NOT an ad-hoc shell loop; `nil-open.sh` is covered by the allow rules setup.sh installs, so this never prompts):

   ```bash
   ~/.claude/sfl/lib/nil-open.sh --list
   ```

   It prints `── <file>` then the `window/project/cwd/saved_at` lines per entry, and opens nothing. If it prints `no-entries`, say there is nothing saved and stop.

2. **Open the tabs.** This generates the AppleScript and runs it (one tab per entry, with a settle delay between tabs):

   ```bash
   ~/.claude/sfl/lib/nil-open.sh
   ```

   To preview without spawning anything, run `~/.claude/sfl/lib/nil-open.sh --dry-run` first (prints the generated AppleScript and the entry list, opens nothing, archives nothing).

3. **Report.** Say which windows opened (the script prints `opening: <window>  (<cwd>)` per tab, then a final line confirming how many entries were archived). `~/.claude/sfl/` is now empty; the script archived every entry at launch. Each new tab will catch itself up from its archived checkpoint and ask before starting work.

## Notes & failure modes

- **Resume is checkpoint-based by design**: each tab is a fresh `claude` that rebuilds context from its entry file, not from the old conversation transcript. This survives Claude Code version upgrades and transcript-format changes.
- If `osascript` fails (iTerm2 not running, Automation denied), the opener restores all live entries and exits nonzero; nothing is lost and `/nil` can simply be run again.
- Storage details and the entry format live in the `/sfl` skill (save mode writes the entries `/nil` consumes; resume mode is what each reopened tab runs).
