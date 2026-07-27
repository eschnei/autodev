#!/usr/bin/env bash
# autoDev — one heartbeat tick. Fired by the timer (interval = execution.tick_interval_minutes
# in the target repo's .autodev/deployment.json). Stateless: all real state lives on the
# board + git. Safe to run anytime.
#
# Lives at a stable per-operator path (~/.autodev/bin/ by convention — see
# ops/launchd-timer.md), copied there alongside its sibling scripts (notify.sh,
# watchdog.sh, tracker.mjs, linear.mjs, report.mjs) so a launchd plist path survives
# a plugin update (the plugin's own cache directory is versioned and moves).
#
# Usage: devloop-tick.sh <repo-path>
set -uo pipefail

REPO="${1:?usage: devloop-tick.sh <repo-path>}"
CONFIG="$REPO/.autodev/deployment.json"
[[ -f "$CONFIG" ]] || { echo "devloop-tick: no $CONFIG" >&2; exit 1; }
source "$(dirname "$0")/lib/config.sh" || { echo "devloop-tick: missing lib/config.sh next to $0" >&2; exit 1; }
autodev_resolve_config "$REPO"

RUN_HOME="$(autodev_cfg_get runner.home_dir "~/.autodev")"
RUN_HOME="${RUN_HOME/#\~/$HOME}"
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

# --- rate-limit gate: while paused, PROBE instead of trusting a recorded reset time.
# A refused call returns instantly and costs nothing; a successful one is ground truth
# that the limit lifted — so the engine resumes within ONE tick of Claude Code coming
# back, instead of overshooting a guessed timestamp (reset-time fields vary across CLI
# versions, and the old 1h-fallback routinely waited long past the actual reset).
PAUSE="$RUN_HOME/rate-limited-until"
if [[ -f "$PAUSE" ]]; then
  if PROBE=$(claude -p "reply with exactly: ok" --output-format json 2>/dev/null) \
     && [[ -n "$PROBE" ]] \
     && ! echo "$PROBE" | jq -e '.is_error == true' >/dev/null 2>&1; then
    rm -f "$PAUSE"
    "$(dirname "$0")/notify.sh" "$REPO" resumed
    # fall through — run the full tick right now, don't waste the interval
  else
    touch "$PAUSE"                     # still limited; mtime records the last probe
    exit 0
  fi
fi

# --- build the headless allowlist from THIS repo's config; never written to disk ---
ALLOW=()
add() { ALLOW+=(--allowedTools "$1"); }
for c in install test lint build app_run; do
  v=$(jq -r --arg c "$c" '.commands[$c] // empty' "$CONFIG")
  [[ -n "$v" ]] && add "Bash($v)"
done
DEFAULT_BRANCH=$(jq -r '.repo.default_branch // "main"' "$CONFIG")
FEATURE_PREFIX=$(jq -r '.repo.feature_branch_prefix // "feature/"' "$CONFIG")
STORY_PREFIX=$(jq -r '.repo.story_branch_prefix // "autodev"' "$CONFIG")
BACKUP_REMOTE=$(jq -r '.backup.remote // "origin"' "$CONFIG")
add "Bash(git status:*)"; add "Bash(git add:*)"; add "Bash(git commit:*)"
add "Bash(git checkout:*)"; add "Bash(git switch:*)"; add "Bash(git branch:*)"
add "Bash(git worktree:*)"; add "Bash(git diff:*)"; add "Bash(git log:*)"
add "Bash(git rebase:*)"; add "Bash(git merge --squash:*)"
add "Bash(git push origin ${FEATURE_PREFIX}*)"
add "Bash(git push origin ${STORY_PREFIX}/*)"
add "Bash(git push ${BACKUP_REMOTE} ${FEATURE_PREFIX}*)"
add "Bash(gh pr create:*)"; add "Bash(gh pr view:*)"; add "Bash(gh pr comment:*)"
add "Bash(gh pr checks:*)"
# NO gh PR-merge grant — only humans merge (manual.md non-negotiable 3): story→feature
# is a local `git merge --squash` (allowed above); the feature PR is merged by a human.
# node is scoped to the engine's own board helper, never bare `node` (`node -e` = arbitrary
# exec). Entries are literal prefix matches on the command string, so cover both spellings
# the agent docs use (unquoted + quoted); the vendored installer rewrites
# ${CLAUDE_PLUGIN_ROOT} here and in those docs identically, keeping them in sync. Drivers
# (linear.mjs/shortcut.mjs) are child processes OF tracker.mjs, not Bash tool calls — no
# entry needed; report.mjs and every jq below run in THIS wrapper, outside the session.
add 'Bash(node ${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs *)'
add 'Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs" *)'
add "mcp__linear__*"; add "mcp__playwright__*"

cd "$REPO" || exit 1
OUT=$(claude -p "/autodev:loop" --output-format json "${ALLOW[@]}" 2>>"$RUN_HOME/logs/err.log")
echo "$OUT" >> "$RUN_HOME/logs/$(date +%F).jsonl"

# --- detect a usage-limit result and enter probe-paused mode ---
# The pause file's EXISTENCE is what matters (each tick probes and resumes the moment
# a call succeeds); any reset time we can parse is informational, for the notify only.
if echo "$OUT" | jq -e '.is_error and (.result // "" | ascii_downcase
      | test("usage limit|rate limit"))' >/dev/null 2>&1; then
  reset=$(echo "$OUT" | jq -r '.reset_at_epoch // empty' 2>/dev/null)
  echo "${reset:-unknown}" > "$PAUSE"
  "$(dirname "$0")/notify.sh" "$REPO" limited "${reset:-}"
fi

# --- operator digest (B4): cheap, self-gates on reporting.cadence; no-op if off/not-due ---
AUTODEV_CONFIG="$CONFIG" node "$(dirname "$0")/report.mjs" >/dev/null 2>>"$RUN_HOME/logs/err.log" || true

# --- Linear mirror flush: async, off the critical path; self-gates (no-op unless
# tracker.kind=local + tracker.mirror.linear). Failures defer to the next tick. ---
AUTODEV_CONFIG="$CONFIG" node "$(dirname "$0")/tracker.mjs" flush-mirror >/dev/null 2>>"$RUN_HOME/logs/err.log" || true
