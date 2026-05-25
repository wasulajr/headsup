---
name: iterm-colors
description: Customize the three global tab colors for Claude Code's iTerm2 status hook — idle (fresh session), processing (Claude working), and waiting (Claude needs you). Invoke when the user wants to change any of those three colors ("change waiting color to orange", "idle should be gray", "swap blue for purple while processing"). Edits ~/.claude/hooks/iterm-status.conf, applies the matching color to the current tab immediately, then commits + pushes to wasulajr/lookout. Title/badge customization is a SEPARATE skill (/iterm-label) — don't handle those here.
---

# iTerm2 Color Customization (global)

Edits the three state colors in the GLOBAL hook config. All iTerm2 tabs running `claude` share these colors; per-tab labels (title + badge) are handled separately by `/iterm-label`.

## Files involved

- **`~/.claude/hooks/iterm-status.conf`** — global config. Edit this only; do NOT touch `~/.claude/hooks/iterm-status.sh` (the script has defaults that apply when the conf file is missing — that's the safety net).
- **`~/.claude/`** — git repo (`wasulajr/lookout`, public). After saving, commit + push.

## Configurable surface

Three hex values (no leading `#`):

- `IDLE_COLOR` — fresh session / idle state
- `PROCESS_COLOR` — Claude is processing the user's prompt
- `WAIT_COLOR` — Claude has finished and is waiting on the user

Title and badge are NOT in scope here. If the user asks about title/badge changes during this skill, redirect them to `/iterm-label`.

## Flow

1. **Read current colors** from `~/.claude/hooks/iterm-status.conf`. If the file doesn't exist, the script defaults apply (white / blue / yellow).
2. **Show the three current values** clearly. Use the user's argument to the skill (if any) as a hint about which color(s) they want to change; otherwise ask.
3. **Ask only about colors the user wants to change.** Accept hex codes OR common color names — translate names to hex yourself (e.g. `red` → `e74c3c`, `green` → `2ecc71`, `orange` → `e67e22`, `purple` → `9b59b6`).
4. **Validate hex** — must be 6 hex chars, no `#`. Reject 3-char or `#`-prefixed forms with a one-line correction.
5. **Rewrite the conf file**, preserving the existing badge/title function bodies and any other content unchanged. Only modify the `*_COLOR=` lines that the user asked about.
6. **Apply the matching color immediately to the current tab.** Don't wait for the next session. Only write the color matching Claude's CURRENT state — writing the wrong-state color would visually contradict reality (e.g. don't write the new WAIT_COLOR right now because Claude is currently processing the user's prompt, so the tab should be PROCESS_COLOR). The simple heuristic: if you changed `PROCESS_COLOR`, write that one (Claude is processing while this skill runs). If you changed `IDLE_COLOR` or `WAIT_COLOR`, mention they'll appear at the appropriate future moment but don't write them now.
   - To write the color: find the parent tty by walking up via `ps -o tty= -p $PPID` until a non-`??` tty appears, then write `\033]1337;SetColors=tab=<hex>\007` directly to `/dev/<tty>`.
7. **Commit and push.** In `~/.claude/`: `git add hooks/iterm-status.conf`, commit with a HEREDOC message naming the specific change (e.g. "Switch WAIT_COLOR from yellow to orange") and the standard `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` footer, then `git push origin main`.
8. **Tell the user what changed**, 1-2 sentences. If you applied a color immediately in step 6, mention they should see it right now. Otherwise mention which future event will show the new color (SessionStart for idle, UserPromptSubmit for processing, Stop/Notification for waiting).

## Notes

- Don't ask permission to commit + push. The user invoked the skill; persistence is the whole point.
- Don't add or remove any other config — only the three `*_COLOR=` variables.
- If the user wants different colors per session, that's not supported by design (per Steve's 2026-05-12 decision: colors are global, labels are per-session). Tell them and offer `/iterm-label` for per-session distinguishability via the badge instead.
