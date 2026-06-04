---
name: headsup-update
description: Pull the latest headsup release from GitHub and apply it in-place. Use when the user types /headsup-update, asks to "update headsup", or wants to pull the newest version of the tab-color/status hooks.
---

# headsup update

Pull the latest headsup from GitHub and apply it in-place. No reinstall needed.

## When to use

- "/headsup-update"
- "update headsup"
- "pull the latest headsup"
- "get the newest headsup version"
- After someone tells you a headsup fix was shipped and they want it

## What to do

Run the update script and let its output speak for itself:

```bash
bash ~/.claude/hooks/headsup-update.sh
```

The script:
1. `git fetch`es to check for changes
2. Shows the changelog (commits being pulled)
3. `git pull`s and applies in-place
4. Kills the iTerm2 daemon if `iterm2-daemon.py` changed — the watchdog respawns it within 30s

If already up to date it says so and exits cleanly. Don't add commentary unless something failed or the user asks.

## If the script is missing

`setup.sh` copies all hook scripts into `~/.claude/hooks/`. Re-run it from the headsup repo to restore any missing files:

```bash
cd /path/to/headsup
./setup.sh
```

## Where files live

- `~/.claude/hooks/headsup-update.sh` — the update script, copied here by `setup.sh`
- Repo: github.com/wasulajr/headsup
