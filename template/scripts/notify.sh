#!/usr/bin/env bash
# autoDev — surface engine state to the team via a Linear issue.
# Uses the linear.mjs helper (robust: retry/backoff, reads .autodev/deployment.json).
#
# Usage:
#   notify.sh limited <reset_epoch>   # engine hit a usage limit, auto-resuming
#   notify.sh resumed                 # engine resumed after a rate-limit pause
#   notify.sh stalled  <age_seconds>  # watchdog: heartbeat went stale
#
# Token (kept OFF chat / out of git): $LINEAR_API_TOKEN or
#   ~/.config/autodev/<client>.linear.token  (linear.mjs resolves it)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTODEV_CONFIG="$(cd "$HERE/../.." && pwd)/.autodev/deployment.json"
KIND="${1:-}"
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
# linear.mjs files the issue (retry/backoff); always keep the local log as a fallback.
node "$HERE/linear.mjs" create-issue --title "$TITLE" >> "$LOG" 2>&1 || log "linear post failed (logged locally only)"
