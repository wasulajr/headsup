#!/bin/bash
# Read-only status snapshot for headsup Codex.

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_DIR="$CODEX_HOME/hooks"
STATE_ROOT="${HEADSUP_CODEX_STATE_ROOT:-/tmp/headsup-codex-${UID:-$(id -u)}}"
STATE_DIR="$STATE_ROOT/.state"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
LOG_FILE="$STATE_ROOT/headsup-status.log"
DISABLED_FLAG="$HOOK_DIR/.disabled"
WATCHDOG_LABEL="codex.headsup-watchdog"
NOTIFICATIONS_CONFIG="$HOOK_DIR/headsup-notifications.conf"

if [ -t 1 ]; then
    G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' B=$'\033[34m' DIM=$'\033[2m' RST=$'\033[0m'
else
    G='' Y='' R='' B='' DIM='' RST=''
fi

ok()    { printf '  %s✓%s %s\n' "$G" "$RST" "$*"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$RST" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$R" "$RST" "$*"; }
dim()   { printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }
hdr()   { printf '\n%s── %s ──%s\n' "$B" "$*" "$RST"; }

if [ -f "$DISABLED_FLAG" ]; then
    hdr "Kill switch"
    warn "$DISABLED_FLAG exists — Codex hook chain is DISABLED"
fi

hdr "Daemon"
daemon_pid=""
[ -f "$PID_FILE" ] && daemon_pid=$(cat "$PID_FILE" 2>/dev/null)
if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    etime=$(ps -p "$daemon_pid" -o etime= 2>/dev/null | tr -d ' ')
    ok "alive (pid $daemon_pid, up $etime)"
else
    warn "not running — will spawn on next Codex hook event or watchdog tick"
fi

if [ -f "$HEARTBEAT_FILE" ]; then
    hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null | head -1)
    hb_ts=$(printf '%s' "$hb" | awk '{print $1}')
    hb_status=$(printf '%s' "$hb" | awk '{print $2}')
    [ -z "$hb_status" ] && hb_status="OK"
    now=$(date +%s)
    age=$(( now - ${hb_ts%.*} ))
    if [ "$hb_status" = "OK" ] && [ "$age" -le 2 ]; then
        ok "heartbeat $hb_status (${age}s ago)"
    elif [ "$hb_status" = "OK" ]; then
        warn "heartbeat OK but stale (${age}s ago)"
    else
        fail "heartbeat status=$hb_status (${age}s ago)"
    fi
else
    warn "no heartbeat file"
fi

hdr "Watchdog"
if launchctl print "gui/$(id -u)/$WATCHDOG_LABEL" >/dev/null 2>&1; then
    ok "loaded as $WATCHDOG_LABEL"
else
    warn "$WATCHDOG_LABEL not loaded"
    dim "run ~/.codex/hooks setup via setup-codex.sh to install it"
fi

hdr "Sessions"
if [ -d "$STATE_DIR" ]; then
    recent_cutoff=$(( $(date +%s) - 3600 ))
    recent=0; stale=0
    for f in "$STATE_DIR"/*.state; do
        [ -f "$f" ] || continue
        mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
        if [ "$mtime" -gt "$recent_cutoff" ]; then
            recent=$((recent+1))
            uuid=$(basename "$f" .state)
            state=$(cat "$f" 2>/dev/null | head -1)
            color=$(printf '%s' "$state" | awk '{print $1}')
            attn=$(printf '%s' "$state" | awk '{print $2}')
            [ -z "$attn" ] && attn="no"
            label="${uuid:0:8}"
            [ -f "$STATE_DIR/${uuid}.badge" ] && label=$(cat "$STATE_DIR/${uuid}.badge" 2>/dev/null | head -1)
            human="custom #$color"
            case "$color" in
                ffffff|FFFFFF) human="idle (white)" ;;
                3a82f5)        human="working (blue)" ;;
                e67e22)        human="waiting (orange)" ;;
                ffcc00)        human="waiting (yellow)" ;;
            esac
            dim "$label (${uuid:0:8}) -> $human attention=$attn"
        else
            stale=$((stale+1))
        fi
    done
    [ "$recent" = "0" ] && warn "no active sessions in the last hour" || ok "$recent active session(s) in the last hour"
    [ "$stale" -gt "0" ] && dim "(plus $stale stale state file(s))"
else
    warn "$STATE_DIR does not exist yet"
fi

hdr "Wait notifications"
if [ -f "$NOTIFICATIONS_CONFIG" ]; then
    eval "$(awk -F'=' '/^[[:space:]]*[A-Z_]+=/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); printf "_NC_%s=%s\n", $1, $2 }' "$NOTIFICATIONS_CONFIG")"
    _NC_NOTIFICATION_SOUND="${_NC_NOTIFICATION_SOUND%\"}"
    _NC_NOTIFICATION_SOUND="${_NC_NOTIFICATION_SOUND#\"}"
    if [ "${_NC_ENABLED:-1}" = "1" ]; then
        ok "enabled — fires after ${_NC_THRESHOLD_MIN:-5}m of waiting"
    else
        warn "disabled"
    fi
    [ -n "${_NC_NOTIFICATION_SOUND:-}" ] && dim "sound: $_NC_NOTIFICATION_SOUND" || dim "sound: silent"
else
    dim "(config not installed — defaults: enabled, 5m threshold)"
fi

hdr "Log"
if [ -f "$LOG_FILE" ]; then
    ok "$LOG_FILE"
else
    dim "(no log yet — touch $HOOK_DIR/.debug to enable event logging)"
fi

echo
