---
name: nil
description: "now is later: the companion to /sfl. Reopen the windows you saved for later: list the saved checkpoints in ~/.claude/sfl/ numbered, ask which to launch (all or specific numbers), then open one tab per selected entry in the current terminal provider, or AI Power Term when selected or when run from AI Power Term. Each tab cds to its dir, restores its label, and launches the current/forced LLM CLI (Claude or Codex) pointed at the archived checkpoint. Only launched entries are archived; un-selected ones stay live for a later /nil. Use when the user types /nil, \"now is later\", \"reopen my windows\", \"restore my tabs\", or \"bring my saved windows back\"."
---

# /nil: now is later

The inverse of `/sfl`. Where `sfl` saved each window for later, `/nil` says later is now: it reopens them. You choose which to bring back.

## Requirements

- **macOS with iTerm2, WezTerm, or AI Power Term.** The opener chooses the current terminal provider automatically: `AI_POWER_TERM_SESSION_ID` means AI Power Term; `WEZTERM_PANE` means WezTerm; `ITERM_SESSION_ID` means iTerm2; outside those, legacy iTerm2 remains the default. Force AI Power Term with `HEADSUP_NIL_PROVIDER=ai-power-term`.
- **Claude or Codex on the login-shell PATH.** The opener chooses the current agent automatically: Codex when run from Codex, otherwise Claude. Force an agent with `HEADSUP_NIL_AGENT=codex|claude`.
- **For iTerm2:** macOS Automation permission for controlling iTerm2. The first run triggers a prompt; allow it. If denied later, re-enable under System Settings > Privacy & Security > Automation.
- **For WezTerm:** the `wezterm` CLI must be available. The normal install path/symlink is enough.
- **Current-agent resume.** Each new tab runs `cd ... && <label helper> ... && <agent> <resume prompt>`. Claude resumes restore Claude permission mode from the saved entry; Codex resumes use normal Codex local config and approval policy.

## What it does

For each **selected** live checkpoint in `~/.claude/sfl/*.md` (one per saved window), open a new tab in the current provider that:
1. `cd`s into the window's recorded `cwd`,
2. restores the window's headsup label via `headsup-set-label.sh` (iTerm2 badge/title or WezTerm label/user vars),
3. launches the current/forced agent CLI with a resume prompt pointing at that window's **archived** entry file. Claude launches in the saved permission mode (`--permission-mode <mode>` from the entry's `mode:` field: auto-accept / plan / default / bypass). Codex launches with normal Codex config.

**`/nil` archives only the LAUNCHED entries, at launch time.** `nil-open.sh` moves each selected entry into `~/.claude/sfl/archive/` before the tabs open and points its resume prompt at the archived path, so a launched window can never be relaunched twice by a later `/nil`. **Un-selected entries stay live** in `~/.claude/sfl/`, so you can bring them back with a later `/nil`. If launch fails, the script rolls back entries that were not successfully launched. Each reopened tab then **self-resumes**: its `claude` runs `/sfl` resume mode, reads the archived entry plus its `gov_memory` reference, and gives a 3-5 line catch-up; it does NOT need to archive anything.

## Steps

1. **List what could be reopened, numbered.** Show the user the plan before spawning anything. Use the opener's compact chat-list mode (NOT an ad-hoc shell loop; `nil-open.sh` is covered by the allow rules setup.sh installs, so this never prompts):

   ```bash
   ~/.claude/sfl/lib/nil-open.sh --chat-list
   ```

   It prints each entry prefixed with a **number** (`1.`, `2.`, ...) followed by its window, short project label, saved time, and cwd. It opens nothing. These are the same selection numbers accepted by `nil-open.sh all` or `nil-open.sh 1,3,4`. If it prints `no-entries`, say there is nothing saved and stop.

   **Then paste the numbered list into your next visible message, preserving its line breaks.** Do not compress it into one sentence, do not join entries with pipes, do not say "rendered above", and do not rely on the shell tool result. The shell output may be collapsed in the terminal UI. The visible copy is what the user actually reads.

2. **Ask which to launch with `AskUserQuestion`, using exactly these THREE hard-coded options. Never one-per-window.** The options are a FIXED set and do NOT scale with the number of saved windows, so the call can never exceed the tool's 4-option cap no matter how many windows exist:

   - `header`: `"Reopen"`, `multiSelect`: `false`
   - Option 1 — label **"Open All the Windows"**, description: "Reopen every saved window listed above."
   - Option 2 — label **"Type the #'s of the Windows to Open"**, description: "Reopen only specific windows. Use the text box to type the numbers from the list, e.g. `1,3,4`."
   - Option 3 — label **"Something Else"**, description: "None of the above — tell me what you want instead."

   Put the numbered list directly in the question text above the choices, preserving one window per numbered block. This is mandatory: it makes the list visible even when the command output is hidden or collapsed.

   Map the answer to step 3's selection argument:
   - "Open All the Windows" → `all`.
   - "Type the #'s of the Windows to Open" → read the numbers the user typed; if no numbers came back, ask one short prose follow-up ("Which numbers? e.g. `1,3,4`") before opening. Selection argument = that comma/space-separated number list.
   - "Something Else" / the auto "Other" → do what the free text says (e.g. they may type numbers directly, "none", or a different instruction).

3. **Open the selected tabs.** Pass the selection to the opener. The opener decides iTerm2 vs WezTerm from the current terminal:

   ```bash
   ~/.claude/sfl/lib/nil-open.sh all          # every window
   ~/.claude/sfl/lib/nil-open.sh 1,3,4        # only those numbers
   ```

   To preview without spawning anything, run `~/.claude/sfl/lib/nil-open.sh --dry-run <selection>` first. To force a provider for testing only:

   ```bash
   HEADSUP_NIL_PROVIDER=wezterm ~/.claude/sfl/lib/nil-open.sh --dry-run 1
   HEADSUP_NIL_PROVIDER=iterm ~/.claude/sfl/lib/nil-open.sh --dry-run 1
   HEADSUP_NIL_PROVIDER=ai-power-term ~/.claude/sfl/lib/nil-open.sh --dry-run 1
   HEADSUP_NIL_AGENT=codex ~/.claude/sfl/lib/nil-open.sh --dry-run 1
   HEADSUP_NIL_AGENT=claude ~/.claude/sfl/lib/nil-open.sh --dry-run 1
   ```

4. **Report.** Say which windows opened. The script prints `opening: <window>  (<cwd>)` per tab, then a final line saying how many provider tabs opened, how many entries were archived, and how many remain live in `~/.claude/sfl/`. Each new tab will catch itself up from its archived checkpoint and ask before starting work.

## Notes & failure modes

- **Selection numbers come from `--list`.** Always run `--list` first so the numbers the user picks match what the opener will launch.
- **Provider choice is automatic unless forced.** `/nil` from AI Power Term opens AI Power Term tabs. `/nil` from WezTerm opens WezTerm tabs. `/nil` from iTerm2 opens iTerm2 tabs. `HEADSUP_NIL_PROVIDER=ai-power-term|wezterm|iterm` forces a provider for tests or one-offs.
- **Agent choice is automatic unless forced.** `/nil` from Codex opens Codex sessions; otherwise it opens Claude sessions. `HEADSUP_NIL_AGENT=codex|claude` lets you intentionally switch LLMs while keeping the same saved `/sfl` checkpoints.
- **Resume is checkpoint-based by design**: each tab is a fresh Claude or Codex session that rebuilds context from its entry file, not from the old conversation transcript.
- **Claude permission mode is restored** from the entry's `mode:` field (`/sfl` captures the live mode via the `sfl-capture-mode.sh` hook). Entries with no `mode:` launch plain `claude`. Codex resumes use Codex's local approval/sandbox config.
- **iTerm2 cold-start tab reuse**: when iTerm2 is not already running, `activate` auto-creates one empty default tab. `nil-open.sh` reuses that tab for the first entry instead of leaving it as a stray extra tab.
- If iTerm2 AppleScript fails, the opener restores the selected live entries and exits nonzero. If WezTerm or AI Power Term spawn partially fails, entries for tabs already launched stay archived; entries not launched are restored.
- Storage details and the entry format live in the `/sfl` skill (save mode writes the entries `/nil` consumes; resume mode is what each reopened tab runs).
- **Daily maintenance sweep.** On every real reopen (not `--list`/`--dry-run`), `nil-open.sh` runs `~/.claude/maintenance/daily-sweep.sh` once after the tabs launch. It is fail-open and reversible; `SWEEP_DRYRUN=1 ~/.claude/maintenance/daily-sweep.sh` previews it.
