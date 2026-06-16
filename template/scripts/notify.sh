#!/usr/bin/env bash
# autoDev — surface engine state to the team via a Linear issue.
# No Claude: direct Linear GraphQL API (curl). Linear is the dashboard.
#
# Usage:
#   notify.sh limited <reset_epoch>   # engine hit a usage limit, auto-resuming
#   notify.sh resumed                 # engine resumed after a rate-limit pause
#   notify.sh stalled  <age_seconds>  # watchdog: heartbeat went stale
#
# Requires (on the runner host, kept OFF the chat / out of git):
#   LINEAR_API_TOKEN   the client's Linear API key
#   LINEAR_TEAM_ID     the team UUID issues are filed under ('{{LINEAR_TEAM}}')
set -uo pipefail

KIND="${1:-}"
TOKEN="${LINEAR_API_TOKEN:-}"
TEAM_ID="${LINEAR_TEAM_ID:-}"
API="https://api.linear.app/graphql"
LOG="${RUN_HOME:-{{RUN_HOME}}}/logs/notify.log"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(ts) [$KIND] $*" >> "$LOG"; }

case "$KIND" in
  limited)
    when=$(date -r "${2:-0}" "+%H:%M" 2>/dev/null || echo "soon")
    TITLE="⏳ autoDev rate-limited — auto-resuming at ${when}. No action needed." ;;
  resumed)
    TITLE="▶️ autoDev resumed after a rate-limit pause." ;;
  stalled)
    mins=$(( ${2:-0} / 60 ))
    TITLE="⚠️ ENGINE STALLED — no heartbeat for ~${mins} min. Check the runner host." ;;
  *) echo "usage: notify.sh {limited <epoch>|resumed|stalled <age>}" >&2; exit 1 ;;
esac

log "$TITLE"

if [[ -z "$TOKEN" || -z "$TEAM_ID" ]]; then
  log "missing LINEAR_API_TOKEN/LINEAR_TEAM_ID — logged locally only"; exit 0
fi

# Linear personal API key goes in the Authorization header verbatim (no "Bearer").
QUERY=$(jq -n --arg t "$TITLE" --arg team "$TEAM_ID" \
  '{query:"mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{identifier}}}",
    variables:{i:{teamId:$team, title:$t}}}')
curl -s -X POST "$API" \
  -H "Content-Type: application/json" \
  -H "Authorization: $TOKEN" \
  -d "$QUERY" >> "$LOG" 2>&1 || log "linear post failed"
