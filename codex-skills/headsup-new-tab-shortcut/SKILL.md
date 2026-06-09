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
