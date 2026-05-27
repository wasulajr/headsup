---
name: headsup-label
description: Set or change the per-iTerm2-session label — both the window/tab title AND the badge (watermark) for THIS iTerm2 pane only. Use when the user wants a custom name for this specific tab ("call this tab 'deploy debugging'", "label this session 'prod work'", "set the badge to 'frontend'"). Title and badge always share the same string in this skill (per Steve's design — banner and watermark should match). Edits ~/.claude/hooks/headsup-status.d/<session>.conf which is LOCAL ONLY (gitignored, not pushed). For changing colors instead, use /headsup-colors.
---

# iTerm2 Per-Session Label

Sets one shared string as both the iTerm2 badge (top-right watermark) and the window/tab title for THIS iTerm2 session only. Other tabs / panes are unaffected. Local-only — does NOT commit/push (session IDs change across iTerm2 restarts, so committing would just accumulate dead files).

## Files involved

- **`~/.claude/hooks/headsup-status.d/<session-key>.conf`** — per-session conf, sourced by the hook script after the global conf. Holds `headsup_badge_text()` and `headsup_title_text()` definitions that return the chosen label.
- **`~/.claude/hooks/.state/<uuid>.badge`** — the badge sidecar that the waiting-notification script reads to label notifications. Normally `headsup-status.sh` refreshes it on every hook event, but this skill writes it directly so the notification picks up the new label without waiting for the next tool call.
- The directory `headsup-status.d/` is gitignored; nothing committed.

## Flow

**Prompt-first design.** Do NOT run any Bash commands before you have the label. Reading the current label or looking up the session key first would trigger a permission prompt before the user has even been asked what they want — that's worse UX than skipping the current-label read. If the user wants to know the current label they'll ask.

1. **Get the label.**
   - If the user passed an argument when invoking the skill (e.g. `/headsup-label deploy debugging`), use that argument verbatim as the label. Skip to step 2.
   - Otherwise, **ask the user** what they want to call this tab. One question, one string (title and badge share it). Do this with `AskUserQuestion` or plain text — but before any tool calls.

2. **Run a single Bash command** that does everything: resolves the session key from `ITERM_SESSION_ID` (looked up from the parent `claude` TUI process via `ps eww -p $PPID`), creates `~/.claude/hooks/headsup-status.d/` if missing, writes the per-session conf, walks up `$PPID` to find a real tty, and writes the OSC sequences to apply badge + title immediately. Template:

   ```bash
   LABEL='<user-supplied-label>'   # single-quote; escape any literal ' inside
   SESSION_ID=$(ps eww -p $PPID 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | head -1 | cut -d= -f2-)
   [ -z "$SESSION_ID" ] && { echo "ERROR: ITERM_SESSION_ID not found — are you in iTerm2?"; exit 1; }
   SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c '[:alnum:]-' '_')
   UUID="${SESSION_ID##*:}"   # the UUID portion the notify script keys on
   CONF_DIR="$HOME/.claude/hooks/headsup-status.d"
   CONF="$CONF_DIR/${SESSION_KEY}.conf"
   STATE_DIR="$HOME/.claude/hooks/.state"
   BADGE_FILE="$STATE_DIR/${UUID}.badge"
   mkdir -p "$CONF_DIR" "$STATE_DIR"
   cat > "$CONF" <<EOF
   # Per-iTerm2-session override for this pane.
   # Managed by /headsup-label. Local-only — headsup-status.d/ is gitignored.
   # ITERM_SESSION_ID changes across iTerm2 restarts, so this becomes stale.

   headsup_badge_text() { printf '%s' "$LABEL"; }
   headsup_title_text() { printf '%s' "$LABEL"; }
   EOF
   # Sync the badge sidecar so the waiting-notification script picks up the
   # new label immediately, without waiting for the next hook event.
   printf '%s\n' "$LABEL" > "$BADGE_FILE"
   # Walk up $PPID until a real tty appears
   pid=$PPID; tty="??"
   while [ "$tty" = "??" ] && [ "$pid" != "1" ]; do
       tty=$(ps -o tty= -p "$pid" | tr -d ' '); [ -z "$tty" ] && tty="??"
       pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
   done
   if [ "$tty" != "??" ] && [ -w "/dev/$tty" ]; then
       BADGE_B64=$(printf '%s' "$LABEL" | base64)
       printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$BADGE_B64" "$LABEL" > "/dev/$tty"
   fi
   echo "Wrote $CONF + $BADGE_FILE and applied to /dev/$tty"
   ```

   Use `printf '%s' "$LABEL"` (not `echo`) inside the conf so special chars in the label aren't interpreted. Don't commit / push — `headsup-status.d/` is gitignored and per-session ephemeral.

3. **Confirm to the user**, 1–2 sentences. "Label set to '<value>'. Visible in the badge now; persists until you restart iTerm2 (then run `/headsup-label` again)."

The title may flicker if the user's iTerm2 profile doesn't have `Allow Title Setting: false` — Claude Code's TUI re-asserts the title on each render. Badge is stable regardless. Mention only if it actually misbehaves.

## Removing a label

If the user wants to remove the per-session override and revert to the global default (`Claude · <project>` etc.):

```bash
rm "$HOME/.claude/hooks/headsup-status.d/${SESSION_KEY}.conf"
rm -f "$HOME/.claude/hooks/.state/${UUID}.badge"   # next hook event will repopulate from the default
```

Then re-apply the global badge/title by computing them in a subshell that sources only the global conf, and writing the resulting OSC to the parent tty as in step 5.

## Notes

- This skill is per-session, no commit/push. `/headsup-colors` is the global-and-committed counterpart.
- If `ITERM_SESSION_ID` is empty, the design fails — abort cleanly with an error telling the user to check they're running Claude Code from inside an iTerm2 pane.
- Don't write to the global conf from this skill; that would clobber the project-name default everyone else's tabs depend on.
