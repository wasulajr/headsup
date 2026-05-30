#!/usr/bin/env bash
# iTerm2 status hooks + skills installer for Claude Code on macOS.
# Idempotent. Re-running is safe — existing files are diffed and skipped if
# identical, or you're prompted before any overwrite.
#
# Usage: setup.sh [--no-pull]
#   By default setup.sh pulls the latest from GitHub before running so you
#   always install the current version. Pass --no-pull to skip the pull.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
VENV="$CLAUDE_DIR/hooks/iterm2-venv"
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
WATCHDOG_LABEL="claude-code.headsup-watchdog"
WATCHDOG_PLIST="$LAUNCHAGENTS_DIR/${WATCHDOG_LABEL}.plist"

if [ -t 1 ]; then
    R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' B=$'\033[34m' DIM=$'\033[2m' RST=$'\033[0m'
else
    R='' G='' Y='' B='' DIM='' RST=''
fi

ok()      { printf '  %s✓%s %s\n' "$G" "$RST" "$*"; }
note()    { printf '  %s•%s %s\n' "$B" "$RST" "$*"; }
warn()    { printf '  %s!%s %s\n' "$Y" "$RST" "$*"; }
fatal()   { printf '  %s✗%s %s\n' "$R" "$RST" "$*" >&2; exit 1; }
header()  { printf '\n%s── %s ──%s\n' "$B" "$*" "$RST"; }
confirm() {
    local prompt="$1" default="${2:-n}"
    local hint='[y/N]'
    [ "$default" = "y" ] && hint='[Y/n]'
    local a
    read -rp "  $prompt $hint " a
    a="${a:-$default}"
    [[ "$a" =~ ^[Yy]$ ]]
}

# ── Argument parsing ─────────────────────────────────────────────────────────
PULL=1
for _arg in "$@"; do
    case "$_arg" in
        --no-pull) PULL=0 ;;
        --pull)    PULL=1 ;;
    esac
done

# ── 0. Pull latest from GitHub ───────────────────────────────────────────────
# Runs before the numbered steps so setup always installs the current version.
# After a successful pull the script re-execs itself (--no-pull) so the rest
# of the install runs with the freshly downloaded code.
if [ "$PULL" = "1" ] && [ -d "$SCRIPT_DIR/.git" ]; then
    header "Updating headsup from GitHub"
    if git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null; then
        _local=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
        _remote=$(git -C "$SCRIPT_DIR" rev-parse origin/main 2>/dev/null)
        if [ "$_local" = "$_remote" ]; then
            ok "Already up to date — $(git -C "$SCRIPT_DIR" log -1 --format='%h %s')"
        else
            _count=$(git -C "$SCRIPT_DIR" rev-list HEAD..origin/main --count)
            note "Pulling $_count commit(s)..."
            if git -C "$SCRIPT_DIR" pull origin main --quiet; then
                ok "Updated to $(git -C "$SCRIPT_DIR" log -1 --format='%h %s')"
                exec "$SCRIPT_DIR/setup.sh" --no-pull
            else
                warn "git pull failed — continuing with current version"
            fi
        fi
    else
        warn "Could not reach GitHub — continuing with current version"
    fi
fi

PROBLEMS=0

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
header "Step 1/8 — checking prerequisites"

if [ "$(uname -s)" != "Darwin" ]; then
    fatal "macOS only (saw $(uname -s))."
fi
ok "macOS $(sw_vers -productVersion)"

if [ -d "/Applications/iTerm.app" ] || mdfind -name "iTerm.app" 2>/dev/null | grep -q .; then
    ok "iTerm2 installed"
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "iTerm2 not found at /Applications/iTerm.app"
    note "  install:  brew install --cask iterm2"
    note "  or download from https://iterm2.com/"
fi

if command -v claude >/dev/null 2>&1; then
    ok "Claude Code installed ($(claude --version 2>&1 | head -1))"
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "\`claude\` not on PATH"
    note "  install instructions: https://claude.com/claude-code"
fi

if command -v python3 >/dev/null 2>&1; then
    PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    PYMAJ=$(printf '%s' "$PYV" | cut -d. -f1)
    PYMIN=$(printf '%s' "$PYV" | cut -d. -f2)
    if [ "$PYMAJ" -lt 3 ] || { [ "$PYMAJ" -eq 3 ] && [ "$PYMIN" -lt 9 ]; }; then
        PROBLEMS=$((PROBLEMS + 1))
        warn "Python 3.9+ required (saw $PYV)"
        note "  install:  brew install python@3.12"
    else
        ok "Python $PYV"
    fi
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "python3 not on PATH"
    note "  install:  brew install python@3.12"
fi

if command -v jq >/dev/null 2>&1; then
    ok "jq $(jq --version)"
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "jq not on PATH (needed for safe settings.json merge)"
    note "  install:  brew install jq"
fi

# swiftc compiles the bundled notifier (so wait-notifications can show
# headsup's own icon instead of Script Editor's). Ships with Xcode
# Command Line Tools.
if command -v swiftc >/dev/null 2>&1; then
    ok "swiftc $(swiftc --version | head -1 | awk '{print $3, $4}')"
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "swiftc not on PATH (needed to compile the notifier binary)"
    note "  install:  xcode-select --install"
fi

if [ $PROBLEMS -gt 0 ]; then
    echo
    fatal "$PROBLEMS prerequisite(s) missing — install them and re-run this script."
fi

# ── 2. iTerm2 Python API ─────────────────────────────────────────────────────
header "Step 2/8 — iTerm2 Python API"

API_ENABLED=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || echo "")
if [ "$API_ENABLED" = "1" ]; then
    ok "iTerm2 Python API already enabled"
else
    warn "iTerm2 Python API not enabled"
    note "The daemon needs this to talk to iTerm2 over its websocket."
    if confirm "Enable it now via 'defaults write'?" y; then
        defaults write com.googlecode.iterm2 EnableAPIServer -bool true
        ok "Wrote EnableAPIServer=true"
        warn "iTerm2 needs to be restarted (or the Settings → General → Magic → Python API toggle flipped) for this to take effect."
    else
        warn "Skipping. Enable manually: iTerm2 → Settings → General → Magic → Python API"
    fi
fi

# ── 3. Python venv with iterm2 package ───────────────────────────────────────
header "Step 3/8 — Python venv at $VENV"

if [ -d "$VENV" ] && [ -x "$VENV/bin/python" ]; then
    if "$VENV/bin/python" -c 'import iterm2' 2>/dev/null; then
        ok "venv exists and \`import iterm2\` works"
    else
        warn "venv exists but iterm2 package not importable"
        if confirm "Install iterm2 into the existing venv?" y; then
            "$VENV/bin/pip" install -q iterm2 || fatal "pip install iterm2 failed"
            ok "iterm2 installed"
        fi
    fi
else
    mkdir -p "$CLAUDE_DIR/hooks"
    note "Creating venv with python3"
    python3 -m venv "$VENV" || fatal "venv creation failed"
    "$VENV/bin/pip" install -q --upgrade pip
    "$VENV/bin/pip" install -q iterm2 || fatal "pip install iterm2 failed"
    ok "venv ready, iterm2 installed"
fi

# ── 4. Install hook scripts ──────────────────────────────────────────────────
header "Step 4/8 — installing hook scripts into $CLAUDE_DIR/hooks/"

mkdir -p "$CLAUDE_DIR/hooks"
installed=0; skipped=0; overwrote=0
for src in "$SCRIPT_DIR/hooks/"*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$CLAUDE_DIR/hooks/$name"
    if [ -L "$dst" ]; then
        # Symlink target — likely the repo-is-my-config setup. Leave alone.
        ok "$name ${DIM}(symlink, leaving as-is)${RST}"
        skipped=$((skipped+1)); continue
    fi
    if [ -f "$dst" ]; then
        if cmp -s "$src" "$dst"; then
            ok "$name ${DIM}(identical, skipped)${RST}"
            skipped=$((skipped+1)); continue
        fi
        warn "$name exists at $dst and differs"
        if confirm "Overwrite (backup at $dst.bak)?"; then
            cp "$dst" "$dst.bak"
            cp "$src" "$dst"
            chmod +x "$dst" 2>/dev/null || true
            ok "$name installed ${DIM}(backup at $name.bak)${RST}"
            overwrote=$((overwrote+1))
        else
            warn "$name skipped at user request"
            skipped=$((skipped+1))
        fi
    else
        cp "$src" "$dst"
        chmod +x "$dst" 2>/dev/null || true
        ok "$name installed"
        installed=$((installed+1))
    fi
done
note "${installed} installed, ${overwrote} overwritten, ${skipped} skipped"

# ── 5. Build & install the notifier .app bundle ──────────────────────────────
header "Step 5/8 — building notifier .app for custom notification icon"

# The notifier is a tiny Swift binary inside a .app bundle. We compile
# it from source at install time so the bundle's icon resource is OURS
# (notifications show the headsup icon instead of Script Editor's).
# Build script handles compile + ad-hoc codesign + lsregister.

NOTIFIER_DIR="$HOME/Library/Application Support/headsup"
NOTIFIER_BUILD="$SCRIPT_DIR/notifier-app/build-notifier.sh"

if [ ! -x "$NOTIFIER_BUILD" ]; then
    warn "notifier build script missing at $NOTIFIER_BUILD — wait-notifications will fall back to osascript (Script Editor icon)"
else
    mkdir -p "$NOTIFIER_DIR"
    if "$NOTIFIER_BUILD" "$NOTIFIER_DIR" >/dev/null 2>&1; then
        ok "built $NOTIFIER_DIR/headsup-notifier.app"
        if [ -f "$SCRIPT_DIR/notifier-app/AppIcon.icns" ]; then
            ok "  icon bundled"
        else
            note "  ${DIM}no icon yet — drop a 1024×1024 PNG at notifier-app/icon-source.png, run ./notifier-app/build-icon.sh, then re-run this setup script${RST}"
        fi
        note "  ${DIM}first wait-notification will trigger a one-time macOS permission prompt (\"headsup wants to send notifications\")${RST}"
    else
        warn "notifier build failed — wait-notifications will fall back to osascript"
    fi
fi

# ── 6. Install headsup-watchdog LaunchAgent ────────────────────────────────────
header "Step 6/8 — installing LaunchAgent at $WATCHDOG_PLIST"

# The watchdog is the outermost safety net for the headsup hook stack —
# launchd fires it every 30s, completely independent of Claude Code. On
# the healthy path it's dirt cheap (a few stats); when the daemon is
# down it respawns it and fires Tier 2 per-session.
#
# Template lives in headsup/launchagents/. We substitute __HOME__ →
# $HOME at install time so the same template works for any user.

WATCHDOG_TEMPLATE="$SCRIPT_DIR/launchagents/${WATCHDOG_LABEL}.plist.template"
if [ ! -f "$WATCHDOG_TEMPLATE" ]; then
    warn "watchdog template missing at $WATCHDOG_TEMPLATE — skipping LaunchAgent install"
elif [ ! -f "$CLAUDE_DIR/hooks/headsup-watchdog.sh" ]; then
    # Step 4 should have placed this. If it didn't, the watchdog has nothing
    # to call, so installing the LaunchAgent would just produce errors.
    warn "headsup-watchdog.sh missing in $CLAUDE_DIR/hooks/ — skipping LaunchAgent install"
else
    mkdir -p "$LAUNCHAGENTS_DIR"
    RENDERED=$(mktemp -t headsup-watchdog.plist.XXXXXX)
    # macOS sed: use a literal-pipe delimiter so the homedir slashes don't
    # need escaping. __HOME__ → $HOME substitution.
    sed "s|__HOME__|$HOME|g" "$WATCHDOG_TEMPLATE" > "$RENDERED"

    install_watchdog=0
    reload_watchdog=0
    if [ -f "$WATCHDOG_PLIST" ]; then
        if cmp -s "$RENDERED" "$WATCHDOG_PLIST"; then
            ok "LaunchAgent plist ${DIM}(identical, skipped)${RST}"
        else
            warn "LaunchAgent plist exists at $WATCHDOG_PLIST and differs"
            if confirm "Overwrite (backup at $WATCHDOG_PLIST.bak)?" y; then
                cp "$WATCHDOG_PLIST" "$WATCHDOG_PLIST.bak"
                install_watchdog=1
                reload_watchdog=1
            else
                warn "LaunchAgent plist skipped at user request"
            fi
        fi
    else
        install_watchdog=1
        reload_watchdog=1
    fi

    if [ "$install_watchdog" = "1" ]; then
        cp "$RENDERED" "$WATCHDOG_PLIST"
        ok "LaunchAgent plist installed"
    fi
    rm -f "$RENDERED"

    # Load (or reload) into launchd. Idempotent: unload first to drop any
    # previous registration, then load the fresh plist. Errors from
    # unload-when-not-loaded are expected on first install and harmless.
    if [ "$reload_watchdog" = "1" ]; then
        launchctl unload "$WATCHDOG_PLIST" 2>/dev/null || true
        if launchctl load "$WATCHDOG_PLIST" 2>/dev/null; then
            ok "LaunchAgent loaded (\`launchctl list | grep ${WATCHDOG_LABEL}\`)"
        else
            warn "launchctl load failed for $WATCHDOG_PLIST"
            note "  retry manually:  launchctl load $WATCHDOG_PLIST"
        fi
    elif launchctl list "$WATCHDOG_LABEL" >/dev/null 2>&1; then
        ok "LaunchAgent already loaded"
    else
        # Plist on disk but not loaded — load it.
        if launchctl load "$WATCHDOG_PLIST" 2>/dev/null; then
            ok "LaunchAgent loaded"
        else
            warn "launchctl load failed for $WATCHDOG_PLIST"
        fi
    fi
fi

# ── 6. Install skills ────────────────────────────────────────────────────────
header "Step 7/8 — installing skills into $CLAUDE_DIR/skills/"

mkdir -p "$CLAUDE_DIR/skills"
sinstalled=0; sskipped=0; soverwrote=0
for srcdir in "$SCRIPT_DIR/skills/"headsup-*/; do
    [ -d "$srcdir" ] || continue
    name=$(basename "$srcdir")
    dst="$CLAUDE_DIR/skills/$name"
    if [ -L "$dst" ]; then
        ok "$name ${DIM}(symlink, leaving as-is)${RST}"
        sskipped=$((sskipped+1)); continue
    fi
    if [ -d "$dst" ]; then
        if diff -qr "$srcdir" "$dst" >/dev/null 2>&1; then
            ok "$name ${DIM}(identical, skipped)${RST}"
            sskipped=$((sskipped+1)); continue
        fi
        warn "$name exists at $dst and differs"
        if confirm "Overwrite (backup at $dst.bak)?"; then
            rm -rf "$dst.bak"
            mv "$dst" "$dst.bak"
            cp -r "$srcdir" "$dst"
            ok "$name installed ${DIM}(backup at $name.bak)${RST}"
            soverwrote=$((soverwrote+1))
        else
            warn "$name skipped at user request"
            sskipped=$((sskipped+1))
        fi
    else
        cp -r "$srcdir" "$dst"
        ok "$name installed"
        sinstalled=$((sinstalled+1))
    fi
done
note "${sinstalled} installed, ${soverwrote} overwritten, ${sskipped} skipped"

# ── 7. Wire hooks into settings.json ─────────────────────────────────────────
header "Step 8/8 — wiring hooks into $SETTINGS"

# The JSON shape Claude Code expects. Six events; all are load-bearing
# (see README.md → "How it works" for why).
HOOK_WIRING=$(cat <<'JSON'
{
  "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" SessionStart" }] }],
  "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" Notification" }] }],
  "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" Stop" }] }],
  "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" UserPromptSubmit" }] }],
  "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" PreToolUse" }] }],
  "PostToolUse":      [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$HOME/.claude/hooks/headsup-status.sh\" PostToolUse" }] }]
}
JSON
)

if [ -f "$SETTINGS" ]; then
    # Check if our hooks are already wired
    if jq -e '.hooks.SessionStart[0].hooks[0].command' "$SETTINGS" 2>/dev/null | grep -q "headsup-status.sh"; then
        ok "Hooks already wired in $SETTINGS"
    else
        warn "$SETTINGS exists; need to add hook wiring"
        if confirm "Merge wiring in (backup at $SETTINGS.bak)?" y; then
            cp "$SETTINGS" "$SETTINGS.bak"
            jq --argjson hooks "$HOOK_WIRING" '.hooks = ((.hooks // {}) * $hooks)' "$SETTINGS" > "$SETTINGS.tmp" \
                && mv "$SETTINGS.tmp" "$SETTINGS" \
                && ok "Hooks merged (backup at settings.json.bak)" \
                || fatal "jq merge failed"
        else
            warn "Hooks NOT wired. The status system won't activate until you wire them yourself. See README.md."
        fi
    fi
else
    note "Creating $SETTINGS with the hook wiring"
    printf '{\n  "hooks": %s\n}\n' "$HOOK_WIRING" | jq . > "$SETTINGS"
    ok "Created"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
header "Setup complete"
note "Next steps:"
note "  1. If iTerm2's Python API was just enabled, restart iTerm2 (or toggle the"
note "     checkbox in Settings → General → Magic → Python API)."
note "  2. Open a new iTerm2 tab and run \`claude\`. The first hook event will"
note "     trigger an iTerm2 permission dialog — click \"Always Allow\"."
note "  3. Type any prompt. The tab should turn blue while Claude works, then"
note "     orange when it's waiting for you."
echo
note "Customize from any Claude Code session:"
note "  /headsup-colors         change the global color palette"
note "  /headsup-label          set this tab's title + badge"
note "  /headsup-resync-tab     force-resync a drifted tab"
note "  /headsup-status         passive health snapshot (daemon, sessions, tokens)"
note "  /headsup-diagnose       active end-to-end test (flashes tab colors)"
note "  /headsup-notifications  toggle / threshold the 'Claude is waiting' macOS notification"
note "  /headsup-update         pull the latest headsup from GitHub (or re-run setup.sh)"
echo
note "If something's off:"
note "  touch ~/.claude/hooks/.debug      enable per-event logging"
note "  touch ~/.claude/hooks/.disabled   kill switch (no-op all events)"
note "  see README.md → Troubleshooting"
