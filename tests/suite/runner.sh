#!/usr/bin/env bash
# Headless runner mechanics — devloop-tick.sh, watchdog.sh, notify.sh — with the
# `claude` CLI stubbed (tests/lib.sh). This is the only place the engine shells out to
# a vendor CLI today; M3 moves exactly these calls behind ClaudeCodeExecutor, so the
# observable contract (lock, probe/pause, allowlist, logging, notifications) is pinned.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
TICK="$PLUGIN/scripts/devloop-tick.sh"
WD="$PLUGIN/scripts/watchdog.sh"
NOTIFY="$PLUGIN/scripts/notify.sh"

fresh() { : > "$CLAUDE_STUB_LOG"; }
calls() { local n; n=$(grep -c . "$CLAUDE_STUB_LOG" 2>/dev/null); echo "${n:-0}"; }
titles() { jq -r '.title' "$1"/.autodev/board/AD-*.json 2>/dev/null; }
export -f titles

R=$(mkrepo TickCo '.commands.test="npm test" | .commands.lint="npm run lint" | .commands.install="" | .repo.story_branch_prefix="autodev" | .backup.remote="backup"')
RUNHOME=$(runhome "$R")

echo "devloop-tick — normal tick:"
fresh; CLAUDE_STUB_MODE=ok bash "$TICK" "$R"; rc=$?
export OUT
check "exits 0"                                          test $rc -eq 0
check "invokes claude exactly once (the loop, no probe)" test "$(calls)" -eq 1
check "runs /autodev:loop headless with json output"     grep -q -- '-p /autodev:loop --output-format json' "$CLAUDE_STUB_LOG"
check "heartbeat touched"                                test -f "$RUNHOME/heartbeat"
check "lock released after the tick"                     test ! -f "$RUNHOME/devloop.lock"
check "result appended to today's jsonl log"             bash -c "grep -q '\"result\":\"ok\"' '$RUNHOME/logs/$(date -u +%F).jsonl'"
check "no pause file on a healthy result"                test ! -f "$RUNHOME/rate-limited-until"

echo "devloop-tick — allowlist is built from THIS repo's config:"
OUT=$(cat "$CLAUDE_STUB_LOG")
grant() { has "--allowedTools $1"; }
check "configured commands.test granted"                 grant 'Bash(npm test)'
check "configured commands.lint granted"                 grant 'Bash(npm run lint)'
check "empty command is NOT granted as Bash()"           lacks 'Bash()'
check "feature-branch push granted (prefix from config)" grant 'Bash(git push origin feature/*)'
check "story-branch push granted (prefix from config)"   grant 'Bash(git push origin autodev/*)'
check "backup remote push granted"                       grant 'Bash(git push backup feature/*)'
check "gh pr create/view/comment/checks granted"          bash -c 'for g in create view comment checks; do grep -qF -- "--allowedTools Bash(gh pr $g:*)" <<<"$OUT" || exit 1; done'
check "gh pr merge NEVER granted"                        lacks 'gh pr merge'
check "bare node NEVER granted"                          lacks '--allowedTools Bash(node *)'
check "node scoped to tracker.mjs"                       has 'scripts/tracker.mjs *)'
check "default-branch push NOT granted"                  bash -c '! grep -qE "git push [a-z]+ main" <<<"$OUT"'
check "git rebase/merge --squash granted (story→feature)" bash -c 'grep -qF "Bash(git merge --squash:*)" <<<"$OUT" && grep -qF "Bash(git rebase:*)" <<<"$OUT"'

echo "devloop-tick — single-flight lock:"
sleep 30 & HOLDER=$!
echo $HOLDER > "$RUNHOME/devloop.lock"
fresh; bash "$TICK" "$R"; rc=$?
check "live lock holder → tick skips (exit 0, claude not called)" bash -c "test $rc -eq 0 && test $(calls) -eq 0"
check "live lock left in place"                          test -f "$RUNHOME/devloop.lock"
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
echo 2147483000 > "$RUNHOME/devloop.lock"   # dead PID
fresh; bash "$TICK" "$R" >/dev/null
check "stale lock (dead PID) is taken over — tick runs"  test "$(calls)" -eq 1
check "stale lock cleaned up afterwards"                 test ! -f "$RUNHOME/devloop.lock"

echo "devloop-tick — rate-limit pause + probe:"
fresh; CLAUDE_STUB_MODE=limited bash "$TICK" "$R" >/dev/null
check "usage-limit result creates the pause file"        test -f "$RUNHOME/rate-limited-until"
check "pause file records the parsed reset epoch"        grep -qx 4102444800 "$RUNHOME/rate-limited-until"
check "operator notified on the board (limited)"         bash -c "titles '$R' | grep -q 'rate-limited'"
check "notify log written"                               grep -q '\[limited\]' "$RUNHOME/logs/notify.log"
fresh; CLAUDE_STUB_MODE=fail bash "$TICK" "$R" >/dev/null
check "while paused: only the probe runs (1 call), not the loop" bash -c "test $(calls) -eq 1 && grep -q 'reply with exactly: ok' '$CLAUDE_STUB_LOG' && ! grep -q '/autodev:loop' '$CLAUDE_STUB_LOG'"
check "failed probe keeps the pause"                     test -f "$RUNHOME/rate-limited-until"
fresh; CLAUDE_STUB_MODE=ok bash "$TICK" "$R" >/dev/null
check "successful probe lifts the pause"                 test ! -f "$RUNHOME/rate-limited-until"
check "…and the full tick runs in the same pass (probe + loop = 2 calls)" bash -c "test $(calls) -eq 2 && grep -q '/autodev:loop' '$CLAUDE_STUB_LOG'"
check "operator notified on the board (resumed)"         bash -c "titles '$R' | grep -q 'resumed'"

echo "devloop-tick — preconditions:"
check_out "no deployment.json → exits 1 loudly"          "no .*deployment.json" bash -c "bash '$TICK' '$SANDBOX' 2>&1; true"
check "no deployment.json → exit status 1"               bash -c "! bash '$TICK' '$SANDBOX' >/dev/null 2>&1"
check_out "usage without a repo path"                    "usage: devloop-tick.sh" bash -c "bash '$TICK' 2>&1; true"

echo "notify.sh — board notifications via the tracker:"
RN=$(mkrepo NotifyCo); RUNHOME=$(runhome "$RN")
check "limited with a reset epoch names the time"        bash -c "bash '$NOTIFY' '$RN' limited 4102444800 && titles '$RN' | grep -q 'rate-limited (reset ~'"
check "limited without an epoch still posts"             bash -c "bash '$NOTIFY' '$RN' limited && titles '$RN' | grep -c 'rate-limited' | grep -qx 2"
check "resumed posts"                                    bash -c "bash '$NOTIFY' '$RN' resumed && titles '$RN' | grep -q '▶️ autoDev resumed'"
check "stalled converts seconds to minutes"              bash -c "bash '$NOTIFY' '$RN' stalled 5400 && titles '$RN' | grep -q 'no heartbeat for ~90 min'"
check "unknown kind exits 1 with usage"                  bash -c "! bash '$NOTIFY' '$RN' bogus >/dev/null 2>&1"
check "every notification is logged under runner.home_dir" bash -c "grep -cE '\[(limited|resumed|stalled)\]' '$RUNHOME/logs/notify.log' | grep -qx 4"

echo "watchdog — dead-man + hung-tick detection:"
RW=$(mkrepo WdCo); WRH=$(runhome "$RW")
check "never-started engine (no heartbeat) → silent"     bash -c "bash '$WD' '$RW' && test -z \"\$(titles '$RW')\""
touch "$WRH/heartbeat"
check "fresh heartbeat → silent"                         bash -c "bash '$WD' '$RW' && test -z \"\$(titles '$RW')\""
old_touch "$WRH/heartbeat"
check "stale heartbeat (>60 min) → STALLED posted"       bash -c "bash '$WD' '$RW' && titles '$RW' | grep -q 'ENGINE STALLED'"
echo 4102444800 > "$WRH/rate-limited-until"
check "known rate-limit pause is healthy-idle, not a stall" bash -c "bash '$WD' '$RW' && titles '$RW' | grep -c 'ENGINE STALLED' | grep -qx 1"
rm -f "$WRH/rate-limited-until"
echo 0 > "$WRH/rate-limited-until"   # expired pause → normal checks resume
check "expired pause file no longer suppresses"          bash -c "bash '$WD' '$RW' && titles '$RW' | grep -c 'ENGINE STALLED' | grep -qx 2"
rm -f "$WRH/rate-limited-until"
touch "$WRH/heartbeat"
echo 2147483000 > "$WRH/devloop.lock"; old_touch "$WRH/devloop.lock"
check "hung tick (old lock, no recent commits) → lock cleared + notified" bash -c "bash '$WD' '$RW' && test ! -f '$WRH/devloop.lock' && titles '$RW' | grep -c 'ENGINE STALLED' | grep -qx 3"
echo 2147483000 > "$WRH/devloop.lock"; old_touch "$WRH/devloop.lock"
(cd "$RW" && git add -A >/dev/null && git commit -qm "progress" >/dev/null)
check "old lock but recent commit = progress → lock kept" bash -c "bash '$WD' '$RW' && test -f '$WRH/devloop.lock'"
check_out "no deployment.json → exits 1"                 "no .*deployment.json" bash -c "bash '$WD' '$SANDBOX' 2>&1; true"

exit $FAIL
