#!/usr/bin/env bash
# autoDev — one heartbeat tick. Fired by the timer ({{TICK_MIN}}-min interval).
# Stateless: all real state lives in Linear + git. Safe to run anytime.
set -uo pipefail

RUN_HOME="${RUN_HOME:-{{RUN_HOME}}}"
REPO="{{REPO_PATH}}"
mkdir -p "$RUN_HOME/logs"

# Single-flight lock — portable (macOS has no flock). A stale lock from a killed
# tick self-clears: if the recorded PID is no longer alive, we take the lock.
LOCK="$RUN_HOME/devloop.lock"
if [[ -f "$LOCK" ]] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  exit 0                             # previous tick still running — skip, don't stack
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
touch "$RUN_HOME/heartbeat"          # prove the runner is alive (even while paused)

# --- rate-limit gate: if a reset time is recorded and still ahead, no-op ---
PAUSE="$RUN_HOME/rate-limited-until"
if [[ -f "$PAUSE" ]]; then
  now=$(date +%s); until=$(cat "$PAUSE" 2>/dev/null || echo 0)
  if [[ "$now" -lt "$until" ]]; then exit 0; fi
  rm -f "$PAUSE"; "$(dirname "$0")/notify.sh" resumed
fi

cd "$REPO" || exit 1
OUT=$(claude -p "/devloop" --output-format json 2>>"$RUN_HOME/logs/err.log")
echo "$OUT" >> "$RUN_HOME/logs/$(date +%F).jsonl"

# --- detect a usage-limit result and record the reset time ---
# NOTE: confirm the exact field against the installed Claude Code version.
if echo "$OUT" | jq -e '.is_error and (.result // "" | ascii_downcase
      | test("usage limit|rate limit"))' >/dev/null 2>&1; then
  reset=$(echo "$OUT" | jq -r '.reset_at_epoch // empty' 2>/dev/null)
  [[ -z "$reset" ]] && reset=$(( $(date +%s) + 3600 ))   # fallback: back off 1h
  echo "$reset" > "$PAUSE"
  "$(dirname "$0")/notify.sh" limited "$reset"
fi

# --- operator digest (B4): cheap, self-gates on reporting.cadence; no-op if off/not-due ---
AUTODEV_CONFIG="$REPO/.autodev/deployment.json" RUN_HOME="$RUN_HOME" \
  node "$(dirname "$0")/report.mjs" >/dev/null 2>>"$RUN_HOME/logs/err.log" || true
