#!/bin/bash
# headsup-context-bar.sh — Claude Code statusLine hook.
# Renders a live context-usage bar in Claude Code's status line and fires
# a one-shot macOS notification when context crosses the danger threshold.
#
# Part of the headsup stack. Add to ~/.claude/settings.json:
#   "statusLine": [{"matcher":"","hooks":[{"type":"command",
#     "command":"\"$HOME/.claude/hooks/headsup-context-bar.sh\""}]}]
# Restart Claude Code after adding it.
#
# Requires: jq

# ── Thresholds (override in ~/.claude/hooks/headsup-status.conf) ──────────
WARN_AT=70       # yellow + ⚠
DANGER_AT=90     # red + 🔴  + fires the macOS notification
BAR_WIDTH=10

# ── Notification defaults (also honor headsup-notifications.conf) ─────────
NOTIFICATION_SOUND="Glass"

NOTIFIER_BIN="$HOME/Library/Application Support/headsup/headsup-notifier.app/Contents/MacOS/headsup-notifier"

# shellcheck source=/dev/null
[ -f "$HOME/.claude/hooks/headsup-status.conf"       ] && source "$HOME/.claude/hooks/headsup-status.conf"
# shellcheck source=/dev/null
[ -f "$HOME/.claude/hooks/headsup-notifications.conf" ] && source "$HOME/.claude/hooks/headsup-notifications.conf"

# Kill switch — same convention as headsup-status.sh.
[ -f "$HOME/.claude/hooks/.disabled" ] && exit 0

RESET=$'\033[0m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'

# ── Parse all fields in one jq pass ──────────────────────────────────────
# jq computes context % via floor() in both the pre-calculated and the
# manual-calculation path, so PCT is always an integer — no post-processing.
input=$(cat)
eval "$(printf '%s' "$input" | jq -r '
  ((.context_window.current_usage.input_tokens              // 0) +
   (.context_window.current_usage.cache_creation_input_tokens // 0) +
   (.context_window.current_usage.cache_read_input_tokens    // 0) +
   (.context_window.current_usage.output_tokens              // 0)) as $tok |
  (if .context_window.used_percentage != null then
     (.context_window.used_percentage | floor)
   else
     ((.context_window.context_window_size // 200000) as $sz |
      ((.context_window.current_usage.input_tokens              // 0) +
       (.context_window.current_usage.cache_creation_input_tokens // 0) +
       (.context_window.current_usage.cache_read_input_tokens    // 0) +
       (.context_window.current_usage.output_tokens              // 0)) as $used |
      ($used * 100 / $sz | floor))
   end) as $pct |
  [
    "MODEL=" + (.model.display_name // "Claude" | @sh),
    "COST="  + (.cost.total_cost_usd // 0 | tostring),
    "SESSION=" + (.session_id // "default" | @sh),
    "DIR="   + (.workspace.current_dir // "." | @sh),
    "PCT=\($pct)",
    "TOKENS=\($tok)",
    "CTX_SIZE=\(.context_window.context_window_size // 200000)"
  ] | .[]
')"

BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
LABEL=$(basename "$DIR")
ACCOUNT=$(jq -r '.oauthAccount.emailAddress // empty' ~/.claude.json 2>/dev/null)
[ -z "$ACCOUNT" ] && ACCOUNT="$(whoami)"
IS_MAX=$(jq -r '.oauthAccount.organizationType // empty' ~/.claude.json 2>/dev/null)

# Tilde prefix = estimated at API rates (Max subscription); no tilde = actual charge (API key)
if [ "$IS_MAX" = "claude_max" ]; then
    COST_LABEL="~\$$(printf '%.2f' "$COST") est"
else
    COST_LABEL="\$$(printf '%.2f' "$COST")"
fi

# ── Session and week usage windows ───────────────────────────────────────────
# headsup-usage-windows.py aggregates output tokens from JSONL files and
# caches results for 60s so this stays fast on every status line update.
USAGE_WINDOWS_SCRIPT="$HOME/.claude/hooks/headsup-usage-windows.py"
SESSION_PCT="" SESSION_USED="" SESSION_LIMIT_FMT="" SESSION_COST=""
WEEK_PCT=""    WEEK_USED=""    WEEK_LIMIT_FMT=""    WEEK_COST=""
SESSION_RESET=""
if [ -f "$USAGE_WINDOWS_SCRIPT" ]; then
    eval "$(python3 "$USAGE_WINDOWS_SCRIPT" 2>/dev/null)" 2>/dev/null || true
fi

# ── macOS notification — mirrors headsup-notify-waiting.sh's fire_notification
# Uses the bundled Swift notifier (custom icon) with osascript as fallback.
fire_notification() {
    local title="$1" subtitle="$2" body="$3" group_id="${4:-ctx}"
    if [ -x "$NOTIFIER_BIN" ]; then
        "$NOTIFIER_BIN" "$title" "$subtitle" "$body" "$group_id" >/dev/null 2>&1 || true
        return
    fi
    local script="display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\""
    [ -n "$subtitle" ] && script+=" subtitle \"${subtitle//\"/\\\"}\""
    [ -n "$NOTIFICATION_SOUND" ] && script+=" sound name \"${NOTIFICATION_SOUND//\"/\\\"}\""
    osascript -e "$script" 2>/dev/null || true
}

# ── Escalating notifications at 90, 95, 96, 97, 98, 99% ──────────────────
# State file tracks highest threshold notified. Resets below 85% (after
# /compact or /clear) so the sequence fires again next time.
ALERT_THRESHOLDS=(90 95 96 97 98 99)
STATE="/tmp/cc_ctx_alert_${SESSION}"
_raw=$([ -f "$STATE" ] && cat "$STATE" || echo "0")
[[ "$_raw" =~ ^[0-9]+$ ]] && LAST=$_raw || LAST=0

# Find the highest unnotified threshold PCT has crossed, fire once for it.
NEXT=0
for thresh in "${ALERT_THRESHOLDS[@]}"; do
    if [ "$PCT" -ge "$thresh" ] && [ "$LAST" -lt "$thresh" ]; then
        NEXT=$thresh
    fi
done

if [ "$NEXT" -gt 0 ]; then
    if   [ "$NEXT" -ge 99 ]; then body="🚨 Compact NOW — you are about to lose context"
    elif [ "$NEXT" -ge 97 ]; then body="Compact immediately — context nearly gone"
    elif [ "$NEXT" -ge 95 ]; then body="Compact soon — context almost full"
    else                          body="Run /compact to avoid losing context"; fi
    fire_notification "$LABEL" "Context at ${PCT}%" "$body" "ctx_${SESSION}"
    echo "$NEXT" > "$STATE"
fi

[ "$PCT" -lt 85 ] && echo "0" > "$STATE"

# ── Color + label ─────────────────────────────────────────────────────────
if   [ "$PCT" -ge "$DANGER_AT" ]; then COLOR=$RED;    NOTE=" 🔴 compact soon"
elif [ "$PCT" -ge "$WARN_AT"   ]; then COLOR=$YELLOW; NOTE=" ⚠"
else                                   COLOR=$GREEN;  NOTE=""; fi

FILLED=$(( PCT * BAR_WIDTH / 100 ))
[ "$FILLED" -gt "$BAR_WIDTH" ] && FILLED=$BAR_WIDTH
BAR=""
for ((i=0; i<BAR_WIDTH; i++)); do
    [ "$i" -lt "$FILLED" ] && BAR+="▓" || BAR+="░"
done

LINE="👤 ${DIM}${ACCOUNT}${RESET}  ${DIM}${MODEL}${RESET}"
if [ "$PCT" -ge "$WARN_AT" ]; then
    LINE+="  Context: ${COLOR}${BAR} ${PCT}%${NOTE}${RESET}"
else
    LINE+="  ${DIM}${PCT}%${RESET}"
fi
if [ -n "$SESSION_PCT" ]; then
    LINE+="  Session: ${DIM}${SESSION_USED}/${SESSION_LIMIT_FMT} ~${SESSION_PCT}%${RESET}  ${DIM}API cost ~\$${SESSION_COST}${RESET}"
fi
if [ -n "$WEEK_PCT" ]; then
    LINE+="  Week: ${DIM}${WEEK_USED}/${WEEK_LIMIT_FMT} ~${WEEK_PCT}%${RESET}  ${DIM}API cost ~\$${WEEK_COST}${RESET}"
fi
LINE+="  Cost: ${DIM}${COST_LABEL}${RESET}"
[ -n "$BRANCH" ] && LINE+="  ${DIM}⎇ ${BRANCH}${RESET}"
printf '%s' "$LINE"
