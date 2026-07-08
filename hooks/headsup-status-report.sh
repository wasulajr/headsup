#!/bin/bash
# /headsup-status — health snapshot for the headsup hook stack.
#
# Run from the /headsup-status skill (or directly) to see whether the daemon,
# watchdog, hook chain, and current session are all behaving. Read-only:
# does NOT modify anything.
#
# Sections:
#   - Daemon       : iTerm2 daemon PID alive, heartbeat age + status
#   - Watchdog     : LaunchAgent registration + last exit
#   - Sessions     : known sessions (active in last hour) and their colors
#   - Suppressions : count of stray PostToolUse events suppressed (24h)
#   - This session : token usage from the latest JSONL for $PWD

set -u

STATE_DIR="$HOME/.claude/hooks/.state"
HEARTBEAT_FILE="$STATE_DIR/.daemon.heartbeat"
PID_FILE="$STATE_DIR/daemon.pid"
LOG_FILE="$HOME/.claude/hooks/headsup-status.log"
DEBUG_FLAG="$HOME/.claude/hooks/.debug"
DISABLED_FLAG="$HOME/.claude/hooks/.disabled"
WATCHDOG_LABEL="claude-code.headsup-watchdog"
COST_HELPER="$HOME/.claude/hooks/headsup-session-cost.py"
VENV_PYTHON="$HOME/.claude/hooks/iterm2-venv/bin/python"
NOTIFICATIONS_CONFIG="$HOME/.claude/hooks/headsup-notifications.conf"

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

# ── Kill switch ───────────────────────────────────────────────────────────
if [ -f "$DISABLED_FLAG" ]; then
    hdr "Kill switch"
    warn "$DISABLED_FLAG exists — hook chain is DISABLED"
    dim "remove the file to re-enable: rm $DISABLED_FLAG"
fi

# ── Daemon ────────────────────────────────────────────────────────────────
hdr "iTerm2 Daemon"
daemon_pid=""
if [ -f "$PID_FILE" ]; then
    daemon_pid=$(cat "$PID_FILE" 2>/dev/null)
fi
if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    etime=$(ps -p "$daemon_pid" -o etime= 2>/dev/null | tr -d ' ')
    ok "alive (pid $daemon_pid, up $etime)"
else
    warn "not running — will spawn on next hook event or watchdog tick"
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
        fail "heartbeat status=$hb_status (${age}s ago) — daemon should respawn"
    fi
else
    warn "no heartbeat file"
fi

# ── Watchdog (LaunchAgent) ────────────────────────────────────────────────
hdr "Watchdog"
if launchctl list "$WATCHDOG_LABEL" >/dev/null 2>&1; then
    last_exit=$(launchctl list "$WATCHDOG_LABEL" 2>/dev/null | awk -F'=' '/LastExitStatus/ {gsub(/[^0-9]/,"",$2); print $2}')
    if [ -z "$last_exit" ] || [ "$last_exit" = "0" ]; then
        ok "loaded as $WATCHDOG_LABEL (last exit ${last_exit:-?})"
    else
        warn "loaded but last exit was $last_exit"
    fi
else
    fail "$WATCHDOG_LABEL not loaded"
    dim "load with: launchctl load ~/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
fi

# ── Sessions ──────────────────────────────────────────────────────────────
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
            human="custom #$color"
            case "$color" in
                ffffff|FFFFFF) human="idle (white)" ;;
                3a82f5)        human="processing (blue)" ;;
                e67e22)        human="waiting (orange)" ;;
                ffcc00)        human="waiting (yellow)" ;;
            esac
            provider="iTerm"
            short_uuid="${uuid:0:8}"
            case "$uuid" in
                wezterm-*)
                    provider="WezTerm"
                    short_uuid="wez:${uuid#wezterm-}"
                    ;;
            esac
            waiting_marker=""
            [ -f "$STATE_DIR/${uuid}.waiting" ] && waiting_marker=" [waiting-marker]"
            precount=""
            if [ -f "$STATE_DIR/${uuid}.precount" ]; then
                pc=$(cat "$STATE_DIR/${uuid}.precount" 2>/dev/null | head -1)
                [ -n "$pc" ] && [ "$pc" != "0" ] && precount=" [in-flight=$pc]"
            fi
            dim "$short_uuid [$provider] → $human${waiting_marker}${precount}"
        else
            stale=$((stale+1))
        fi
    done
    if [ "$recent" = "0" ]; then
        warn "no active sessions in the last hour"
    else
        ok "$recent active session(s) in the last hour"
    fi
    if [ "$stale" -gt "0" ]; then
        dim "(plus $stale stale state file(s) — daemon GCs after 24h)"
    fi
else
    fail "$STATE_DIR does not exist"
fi

# ── Suppressions ──────────────────────────────────────────────────────────
hdr "Recent PostToolUse suppressions"
if [ -f "$LOG_FILE" ]; then
    today=$(date '+%Y-%m-%d')
    yesterday=$(date -v -1d '+%Y-%m-%d' 2>/dev/null)
    # grep -c outputs "0" on no-match AND exits 1; don't add an `|| echo 0`
    # fallback or we'd double up to "0\n0".
    sup_today=$(grep -c "^${today}.*suppress event=PostToolUse" "$LOG_FILE" 2>/dev/null)
    [ -z "$sup_today" ] && sup_today=0
    ok "today: $sup_today stray PostToolUse events suppressed"
    if [ -n "$yesterday" ]; then
        sup_yest=$(grep -c "^${yesterday}.*suppress event=PostToolUse" "$LOG_FILE" 2>/dev/null)
        [ -z "$sup_yest" ] && sup_yest=0
        dim "yesterday: $sup_yest"
    fi
else
    if [ -f "$DEBUG_FLAG" ]; then
        dim "(no log yet — wait for events to fire)"
    else
        dim "(log disabled — touch $DEBUG_FLAG to enable per-event logging)"
    fi
fi

# ── Wait notifications ────────────────────────────────────────────────────
hdr "Wait notifications"
if [ -f "$NOTIFICATIONS_CONFIG" ]; then
    # shellcheck source=/dev/null
    # Use a subshell so we don't leak vars into the rest of the script.
    eval "$(awk -F'=' '
        /^[[:space:]]*[A-Z_]+=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
            printf "_NC_%s=%s\n", $1, $2;
        }' "$NOTIFICATIONS_CONFIG")"
    # Strip surrounding quotes from values
    _NC_NOTIFICATION_SOUND="${_NC_NOTIFICATION_SOUND%\"}"
    _NC_NOTIFICATION_SOUND="${_NC_NOTIFICATION_SOUND#\"}"
    if [ "${_NC_ENABLED:-1}" = "1" ]; then
        ok "enabled — fires after ${_NC_THRESHOLD_MIN:-5}m of waiting"
    else
        warn "disabled (use /headsup-notifications on to enable)"
    fi
    if [ -n "${_NC_NOTIFICATION_SOUND:-}" ]; then
        dim "sound: $_NC_NOTIFICATION_SOUND"
    else
        dim "sound: silent"
    fi
else
    dim "(config not installed — defaults: enabled, 5m threshold)"
fi

# ── This session's token usage ────────────────────────────────────────────
hdr "This session"
if [ -x "$VENV_PYTHON" ] && [ -f "$COST_HELPER" ]; then
    cost_output=$("$VENV_PYTHON" "$COST_HELPER" --cwd "$PWD" --format long 2>/dev/null)
    if [ -n "$cost_output" ]; then
        printf '%s\n' "$cost_output" | sed 's/^/    /'
    else
        dim "no Claude Code session jsonl found for $PWD"
    fi
else
    dim "(cost helper not installed)"
fi

# ── Usage windows (6h block + week) ───────────────────────────────────────
USAGE_WINDOWS="$HOME/.claude/hooks/headsup-usage-windows.py"
hdr "Usage windows"
if [ -f "$USAGE_WINDOWS" ]; then
    SESSION_PCT="" SESSION_USED="" SESSION_LIMIT_FMT="" SESSION_COST=""
    WEEK_PCT="" WEEK_USED="" WEEK_LIMIT_FMT="" WEEK_COST="" SESSION_RESET=""
    eval "$(python3 "$USAGE_WINDOWS" 2>/dev/null)" 2>/dev/null || true
    if [ -n "$SESSION_PCT" ]; then
        dim "Session (6h): ${SESSION_USED}/${SESSION_LIMIT_FMT} ~${SESSION_PCT}%  API cost ~\$${SESSION_COST}"
        dim "Week:         ${WEEK_USED}/${WEEK_LIMIT_FMT} ~${WEEK_PCT}%  API cost ~\$${WEEK_COST}"
        [ -n "$SESSION_RESET" ] && dim "Session resets: ${SESSION_RESET}"
    else
        dim "no usage-window data (headsup-usage-windows.py produced no output)"
    fi
else
    dim "(usage-windows helper not installed)"
fi

echo
