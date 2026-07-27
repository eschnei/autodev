#!/usr/bin/env bash
# autoDev — dead-man watchdog. Runs on its own timer (e.g. every 15 min), from the
# stable per-operator copy (see ops/launchd-timer.md) — one watchdog instance per
# repo running the timer. If the heartbeat is stale > 60 min AND we're not in a
# known rate-limit pause, the engine has stalled — file a board issue so the team
# sees it where they already look.
#
# Usage: watchdog.sh <repo-path>
set -uo pipefail

REPO="${1:?usage: watchdog.sh <repo-path>}"
CONFIG="$REPO/.autodev/deployment.json"
[[ -f "$CONFIG" ]] || { echo "watchdog: no $CONFIG" >&2; exit 1; }
source "$(dirname "$0")/lib/config.sh" || { echo "watchdog: missing lib/config.sh next to $0" >&2; exit 1; }
autodev_resolve_config "$REPO"
RUN_HOME="$(autodev_cfg_get runner.home_dir "~/.autodev")"
RUN_HOME="${RUN_HOME/#\~/$HOME}"
HEARTBEAT="$RUN_HOME/heartbeat"
PAUSE="$RUN_HOME/rate-limited-until"
LOCK="$RUN_HOME/devloop.lock"
STALE_SECONDS=3600
HUNG_SECONDS=2700        # a single tick shouldn't hold the lock this long with no commits

now=$(date +%s)
# BSD stat's -f FORMAT and GNU stat's -f (filesystem mode) collide: on GNU stat,
# `stat -f %m FILE` fails but still prints filesystem info to stdout before it does
# (only stderr is a format error there), so each attempt must be captured on its own
# — piping both attempts through a single `||` leaks the failed one's stdout into the
# result and corrupts it.
mtime() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null) && { printf '%s' "$m"; return; }
  m=$(stat -c %Y "$1" 2>/dev/null) && { printf '%s' "$m"; return; }
  printf '%s' "$now"
}

# A known rate-limit pause is healthy-idle, not a stall.
if [[ -f "$PAUSE" ]]; then
  until=$(cat "$PAUSE" 2>/dev/null || echo 0)
  if [[ "$now" -lt "$until" ]]; then
    exit 0   # paused on purpose; resumes automatically at $until
  fi
fi

# --- hung-tick detection — lock held a long time AND no repo progress ---
if [[ -f "$LOCK" ]]; then
  lockage=$(( now - $(mtime "$LOCK") ))
  if (( lockage > HUNG_SECONDS )); then
    lastcommit=$(git -C "$REPO" log --all -1 --format=%ct 2>/dev/null || echo 0)
    if (( now - lastcommit > HUNG_SECONDS )); then
      pid=$(cat "$LOCK" 2>/dev/null || true)
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
      rm -f "$LOCK"
      "$(dirname "$0")/notify.sh" "$REPO" stalled "$lockage"   # hung tick: cleared the wedged lock
    fi
  fi
fi

if [[ ! -f "$HEARTBEAT" ]]; then exit 0; fi   # never started yet
last=$(mtime "$HEARTBEAT")
age=$(( now - last ))

if (( age > STALE_SECONDS )); then
  "$(dirname "$0")/notify.sh" "$REPO" stalled "$age"
  command -v osascript >/dev/null && \
    osascript -e 'display notification "autoDev engine appears stalled" with title "⚠️ ENGINE STALLED"' 2>/dev/null || true
fi
