#!/usr/bin/env bash
# autoDev — dead-man watchdog. Runs on its own timer (e.g. every 15 min).
# If the heartbeat is stale > 60 min AND we're not in a known rate-limit pause,
# the engine has stalled — file a Linear story so the team sees it where they
# already look. No Claude, no email infra.
set -uo pipefail

RUN_HOME="${RUN_HOME:-{{RUN_HOME}}}"
HEARTBEAT="$RUN_HOME/heartbeat"
PAUSE="$RUN_HOME/rate-limited-until"
STALE_SECONDS=3600

now=$(date +%s)

# A known rate-limit pause is healthy-idle, not a stall.
if [[ -f "$PAUSE" ]]; then
  until=$(cat "$PAUSE" 2>/dev/null || echo 0)
  if [[ "$now" -lt "$until" ]]; then
    exit 0   # paused on purpose; resumes automatically at $until
  fi
fi

if [[ ! -f "$HEARTBEAT" ]]; then exit 0; fi   # never started yet
last=$(stat -f %m "$HEARTBEAT" 2>/dev/null || stat -c %Y "$HEARTBEAT" 2>/dev/null || echo "$now")
age=$(( now - last ))

if (( age > STALE_SECONDS )); then
  "$(dirname "$0")/notify.sh" stalled "$age"
  command -v osascript >/dev/null && \
    osascript -e 'display notification "autoDev engine appears stalled" with title "⚠️ ENGINE STALLED"' 2>/dev/null || true
fi
