#!/bin/bash
# headsup-set-label.sh — set or clear the headsup per-session label from
# inside the target terminal session.
#
# Usage: headsup-set-label.sh <label...>
#        headsup-set-label.sh --clear
#
# Two callers:
#   1. The "New Claude Tab" Finder Quick Action runs it in a fresh tab
#      before `claude` launches (stdout IS the tty there).
#   2. The /headsup-label skill runs it from inside a Claude Code session,
#      where stdout is a pipe — so we walk up the process tree to find the
#      real tty and write the OSC escapes there instead. Keeping the whole
#      flow inside this one script means a single permission allowlist rule
#      (Bash(~/.claude/hooks/headsup-set-label.sh:*)) covers every label
#      change with no prompt.
#
# Writes the same per-session override that /headsup-label manages:
#   ~/.claude/hooks/headsup-status.d/<session-key>.conf  (sourced by headsup-status.sh)
#   ~/.claude/hooks/.state/<terminal-id>.badge           (read by the waiting notifier)
#
# Always exits 0 so callers can safely chain `... && claude`.

TERMINAL_PROVIDER=""
TERMINAL_SESSION_KEY=""
TERMINAL_ID=""
# AI Power Term is checked first: its sessions can inherit a stale
# ITERM_SESSION_ID from the shell that launched the app server, but
# AI_POWER_TERM_SESSION_ID is only ever set by the app itself.
if [ -n "${AI_POWER_TERM_SESSION_ID:-}${STEVE_TABS_SESSION_ID:-}" ]; then
    TERMINAL_PROVIDER="ai-power-term"
    TERMINAL_ID="${AI_POWER_TERM_SESSION_ID:-$STEVE_TABS_SESSION_ID}"
    TERMINAL_SESSION_KEY=$(printf '%s' "apt-$TERMINAL_ID" | tr -c '[:alnum:]-' '_')
elif [ -n "${ITERM_SESSION_ID:-}" ]; then
    TERMINAL_PROVIDER="iterm"
    TERMINAL_SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
    TERMINAL_ID="${ITERM_SESSION_ID##*:}"
elif [ -n "${WEZTERM_PANE:-}" ]; then
    TERMINAL_PROVIDER="wezterm"
    TERMINAL_ID="wezterm-${WEZTERM_PANE}"
    TERMINAL_SESSION_KEY=$(printf '%s' "$TERMINAL_ID" | tr -c '[:alnum:]-' '_')
fi

if [ -z "$TERMINAL_ID" ]; then
    echo "headsup-set-label: no supported terminal session id found — label skipped" >&2
    exit 0
fi

CONF_DIR="$HOME/.claude/hooks/headsup-status.d"
STATE_DIR="$HOME/.claude/hooks/.state"

# AI Power Term has no OSC title path (its xterm.js frontend does not listen
# for title changes); the tab title lives in the app server's session state,
# exposed only as the websocket "rename" action. Derive the server URL from
# the hook URL the app injects (same convention as the app's status.sh hook).
apply_ai_power_term_rename() {  # $1 = title text
    local hook_url base_url
    hook_url="${AI_POWER_TERM_HOOK_URL:-${STEVE_TABS_HOOK_URL:-}}"
    if [ -n "$hook_url" ]; then
        base_url="${hook_url%/hook}"
    elif [ -f "$HOME/.ai-power-term/server.json" ]; then
        base_url=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$HOME/.ai-power-term/server.json" 2>/dev/null)
        hook_url="${base_url%/}/hook"
    fi
    if [ -z "$base_url" ]; then
        echo "headsup-set-label: AI Power Term server url not found — live tab title unchanged" >&2
        return 1
    fi
    if [ -z "$hook_url" ]; then
        hook_url="${base_url%/}/hook"
    fi
    python3 - "$hook_url" "$base_url" "$TERMINAL_ID" "$1" <<'PY' 2>/dev/null && return 0
import base64, json, os, socket, struct, sys
from urllib.parse import urlparse
from urllib import request

hook_url, base_url, session_id, title = sys.argv[1:5]
payload = json.dumps({"session_id": session_id, "title": title}).encode()
req = request.Request(hook_url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
with request.urlopen(req, timeout=2) as response:
    if response.status >= 400:
        raise SystemExit(1)

def read_frame(sock):
    header = sock.recv(2)
    if len(header) < 2:
        return None
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", sock.recv(8))[0]
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            return None
        data += chunk
    return data

parsed = urlparse(base_url)
sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=2)
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((
    f"GET /ws HTTP/1.1\r\nHost: {parsed.netloc}\r\n"
    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
).encode())
if b"101" not in sock.recv(4096).split(b"\r\n", 1)[0]:
    raise SystemExit(1)
frame = read_frame(sock)
sock.close()
if not frame:
    raise SystemExit(1)
hello = json.loads(frame)
for session in hello.get("sessions", []):
    if session.get("id") == session_id and session.get("title") == title:
        raise SystemExit(0)
raise SystemExit(1)
PY
    python3 - "$base_url" "$TERMINAL_ID" "$1" <<'PY' 2>/dev/null || {
import base64, json, os, socket, struct, sys
from urllib.parse import urlparse

base_url, session_id, title = sys.argv[1:4]
parsed = urlparse(base_url)
s = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=2)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((
    f"GET /ws HTTP/1.1\r\nHost: {parsed.netloc}\r\n"
    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
).encode())
if b"101" not in s.recv(4096).split(b"\r\n", 1)[0]:
    sys.exit(1)
def read_frame(sock):
    header = sock.recv(2)
    if len(header) < 2:
        return None
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", sock.recv(8))[0]
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            return None
        data += chunk
    return data

read_frame(s)
payload = json.dumps({"action": "rename", "id": session_id, "title": title}).encode()
mask = os.urandom(4)
masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
if len(payload) < 126:
    header = bytes([0x81, 0x80 | len(payload)])
else:
    header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(payload))
s.sendall(header + mask + masked)
try:
    s.settimeout(1)
    while True:
        frame = read_frame(s)
        if not frame:
            break
        message = json.loads(frame)
        session = message.get("session") or {}
        if session.get("id") == session_id and session.get("title") == title:
            s.close()
            sys.exit(0)
except Exception:
    pass
s.close()
sys.exit(1)
PY
        echo "headsup-set-label: AI Power Term rename failed — live tab title unchanged" >&2
        return 1
    }
    return 0
}

# Apply label OSC escapes. If stdout is the tty (Quick Action path) write
# straight to it; otherwise (Claude Code Bash tool — stdout is a pipe) walk
# up the process tree until an ancestor has a real tty.
apply_osc() {  # $1 = badge text, $2 = title text
    local label_b64 payload out pid tty
    if [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
        apply_ai_power_term_rename "$2"
        return $?
    fi
    label_b64=$(printf '%s' "$1" | base64 | tr -d '\n')
    if [ "$TERMINAL_PROVIDER" = "iterm" ]; then
        payload=$(printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$label_b64" "$2")
    else
        payload=$(printf '\033]0;%s\007\033]1337;SetUserVar=headsup_label=%s\007' "$2" "$label_b64")
    fi
    if [ -t 1 ]; then
        printf '%s' "$payload"
        return 0
    fi
    pid=$$
    while [ -n "$pid" ] && [ "$pid" != "1" ]; do
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$tty" ] && [ "$tty" != "??" ] && [ -w "/dev/$tty" ]; then
            out="/dev/$tty"
            printf '%s' "$payload" > "$out"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo "headsup-set-label: no tty found — label saved, tab updates on the next hook event" >&2
    return 1
}

# ── --clear: remove the override and revert to the global default ───────────
if [ "$1" = "--clear" ]; then
    # Recompute the default badge/title from the global conf and re-apply,
    # mirroring the fallbacks in headsup-status.sh.
    headsup_badge_text() { basename "$PWD"; }
    headsup_title_text() { printf 'Claude · %s' "$1"; }
    [ -f "$HOME/.claude/hooks/headsup-status.conf" ] && . "$HOME/.claude/hooks/headsup-status.conf"
    BADGE=$(headsup_badge_text)
    TITLE=$(headsup_title_text "$BADGE")
    if apply_osc "$BADGE" "$TITLE"; then
        rm -f "$CONF_DIR/${TERMINAL_SESSION_KEY}.conf" "$STATE_DIR/${TERMINAL_ID}.badge"
        echo "headsup-set-label: per-session label cleared — reverted to '$TITLE'"
    elif [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
        echo "headsup-set-label: AI Power Term rename failed — saved label kept, live tab title unchanged" >&2
    else
        rm -f "$CONF_DIR/${TERMINAL_SESSION_KEY}.conf" "$STATE_DIR/${TERMINAL_ID}.badge"
        echo "headsup-set-label: per-session label cleared, but live terminal title did not update" >&2
    fi
    exit 0
fi

LABEL="$*"
[ -n "$LABEL" ] || exit 0

mkdir -p "$CONF_DIR" "$STATE_DIR"

# Single-quote the label inside the conf, escaping embedded single quotes,
# so special characters round-trip through the sourced file untouched.
ESCAPED=$(printf '%s' "$LABEL" | sed "s/'/'\\\\''/g")

if [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
    if ! apply_osc "$LABEL" "$LABEL"; then
        echo "headsup-set-label: AI Power Term rename failed — label not saved" >&2
        exit 0
    fi
fi

cat > "$CONF_DIR/${TERMINAL_SESSION_KEY}.conf" <<EOF
# Per-terminal-session override for this pane.
# Written by headsup-set-label.sh. Local-only — headsup-status.d/ is gitignored.
# Terminal session ids change across terminal restarts, so this becomes stale.

headsup_badge_text() { printf '%s' '$ESCAPED'; }
headsup_title_text() { printf '%s' '$ESCAPED'; }
EOF

# Badge sidecar so the waiting-notification script picks up the label
# without waiting for the next hook event.
printf '%s\n' "$LABEL" > "$STATE_DIR/${TERMINAL_ID}.badge"

if [ "$TERMINAL_PROVIDER" != "ai-power-term" ]; then
    if apply_osc "$LABEL" "$LABEL"; then
        echo "headsup-set-label: label set to '$LABEL'"
    else
        echo "headsup-set-label: label saved to '$LABEL', but live terminal title did not update" >&2
    fi
else
    echo "headsup-set-label: label set to '$LABEL'"
fi

exit 0
