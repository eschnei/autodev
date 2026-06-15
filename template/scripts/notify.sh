#!/usr/bin/env bash
# autoDev — surface engine state to the team via a Shortcut comment/story.
# No Claude: direct Shortcut API (curl). The board is the dashboard.
#
# Usage:
#   notify.sh limited <reset_epoch>   # engine hit a usage limit, auto-resuming
#   notify.sh resumed                 # engine resumed after a rate-limit pause
#   notify.sh stalled  <age_seconds>  # watchdog: heartbeat went stale
#
# Requires a Shortcut API token in $SHORTCUT_API_TOKEN (read-scoped to this
# workspace). Stories land in the "{{CLIENT_NAME}}" workspace.
set -uo pipefail

KIND="${1:-}"
TOKEN="${SHORTCUT_API_TOKEN:-}"
API="https://api.app.shortcut.com/api/v3"
LOG="${RUN_HOME:-{{RUN_HOME}}}/logs/notify.log"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(ts) [$KIND] $*" >> "$LOG"; }

case "$KIND" in
  limited)
    when=$(date -r "${2:-0}" "+%H:%M" 2>/dev/null || echo "soon")
    MSG="⏳ autoDev rate-limited — auto-resuming at ${when}. No action needed."
    ;;
  resumed)
    MSG="▶️ autoDev resumed after a rate-limit pause."
    ;;
  stalled)
    mins=$(( ${2:-0} / 60 ))
    MSG="⚠️ ENGINE STALLED — no heartbeat for ~${mins} min. Check the runner host."
    ;;
  *) echo "usage: notify.sh {limited <epoch>|resumed|stalled <age>}" >&2; exit 1 ;;
esac

log "$MSG"

if [[ -z "$TOKEN" ]]; then
  log "no SHORTCUT_API_TOKEN — logged locally only"; exit 0
fi

# File a lightweight story so it's visible on the board.
curl -s -X POST "$API/stories" \
  -H "Content-Type: application/json" \
  -H "Shortcut-Token: $TOKEN" \
  -d "$(jq -n --arg name "$MSG" '{name:$name, story_type:"chore"}')" \
  >> "$LOG" 2>&1 || log "shortcut post failed"
