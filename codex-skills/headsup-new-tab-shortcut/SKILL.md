---
name: headsup-new-tab-shortcut
description: Install, update, verify, or remove the New Codex Tab Finder Quick Action.
---

# New Codex Tab Quick Action

The Quick Action bundle is installed by `setup-codex.sh`:

```bash
cd "$(cat ~/.codex/hooks/.headsup-repo)"
./setup-codex.sh
```

It installs `New Codex Tab.workflow` into `~/Library/Services/`.

**Launch mode is configurable.** The workflow reads `NEWTAB_CODEX_ARGS` from `~/.codex/hooks/headsup-status.conf` and appends it to `codex`. Empty (the default) is normal interactive mode; set it to start every shortcut-launched session in a given mode (e.g. `--full-auto`, `--ask-for-approval never`, or `--dangerously-bypass-approvals-and-sandbox`). Set it with `/headsup-config codextabs` (`off` / `full-auto` / `yolo` / `never` / `approval <policy>` / raw args), or by hand.

**Cold start vs warm start.** When iTerm2 is already running, the action opens one new tab. When iTerm2 is not running, `activate` makes it spawn its own launch window asynchronously; the action detects this (System Events process check before activating), waits for that window, and reuses it, so exactly one window opens instead of two.

Verify:

```bash
ls "$HOME/Library/Services/New Codex Tab.workflow"
```

Remove the bundle if requested:

```bash
rm -rf "$HOME/Library/Services/New Codex Tab.workflow"
/System/Library/CoreServices/pbs -flush
```

Do not remove global Services hotkey preferences unless the user explicitly asks.
