#!/usr/bin/env bash
# autoDev — surface engine state to the board via tracker.mjs (retry/backoff built in).
#
# Usage:
#   notify.sh <repo-path> limited <reset_epoch>   # engine hit a usage limit, auto-resuming
#   notify.sh <repo-path> resumed                 # engine resumed after a rate-limit pause
#   notify.sh <repo-path> stalled  <age_seconds>  # watchdog: heartbeat went stale
#
# Token (kept OFF chat / out of git): $LINEAR_API_TOKEN or
#   ~/.config/autodev/<client>.linear.token  (tracker.mjs resolves it)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:?usage: notify.sh <repo-path> \{limited <epoch>|resumed|stalled <age>\}}"
export AUTODEV_CONFIG="$REPO/.autodev/deployment.json"
KIND="${2:-}"
source "$HERE/lib/config.sh" || { echo "notify.sh: missing lib/config.sh next to $0" >&2; exit 1; }
autodev_resolve_config "$REPO"
RUN_HOME="$(autodev_cfg_get runner.home_dir "~/.autodev")"
RUN_HOME="${RUN_HOME/#\~/$HOME}"
LOG="$RUN_HOME/logs/notify.log"
mkdir -p "$(dirname "$LOG")"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(ts) [$KIND] $*" >> "$LOG"; }

case "$KIND" in
  limited)
    if [[ -n "${3:-}" ]] && when=$(date -r "$3" "+%H:%M" 2>/dev/null); then
      TITLE="⏳ autoDev rate-limited (reset ~${when}) — probing every tick; resumes within one tick of the limit lifting."
    else
      TITLE="⏳ autoDev rate-limited — probing every tick; resumes within one tick of the limit lifting."
    fi ;;
  resumed)
    TITLE="▶️ autoDev resumed after a rate-limit pause." ;;
  stalled)
    mins=$(( ${3:-0} / 60 ))
    TITLE="⚠️ ENGINE STALLED — no heartbeat for ~${mins} min. Check the runner host." ;;
  *) echo "usage: notify.sh <repo-path> {limited <epoch>|resumed|stalled <age>}" >&2; exit 1 ;;
esac

log "$TITLE"
node "$HERE/tracker.mjs" create-issue --title "$TITLE" >> "$LOG" 2>&1 || log "board post failed (logged locally only)"
