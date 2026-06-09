#!/bin/bash
# Active end-to-end test for headsup Codex.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
LOG_FILE="$HOOK_DIR/headsup-status.log"
DEBUG_FLAG="$HOOK_DIR/.debug"
WATCHDOG_LABEL="codex.headsup-watchdog"
VENV_PYTHON="$HOOK_DIR/iterm2-venv/bin/python"
DAEMON_SCRIPT="$HOOK_DIR/iterm2-daemon.py"
RESYNC="$HOOK_DIR/headsup-codex-resync.sh"

INCLUDE_DAEMON_RESTART=0
QUIET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --restart) INCLUDE_DAEMON_RESTART=1 ;;
        --quiet) QUIET=1 ;;
        -h|--help) echo "Usage: $0 [--restart] [--quiet]"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ] && [ "$QUIET" = "0" ]; then
    G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' B=$'\033[34m' DIM=$'\033[2m' RST=$'\033[0m'
else
    G='' Y='' R='' B='' DIM='' RST=''
fi

PASSES=0; FAILS=0
step() { [ "$QUIET" = "0" ] && printf '\n%s── %s ──%s\n' "$B" "$*" "$RST"; }
pass() { PASSES=$((PASSES+1)); [ "$QUIET" = "0" ] && printf '  %s✓%s %s\n' "$G" "$RST" "$*"; }
fail() { FAILS=$((FAILS+1)); printf '  %s✗%s %s\n' "$R" "$RST" "$*"; }
warn() { [ "$QUIET" = "0" ] && printf '  %s!%s %s\n' "$Y" "$RST" "$*"; }
dim()  { [ "$QUIET" = "0" ] && printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }

walk_ppid_for_iterm_session() {
    local pid="$PPID" candidate
    for _ in 1 2 3 4 5 6; do
        [ -z "$pid" ] && break; [ "$pid" = "0" ] && break; [ "$pid" = "1" ] && break
        candidate=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | head -1 | cut -d= -f2-)
        [ -n "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")
    done
    return 1
}

if [ -z "${ITERM_SESSION_ID:-}" ]; then
    ITERM_SESSION_ID=$(walk_ppid_for_iterm_session) || ITERM_SESSION_ID=""
fi
UUID="${ITERM_SESSION_ID#*:}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
DEBUG_PRE_EXISTING=0
[ -f "$DEBUG_FLAG" ] && DEBUG_PRE_EXISTING=1 || : > "$DEBUG_FLAG" 2>/dev/null || true

cleanup() {
    if [ -n "$UUID" ] && [ -n "${ORIG_STATE:-}" ]; then
        orig_color=$(printf '%s' "$ORIG_STATE" | awk '{print $1}')
        orig_attn=$(printf '%s' "$ORIG_STATE" | awk '{print $2}')
        [ -z "$orig_attn" ] && orig_attn=no
        [ -x "$RESYNC" ] && [ -n "$orig_color" ] && "$RESYNC" "$UUID" "$orig_color" "$orig_attn" >/dev/null 2>&1 || true
    fi
    [ "$DEBUG_PRE_EXISTING" = "0" ] && rm -f "$DEBUG_FLAG" 2>/dev/null
}
trap cleanup EXIT

step "Step 1: prereqs"
[ -x "$VENV_PYTHON" ] && pass "venv python at $VENV_PYTHON" || fail "venv python missing"
[ -f "$DAEMON_SCRIPT" ] && pass "daemon script at $DAEMON_SCRIPT" || fail "daemon script missing"
[ -x "$RESYNC" ] && pass "resync script at $RESYNC" || fail "resync script missing"
[ -n "$UUID" ] && pass "resolved ITERM_SESSION_ID uuid=${UUID:0:8}" || fail "could not resolve ITERM_SESSION_ID"

step "Step 2: daemon health"
if [ -f "$PID_FILE" ]; then
    dpid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null && pass "daemon alive (pid $dpid)" || warn "daemon not alive"
else
    warn "no PID file — daemon not currently running"
fi
if [ -f "$HEARTBEAT_FILE" ]; then
    hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1)
    hb_status=$(printf '%s' "$hb" | awk '{print $2}')
    [ -z "$hb_status" ] && hb_status="OK"
    [ "$hb_status" = "OK" ] && pass "heartbeat status=OK" || warn "heartbeat status=$hb_status"
else
    warn "no heartbeat file"
fi

step "Step 3: launchd watchdog"
launchctl print "gui/$(id -u)/$WATCHDOG_LABEL" >/dev/null 2>&1 && pass "$WATCHDOG_LABEL loaded" || warn "$WATCHDOG_LABEL not loaded"

ORIG_STATE=""
[ -n "$UUID" ] && [ -f "$STATE_DIR/${UUID}.state" ] && ORIG_STATE=$(cat "$STATE_DIR/${UUID}.state" 2>/dev/null | head -1)
[ -n "$ORIG_STATE" ] && dim "saved original state: $ORIG_STATE"

verify_apply() {
    local color="$1" attention="$2" deadline matched
    deadline=$(( $(date +%s) + 2 ))
    matched=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if tail -80 "$LOG_FILE" 2>/dev/null | grep -q "daemon applied uuid=$UUID color=$color attn=$attention"; then
            matched=1; break
        fi
        sleep 0.1
    done
    [ "$matched" = "1" ]
}

if [ -n "$UUID" ] && [ -x "$RESYNC" ]; then
    IDLE_COLOR="ffffff"; PROCESS_COLOR="3a82f5"; WAIT_COLOR="e67e22"
    [ -f "$HOOK_DIR/headsup-status.conf" ] && source "$HOOK_DIR/headsup-status.conf" 2>/dev/null || true
    for test_pair in "IDLE:$IDLE_COLOR:no" "PROCESS:$PROCESS_COLOR:no" "WAIT:$WAIT_COLOR:yes"; do
        label="${test_pair%%:*}"
        rest="${test_pair#*:}"
        color="${rest%%:*}"
        attn="${rest#*:}"
        step "Color test: $label color=$color attn=$attn"
        if ! "$RESYNC" "$UUID" "$color" "$attn" >/dev/null 2>&1; then
            fail "resync returned non-zero for $label"; continue
        fi
        written=$(cat "$STATE_DIR/${UUID}.state" 2>/dev/null | head -1)
        [ "$written" = "$color $attn" ] && pass "state file written ($written)" || fail "state file mismatch: wanted '$color $attn', got '$written'"
        verify_apply "$color" "$attn" && pass "daemon applied via API within 2s" || fail "no daemon-applied log line for color=$color within 2s"
        sleep 0.4
    done
else
    warn "skipping color tests"
fi

if [ "$INCLUDE_DAEMON_RESTART" = "1" ]; then
    step "Daemon restart via watchdog"
    if [ -f "$PID_FILE" ]; then
        original_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$original_pid" ] && kill -0 "$original_pid" 2>/dev/null; then
            kill "$original_pid" 2>/dev/null || true
            new_pid=""
            for _ in $(seq 1 35); do
                sleep 1
                [ -f "$PID_FILE" ] && new_pid=$(cat "$PID_FILE" 2>/dev/null)
                [ -n "$new_pid" ] && [ "$new_pid" != "$original_pid" ] && kill -0 "$new_pid" 2>/dev/null && break
                new_pid=""
            done
            [ -n "$new_pid" ] && pass "watchdog respawned daemon as pid=$new_pid" || fail "no new daemon spawned within 35s"
        else
            warn "no live daemon to kill"
        fi
    else
        warn "no PID file"
    fi
fi

[ "$QUIET" = "0" ] && printf '\n'
if [ "$FAILS" = "0" ]; then
    printf '  %s✓%s All %d checks passed.\n' "$G" "$RST" "$PASSES"
    exit 0
fi
printf '  %s✗%s %d failed, %d passed.\n' "$R" "$RST" "$FAILS" "$PASSES"
exit 1
