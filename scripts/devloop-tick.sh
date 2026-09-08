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
# CLI resolution, first hit wins — so an existing ~/.autodev/bin/ copy keeps working after
# a plugin auto-update with no manual step (PRD §54: never break existing deployments):
#   1. the sibling checkout's bin/autodev.mjs (running from the repo / plugin tree)
#   2. `autodev` on PATH (npm link from a git checkout — ops/launchd-timer.md)
#   3. the installed plugin's recorded path (~/.claude/plugins/installed_plugins.json)
#   4. the newest versioned plugin cache dir (~/.claude/plugins/cache/*/autodev/<ver>/)
# $AUTODEV_CLI overrides all of it (tests; unusual layouts).
#
# Usage: devloop-tick.sh <repo-path>
set -uo pipefail

REPO="${1:?usage: devloop-tick.sh <repo-path>}"
CONFIG="$REPO/.autodev/deployment.json"
[[ -f "$CONFIG" ]] || { echo "devloop-tick: no $CONFIG" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS="${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins}"

find_cli() {
  [[ -n "${AUTODEV_CLI:-}" && -f "$AUTODEV_CLI" ]] && { printf 'node\n%s\n' "$AUTODEV_CLI"; return 0; }
  [[ -f "$HERE/../bin/autodev.mjs" ]] && { printf 'node\n%s\n' "$HERE/../bin/autodev.mjs"; return 0; }
  command -v autodev >/dev/null 2>&1 && { printf '%s\n' "$(command -v autodev)"; return 0; }
  if [[ -f "$PLUGINS/installed_plugins.json" ]] && command -v jq >/dev/null 2>&1; then
    local p
    p=$(jq -r '.plugins | to_entries[] | select(.key | startswith("autodev@")) | .value[0].installPath // empty' "$PLUGINS/installed_plugins.json" 2>/dev/null | head -1)
    [[ -n "$p" && -f "$p/bin/autodev.mjs" ]] && { printf 'node\n%s\n' "$p/bin/autodev.mjs"; return 0; }
  fi
  local newest
  newest=$(ls -d "$PLUGINS"/cache/*/autodev/*/bin/autodev.mjs 2>/dev/null | sort -V | tail -1)
  [[ -n "$newest" ]] && { printf 'node\n%s\n' "$newest"; return 0; }
  return 1
}

if CLI_LINES=$(find_cli); then
  # shellcheck disable=SC2206
  CLI=($CLI_LINES)
  exec "${CLI[@]}" tick "$REPO"
fi
echo "devloop-tick: the autodev CLI was not found (not next to this script, not on PATH, no installed autodev plugin) — run 'npm link' in the autoDev checkout, or install the plugin (ops/launchd-timer.md)" >&2
exit 1
