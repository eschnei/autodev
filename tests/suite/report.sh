#!/usr/bin/env bash
# report.mjs — the operator digest. Cadence gating, bucket counts from the local
# board, marker handling, and fail-loud on unsupported trackers.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
REP="$PLUGIN/scripts/report.mjs"

R=$(mkrepo RepCo '.reporting.cadence="off"'); RUNHOME=$(runhome "$R")
rep() { (cd "$R" && node "$REP" "$@"); }
t() { (cd "$R" && node "$TRK" "$@" >/dev/null); }

echo "report — cadence gating:"
check_no_out "cadence=off → exit 0, no output, even with --force" rep --force
check "cadence=off → no marker written"                  test ! -f "$R/.autodev/.last_report"
jq '.reporting.cadence="hourly"' "$R/.autodev/deployment.json" > "$R/t" && mv "$R/t" "$R/.autodev/deployment.json"
check_out "first run (no marker) emits"                  "autoDev digest — RepCo.*first report" rep
check "marker written"                                   test -f "$R/.autodev/.last_report"
check_no_out "second run inside the window → silent"     rep
check_out "--force bypasses the window"                  "autoDev digest" rep --force
old_touch "$R/.autodev/.last_report"
check_out "elapsed window (marker 2h old, cadence 1h) → emits" "since " rep
jq '.reporting.cadence="30m"' "$R/.autodev/deployment.json" > "$R/t" && mv "$R/t" "$R/.autodev/deployment.json"
old_touch "$R/.autodev/.last_report"
check_out "<N>m cadence parses"                          "autoDev digest" rep
jq '.reporting.cadence="garbage"' "$R/.autodev/deployment.json" > "$R/t" && mv "$R/t" "$R/.autodev/deployment.json"
check_no_out "unparseable cadence behaves like off"      rep --force

echo "report — bucket counts from the local board:"
jq '.reporting.cadence="hourly"' "$R/.autodev/deployment.json" > "$R/t" && mv "$R/t" "$R/.autodev/deployment.json"
t create-issue --title "q1" --stage ready_for_ai_dev
t create-issue --title "q2" --stage ready_for_ai_dev
t create-issue --title "dev" --stage ai_development
t create-issue --title "qa" --stage ai_qa
t create-issue --title "rev" --stage ready_for_human_review
t create-issue --title "acc" --stage ready_for_human_acceptance
t create-issue --title "blk" --stage blocked
t create-issue --title "prd" --stage prd_review
t create-issue --title "dn" --stage done
t create-issue --title "new" --stage new_request
OUT=$(rep --force)
check "in-flight = dev + qa"                             grep -q 'in-flight (dev/QA): 2' <<<"$OUT"
check "queued = ready_for_ai_dev"                        grep -q 'queued: 2' <<<"$OUT"
check "awaiting you = the (H) stages (PRD review, review, acceptance)" grep -q 'awaiting you (gates): 3' <<<"$OUT"
check "Blocked (H) counts as blocked, not awaiting"      grep -q 'blocked: 1' <<<"$OUT"
check "done = done"                                      grep -q 'done: 1' <<<"$OUT"
check "engine status line"                               grep -q 'engine: running' <<<"$OUT"
echo 4102444800 > "$RUNHOME/rate-limited-until"
check_out "rate-limit pause is reflected"                "engine: rate-limited" rep --force
rm -f "$RUNHOME/rate-limited-until"
check "digest also appended to runner logs"              grep -q 'autoDev digest' "$RUNHOME/logs/report.log"
check "commit count is numeric"                          has_re 'commits[^:]*: [0-9]+'

echo "report — destinations + unsupported trackers:"
RS=$(mkrepo ShCo '.tracker.kind="shortcut" | .reporting.cadence="hourly"')
check_out "kind=shortcut fails loud (n/a), never a silent zero digest" "board counts n/a.*tracker.kind=shortcut" bash -c "cd '$RS' && node '$REP' --force"
RL=$(mkrepo LnCo '.tracker.kind="linear" | .reporting.cadence="hourly" | .reporting.destination="linear" | .reporting.linear_issue=""')
check_out "destination=linear without issue/token errors (no network attempted)" "no linear_issue/token" bash -c "cd '$RL' && node '$REP' --force 2>&1"
RK=$(mkrepo SlCo '.reporting.cadence="hourly" | .reporting.destination="slack" | .reporting.slack_webhook=""')
check_out "destination=slack without a webhook errors"   "no slack_webhook" bash -c "cd '$RK' && node '$REP' --force 2>&1"
check_out "no config dies"                               "no .autodev/deployment.json" bash -c "cd '$SANDBOX' && node '$REP' 2>&1; true"

exit $FAIL
