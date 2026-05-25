#!/bin/bash
# /iterm-diagnose — active end-to-end test of the iterm-config stack.
#
# Flashes the three colors (idle → processing → waiting) on the current
# tab to confirm the bash hook + daemon + Tier 2 + OSC pipeline actually
# applies each transition. Optionally restarts the daemon to verify the
# launchd watchdog respawns it.
#
# Read-mostly: changes are visible (colors flash on the tab) but the
# original state is restored at the end.
#
# Usage:
#   iterm-diagnose.sh                — color-flash test only (~3s)
#   iterm-diagnose.sh --restart      — also kill daemon + verify respawn
#   iterm-diagnose.sh --quiet        — suppress progress output
#
# Exit code: 0 on all-pass, 1 on any fail.

set -u

STATE_DIR="$HOME/.claude/hooks/.state"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
LOG_FILE="$HOME/.claude/hooks/iterm-status.log"
DEBUG_FLAG="$HOME/.claude/hooks/.debug"
WATCHDOG_LABEL="claude-code.iterm-watchdog"
VENV_PYTHON="$HOME/.claude/hooks/iterm2-venv/bin/python"
DAEMON_SCRIPT="$HOME/.claude/hooks/iterm2-daemon.py"
RESYNC="$HOME/.claude/hooks/iterm-resync.sh"
COST_HELPER="$HOME/.claude/hooks/iterm-session-cost.py"

INCLUDE_DAEMON_RESTART=0
QUIET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --restart) INCLUDE_DAEMON_RESTART=1 ;;
        --quiet)   QUIET=1 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--restart] [--quiet]

  --restart   Also kill the daemon and verify the watchdog respawns it
              within ~30s. Adds ~30s to the test runtime.
  --quiet     Suppress per-step progress output.
EOF
            exit 0
            ;;
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
step()  { [ "$QUIET" = "0" ] && printf '\n%s── %s ──%s\n' "$B" "$*" "$RST"; }
pass()  { PASSES=$((PASSES+1)); [ "$QUIET" = "0" ] && printf '  %s✓%s %s\n' "$G" "$RST" "$*"; }
fail()  { FAILS=$((FAILS+1));    printf '  %s✗%s %s\n' "$R" "$RST" "$*"; }
warn()  { [ "$QUIET" = "0" ] && printf '  %s!%s %s\n' "$Y" "$RST" "$*"; }
dim()   { [ "$QUIET" = "0" ] && printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }

# ── Resolve session UUID ──────────────────────────────────────────────────
# Walk PPID like iterm-resync.sh does — the hook script's env doesn't
# include ITERM_SESSION_ID directly; it lives on an iTerm-spawned ancestor.
walk_ppid_for_iterm_session() {
    local pid="$PPID" candidate
    for _ in 1 2 3 4 5 6; do
        [ -z "$pid" ] && break; [ "$pid" = "0" ] && break; [ "$pid" = "1" ] && break
        candidate=$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | head -1 | cut -d= -f2-)
        if [ -n "$candidate" ]; then
            printf '%s' "$candidate"; return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")
    done
    return 1
}

if [ -z "${ITERM_SESSION_ID:-}" ]; then
    ITERM_SESSION_ID=$(walk_ppid_for_iterm_session) || ITERM_SESSION_ID=""
fi
UUID="${ITERM_SESSION_ID#*:}"

# Ensure log is being written during the test — touch the debug flag if it
# wasn't already set, restore at the end.
DEBUG_PRE_EXISTING=0
if [ -f "$DEBUG_FLAG" ]; then
    DEBUG_PRE_EXISTING=1
else
    : > "$DEBUG_FLAG" 2>/dev/null || true
fi

cleanup() {
    # Restore original tab state (best effort)
    if [ -n "$UUID" ] && [ -n "${ORIG_STATE:-}" ]; then
        local orig_color orig_attn
        orig_color=$(printf '%s' "$ORIG_STATE" | awk '{print $1}')
        orig_attn=$(printf '%s' "$ORIG_STATE" | awk '{print $2}')
        [ -z "$orig_attn" ] && orig_attn=no
        if [ -x "$RESYNC" ] && [ -n "$orig_color" ]; then
            "$RESYNC" "$UUID" "$orig_color" "$orig_attn" >/dev/null 2>&1 || true
        fi
    fi
    # Restore debug flag
    if [ "$DEBUG_PRE_EXISTING" = "0" ]; then
        rm -f "$DEBUG_FLAG" 2>/dev/null
    fi
}
trap cleanup EXIT

# ── Step 1: prereqs ──────────────────────────────────────────────────────
step "Step 1: prereqs"
[ -x "$VENV_PYTHON" ] && pass "venv python at $VENV_PYTHON" || fail "venv python missing"
[ -f "$DAEMON_SCRIPT" ] && pass "daemon script at $DAEMON_SCRIPT" || fail "daemon script missing"
[ -x "$RESYNC" ] && pass "resync script at $RESYNC" || fail "resync script missing"
if [ -n "$UUID" ]; then
    pass "resolved ITERM_SESSION_ID uuid=${UUID:0:8}"
else
    fail "could not resolve ITERM_SESSION_ID — color tests will be skipped"
fi

# ── Step 2: daemon health ─────────────────────────────────────────────────
step "Step 2: daemon health"
if [ -f "$PID_FILE" ]; then
    dpid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
        pass "daemon alive (pid $dpid)"
    else
        warn "PID file points at $dpid but process is dead — will respawn on first event"
    fi
else
    warn "no PID file — daemon not currently running"
fi

if [ -f "$HEARTBEAT_FILE" ]; then
    hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1)
    hb_status=$(printf '%s' "$hb" | awk '{print $2}')
    [ -z "$hb_status" ] && hb_status="OK"
    if [ "$hb_status" = "OK" ]; then
        pass "heartbeat status=OK"
    else
        warn "heartbeat status=$hb_status"
    fi
else
    warn "no heartbeat file"
fi

# ── Step 3: watchdog ──────────────────────────────────────────────────────
step "Step 3: launchd watchdog"
if launchctl list "$WATCHDOG_LABEL" >/dev/null 2>&1; then
    pass "$WATCHDOG_LABEL loaded"
else
    fail "$WATCHDOG_LABEL not loaded"
fi

# ── Step 4: cost helper ───────────────────────────────────────────────────
step "Step 4: cost helper"
if [ -f "$COST_HELPER" ] && [ -x "$VENV_PYTHON" ]; then
    if "$VENV_PYTHON" "$COST_HELPER" --cwd "$PWD" --format json >/dev/null 2>&1; then
        pass "iterm-session-cost.py executes cleanly"
    else
        fail "iterm-session-cost.py exited non-zero"
    fi
else
    warn "cost helper not installed; skipping"
fi

# ── Save original tab state for restoration ───────────────────────────────
ORIG_STATE=""
if [ -n "$UUID" ] && [ -f "$STATE_DIR/${UUID}.state" ]; then
    ORIG_STATE=$(cat "$STATE_DIR/${UUID}.state" 2>/dev/null | head -1)
    dim "saved original state: $ORIG_STATE"
fi

# ── Step 5-7: push each color, verify it applied ──────────────────────────
verify_apply() {
    # Wait up to 2s for the daemon to log an "applied" line for our color.
    local color="$1" attention="$2" deadline now matched
    deadline=$(( $(date +%s) + 2 ))
    matched=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if tail -50 "$LOG_FILE" 2>/dev/null | grep -q "daemon applied uuid=$UUID color=$color attn=$attention"; then
            matched=1
            break
        fi
        sleep 0.1
    done
    [ "$matched" = "1" ]
}

if [ -n "$UUID" ] && [ -x "$RESYNC" ]; then
    # Read colors from conf (or defaults) so we test what's actually configured
    IDLE_COLOR="ffffff"; PROCESS_COLOR="3a82f5"; WAIT_COLOR="e67e22"
    CONFIG_FILE="$HOME/.claude/hooks/iterm-status.conf"
    # shellcheck source=/dev/null
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true

    for test_pair in "IDLE:$IDLE_COLOR:no" "PROCESS:$PROCESS_COLOR:no" "WAIT:$WAIT_COLOR:yes"; do
        label="${test_pair%%:*}"
        rest="${test_pair#*:}"
        color="${rest%%:*}"
        attn="${rest#*:}"
        step "Step 5-7: push $label color=$color attn=$attn"
        if ! "$RESYNC" "$UUID" "$color" "$attn" >/dev/null 2>&1; then
            fail "iterm-resync.sh returned non-zero for $label"
            continue
        fi
        # Confirm state file got written
        written=$(cat "$STATE_DIR/${UUID}.state" 2>/dev/null | head -1)
        if [ "$written" = "$color $attn" ]; then
            pass "state file written ($written)"
        else
            fail "state file mismatch: wanted '$color $attn', got '$written'"
        fi
        # Confirm daemon applied
        if verify_apply "$color" "$attn"; then
            pass "daemon applied via API within 2s"
        else
            fail "no daemon-applied log line for color=$color within 2s"
        fi
        sleep 0.4  # let the user see the color flash
    done
else
    warn "skipping color-flash tests (no UUID resolved or no resync script)"
fi

# ── Step 8: daemon restart (--restart only) ───────────────────────────────
if [ "$INCLUDE_DAEMON_RESTART" = "1" ]; then
    step "Step 8: daemon-restart via watchdog"
    if [ -f "$PID_FILE" ]; then
        original_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$original_pid" ] && kill -0 "$original_pid" 2>/dev/null; then
            dim "killing daemon pid=$original_pid; watchdog should respawn within 30s"
            kill "$original_pid" 2>/dev/null
            # Wait for a new daemon to appear (different PID)
            new_pid=""
            for _ in $(seq 1 35); do
                sleep 1
                if [ -f "$PID_FILE" ]; then
                    new_pid=$(cat "$PID_FILE" 2>/dev/null)
                    if [ -n "$new_pid" ] && [ "$new_pid" != "$original_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
                        break
                    fi
                fi
                new_pid=""
            done
            if [ -n "$new_pid" ]; then
                pass "watchdog respawned daemon as pid=$new_pid"
            else
                fail "no new daemon spawned within 35s"
            fi
        else
            warn "no live daemon to kill; skipping"
        fi
    else
        warn "no PID file; skipping"
    fi
else
    dim "Step 8 skipped — pass --restart to include daemon-respawn test"
fi

# ── Summary ───────────────────────────────────────────────────────────────
[ "$QUIET" = "0" ] && printf '\n'
if [ "$FAILS" = "0" ]; then
    printf '  %s✓%s All %d checks passed.\n' "$G" "$RST" "$PASSES"
    exit 0
else
    printf '  %s✗%s %d failed, %d passed.\n' "$R" "$RST" "$FAILS" "$PASSES"
    exit 1
fi
