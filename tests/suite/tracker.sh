#!/usr/bin/env bash
# Local tracker (git-native board) — the deterministic workflow state machine v3
# keeps. Covers lookup rules, every mutation, dispatch by tracker.kind, and the
# best-effort Linear mirror queue/flush (with a stubbed linear.mjs — no network).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

R=$(mkrepo TrackCo)
t() { (cd "$R" && node "$TRK" "$@"); }
BOARD="$R/.autodev/board"

echo "local tracker — identity + lookup:"
A=$(t create-issue --title "Assign owner to applications" --desc "d1" --labels ai-eligible,feature)
B=$(t create-issue --title "Fix login redirect" --stage ready_for_ai_dev)
check "ids are sequential AD-n"                         test "$A" = "AD-1" -a "$B" = "AD-2"
check "counter persists across invocations"             bash -c "test \"\$(cd '$R' && node '$TRK' create-issue --title third)\" = AD-3"
check "no .tmp left behind (atomic write)"              bash -c "! ls '$BOARD'/*.tmp 2>/dev/null"
check "issue file has the full record shape"            jq -e '.id=="AD-1" and .stage=="new_request" and .labels==["ai-eligible","feature"] and (.history|length)==1 and .history[0].note=="created" and .comments==[] and .linear_id==null' "$BOARD/AD-1.json"
check "explicit --stage is honored at create"           jq -e '.stage=="ready_for_ai_dev" and .history[0].to=="ready_for_ai_dev"' "$BOARD/AD-2.json"
check_out "lookup is case-insensitive (ad-1)"           "AD-1  Assign owner" t show ad-1
check_out "lookup by unique title substring"            "AD-2  Fix login" t show "login redirect"
check_out "ambiguous title substring dies listing candidates" "ambiguous.*AD-" bash -c "cd '$R' && node '$TRK' show 'i' 2>&1; true"
check "ambiguous ref exits non-zero"                    bash -c "cd '$R' && ! node '$TRK' show 'i' >/dev/null 2>&1"
check_out "unknown ref dies clearly"                    "not found: AD-99" bash -c "cd '$R' && node '$TRK' show AD-99 2>&1; true"
check "create-issue without --title dies"               bash -c "cd '$R' && ! node '$TRK' create-issue --desc x >/dev/null 2>&1"

echo "local tracker — mutations:"
check_out "move prints the stage NAME"                  "AD-1 -> AI Development" t move AD-1 ai_development --note "dev started"
check "move records from/to/note in history"            jq -e '.stage=="ai_development" and (.history|last|.from=="new_request" and .to=="ai_development" and .note=="dev started")' "$BOARD/AD-1.json"
check "move --note also posts a comment"                jq -e '.comments|last|.body=="dev started" and .author=="autodev"' "$BOARD/AD-1.json"
check "move without --note posts no comment"            bash -c "cd '$R' && node '$TRK' move AD-1 ai_qa >/dev/null && jq -e '(.comments|length)==1' '$BOARD/AD-1.json'"
check_out "move to an unknown stage key dies"           'unknown stage key "nope"' bash -c "cd '$R' && node '$TRK' move AD-1 nope 2>&1; true"
check "unknown stage does not mutate the issue"         jq -e '.stage=="ai_qa"' "$BOARD/AD-1.json"
check_out "state-id resolves key -> name"               "^Human Review \(H\)$" t state-id ready_for_human_review
check "comment appends"                                 bash -c "cd '$R' && node '$TRK' comment AD-1 'hello **md**' >/dev/null && jq -e '.comments|last|.body==\"hello **md**\"' '$BOARD/AD-1.json'"
check_out "list-comments renders author + body"        "— autodev.*" t list-comments AD-1
check_out "list-comments on a bare issue"               "no comments" t list-comments AD-3
check "update-issue title/desc/labels"                  bash -c "cd '$R' && node '$TRK' update-issue AD-2 --title 'Fix login redirect loop' --desc 'more' --labels bug,p1 >/dev/null && jq -e '.title==\"Fix login redirect loop\" and .description==\"more\" and .labels==[\"bug\",\"p1\"]' '$BOARD/AD-2.json'"
check "update-issue --stage validates + records history" bash -c "cd '$R' && node '$TRK' update-issue AD-2 --stage blocked >/dev/null && jq -e '.stage==\"blocked\" and (.history|last|.note==\"update-issue\")' '$BOARD/AD-2.json'"
check "update-issue --stage bad key dies"               bash -c "cd '$R' && ! node '$TRK' update-issue AD-2 --stage bogus >/dev/null 2>&1"
check_out "relate defaults to blocks"                   "ok: AD-2 blocks AD-1" t relate AD-2 AD-1
check "relate --type related"                           bash -c "cd '$R' && node '$TRK' relate AD-1 AD-3 --type related >/dev/null && jq -e '.relations[0]=={type:\"related\",id:\"AD-3\"}' '$BOARD/AD-1.json'"
check "attach records url + title"                      bash -c "cd '$R' && node '$TRK' attach AD-1 https://x.test/w --title Wireframe >/dev/null && jq -e '.attachments[0]=={url:\"https://x.test/w\",title:\"Wireframe\"}' '$BOARD/AD-1.json'"
check "attach without url dies"                         bash -c "cd '$R' && ! node '$TRK' attach AD-1 >/dev/null 2>&1"
check_out "show renders relations + attachments"        "relations: related AD-3" t show AD-1
check_out "list --stage filters"                        "^AD-2" t list --stage blocked
check "list --stage excludes others"                    bash -c "cd '$R' && ! node '$TRK' list --stage blocked | grep -q AD-1"
check_out "list with no matches"                        "\(none\)" t list --stage done
check_out "board groups by stage in config order"       "■ AI QA \(1\)" t board
check "board --html writes to the given path"           bash -c "cd '$R' && node '$TRK' board --html '$R/out.html' >/dev/null && grep -q 'AD-1' '$R/out.html'"
check "board html escapes titles"                       bash -c "cd '$R' && node '$TRK' create-issue --title '<script>x</script>' >/dev/null && node '$TRK' board >/dev/null && grep -q '&lt;script&gt;' '$R/.autodev/board.html' && ! grep -q '<script>x' '$R/.autodev/board.html'"
check "create-project + create-milestone registry"      bash -c "cd '$R' && node '$TRK' create-project --name Feat >/dev/null && node '$TRK' create-milestone --project Feat --name M1 >/dev/null && jq -e '.projects[0].name==\"Feat\" and .projects[0].milestones[0].name==\"M1\"' '$BOARD/_projects.json'"
check "_projects.json is not listed as an issue"        bash -c "cd '$R' && ! node '$TRK' list | grep -q _projects"
check_out "doctor summarizes the board"                 "ok: local board · [0-9]+ issues · mirror off" t doctor
check_out "whoami names the board path"                 "local board \(" t whoami
check_out "unknown command dies"                        'unknown command "frobnicate"' bash -c "cd '$R' && node '$TRK' frobnicate 2>&1; true"
check_out "no command prints usage"                     "usage: tracker.mjs" bash -c "cd '$R' && node '$TRK' 2>&1; true"
check_out "no config anywhere dies clearly"             "no .autodev/deployment.json" bash -c "cd '$SANDBOX' && node '$TRK' list 2>&1; true"

echo "local tracker — mirror queue (tracker.mirror.linear):"
check "mirror off → no queue file written"              bash -c "! test -f '$BOARD/.mirror-queue.jsonl'"
check_out "flush-mirror with mirror off"                "mirror off" t flush-mirror
RM=$(mkrepo MirrorCo '.tracker.mirror.linear=true')
tm() { (cd "$RM" && node "$TRK" "$@"); }
tm create-issue --title "Mirrored" >/dev/null
tm move AD-1 ai_development --note "go" >/dev/null
tm move AD-1 ai_qa >/dev/null
tm comment AD-1 "note" >/dev/null
tm attach AD-1 https://x.test/a >/dev/null
QM="$RM/.autodev/board/.mirror-queue.jsonl"
check "every mutation is queued in order"               bash -c "jq -r '.op' '$QM' | tr '\n' ' ' | grep -q '^create move move comment attach $'"
check_out "doctor reports queue depth"                  "mirror ON \(5 queued\)" tm doctor

# Stub the Linear driver: copy tracker + lib next to a fake linear.mjs that logs argv.
STUB=$(mktemp -d "$SANDBOX/trk.XXXXXX"); mkdir -p "$STUB/lib"
cp "$TRK" "$STUB/tracker.mjs"; cp "$PLUGIN/scripts/lib/config.mjs" "$STUB/lib/config.mjs"
cat > "$STUB/linear.mjs" <<'EOF'
import { appendFileSync } from 'node:fs';
appendFileSync(process.env.LINEAR_STUB_LOG, process.argv.slice(2).join(' ') + '\n');
if (process.env.LINEAR_STUB_FAIL === '1') { console.error('boom'); process.exit(1); }
if (process.argv[2] === 'create-issue') console.log('LIN-77');
EOF
export LINEAR_STUB_LOG="$SANDBOX/linear-stub.log"; : > "$LINEAR_STUB_LOG"
ts() { (cd "$RM" && node "$STUB/tracker.mjs" "$@"); }
check_out "flush-mirror processes the issue"            "1 issues processed · 0 ops deferred" ts flush-mirror
check "create replayed once with [AD-1] prefix"        bash -c "grep -c '^create-issue --title \[AD-1\] Mirrored' '$LINEAR_STUB_LOG' | grep -qx 1"
check "moves coalesce to ONE final-stage move"         bash -c "grep -c '^move LIN-77' '$LINEAR_STUB_LOG' | grep -qx 1 && grep -q '^move LIN-77 ai_qa' '$LINEAR_STUB_LOG'"
check "move --note becomes a comment; comments in order" bash -c "grep '^comment' '$LINEAR_STUB_LOG' | tr '\n' '|' | grep -q '^comment LIN-77 go|comment LIN-77 note|'"
check "attach replayed"                                 grep -q '^attach LIN-77 https://x.test/a' "$LINEAR_STUB_LOG"
check "linear_id persisted on the issue"                jq -e '.linear_id=="LIN-77"' "$RM/.autodev/board/AD-1.json"
check "queue emptied after success"                     bash -c "test ! -s '$QM'"
check_out "second flush: queue empty"                   "queue empty" ts flush-mirror
tm comment AD-1 "later" >/dev/null
check_out "driver failure defers ops"                   "AD-1 deferred.*boom" env LINEAR_STUB_FAIL=1 bash -c "cd '$RM' && node '$STUB/tracker.mjs' flush-mirror 2>&1"
check "deferred ops stay queued for the next flush"     bash -c "jq -r '.op' '$QM' | grep -qx comment"
check "already-mirrored issue is not re-created on failure" bash -c "grep -c '^create-issue' '$LINEAR_STUB_LOG' | grep -qx 1"

echo "tracker facade — dispatch by tracker.kind:"
RLN=$(mkrepo LinCo '.tracker.kind="linear"')
check_out "kind=linear: list is local-only"             "local-driver only" bash -c "cd '$RLN' && node '$TRK' list 2>&1; true"
check_out "kind=linear: board is local-only"            "local-driver only" bash -c "cd '$RLN' && node '$TRK' board 2>&1; true"
check_out "kind=linear: flush-mirror is a no-op"        "nothing to mirror" bash -c "cd '$RLN' && node '$TRK' flush-mirror 2>&1"
check_out "kind=linear: other commands delegate to linear.mjs (fails on token, not dispatch)" "linear.mjs: no token" bash -c "cd '$RLN' && node '$TRK' whoami 2>&1; true"
RSC=$(mkrepo ScCo '.tracker.kind="shortcut"')
check_out "kind=shortcut delegates to shortcut.mjs"     "shortcut.mjs: no token" bash -c "cd '$RSC' && node '$TRK' whoami 2>&1; true"
RBK=$(mkrepo BadKindCo '.tracker.kind="jira"')
check_out "unknown kind dies with the valid set"        'unknown tracker.kind "jira" \(local \| linear \| shortcut\)' bash -c "cd '$RBK' && node '$TRK' list 2>&1; true"
check_out "AUTODEV_CONFIG env overrides cwd discovery"  "AD-1" bash -c "cd '$SANDBOX' && AUTODEV_CONFIG='$R/.autodev/deployment.json' node '$TRK' list"

exit $FAIL
