#!/usr/bin/env bash
# Milestone 8 — autoDev owns the state machine. Workflow state, story selection,
# and the two human gates are decided by core with no LLM; the model gets a
# bounded job afterwards and core verifies the outcome.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
export AUTODEV_HOME="$SANDBOX/autodev-home-workflow"
CLI="$PLUGIN/bin/autodev.mjs"
n() { node --input-type=module -e "$1"; }

R=$(mkrepo FlowCo '.tracker.instance_label="autodev:flowco" | .execution.max_lanes=2 | .commands.test="npm test"')
git -C "$R" add -A >/dev/null; git -C "$R" commit -qm init >/dev/null
t() { (cd "$R" && node "$TRK" "$@" >/dev/null); }
L="autodev:flowco"
# a feature at Gate 1, stories in various states, a foreign ticket, a blocked chain
t create-issue --title "Feature: ownership" --stage prd_review --labels "route:feature,$L"                 # AD-1  Gate 1
t create-issue --title "story A" --stage ready_for_ai_dev --labels "ai-eligible,$L"                        # AD-2  eligible
t create-issue --title "story B (blocked by A)" --stage ready_for_ai_dev --labels "ai-eligible,$L"          # AD-3  blocked by AD-2
t relate AD-2 AD-3 --type blocks
t create-issue --title "story C no label" --stage ready_for_ai_dev --labels "$L"                           # AD-4  not ai-eligible
t create-issue --title "foreign ticket" --stage ready_for_ai_dev --labels "ai-eligible"                    # AD-5  other lane
t create-issue --title "story D in review" --stage ready_for_human_review --labels "ai-eligible,$L"        # AD-6  Gate 2
t create-issue --title "story E stuck" --stage blocked --labels "ai-eligible,$L"                           # AD-7  blocked
t create-issue --title "story F building" --stage ai_development --labels "ai-eligible,$L" --desc $'Touched files:\n- src/auth.js\n- src/db.js\n\nmore'   # AD-8 in flight
t create-issue --title "story G overlaps F" --stage ready_for_ai_dev --labels "ai-eligible,$L" --desc $'Touched files:\n- src/db.js\n'                    # AD-9 overlaps
t create-issue --title "story H done dep" --stage done --labels "$L"                                       # AD-10
t create-issue --title "story I dep done" --stage ready_for_ai_dev --labels "ai-eligible,$L"               # AD-11 blocked by done AD-10 → eligible
t relate AD-10 AD-11 --type blocks

WJS="import {Tracker} from '$SRC/core/tracker.mjs'; import {readWorkflowState,nextAction,eligibleStories,touchedFiles,blockersOf} from '$SRC/core/workflow/state.mjs'; import {readFileSync} from 'node:fs'; const cfg=JSON.parse(readFileSync('$R/.autodev/deployment.json','utf8')); const tr=new Tracker({repoRoot:'$R',configPath:'$R/.autodev/deployment.json',cfg}); const st=readWorkflowState(tr,cfg);"

echo "workflow state — computed from the board, no model:"
check "gates: AD-1 at Gate 1, AD-6 at Gate 2"          n "$WJS if(st.gates.gate1.map(i=>i.id).join()!=='AD-1'||st.gates.gate2.map(i=>i.id).join()!=='AD-6') throw JSON.stringify(st.gates)"
check "blocked + in-flight"                            n "$WJS if(st.blocked[0].id!=='AD-7'||st.in_flight.map(i=>i.id).join()!=='AD-8') throw 'x'"
check "own lane: the foreign ticket is invisible"      n "$WJS if(st.foreign!==1||st.total!==11) throw st.foreign+'/'+st.total; if(st.eligible.some(i=>i.id==='AD-5')) throw 'foreign selected'"
check "eligible = ai-eligible ∧ blockers done ∧ no file overlap, oldest first" n "$WJS const e=st.eligible.map(i=>i.id).join(); if(e!=='AD-2,AD-11') throw e"
check "…AD-3 excluded: blocked by AD-2 (not done)"    n "$WJS if(blockersOf(tr.issue('AD-3'),tr.readIssues()).map(b=>b.id).join()!=='AD-2') throw 'blockers'"
check "…AD-4 excluded: no ai-eligible label"          n "$WJS if(st.eligible.some(i=>i.id==='AD-4')) throw 'AD-4'"
check "…AD-9 excluded: touches src/db.js like in-flight AD-8" n "$WJS if(touchedFiles(tr.issue('AD-8')).join()!=='src/auth.js,src/db.js') throw touchedFiles(tr.issue('AD-8')); if(st.eligible.some(i=>i.id==='AD-9')) throw 'AD-9'"
check "…the feature issue is never a story"           n "$WJS if(st.eligible.some(i=>i.id==='AD-1')) throw 'feature'"
check "awaiting_human = gates + blocked + clarifying"  n "$WJS if(st.awaiting_human.map(i=>i.id).join()!=='AD-1,AD-6,AD-7') throw st.awaiting_human.map(i=>i.id)"
check "counts per stage"                               n "$WJS if(st.counts.ready_for_ai_dev!==5||st.counts.done!==1) throw JSON.stringify(st.counts)"

echo "next action — loop.md's decision order, explicit:"
check "eligible + a free lane → develop (respects max_lanes)" n "$WJS const nx=nextAction(st,cfg); if(nx.action!=='develop'||nx.issues.join()!=='AD-2') throw JSON.stringify(nx)"
check "lanes full → wait"                              n "$WJS const c2={...cfg,execution:{...cfg.execution,max_lanes:1}}; const nx=nextAction(st,c2); if(nx.action!=='wait') throw JSON.stringify(nx)"
check "an issue in breakdown preempts everything"      n "$WJS const st2={...st,breakdown:[{id:'AD-1'}]}; const nx=nextAction(st2,cfg); if(nx.action!=='breakdown'||nx.issues.join()!=='AD-1') throw JSON.stringify(nx)"
check "nothing eligible, nothing in flight, gates pending → await_human" n "$WJS const st2={...st,eligible:[],in_flight:[]}; const nx=nextAction(st2,cfg); if(nx.action!=='await_human'||!nx.issues.includes('AD-6')) throw JSON.stringify(nx)"
check "empty board → idle"                             n "$WJS const st2={...st,eligible:[],in_flight:[],awaiting_human:[],breakdown:[]}; if(nextAction(st2,cfg).action!=='idle') throw 'idle'"

echo "gates — deterministic approval / rejection with audit trail:"
GJS="import {Tracker} from '$SRC/core/tracker.mjs'; import {approve,reject,gateOf,jobFor} from '$SRC/core/workflow/gates.mjs'; import {readEvents} from '$SRC/core/events.mjs'; import {readFileSync} from 'node:fs'; const cfg=JSON.parse(readFileSync('$R/.autodev/deployment.json','utf8')); const tr=new Tracker({repoRoot:'$R',configPath:'$R/.autodev/deployment.json',cfg}); const P='prj_01J0000000000000000000GATE';"
check "gateOf: prd_review=1, review/acceptance=2, else null" n "$GJS if(gateOf(tr.issue('AD-1'))!==1||gateOf(tr.issue('AD-6'))!==2||gateOf(tr.issue('AD-2'))!==null) throw 'gateOf'"
check "approve at Gate 1 → moves to breakdown, audit comment, next=breakdown" n "$GJS const d=approve({tracker:tr,projectId:P,issueId:'AD-1',by:'eric',note:'ship it'}); const i=tr.issue('AD-1'); if(d.gate!==1||d.next!=='breakdown'||i.stage!=='breakdown'||!i.comments.at(-1).body.includes('Gate 1 approved by eric via autodev CLI')||!i.comments.at(-1).body.includes('ship it')) throw JSON.stringify([d,i])"
check "…event appended with a stable evt_ id"          n "$GJS const ev=readEvents(P,{type:'gate.approved'}); if(ev.length!==1||!ev[0].id.startsWith('evt_')||ev[0].issue!=='AD-1'||ev[0].from!=='prd_review'||ev[0].to!=='breakdown') throw JSON.stringify(ev)"
check "approve at Gate 2 → comment only, stage unchanged, next=merge_story" n "$GJS const d=approve({tracker:tr,projectId:P,issueId:'AD-6',by:'eric'}); const i=tr.issue('AD-6'); if(d.gate!==2||d.next!=='merge_story'||d.moved!==null||i.stage!=='ready_for_human_review'||!i.comments.at(-1).body.includes('Gate 2 approved')) throw JSON.stringify([d,i])"
check "approve at acceptance → next=ship_feature"      n "$GJS tr.move('AD-4','ready_for_human_acceptance'); const d=approve({tracker:tr,projectId:P,issueId:'AD-4'}); if(d.next!=='ship_feature') throw d.next"
check "approve off-gate → GateError, nothing changes"  n "$GJS const before=JSON.stringify(tr.issue('AD-2')); try { approve({tracker:tr,projectId:P,issueId:'AD-2'}); throw new Error('no throw') } catch(e){ if(e.constructor.name!=='GateError'||!/not at a human gate/.test(e.message)) throw e } if(JSON.stringify(tr.issue('AD-2'))!==before) throw 'mutated'"
check "approve unknown → GateError"                    n "$GJS try { approve({tracker:tr,projectId:P,issueId:'AD-99'}); throw new Error('no throw') } catch(e){ if(!/not found/.test(e.message)) throw e }"
check "reject at Gate 2 → back to ai_development with the reason" n "$GJS const d=reject({tracker:tr,projectId:P,issueId:'AD-6',by:'eric',reason:'login loops'}); const i=tr.issue('AD-6'); if(d.moved!=='ai_development'||i.stage!=='ai_development'||!i.comments.at(-1).body.includes('rejected by eric')||!i.comments.at(-1).body.includes('login loops')) throw JSON.stringify([d,i])"
check "reject needs a reason"                          n "$GJS try { reject({tracker:tr,projectId:P,issueId:'AD-6'}); throw new Error('no throw') } catch(e){ if(!/needs a reason/.test(e.message)) throw e }"
check "events are per project, filterable"             n "$GJS const ev=readEvents(P); if(ev.length!==4||readEvents(P,{issue:'AD-6'}).length!==2||readEvents('prj_01J000000000000000000OTHER').length!==0) throw ev.length"
check "jobFor: breakdown job is bounded and names the issue" n "$GJS const j=jobFor('breakdown','AD-1',cfg); if(j.role!=='project_manager'||!j.task.includes('AD-1')||!j.task.includes('Do not ask for approval again')||!j.task.includes('reference/breakdown.md')) throw j.task"
check "jobFor: merge job forbids the default branch + demands merge-verify" n "$GJS const j=jobFor('merge_story','AD-6',cfg); if(j.role!=='implementation'||!j.task.includes('merge-verify.md')||!j.task.includes('Never touch main')) throw j.task"
check "jobFor: unknown → GateError"                    n "$GJS try { jobFor('teleport','AD-1',cfg); throw new Error('no throw') } catch(e){ if(e.constructor.name!=='GateError') throw e }"

echo "cli — approve / reject / next are deterministic on a local board:"
R2=$(mkrepo CliFlow '.commands.test="npm test"'); git -C "$R2" add -A >/dev/null; git -C "$R2" commit -qm init >/dev/null
(cd "$R2" && node "$TRK" create-issue --title "Feature X" --stage prd_review --labels "route:feature,autodev:cliflow" >/dev/null && node "$TRK" create-issue --title "story" --stage ready_for_human_review --labels "ai-eligible,autodev:cliflow" >/dev/null)
: > "$CLAUDE_STUB_LOG"
OUT=$(cd "$R2" && node "$CLI" approve AD-1 looks good 2>&1)
check "approve AD-1: recorded by core BEFORE any model call" has_re 'recorded: Gate 1 approved for AD-1 → breakdown \(event evt_'
check "…the board shows it (stage + audit comment)"    bash -c "jq -e '.stage==\"breakdown\" and (.comments|last|.body|test(\"Gate 1 approved\"))' '$R2/.autodev/board/AD-1.json'"
check "…then ONE bounded breakdown job went to the executor (not the old prose prompt)" bash -c "grep -c -- '^-p ' '$CLAUDE_STUB_LOG' | grep -qx 1 && grep -q 'run the breakdown for AD-1 per reference/breakdown.md' '$CLAUDE_STUB_LOG' && ! grep -q 'The operator approved' '$CLAUDE_STUB_LOG'"
check "…verification line after the job"              has_re 'verify: [0-9]+ story\(ies\) now Ready for AI Dev'
check "…event recorded under the sidecar project"      bash -c "id=\$(cd '$R2' && node '$CLI' status | grep -oE 'prj_[0-9A-Z]{26}'); cat \"$AUTODEV_HOME/projects/\$id/events/\"*.jsonl | grep -q '\"type\":\"gate.approved\"'"
: > "$CLAUDE_STUB_LOG"
OUT=$(cd "$R2" && node "$CLI" approve AD-2 2>&1); rc=$?
check "approve at Gate 2: recorded, merge job dispatched, verify FAILS honestly (stub merged nothing)" bash -c "grep -q 'recorded: Gate 2 approved for AD-2' <<<\"\$0\" && grep -q 'job → claude: merge_story' <<<\"\$0\" && grep -q 'verify: AD-2 is in \"ready_for_human_review\", expected \"done\"' <<<\"\$0\"" "$OUT"
check "…the model's say-so is not trusted: still not done" bash -c "jq -e '.stage==\"ready_for_human_review\"' '$R2/.autodev/board/AD-2.json'"
check_out "approve off-gate → clear error, exit 1"    "not at a human gate" bash -c "cd '$R2' && node '$CLI' approve AD-1 2>&1; true"
check "…exit 1"                                        bash -c "cd '$R2' && ! node '$CLI' approve AD-1 >/dev/null 2>&1"
check_out "reject AD-2 with reason → ai_development"  "recorded: Gate 2 rejected for AD-2 → ai_development" bash -c "cd '$R2' && node '$CLI' reject AD-2 the redirect loops"
check "…board reflects it"                             bash -c "jq -e '.stage==\"ai_development\" and (.comments|last|.body|test(\"the redirect loops\"))' '$R2/.autodev/board/AD-2.json'"
check_out "reject without a reason → usage, exit 2"   "usage: autodev reject" bash -c "cd '$R2' && node '$CLI' reject AD-2 2>&1; true"
: > "$CLAUDE_STUB_LOG"
check_out "next: decided without a model"              "next: (breakdown|wait|develop|await_human|idle)" bash -c "cd '$R2' && node '$CLI' next"
check "…no executor call for next"                     bash -c "! grep -q . '$CLAUDE_STUB_LOG'"
check_out "next: breakdown preempts (AD-1 awaits decomposition)" "next: breakdown \(AD-1\)" bash -c "cd '$R2' && node '$CLI' next"
check_out "status shows 'Awaiting you' from the same state" "Awaiting you: Gate 2 AD-4 · Blocked AD-7" bash -c "cd '$R' && node '$CLI' status"
check "no vendor CLI in core/workflow"                 bash -c "! grep -rniE 'claude|codex' '$SRC/core/workflow' '$SRC/core/events.mjs'"

exit $FAIL
