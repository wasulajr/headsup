---
name: headsup-config
description: "Unified settings hub for headsup (Claude Code's iTerm2 status hooks). One command with a section as the first word, then that section's args. Sections: newtabs (New Claude Tab / Cmd-Opt-C launch mode), colors (idle/processing/waiting tab colors), label (this tab's title + badge), notify (the 'Claude is waiting' macOS notification). Use when the user types /headsup-config, or asks to configure/change headsup settings and names one of those areas, e.g. /headsup-config newtabs off, /headsup-config colors wait orange, /headsup-config label deploy work, /headsup-config notify 10. With no section it shows every current setting."
---

# /headsup-config: headsup settings hub

One entry point for every headsup setting. The first word of the arguments selects a **section**; the rest is that section's own arguments, passed straight through to the same backing helper the dedicated skill uses. The focused skills (`/headsup-colors`, `/headsup-label`, `/headsup-notifications`) still exist and auto-trigger on natural phrasing; this is the unified manual entry point, and it is the ONLY skill for the New Claude Tab launch mode (there is no separate `/headsup-newtab-args`).

## Sections

| Section | What it sets | Backing helper |
|---|---|---|
| `newtabs` | New Claude Tab (Cmd-Opt-C) launch mode | `~/.claude/hooks/headsup-newtab-args.sh` |
| `codextabs` | New Codex Tab launch mode | `~/.claude/hooks/headsup-newtab-args.sh --codex` |
| `colors` | idle / processing / waiting tab colors (global) | the `/headsup-colors` procedure |
| `label` | this tab's title + badge (per-session) | `~/.claude/hooks/headsup-set-label.sh` |
| `notify` | the "Claude is waiting" macOS notification | `~/.claude/hooks/headsup-notifications.sh` |

Accepted section aliases: `newtab`/`autorun` -> `newtabs`; `codex`/`codextab` -> `codextabs`; `color` -> `colors`; `title`/`badge` -> `label`; `notifications` -> `notify`.

## What to do when invoked

1. **Parse the arguments.** The first whitespace-delimited token is the `section`; everything after it is `rest` (may be empty). Map aliases to a canonical section above.

2. **No section, or `show` / `status` / `help`:** show every current setting, then stop. Run these (read-only) and summarize the output:
   ```bash
   ~/.claude/hooks/headsup-newtab-args.sh --show
   ~/.claude/hooks/headsup-newtab-args.sh --codex --show
   ~/.claude/hooks/headsup-notifications.sh            # prints current notify state
   grep -E '^(IDLE|PROCESS|WAIT)_COLOR=' ~/.claude/hooks/headsup-status.conf
   ```
   Also note the current per-session label is whatever `/headsup-label` last set (mention it is per-tab). List the sections so the user knows what they can change.

3. **`newtabs <rest>`:** run the setter, passing `rest` through unchanged:
   ```bash
   ~/.claude/hooks/headsup-newtab-args.sh <rest>
   ```
   `rest` is one of `off | acceptEdits | plan | full`, `-- <raw args>`, or `--show`. Empty `rest` -> run with `--show`. Confirm the printed value in one line; it takes effect on the next Cmd-Opt-C.

   **`codextabs <rest>`:** same setter, but for the New Codex Tab. Prepend `--codex`:
   ```bash
   ~/.claude/hooks/headsup-newtab-args.sh --codex <rest>
   ```
   `rest` is one of `off | full-auto | yolo | never|on-request|on-failure|untrusted | approval <policy>`, `-- <raw args>`, or `--show` (codex flags differ from claude's). Empty `rest` -> run with `--codex --show`.

4. **`label <rest>`:** run the per-session label setter:
   ```bash
   ~/.claude/hooks/headsup-set-label.sh <rest>      # rest = the label text, or --clear
   ```
   Empty `rest` -> ask for the label text first (do not call with no args). Confirm in one line.

5. **`notify <rest>`:** pass `rest` straight through (the helper parses it: `on`/`off`/`<minutes>`/`test`/`sound <name>`):
   ```bash
   ~/.claude/hooks/headsup-notifications.sh <rest>
   ```
   Empty `rest` -> run with no args to show current state. One short confirmation.

6. **`colors <rest>`:** color names need translation and the change is applied live + persisted, so follow the existing procedure rather than a single helper: **read `~/.claude/skills/headsup-colors/SKILL.md` and follow its Flow**, treating `rest` as the user's color request (e.g. `wait orange`, `process 8a3ffc`). If `rest` is empty, ask which of idle/processing/waiting to change.

7. **Unknown section:** list the four sections and ask which one they meant. Do not guess-run a helper.

## Notes

- The backing helpers each print their resulting state; keep your own confirmation to one line and do not duplicate their output.
- Permissions: the helpers are individually allowlisted (setup.sh adds the rules). If a section prompts for permission on first use, that is expected until the rule is present.
- Scope: `colors` and `notify` are global (all tabs); `label` is per-session (this tab only); `newtabs` is global to the shortcut. This mirrors the focused skills.
