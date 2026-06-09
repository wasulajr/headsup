#!/usr/bin/env bash
# iTerm2 status hooks installer for Codex CLI on macOS.
# Idempotent. Re-running is safe.
#
# Usage: setup-codex.sh

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_HOME="${CODEX_SKILLS_HOME:-$HOME/.agents/skills}"
HOOK_DIR="$CODEX_HOME/hooks"
HOOKS_JSON="$CODEX_HOME/hooks.json"
VENV="$HOOK_DIR/iterm2-venv"
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
WATCHDOG_LABEL="codex.headsup-watchdog"
WATCHDOG_PLIST="$LAUNCHAGENTS_DIR/${WATCHDOG_LABEL}.plist"
STATE_ROOT="/tmp/headsup-codex-$(id -u)"

if [ -t 1 ]; then
    R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' B=$'\033[34m' DIM=$'\033[2m' RST=$'\033[0m'
else
    R='' G='' Y='' B='' DIM='' RST=''
fi

ok()     { printf '  %s✓%s %s\n' "$G" "$RST" "$*"; }
note()   { printf '  %s•%s %s\n' "$B" "$RST" "$*"; }
warn()   { printf '  %s!%s %s\n' "$Y" "$RST" "$*"; }
fatal()  { printf '  %s✗%s %s\n' "$R" "$RST" "$*" >&2; exit 1; }
header() { printf '\n%s── %s ──%s\n' "$B" "$*" "$RST"; }

PROBLEMS=0

header "Step 1/7 — checking prerequisites"

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
fi

if command -v codex >/dev/null 2>&1; then
    ok "Codex installed ($(codex --version 2>&1 | tail -1))"
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "\`codex\` not on PATH"
fi

if command -v python3 >/dev/null 2>&1; then
    PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    PYMAJ=$(printf '%s' "$PYV" | cut -d. -f1)
    PYMIN=$(printf '%s' "$PYV" | cut -d. -f2)
    if [ "$PYMAJ" -lt 3 ] || { [ "$PYMAJ" -eq 3 ] && [ "$PYMIN" -lt 9 ]; }; then
        PROBLEMS=$((PROBLEMS + 1))
        warn "Python 3.9+ required (saw $PYV)"
    else
        ok "Python $PYV"
    fi
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "python3 not on PATH"
fi

if command -v jq >/dev/null 2>&1; then
    ok "jq $(jq --version)"
else
    PROBLEMS=$((PROBLEMS + 1))
    warn "jq not on PATH (needed for safe hooks.json merge)"
fi

if command -v swiftc >/dev/null 2>&1; then
    ok "swiftc $(swiftc --version | head -1 | awk '{print $3, $4}')"
else
    warn "swiftc not on PATH (notifier app build will be skipped)"
fi

if [ $PROBLEMS -gt 0 ]; then
    echo
    fatal "$PROBLEMS prerequisite(s) missing — install them and re-run this script."
fi

header "Step 2/7 — Python venv at $VENV"

mkdir -p "$HOOK_DIR"
if [ -d "$VENV" ] && [ -x "$VENV/bin/python" ]; then
    if "$VENV/bin/python" -c 'import iterm2' 2>/dev/null; then
        ok "venv exists and \`import iterm2\` works"
    else
        "$VENV/bin/pip" install -q iterm2 || fatal "pip install iterm2 failed"
        ok "iterm2 installed"
    fi
else
    python3 -m venv "$VENV" || fatal "venv creation failed"
    "$VENV/bin/pip" install -q --upgrade pip
    "$VENV/bin/pip" install -q iterm2 || fatal "pip install iterm2 failed"
    ok "venv ready, iterm2 installed"
fi

header "Step 3/7 — installing Codex hook scripts into $HOOK_DIR"

printf '%s\n' "$SCRIPT_DIR" > "$HOOK_DIR/.headsup-repo"
for name in \
    headsup-codex-status.sh \
    headsup-codex-set-label.sh \
    headsup-codex-resync.sh \
    headsup-codex-status-report.sh \
    headsup-codex-diagnose.sh \
    headsup-codex-notifications.sh \
    headsup-codex-notify-waiting.sh \
    headsup-codex-watchdog.sh \
    headsup-codex-update.sh \
    iterm2-daemon.py \
    iterm2-apply-once.py \
    headsup-status.conf
do
    src="$SCRIPT_DIR/hooks/$name"
    dst="$HOOK_DIR/$name"
    [ -f "$src" ] || fatal "missing source file: $src"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        ok "$name ${DIM}(identical, skipped)${RST}"
    else
        [ -f "$dst" ] && cp "$dst" "$dst.bak"
        cp "$src" "$dst"
        chmod +x "$dst" 2>/dev/null || true
        ok "$name installed"
    fi
done

header "Step 4/7 — installing notifier app and watchdog"

NOTIFIER_DIR="$HOME/Library/Application Support/headsup"
NOTIFIER_BUILD="$SCRIPT_DIR/notifier-app/build-notifier.sh"
if [ -x "$NOTIFIER_BUILD" ] && command -v swiftc >/dev/null 2>&1; then
    mkdir -p "$NOTIFIER_DIR"
    if "$NOTIFIER_BUILD" "$NOTIFIER_DIR" >/dev/null 2>&1; then
        ok "built $NOTIFIER_DIR/headsup-notifier.app"
    else
        warn "notifier build failed — Codex notifications will fall back to osascript"
    fi
else
    warn "notifier build skipped — Codex notifications will fall back to osascript"
fi

WATCHDOG_TEMPLATE="$SCRIPT_DIR/launchagents/${WATCHDOG_LABEL}.plist.template"
mkdir -p "$LAUNCHAGENTS_DIR" "$STATE_ROOT"
if [ -f "$WATCHDOG_TEMPLATE" ]; then
    RENDERED=$(mktemp -t headsup-codex-watchdog.plist.XXXXXX)
    sed "s|__HOME__|$HOME|g; s|__UID__|$(id -u)|g" "$WATCHDOG_TEMPLATE" > "$RENDERED"
    if [ -f "$WATCHDOG_PLIST" ] && cmp -s "$RENDERED" "$WATCHDOG_PLIST"; then
        ok "LaunchAgent plist ${DIM}(identical, skipped)${RST}"
        if launchctl print "gui/$(id -u)/$WATCHDOG_LABEL" >/dev/null 2>&1; then
            ok "LaunchAgent already loaded"
        else
            if launchctl bootstrap "gui/$(id -u)" "$WATCHDOG_PLIST" 2>/dev/null || launchctl load "$WATCHDOG_PLIST" 2>/dev/null; then
                ok "LaunchAgent loaded"
            else
                warn "launchctl load failed for $WATCHDOG_PLIST"
            fi
        fi
    else
        [ -f "$WATCHDOG_PLIST" ] && cp "$WATCHDOG_PLIST" "$WATCHDOG_PLIST.bak"
        cp "$RENDERED" "$WATCHDOG_PLIST"
        ok "LaunchAgent plist installed"
        launchctl bootout "gui/$(id -u)" "$WATCHDOG_PLIST" 2>/dev/null || launchctl unload "$WATCHDOG_PLIST" 2>/dev/null || true
        if launchctl bootstrap "gui/$(id -u)" "$WATCHDOG_PLIST" 2>/dev/null || launchctl load "$WATCHDOG_PLIST" 2>/dev/null; then
            ok "LaunchAgent loaded"
        else
            warn "launchctl load failed for $WATCHDOG_PLIST"
        fi
    fi
    rm -f "$RENDERED"
else
    warn "watchdog template missing at $WATCHDOG_TEMPLATE"
fi

header "Step 5/7 — installing Codex skills into $CODEX_SKILLS_HOME"

mkdir -p "$CODEX_SKILLS_HOME"
for srcdir in "$SCRIPT_DIR/codex-skills/"headsup-*/; do
    [ -d "$srcdir" ] || continue
    name=$(basename "$srcdir")
    dst="$CODEX_SKILLS_HOME/$name"
    if [ -d "$dst" ] && diff -qr "$srcdir" "$dst" >/dev/null 2>&1; then
        ok "$name ${DIM}(identical, skipped)${RST}"
    else
        rm -rf "$dst.bak"
        [ -d "$dst" ] && mv "$dst" "$dst.bak"
        cp -R "$srcdir" "$dst"
        ok "$name installed"
    fi
done

# De-dupe: older versions installed Codex skills into ~/.codex/skills. Codex now
# scans CODEX_SKILLS_HOME (~/.agents/skills), so a stale copy under ~/.codex/skills
# makes every headsup skill show up twice. Remove the legacy headsup-* copies (and
# their .bak) unless that directory is the canonical install location.
LEGACY_SKILLS_DIR="$CODEX_HOME/skills"
if [ "$LEGACY_SKILLS_DIR" != "$CODEX_SKILLS_HOME" ] && [ -d "$LEGACY_SKILLS_DIR" ]; then
    removed=0
    for legacy in "$LEGACY_SKILLS_DIR/"headsup-*; do
        [ -e "$legacy" ] || continue
        rm -rf "$legacy"
        removed=$((removed + 1))
    done
    if [ "$removed" -gt 0 ]; then
        note "removed $removed stale headsup skill(s) from $LEGACY_SKILLS_DIR (legacy duplicate location)"
        rmdir "$LEGACY_SKILLS_DIR" 2>/dev/null && note "removed now-empty $LEGACY_SKILLS_DIR"
    fi
fi

header "Step 6/7 — installing the New Codex Tab Quick Action"

QA_NAME="New Codex Tab.workflow"
QA_SRC="$SCRIPT_DIR/codex-skills/headsup-new-tab-shortcut/$QA_NAME"
QA_DST="$HOME/Library/Services/$QA_NAME"
if [ -d "$QA_SRC" ]; then
    mkdir -p "$HOME/Library/Services"
    if [ -d "$QA_DST" ] && diff -qr "$QA_SRC" "$QA_DST" >/dev/null 2>&1; then
        ok "$QA_NAME ${DIM}(identical, skipped)${RST}"
    else
        rm -rf "$QA_DST"
        cp -R "$QA_SRC" "$QA_DST"
        /System/Library/CoreServices/pbs -flush
        ok "$QA_NAME installed into ~/Library/Services"
    fi
else
    warn "Quick Action bundle missing at $QA_SRC — skipping"
fi

header "Step 7/7 — wiring Codex hooks into $HOOKS_JSON"

HOOK_WIRING=$(cat <<'JSON'
{
  "SessionStart": [
    {
      "matcher": "startup|resume|clear|compact",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" SessionStart", "timeout": 5 }]
    }
  ],
  "UserPromptSubmit": [
    {
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" UserPromptSubmit", "timeout": 5 }]
    }
  ],
  "PreToolUse": [
    {
      "matcher": "*",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" PreToolUse", "timeout": 5 }]
    }
  ],
  "PermissionRequest": [
    {
      "matcher": "*",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" PermissionRequest", "timeout": 5 }]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "*",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" PostToolUse", "timeout": 5 }]
    }
  ],
  "PreCompact": [
    {
      "matcher": "manual|auto",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" PreCompact", "timeout": 5 }]
    }
  ],
  "PostCompact": [
    {
      "matcher": "manual|auto",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" PostCompact", "timeout": 5 }]
    }
  ],
  "SubagentStart": [
    {
      "matcher": "*",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" SubagentStart", "timeout": 5 }]
    }
  ],
  "SubagentStop": [
    {
      "matcher": "*",
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" SubagentStop", "timeout": 5 }]
    }
  ],
  "Stop": [
    {
      "hooks": [{ "type": "command", "command": "\"$HOME/.codex/hooks/headsup-codex-status.sh\" Stop", "timeout": 5 }]
    }
  ]
}
JSON
)

if [ -f "$HOOKS_JSON" ]; then
    if jq -e '.. | strings | select(test("headsup-codex-status.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
        ok "Codex hooks already wired in $HOOKS_JSON"
    else
        cp "$HOOKS_JSON" "$HOOKS_JSON.bak"
        jq --argjson hooks "$HOOK_WIRING" '.hooks = ((.hooks // {}) * $hooks)' "$HOOKS_JSON" > "$HOOKS_JSON.tmp" \
            && mv "$HOOKS_JSON.tmp" "$HOOKS_JSON" \
            && ok "Hooks merged (backup at hooks.json.bak)" \
            || fatal "jq merge failed"
    fi
else
    printf '{\n  "hooks": %s\n}\n' "$HOOK_WIRING" | jq . > "$HOOKS_JSON"
    ok "Created $HOOKS_JSON"
fi

header "Setup complete"
note "Start a new iTerm2 tab and run \`codex\`."
note "If Codex says hooks need review, run /hooks and trust the headsup hook definitions."
note "The tab should turn blue while Codex works and orange when Codex stops or asks for approval."
note "Debug: touch ~/.codex/hooks/.debug and tail /tmp/headsup-codex-\$(id -u)/headsup-status.log"
