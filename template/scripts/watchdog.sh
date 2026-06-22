#!/usr/bin/env bash
# autoDev — dead-man watchdog. Runs on its own timer (e.g. every 15 min).
# If the heartbeat is stale > 60 min AND we're not in a known rate-limit pause,
# the engine has stalled — file a Linear story so the team sees it where they
# already look. No Claude, no email infra.
set -uo pipefail

RUN_HOME="${RUN_HOME:-{{RUN_HOME}}}"
REPO="{{REPO_PATH}}"
HEARTBEAT="$RUN_HOME/heartbeat"
PAUSE="$RUN_HOME/rate-limited-until"
LOCK="$RUN_HOME/devloop.lock"
STALE_SECONDS=3600
HUNG_SECONDS=2700        # a single tick shouldn't hold the lock this long with no commits

now=$(date +%s)
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo "$now"; }

# A known rate-limit pause is healthy-idle, not a stall.
if [[ -f "$PAUSE" ]]; then
  until=$(cat "$PAUSE" 2>/dev/null || echo 0)
  if [[ "$now" -lt "$until" ]]; then
    exit 0   # paused on purpose; resumes automatically at $until
  fi
fi

# --- B6: hung-tick detection — lock held a long time AND no repo progress ---
# (Distinguishes "wedged" from "long-but-productive": a productive tick keeps
#  committing to story branches.) If hung, clear the stale lock so ticks resume.
if [[ -f "$LOCK" ]]; then
  lockage=$(( now - $(mtime "$LOCK") ))
  if (( lockage > HUNG_SECONDS )); then
    lastcommit=$(git -C "$REPO" log --all -1 --format=%ct 2>/dev/null || echo 0)
    if (( now - lastcommit > HUNG_SECONDS )); then
      pid=$(cat "$LOCK" 2>/dev/null || true)
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
      rm -f "$LOCK"
      "$(dirname "$0")/notify.sh" stalled "$lockage"   # hung tick: cleared the wedged lock
    fi
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
