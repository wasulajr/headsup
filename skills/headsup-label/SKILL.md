---
name: headsup-label
description: "Set or change the per-session label (window/tab title AND badge/watermark) for THIS terminal pane only, in iTerm2, WezTerm, or AI Power Term. Use when the user wants a custom name for this specific tab (\"call this tab 'deploy debugging'\", \"label this session 'prod work'\", \"set the badge to 'frontend'\"). Title and badge always share the same string in this skill. Edits ~/.claude/hooks/headsup-status.d/<session>.conf which is LOCAL ONLY (gitignored, not pushed). For changing colors instead, use /headsup-colors."
---

# Per-Session Label

Sets one shared string as the tab title and the badge/watermark for THIS terminal session only, in iTerm2, WezTerm, or AI Power Term. Other tabs and panes are unaffected. Local-only: does NOT commit or push (session IDs change across terminal restarts, so committing would just accumulate dead files).

## How it works

All of the logic lives in one permanent script, `~/.claude/hooks/headsup-set-label.sh`. It resolves the session in this order: `$AI_POWER_TERM_SESSION_ID` (AI Power Term), then `$ITERM_SESSION_ID` (iTerm2), then `$WEZTERM_PANE` (WezTerm). It writes the per-session conf plus a badge sidecar, then applies the label immediately:

- **AI Power Term**: sends the app server's websocket `rename` action (the xterm.js frontend ignores OSC title escapes).
- **iTerm2 / WezTerm**: writes the OSC escapes to stdout when it IS the tty (Quick Action path), or walks up the process tree to the real tty when run from inside a Claude Code session. WezTerm also picks up the label from its user vars.

Because every invocation starts with the same path, a single permission allowlist rule covers it and the user is never prompted:

```
Bash(~/.claude/hooks/headsup-set-label.sh:*)
```

(setup.sh adds this rule automatically. If the user reports a permission prompt, check it exists in `~/.claude/settings.json` under `permissions.allow`.)

## Files involved

- **`~/.claude/hooks/headsup-set-label.sh`**: the script that does everything. Symlinked into place from the headsup repo.
- **`~/.claude/hooks/headsup-status.d/<session-key>.conf`**: per-session conf, sourced by the hook script after the global conf. Holds `headsup_badge_text()` and `headsup_title_text()` definitions that return the chosen label.
- **`~/.claude/hooks/.state/<uuid>.badge`**: the badge sidecar that the waiting-notification script reads to label notifications. The script writes it directly so the notification picks up the new label without waiting for the next hook event.
- The directory `headsup-status.d/` is gitignored; nothing committed.

## Flow

**Prompt-first design.** Do NOT run any Bash commands before you have the label. Reading the current label or looking up the session key first would trigger activity before the user has even been asked what they want. If the user wants to know the current label they'll ask.

1. **Get the label.**
   - If the user passed an argument when invoking the skill (e.g. `/headsup-label deploy debugging`), use that argument verbatim as the label. Skip to step 2.
   - Otherwise, **ask the user** what they want to call this tab. One question, one string (title and badge share it). Do this with `AskUserQuestion` or plain text, but before any tool calls.

2. **Run the script**, invoking it EXACTLY in this form (starting with `~/.claude/hooks/`, not the expanded absolute path, so the permission allowlist prefix matches and the user isn't prompted):

   ```bash
   ~/.claude/hooks/headsup-set-label.sh '<user-supplied-label>'
   ```

   Single-quote the label; escape any literal `'` inside as `'\''`. The script writes the conf plus badge sidecar and applies the label to the live tab in one shot. Don't commit or push: `headsup-status.d/` is gitignored and per-session ephemeral.

3. **Confirm to the user**, 1 to 2 sentences. "Label set to '<value>'. Visible in the badge now; persists until you restart the terminal (then run `/headsup-label` again)."

In iTerm2 the title may flicker if the user's profile doesn't have `Allow Title Setting: false`, because Claude Code's TUI re-asserts the title on each render. The badge is stable regardless. Mention only if it actually misbehaves.

## Removing a label

If the user wants to remove the per-session override and revert to the global default (`Claude · <project>` etc.):

```bash
~/.claude/hooks/headsup-set-label.sh --clear
```

This deletes the per-session conf plus badge sidecar, recomputes the default badge/title from the global conf, and re-applies them to the live tab.

## Notes

- This skill is per-session, no commit or push. `/headsup-colors` is the global-and-committed counterpart.
- If no supported terminal session id is present, the design fails: the script prints an error and exits cleanly. Tell the user to check they're running Claude Code inside iTerm2, WezTerm, or AI Power Term.
- Don't write to the global conf from this skill; that would clobber the project-name default everyone else's tabs depend on.
