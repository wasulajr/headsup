---
name: sfl
description: "Save For Later: checkpoint this window so a fresh session (or /nil) can resume it later. Use when the user types /sfl, \"save for later\", or \"checkpoint this window\". Writes a live per-window entry under ~/.claude/sfl/ (plus an optional durable note in the user's own memory system), then shows the green Saved-for-Later banner. Has a second mode, \"sfl resume\", invoked when /nil reopens a window: read this window's checkpoint, get back up to speed, then archive the entry if it is still live."
---

# sfl: Save For Later (and resume)

Two modes. Default is **save**. If the invocation says `resume` (e.g. `/sfl resume`, or the launch prompt `/nil` injects), run **resume** instead.

---

## SAVE mode

Checkpoint the current window so any fresh session can pick it up with zero re-derivation. One required write, one optional write, then a banner.

### 1. Durable checkpoint (optional)

If you maintain a memory system (project memory files, a notes directory, anything persistent across sessions), write the fuller checkpoint there: what was done, what is pending, exact open questions, file and resource paths, decisions made. Convert relative dates to absolute. Distill; do not dump the transcript. Reference that file in the entry's `gov_memory` field in step 2.

If there is no memory system, skip this step. The entry file from step 2 is then the complete checkpoint, and `gov_memory:` is `(none)`.

### 2. Live per-window entry (what /nil consumes)

Resolve this window's identity:

```bash
~/.claude/sfl/lib/window-id.sh
```

It prints `LABEL=`, `SLUG=`, `CWD=`, `STAMP=`. The entry file is `~/.claude/sfl/<SLUG>.md`: **one file per window, and you overwrite it** (the newest sfl per window wins; that is the whole point, so do not append or version it).

**Write it through the Bash helper, NOT the Write tool.** Claude Code guards direct Write-tool access to its own config directory (`~/.claude/`), which prompts on every save. The helper `sfl-entry.sh` writes via the Bash tool instead (covered by the allow rules setup.sh installs), so checkpoints save silently. Pipe the composed markdown to it via a heredoc, substituting `<SLUG>` and filling every field:

```bash
cat <<'SFLEOF' | ~/.claude/sfl/lib/sfl-entry.sh write '<SLUG>'
---
window: <LABEL>
project: <human project name>
cwd: <CWD>
saved_at: <STAMP>
gov_memory: <path to the durable memory file from step 1, or "(none)">
---

## Checkpoint
<2-4 sentences: what was being worked on, decisions made, what is pending, open questions. Distilled; the fuller version, if any, lives in gov_memory.>

## How to restart
<the single concrete first action on resume, plus any 2nd/3rd step. Concrete enough to act on immediately: "run X against Y", not "continue the work".>
SFLEOF
```

It overwrites any prior entry for this window (newest wins). Use a quoted `'SFLEOF'` heredoc so `$` and backticks in your text are not expanded.

### 3. Banner + confirmation

Show the **Saved-for-Later banner** directly above a 1-2 sentence confirmation, so the checkpoint is unmissable in the terminal. Five lines: 100-`#` walls wrapped in `**...**`, blank lines around the middle line:

`🟢 🟢 🟢  **[ SAVED FOR LATER ]**  🟢 🟢 🟢`

(NEVER use raw HTML like `<span style=...>` or `<u>` in banners. The terminal renders GitHub-flavored markdown only, so HTML tags print as literal text.)

Then confirm in 1-2 sentences, naming the window and stating that the live entry was written, so the user knows `/nil` can restore it.

---

## RESUME mode

Invoked when `/nil` reopens this window (it launches `claude` with a resume prompt) or when the user runs `/sfl resume`. Goal: get THIS window back up to speed, then clear its live entry.

1. **Find this window's entry.** If the prompt names a specific file (`/nil` prompts point into `~/.claude/sfl/archive/`), use it. Otherwise resolve the current window with `~/.claude/sfl/lib/window-id.sh` and read `~/.claude/sfl/<SLUG>.md`; if there is no live entry, fall back to the newest `~/.claude/sfl/archive/<SLUG>-*.md`. If neither exists, say so and stop (nothing to resume).
2. **Read it and its `gov_memory` file** (when not `(none)`) for fuller context.
3. **Catch the user up**: 3-5 lines on where things left off and the single recommended next step (from the "How to restart" section). Do NOT start the work until the user confirms.
4. **Archive the entry IF it is still live.** Entries are archived, never hard-deleted, so a checkpoint can always be recovered. Use the same helper so there is no prompt:

   ```bash
   ~/.claude/sfl/lib/sfl-entry.sh archive '<SLUG>'
   ```

   `/nil` already archives every entry at launch, so when this window was reopened by `/nil` there is nothing left to archive (the helper prints "no live entry"; that is fine, not an error). This step only does work when the user runs `/sfl resume` by hand on a window whose entry is still live. The durable memory file from save mode, if any, is untouched either way; only the live entry is cleared.

---

## Design notes

- **Window identity = the headsup tab label.** `window-id.sh` reads it from `~/.claude/hooks/headsup-status.d/`, falling back to the cwd basename if no label is set.
- **Per-window files, not one shared roster.** Many windows can run sfl simultaneously with zero write contention, since each touches only its own `<SLUG>.md`.
- Companion skill: **`/nil`** opens a tab per live entry and lets each one self-resume via this skill's resume mode.
