---
name: headsup-new-tab-shortcut
description: Install, update, re-bind, or remove the "New Claude Tab" macOS Finder Quick Action — select a folder in Finder, press ⌘⌥C, and a new iTerm2 tab opens, prompts for a headsup label (tab title + badge), cds into the folder, and launches claude. Use when the user wants to (re)install the shortcut, fix or change the ⌘⌥C hotkey, the Quick Action stopped appearing in Finder's menu, or asks "set up the new claude tab shortcut". Normally setup.sh installs this automatically and /headsup-update keeps it current — this skill is the manual/repair path.
---

# New Claude Tab — Finder Quick Action

A macOS Quick Action (Automator Service). Select a folder in Finder, press **⌘⌥C** → a dialog asks for a label (defaults to the folder name) → a new iTerm2 tab opens, the label is applied as tab title + badge via `headsup-set-label.sh`, then `cd <folder> && claude`.

The bundle ships inside this skill folder: `New Claude Tab.workflow/`. The label step calls `~/.claude/hooks/headsup-set-label.sh`, which writes the same per-session conf that `/headsup-label` manages (`~/.claude/hooks/headsup-status.d/<session-key>.conf` + the `.state/<uuid>.badge` sidecar), so the label survives across hook events exactly like a `/headsup-label` label. Clicking **Skip** (or leaving the field empty) opens the tab with the normal headsup default label.

**This skill is rarely needed** — `setup.sh` step 8 installs the Quick Action on a new machine, and `headsup-update.sh` re-copies it to `~/Library/Services` whenever a pull changed the bundle. Use this skill when something's broken or the user wants a manual (re)install, hotkey change, or removal.

## Install / reinstall

```bash
QA_SRC="$HOME/.claude/skills/headsup-new-tab-shortcut/New Claude Tab.workflow"
QA_DST="$HOME/Library/Services/New Claude Tab.workflow"
mkdir -p "$HOME/Library/Services"
rm -rf "$QA_DST"
cp -R "$QA_SRC" "$QA_DST"
/System/Library/CoreServices/pbs -flush
```

Then bind the hotkey (stored per-machine in pbs prefs, NOT in the bundle — so it must be re-bound on each machine):

```bash
defaults write pbs NSServicesStatus -dict-add '"(null) - New Claude Tab - runWorkflowAsService"' '{ key_equivalent = "@~c"; }'
/System/Library/CoreServices/pbs -flush
killall Finder
```

Key-equivalent cheat sheet: `@` = Command, `~` = Option, `^` = Control, `$` = Shift → `@~c` = ⌘⌥C. If the user wants a different hotkey, swap the `key_equivalent` string accordingly.

Tell the user about first run: macOS will prompt to allow the Service to control iTerm2 → click OK. (If denied later: System Settings → Privacy & Security → Automation.)

## Verify

```bash
ls "$HOME/Library/Services/New Claude Tab.workflow" && defaults read pbs NSServicesStatus 2>/dev/null | grep -A2 "New Claude Tab"
```

GUI check: System Settings → Keyboard → Keyboard Shortcuts → Services → Files & Folders → New Claude Tab.

## Remove

```bash
rm -rf "$HOME/Library/Services/New Claude Tab.workflow"
defaults delete pbs NSServicesStatus 2>/dev/null   # WARNING: clears ALL service hotkeys — only if user confirms
/System/Library/CoreServices/pbs -flush
```

Prefer removing just the bundle and leaving pbs prefs alone (a dangling hotkey entry is harmless); only touch `defaults delete` if the user explicitly wants the prefs cleaned and understands it resets other Services hotkeys too.

## Editing the AppleScript

The script lives in `New Claude Tab.workflow/Contents/document.wflow` under `actions:0:action:ActionParameters:source` (XML-escaped: `&` → `&amp;`). After editing, validate before installing:

```bash
plutil -lint "$QA_SRC/Contents/document.wflow"
/usr/libexec/PlistBuddy -c "Print :actions:0:action:ActionParameters:source" "$QA_SRC/Contents/document.wflow" > /tmp/qa.applescript
osacompile -o /tmp/qa-test.scpt /tmp/qa.applescript
```

Edit the copy in the headsup repo (this folder), commit + push, then reinstall to `~/Library/Services` — never edit the Services copy directly, it gets clobbered on the next update.

## Prerequisites

- iTerm2 installed (the AppleScript targets it by name)
- `claude` on the login-shell PATH
- `~/.claude/hooks/headsup-set-label.sh` present (installed by setup.sh; the workflow degrades gracefully without it — tab still opens, label is just skipped)
