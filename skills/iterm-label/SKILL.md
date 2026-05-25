---
name: iterm-label
description: Set or change the per-iTerm2-session label — both the window/tab title AND the badge (watermark) for THIS iTerm2 pane only. Use when the user wants a custom name for this specific tab ("call this tab 'deploy debugging'", "label this session 'prod work'", "set the badge to 'frontend'"). Title and badge always share the same string in this skill (per Steve's design — banner and watermark should match). Edits ~/.claude/hooks/iterm-status.d/<session>.conf which is LOCAL ONLY (gitignored, not pushed). For changing colors instead, use /iterm-colors.
---

# iTerm2 Per-Session Label

Sets one shared string as both the iTerm2 badge (top-right watermark) and the window/tab title for THIS iTerm2 session only. Other tabs / panes are unaffected. Local-only — does NOT commit/push (session IDs change across iTerm2 restarts, so committing would just accumulate dead files).

## Files involved

- **`~/.claude/hooks/iterm-status.d/<session-key>.conf`** — per-session conf, sourced by the hook script after the global conf. Holds `iterm_badge_text()` and `iterm_title_text()` definitions that return the chosen label.
- The directory `iterm-status.d/` is gitignored; nothing committed.

## Determining the session key

The current iTerm2 session is identified by the `ITERM_SESSION_ID` env var inherited from the iTerm2-spawned shell. The hook subprocess for the `claude` TUI inherits it; YOU running as a skill might not have it directly, so look it up from the parent `claude` TUI process:

```bash
SESSION_ID=$(ps eww -p $PPID 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | head -1 | cut -d= -f2-)
```

Then sanitize for use as a filename (colons aren't great for filenames):

```bash
SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c '[:alnum:]-' '_')
```

If `SESSION_ID` comes back empty, abort with a clear error — the user is probably not in iTerm2, or running Claude Code via some path that doesn't propagate the var.

## Flow

1. **Resolve session key** as above. Path is `~/.claude/hooks/iterm-status.d/${SESSION_KEY}.conf`.
2. **Read the current label** by sourcing the existing per-session conf (if any) in a subshell and calling `iterm_badge_text`. If no per-session conf exists, the current label is whatever the global conf produces (probably the project name).
3. **Ask the user what to name this session.** Don't ask about title and badge separately — they share one value here. The user gives one string.
4. **Write the per-session conf file.** Create `~/.claude/hooks/iterm-status.d/` if it doesn't exist. The file content should be exactly this template (replace `LABEL_HERE` with the user's string):

```bash
# Per-iTerm2-session override for this pane.
# Managed by the /iterm-label skill. Edits to this file are local-only —
# the iterm-status.d/ directory is gitignored. ITERM_SESSION_ID changes
# across iTerm2 restarts, so this file becomes stale after restart.

iterm_badge_text() {
    printf 'LABEL_HERE'
}

iterm_title_text() {
    printf 'LABEL_HERE'
}
```

Use `printf` (not `echo`) so the string is taken literally and special chars in the label aren't interpreted.

5. **Apply the label to this tab immediately.** Find the parent tty (`ps -o tty= -p $PPID`, walk up until non-`??`), then write:

```
OSC 1337 ; SetBadgeFormat=<base64-of-label> BEL
OSC 0 ; <label> BEL
```

Both as a single byte stream to `/dev/<tty>`. Note: the title may flicker if the user's iTerm2 profile doesn't have `Allow Title Setting: false` — Claude Code's TUI re-asserts the title on each render. Badge is stable regardless. Mention this caveat to the user only if you suspect they're in an ad-hoc (non-profile) session.

6. **DON'T commit or push.** This file is gitignored and per-session ephemeral. Tell the user it'll persist while this iTerm2 session is alive but get re-keyed on iTerm2 restart.

7. **Confirm to the user**: 1-2 sentences. "Label set to '<value>'. Visible in the badge now; persists until you restart iTerm2 (then run `/iterm-label` again)."

## Removing a label

If the user wants to remove the per-session override and revert to the global default (`Claude · <project>` etc.):

```bash
rm "$HOME/.claude/hooks/iterm-status.d/${SESSION_KEY}.conf"
```

Then re-apply the global badge/title by computing them in a subshell that sources only the global conf, and writing the resulting OSC to the parent tty as in step 5.

## Notes

- This skill is per-session, no commit/push. `/iterm-colors` is the global-and-committed counterpart.
- If `ITERM_SESSION_ID` is empty, the design fails — abort cleanly with an error telling the user to check they're running Claude Code from inside an iTerm2 pane.
- Don't write to the global conf from this skill; that would clobber the project-name default everyone else's tabs depend on.
