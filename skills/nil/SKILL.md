---
name: nil
description: "now is later: the companion to /sfl. Reopen the windows you saved for later: list the saved checkpoints in ~/.claude/sfl/ numbered, ask which to launch (all or specific numbers), then open one iTerm2 tab per selected entry (cd to its dir, restore its headsup label, launch claude pointed at the archived checkpoint). Only the launched entries are archived; un-selected ones stay live for a later /nil. Use when the user types /nil, \"now is later\", \"reopen my windows\", \"restore my tabs\", or \"bring my saved windows back\". Requires iTerm2."
---

# /nil: now is later

The inverse of `/sfl`. Where `sfl` saved each window for later, `/nil` says later is now: it reopens them. You choose which to bring back.

## Requirements

- **macOS with iTerm2 running.** The opener drives iTerm2 via AppleScript.
- **macOS Automation permission** for controlling iTerm2 (the first run triggers a prompt: allow it; if denied later, re-enable under System Settings > Privacy & Security > Automation).
- **`claude` on the login-shell PATH** (each new tab runs `cd ... && headsup-set-label.sh ... && claude ...`).

## What it does

For each **selected** live checkpoint in `~/.claude/sfl/*.md` (one per saved window), open a new iTerm2 tab that:
1. `cd`s into the window's recorded `cwd`,
2. restores the window's headsup label (badge + title) via `headsup-set-label.sh`,
3. launches `claude` with a resume prompt pointing at that window's **archived** entry file.

**`/nil` archives only the LAUNCHED entries, at launch time.** `nil-open.sh` moves each selected entry into `~/.claude/sfl/archive/` before the tabs open and points its resume prompt at the archived path, so a launched window can never be relaunched twice by a later `/nil`. **Un-selected entries stay live** in `~/.claude/sfl/`, so you can bring them back with a later `/nil`. (An earlier design had each child tab archive its own entry; entries leaked whenever a tab was closed before resuming, and stale windows got relaunched.) If the AppleScript fails, the script rolls the (selected) moves back so nothing is lost. Each reopened tab then **self-resumes**: its `claude` runs `/sfl` resume mode, reads the archived entry plus its `gov_memory` reference, and gives a 3-5 line catch-up; it does NOT need to archive anything.

## Steps

1. **List what could be reopened, numbered.** Show the user the plan before spawning anything. Use the opener's `--list` mode (NOT an ad-hoc shell loop; `nil-open.sh` is covered by the allow rules setup.sh installs, so this never prompts):

   ```bash
   ~/.claude/sfl/lib/nil-open.sh --list
   ```

   It prints each entry prefixed with a **number** (`1.`, `2.`, ...) followed by its `window/project/cwd/saved_at`, and opens nothing. If it prints `no-entries`, say there is nothing saved and stop.

2. **Ask which to launch.** Between the list and the open, ask the user which windows to bring back. Accept either **all** (the default) or a list of the numbers from step 1. Use `AskUserQuestion` (offer "All windows" plus the option to type specific numbers) or a one-line plain prompt like: "Which to reopen? `all`, or numbers e.g. `1,3,4`." Treat an empty answer / "all" as every window. Map the user's answer to the selection argument for step 3 (`all` or a comma/space-separated number list such as `1,3,4`).

3. **Open the selected tabs.** Pass the selection to the opener (it generates the AppleScript and runs it, one tab per selected entry, with a settle delay between tabs):

   ```bash
   ~/.claude/sfl/lib/nil-open.sh all          # every window
   ~/.claude/sfl/lib/nil-open.sh 1,3,4        # only those numbers
   ```

   To preview without spawning anything, run `~/.claude/sfl/lib/nil-open.sh --dry-run <selection>` first (prints the generated AppleScript and the entry list for the selection, opens nothing, archives nothing).

4. **Report.** Say which windows opened (the script prints `opening: <window>  (<cwd>)` per tab, then a final line: how many entries were archived and how many were left live in `~/.claude/sfl/`). The launched entries were archived at launch; any un-selected windows are still saved and can be reopened with a later `/nil`. Each new tab will catch itself up from its archived checkpoint and ask before starting work.

## Notes & failure modes

- **Selection numbers come from `--list`.** Always run `--list` first so the numbers the user picks match what the opener will launch (the opener uses the same glob order).
- **Resume is checkpoint-based by design**: each tab is a fresh `claude` that rebuilds context from its entry file, not from the old conversation transcript. This survives Claude Code version upgrades and transcript-format changes.
- If `osascript` fails (iTerm2 not running, Automation denied), the opener restores the selected live entries and exits nonzero; nothing is lost and `/nil` can simply be run again.
- Storage details and the entry format live in the `/sfl` skill (save mode writes the entries `/nil` consumes; resume mode is what each reopened tab runs).
