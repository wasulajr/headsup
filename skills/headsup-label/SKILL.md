---
name: headsup-label
description: Set or change the per-iTerm2-session label — both the window/tab title AND the badge (watermark) for THIS iTerm2 pane only. Use when the user wants a custom name for this specific tab ("call this tab 'deploy debugging'", "label this session 'prod work'", "set the badge to 'frontend'"). Title and badge always share the same string in this skill (per Steve's design — banner and watermark should match). Edits ~/.claude/hooks/headsup-status.d/<session>.conf which is LOCAL ONLY (gitignored, not pushed). For changing colors instead, use /headsup-colors.
---

# iTerm2 Per-Session Label

Sets one shared string as both the iTerm2 badge (top-right watermark) and the window/tab title for THIS iTerm2 session only. Other tabs / panes are unaffected. Local-only — does NOT commit/push (session IDs change across iTerm2 restarts, so committing would just accumulate dead files).

## How it works

All of the logic lives in one permanent script, `~/.claude/hooks/headsup-set-label.sh`. It resolves the session from `$ITERM_SESSION_ID` (present in the Bash tool's environment), writes the per-session conf + badge sidecar, and applies the badge + title immediately — writing the OSC escapes to stdout when it IS the tty (Quick Action path), or walking up the process tree to the real tty when run from inside a Claude Code session.

Because every invocation starts with the same path, a single permission allowlist rule covers it and the user is never prompted:

```
Bash(~/.claude/hooks/headsup-set-label.sh:*)
```

(setup.sh adds this rule automatically. If the user reports a permission prompt, check it exists in `~/.claude/settings.json` under `permissions.allow`.)

## Files involved

- **`~/.claude/hooks/headsup-set-label.sh`** — the script that does everything. Symlinked into place from the headsup repo.
- **`~/.claude/hooks/headsup-status.d/<session-key>.conf`** — per-session conf, sourced by the hook script after the global conf. Holds `headsup_badge_text()` and `headsup_title_text()` definitions that return the chosen label.
- **`~/.claude/hooks/.state/<uuid>.badge`** — the badge sidecar that the waiting-notification script reads to label notifications. The script writes it directly so the notification picks up the new label without waiting for the next hook event.
- The directory `headsup-status.d/` is gitignored; nothing committed.

## Flow

**Prompt-first design.** Do NOT run any Bash commands before you have the label. Reading the current label or looking up the session key first would trigger activity before the user has even been asked what they want. If the user wants to know the current label they'll ask.

1. **Get the label.**
   - If the user passed an argument when invoking the skill (e.g. `/headsup-label deploy debugging`), use that argument verbatim as the label. Skip to step 2.
   - Otherwise, **ask the user** what they want to call this tab. One question, one string (title and badge share it). Do this with `AskUserQuestion` or plain text — but before any tool calls.

2. **Run the script** — invoke it EXACTLY in this form (starting with `~/.claude/hooks/`, not the expanded absolute path, so the permission allowlist prefix matches and the user isn't prompted):

   ```bash
   ~/.claude/hooks/headsup-set-label.sh '<user-supplied-label>'
   ```

   Single-quote the label; escape any literal `'` inside as `'\''`. The script writes the conf + badge sidecar and applies the badge + title to the live tab in one shot. Don't commit / push — `headsup-status.d/` is gitignored and per-session ephemeral.

3. **Confirm to the user**, 1–2 sentences. "Label set to '<value>'. Visible in the badge now; persists until you restart iTerm2 (then run `/headsup-label` again)."

The title may flicker if the user's iTerm2 profile doesn't have `Allow Title Setting: false` — Claude Code's TUI re-asserts the title on each render. Badge is stable regardless. Mention only if it actually misbehaves.

## Removing a label

If the user wants to remove the per-session override and revert to the global default (`Claude · <project>` etc.):

```bash
~/.claude/hooks/headsup-set-label.sh --clear
```

This deletes the per-session conf + badge sidecar, recomputes the default badge/title from the global conf, and re-applies them to the live tab.

## Notes

- This skill is per-session, no commit/push. `/headsup-colors` is the global-and-committed counterpart.
- If `ITERM_SESSION_ID` is empty, the design fails — the script prints an error and exits cleanly. Tell the user to check they're running Claude Code from inside an iTerm2 pane.
- Don't write to the global conf from this skill; that would clobber the project-name default everyone else's tabs depend on.
