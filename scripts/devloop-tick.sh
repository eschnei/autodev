#!/usr/bin/env bash
# autoDev — one heartbeat tick. Fired by the timer (interval = execution.tick_interval_minutes
# in the target repo's .autodev/deployment.json). Stateless: all real state lives on the
# board + git. Safe to run anytime.
#
# Since v3 (Milestone 3) this is a thin launchd-facing wrapper: the tick itself lives in
# src/core/tick.mjs and reaches the model ONLY through the Executor seam
# (src/executors/claude/index.mjs is the one place `claude` is invoked). Lock, heartbeat,
# rate-limit probe/pause, logging, digest and mirror flush all behave exactly as before
# (pinned by tests/suite/runner.sh).
#
# CLI resolution: the sibling checkout's bin/autodev.mjs when this script runs from the
# plugin/repo tree; otherwise `autodev` on PATH (npm link — see ops/launchd-timer.md).
# The stable per-operator copy convention (~/.autodev/bin/) therefore needs `autodev`
# installed; launchd's PATH is minimal, so the plist should export it.
#
# Usage: devloop-tick.sh <repo-path>
set -uo pipefail

REPO="${1:?usage: devloop-tick.sh <repo-path>}"
CONFIG="$REPO/.autodev/deployment.json"
[[ -f "$CONFIG" ]] || { echo "devloop-tick: no $CONFIG" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$HERE/../bin/autodev.mjs" ]]; then
  exec node "$HERE/../bin/autodev.mjs" tick "$REPO"
elif command -v autodev >/dev/null 2>&1; then
  exec autodev tick "$REPO"
else
  echo "devloop-tick: the autodev CLI is not installed — run 'npm link' in the autoDev checkout (ops/launchd-timer.md)" >&2
  exit 1
fi
