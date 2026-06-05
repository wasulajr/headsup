#!/bin/bash
# headsup-update.sh — Pull the latest headsup from GitHub and apply it.
#
# Usage: headsup-update.sh
# Invoked via the /headsup-update skill or directly from the terminal.

HEADSUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok()   { printf '%s✓%s  %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s⚠%s  %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s✗%s  %s\n' "$RED"    "$RESET" "$*"; }
info() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }

printf '%sheadsup update%s\n' "$BOLD" "$RESET"
printf '%s%s%s\n\n' "$DIM" "$HEADSUP_DIR" "$RESET"

# ── Sanity check ──────────────────────────────────────────────────────────────
if [ ! -d "$HEADSUP_DIR/.git" ]; then
    fail "headsup repo not found at $HEADSUP_DIR"
    exit 1
fi

# ── Fetch ─────────────────────────────────────────────────────────────────────
printf 'Checking for updates...\n'
if ! git -C "$HEADSUP_DIR" fetch origin --quiet 2>/dev/null; then
    fail "git fetch failed — check network or remote"
    exit 1
fi

LOCAL=$(git -C "$HEADSUP_DIR" rev-parse HEAD)
REMOTE=$(git -C "$HEADSUP_DIR" rev-parse origin/main 2>/dev/null)

if [ "$LOCAL" = "$REMOTE" ]; then
    ok "Already up to date — $(git -C "$HEADSUP_DIR" log -1 --format='%h %s')"
    exit 0
fi

# ── Changelog ─────────────────────────────────────────────────────────────────
COUNT=$(git -C "$HEADSUP_DIR" rev-list HEAD..origin/main --count)
printf '\nPulling %d commit%s:\n' "$COUNT" "$([ "$COUNT" -eq 1 ] && echo '' || echo 's')"
while IFS= read -r line; do info "$line"; done < <(git -C "$HEADSUP_DIR" log --oneline HEAD..origin/main)
echo

# ── Note which files are changing before pulling ──────────────────────────────
CHANGED=$(git -C "$HEADSUP_DIR" diff --name-only HEAD origin/main)
DAEMON_CHANGED=$(echo "$CHANGED" | grep -c "iterm2-daemon.py" || true)
QA_CHANGED=$(echo "$CHANGED" | grep -c "headsup-new-tab-shortcut/New Claude Tab.workflow" || true)

# ── Pull ──────────────────────────────────────────────────────────────────────
if ! git -C "$HEADSUP_DIR" pull origin main --quiet; then
    fail "git pull failed"
    exit 1
fi
ok "Updated to $(git -C "$HEADSUP_DIR" log -1 --format='%h %s')"

# ── Restart daemon if its script changed ──────────────────────────────────────
if [ "$DAEMON_CHANGED" -gt 0 ]; then
    DAEMON_PID_FILE="$HOME/.claude/hooks/.state/daemon.pid"
    if [ -f "$DAEMON_PID_FILE" ]; then
        DAEMON_PID=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            kill "$DAEMON_PID" 2>/dev/null
            warn "iterm2-daemon.py changed — killed PID $DAEMON_PID; watchdog will respawn it within 30s"
        fi
    fi
fi

# ── Re-install the New Claude Tab Quick Action if the bundle changed ──────────
# ~/Library/Services must hold a real copy (not a symlink), so a pull that
# touches the bundle needs an explicit re-copy. Only re-installs if the
# Quick Action was already installed — first-time install is setup.sh's job.
QA_SRC="$HEADSUP_DIR/skills/headsup-new-tab-shortcut/New Claude Tab.workflow"
QA_DST="$HOME/Library/Services/New Claude Tab.workflow"
if [ "$QA_CHANGED" -gt 0 ] && [ -d "$QA_DST" ] && [ -d "$QA_SRC" ]; then
    rm -rf "$QA_DST"
    cp -R "$QA_SRC" "$QA_DST"
    /System/Library/CoreServices/pbs -flush
    ok "New Claude Tab Quick Action re-installed into ~/Library/Services"
fi

echo
ok "Done"
