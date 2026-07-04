#!/bin/bash
# Set or clear the headsup label for this Codex terminal session.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
CONF_DIR="$HOOK_DIR/headsup-status.d"

TERMINAL_PROVIDER=""
SESSION_KEY=""
UUID=""
if [ -n "${AI_POWER_TERM_SESSION_ID:-}${STEVE_TABS_SESSION_ID:-}" ]; then
    TERMINAL_PROVIDER="ai-power-term"
    UUID="${AI_POWER_TERM_SESSION_ID:-$STEVE_TABS_SESSION_ID}"
    SESSION_KEY=$(printf '%s' "apt-$UUID" | tr -c '[:alnum:]-' '_')
elif [ -n "${ITERM_SESSION_ID:-}" ]; then
    TERMINAL_PROVIDER="iterm"
    SESSION_KEY=$(printf '%s' "$ITERM_SESSION_ID" | tr -c '[:alnum:]-' '_')
    UUID="${ITERM_SESSION_ID##*:}"
fi

if [ -z "$UUID" ]; then
    echo "headsup-codex-set-label: no supported terminal session id found — label skipped" >&2
    exit 0
fi

apply_ai_power_term_rename() {
    local hook_url base_url
    hook_url="${AI_POWER_TERM_HOOK_URL:-${STEVE_TABS_HOOK_URL:-}}"
    if [ -n "$hook_url" ]; then
        base_url="${hook_url%/hook}"
    elif [ -f "$HOME/.ai-power-term/server.json" ]; then
        base_url=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$HOME/.ai-power-term/server.json" 2>/dev/null)
        hook_url="${base_url%/}/hook"
    fi
    if [ -z "$base_url" ]; then
        echo "headsup-codex-set-label: AI Power Term server url not found — live tab title unchanged" >&2
        return 1
    fi
    if [ -z "$hook_url" ]; then
        hook_url="${base_url%/}/hook"
    fi
    python3 - "$hook_url" "$base_url" "$UUID" "$1" <<'PY' 2>/dev/null && return 0
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
    python3 - "$base_url" "$UUID" "$1" <<'PY' 2>/dev/null || {
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
        echo "headsup-codex-set-label: AI Power Term rename failed — live tab title unchanged" >&2
        return 1
    }
    return 0
}

apply_osc() {
    local badge_b64 out pid tty
    if [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
        apply_ai_power_term_rename "$2"
        return $?
    fi
    badge_b64=$(printf '%s' "$1" | base64)
    if [ -t 1 ]; then
        printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$badge_b64" "$2"
        return 0
    fi
    pid=$$
    while [ -n "$pid" ] && [ "$pid" != "1" ]; do
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$tty" ] && [ "$tty" != "??" ] && [ -w "/dev/$tty" ]; then
            out="/dev/$tty"
            printf '\033]1337;SetBadgeFormat=%s\007\033]0;%s\007' "$badge_b64" "$2" > "$out"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo "headsup-codex-set-label: no tty found — label saved, tab updates on the next hook event" >&2
    return 1
}

if [ "${1:-}" = "--clear" ]; then
    headsup_badge_text() { basename "$PWD"; }
    headsup_title_text() { printf 'Codex · %s' "$1"; }
    [ -f "$HOOK_DIR/headsup-status.conf" ] && . "$HOOK_DIR/headsup-status.conf"
    headsup_title_text() { printf 'Codex · %s' "$1"; }
    BADGE=$(headsup_badge_text)
    TITLE=$(headsup_title_text "$BADGE")
    if apply_osc "$BADGE" "$TITLE"; then
        rm -f "$CONF_DIR/${SESSION_KEY}.conf" "$STATE_DIR/${UUID}.badge"
        echo "headsup-codex-set-label: per-session label cleared — reverted to '$TITLE'"
    elif [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
        echo "headsup-codex-set-label: AI Power Term rename failed — saved label kept, live tab title unchanged" >&2
    else
        rm -f "$CONF_DIR/${SESSION_KEY}.conf" "$STATE_DIR/${UUID}.badge"
        echo "headsup-codex-set-label: per-session label cleared, but live terminal title did not update" >&2
    fi
    exit 0
fi

LABEL="$*"
[ -n "$LABEL" ] || exit 0

mkdir -p "$CONF_DIR" "$STATE_DIR"
ESCAPED=$(printf '%s' "$LABEL" | sed "s/'/'\\\\''/g")

if [ "$TERMINAL_PROVIDER" = "ai-power-term" ]; then
    if ! apply_osc "$LABEL" "$LABEL"; then
        echo "headsup-codex-set-label: AI Power Term rename failed — label not saved" >&2
        exit 0
    fi
fi

cat > "$CONF_DIR/${SESSION_KEY}.conf" <<EOF
# Per-terminal-session override for this Codex pane.
# Written by headsup-codex-set-label.sh. Local-only.

headsup_badge_text() { printf '%s' '$ESCAPED'; }
headsup_title_text() { printf '%s' '$ESCAPED'; }
EOF

printf '%s\n' "$LABEL" > "$STATE_DIR/${UUID}.badge"
if [ "$TERMINAL_PROVIDER" != "ai-power-term" ]; then
    if apply_osc "$LABEL" "$LABEL"; then
        echo "headsup-codex-set-label: label set to '$LABEL'"
    else
        echo "headsup-codex-set-label: label saved to '$LABEL', but live terminal title did not update" >&2
    fi
else
    echo "headsup-codex-set-label: label set to '$LABEL'"
fi
