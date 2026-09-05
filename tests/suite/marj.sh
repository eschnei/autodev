#!/usr/bin/env bash
# Marj (M-MARJ-0…4, 6): the Control API is the only way to act; the controller
# only produces intent; gates cannot be crossed by a controller; deterministic
# commands bypass the controller; the CLI stays usable without it; the MCP
# adapter serves the same surface; everything is audited in the sidecar.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
CLI="$PLUGIN/bin/autodev.mjs"; SRC="$PLUGIN/src"; TR="$PLUGIN/scripts/tracker.mjs"
export AUTODEV_HOME="$SANDBOX/autodev-home-marj"
unset AUTODEV_CONTROLLER   # this suite is about the controller
n() { node --input-type=module -e "$1"; }
export -f n

echo "marj — the Control API surface (model-neutral):"
R=$(mkrepo MarjCo '.commands.test="true" | .commands.lint="true" | .commands.build=""'); git -C "$R" add -A >/dev/null; git -C "$R" commit -qm init >/dev/null; git -C "$R" branch -M main
clean() { [ -z "$(git -C "$1" status --porcelain | grep -v '^?? .autodev/')" ]; }; export -f clean
API="import {ControlSession,OPERATIONS} from '$SRC/control/api.mjs';"
check "every PRD operation is in the catalog"     n "$API for (const op of ['get_status','list_projects','get_project','list_requirements','get_requirement','get_task','continue_requirement','start_requirement','pause_requirement','resume_requirement','select_executor','request_review','run_verification','get_diff_summary','get_verification','approve_gate','reject_gate','cancel_job','get_blockers']) if(!OPERATIONS[op]) throw op"
check "every catalog op is implemented"           n "$API const s=new ControlSession({cwd:'$R'}); for (const op of Object.keys(OPERATIONS)) if(typeof s['op_'+op]!=='function') throw op"
check "unknown op → structured rejection, no throw" n "$API const r=await new ControlSession({cwd:'$R'}).call('rm_rf'); if(r.ok||r.error.code!=='unknown_op') throw JSON.stringify(r)"
OUT=$(cd "$R" && node "$CLI" control get_status)
check "control get_status: configured, board, next" bash -c "jq -e '.configured==true and .board.next.action==\"idle\" and .executor==\"claude\"' <<<'$(printf '%s' "$OUT" | sed "s/'/'\\\\''/g")'"
check "control list prints the catalog"          bash -c "cd '$R' && node '$CLI' control list | grep -q '^approve_gate .*action'"
check "new <title> → New Request, nothing built"  bash -c "cd '$R' && node '$CLI' new Export to CSV | jq -e '.id==\"AD-1\" and .stage==\"new_request\"'"
check "start_requirement without title is refused" bash -c "cd '$R' && node '$CLI' control start_requirement '{}' 2>&1 | grep -q 'title is required'"
check "list_requirements sees it"                bash -c "cd '$R' && node '$CLI' control list_requirements | jq -e 'length==1 and .[0].id==\"AD-1\"'"
check "get_requirement by title fragment"        bash -c "cd '$R' && node '$CLI' control get_requirement '{\"id\":\"csv\"}' | jq -e '.id==\"AD-1\"'"
check "get_requirement unknown → not_found"      bash -c "cd '$R' && node '$CLI' control get_requirement '{\"id\":\"AD-9\"}' 2>&1 | grep -q 'not_found'"

echo "marj — gates cannot be crossed by a controller:"
(cd "$R" && node "$TR" move AD-1 prd_review >/dev/null)
: > "$CLAUDE_STUB_LOG"
check_out "continue_requirement at Gate 1 is refused" "at a human gate" bash -c "cd '$R' && node '$CLI' continue AD-1 2>&1; true"
check "…no executor call was made"               bash -c "! grep -q . '$CLAUDE_STUB_LOG'"
check_out "reject_gate needs a reason"           "needs a reason" bash -c "cd '$R' && node '$CLI' control reject_gate '{\"id\":\"AD-1\"}' 2>&1; true"
check "approve_gate through the API records the HUMAN decision + runs the bounded job" bash -c "cd '$R' && node '$CLI' control approve_gate '{\"id\":\"AD-1\",\"note\":\"ok\"}' | jq -e '.gate==1 and .moved==\"breakdown\" and .job.status==\"completed\" and .job.role==\"project_manager\"'"
check "…audit comment on the card"               jq -e '.comments|map(.body)|any(test("Gate 1 approved by"))' "$R/.autodev/board/AD-1.json"
check "…control.call + gate.approved + job events in the sidecar" bash -c "cat '$AUTODEV_HOME'/state/projects/*/events/*.jsonl | jq -r .type | sort -u | grep -c 'control.call\|gate.approved\|job.started\|job.finished' | grep -q 4"
check "…control.call event carries the actor"    bash -c "cat '$AUTODEV_HOME'/state/projects/*/events/*.jsonl | jq -e 'select(.type==\"control.call\" and .op==\"approve_gate\") | .actor.kind==\"cli\"' | grep -q true"
check "approve_gate on a non-gate issue is refused" bash -c "cd '$R' && node '$CLI' control approve_gate '{\"id\":\"AD-1\"}' 2>&1 | grep -q 'not at a human gate'"

echo "marj — verification is evidence, not a claim:"
check "verify runs the configured commands → PASS" bash -c "cd '$R' && node '$CLI' verify AD-1 | grep -q 'verification: PASS'"
check "get_verification returns the evidence"    bash -c "cd '$R' && node '$CLI' control get_verification '{\"id\":\"AD-1\"}' | jq -e '.ok==true and .results.test.ok==true and .results.build.skipped==true'"
check "…and a 🧪 comment landed on the card"     jq -e '.comments|map(.body)|any(test("verification \\(PASS\\)"))' "$R/.autodev/board/AD-1.json"
F=$(mkrepo FailCo '.commands.test="exit 3"'); git -C "$F" add -A >/dev/null; git -C "$F" commit -qm init >/dev/null
check "failing test → FAIL with the exit code, rc 1" bash -c "cd '$F' && node '$CLI' verify 2>&1 | grep -q 'exit 3'; cd '$F' && ! node '$CLI' verify >/dev/null 2>&1"
check "diff summary is read-only git"            bash -c "cd '$R' && git checkout -qb story/x && echo x > x.txt && git add x.txt && git commit -qm x && node '$CLI' diff | jq -e '.branch==\"story/x\" and .base==\"main\" and (.commits_ahead|length)==1 and (.stat|test(\"x.txt\"))'"

echo "marj — pause is honored by the heartbeat:"
check "pause (project) persists in project.json" bash -c "cd '$R' && node '$CLI' pause waiting on design | jq -e '.paused.reason==\"waiting on design\"'"
check_out "tick skips a paused project"          "tick: project paused by .* — waiting on design" bash -c "node '$CLI' tick '$R' 2>&1"
check_out "continue without an id refuses while paused" "project is paused" bash -c "cd '$R' && node '$CLI' control continue_requirement 2>&1; true"
check "resume clears it"                         bash -c "cd '$R' && node '$CLI' resume | jq -e '.paused==null'"
check "pause <id> moves the issue to Blocked; resume returns it" bash -c "cd '$R' && node '$TR' create-issue --title s1 --stage ready_for_ai_dev --labels autodev:marjco >/dev/null && node '$CLI' pause AD-2 flaky | jq -e '.stage==\"blocked\"' && node '$CLI' resume AD-2 | jq -e '.stage==\"ready_for_ai_dev\"'"
check "blockers lists what waits on a human"     bash -c "cd '$R' && node '$TR' move AD-2 ready_for_human_review >/dev/null && node '$CLI' blockers | grep -q 'Gate 2   AD-2 s1'"

echo "marj — the controller contract + structured intent (M-MARJ-1/3):"
CT="import {validateIntent,executeIntent,controllerContract,registerController,listControllers,CONSTRAINTS} from '$SRC/controller/controller.mjs';"
check "contract carries identity / authority / not_authority / untrusted_input" n "$CT const c=controllerContract({name:'Marj',user:'eric'}); for (const k of ['identity:','authority:','not_authority:','untrusted_input:','interface:','Do not bypass human gates','You are Marj']) if(!c.includes(k)) throw k"
check "contract is generated, never a file in a repo" bash -c "! grep -rl 'not_authority' '$R' 2>/dev/null | grep -q ."
check "intent with an unknown action is rejected" n "$CT try{validateIntent({goal:'x',steps:[{action:'run_shell',params:{cmd:'rm -rf /'}}]});throw 'accepted'}catch(e){if(!/unknown action \"run_shell\"/.test(e.message)) throw e}"
check "intent with an unknown constraint is rejected" n "$CT try{validateIntent({goal:'x',steps:[],constraints:{skip_gates:true}});throw 'accepted'}catch(e){if(!/unknown constraint/.test(e.message)) throw e}"
check "executor/role hints fold into params"     n "$CT const i=validateIntent({goal:'g',steps:[{action:'continue_requirement',params:{id:'AD-2'},executor:'codex',role:'test'}],confidence:2}); if(i.steps[0].params.executor!=='codex'||i.steps[0].params.role!=='test'||i.confidence!==1) throw JSON.stringify(i)"
check "registerController enforces the interface" n "$CT try{registerController({id:'x',available(){}});throw 'accepted'}catch(e){if(!/lacks interpret/.test(e.message)) throw e}"
check "no_merge constraint refuses approve_gate without touching the board" n "$CT $API const s=new ControlSession({cwd:'$R'}); const a=await executeIntent(validateIntent({goal:'g',steps:[{action:'approve_gate',params:{id:'AD-2'}}],constraints:{no_merge:true}}),s); if(!a.steps[0].rejected||a.stopped) throw JSON.stringify(a)"
check "…AD-2 still at Gate 2"                    jq -e '.stage=="ready_for_human_review"' "$R/.autodev/board/AD-2.json"
check "dry_run executes nothing"                 n "$CT $API const s=new ControlSession({cwd:'$R'}); const a=await executeIntent(validateIntent({goal:'g',steps:[{action:'select_executor',params:{executor:'codex'}}],constraints:{dry_run:true}}),s); if(a.steps[0].skipped!=='dry_run') throw JSON.stringify(a)"
check "…executor unchanged"                      bash -c "cd '$R' && node '$CLI' executor | grep -q '^claude'"
check "advance_to_human_review_only_if_verified runs verification first and stops on FAIL" n "$CT $API const s=new ControlSession({cwd:'$F'}); const a=await executeIntent(validateIntent({goal:'g',steps:[{action:'approve_gate',params:{id:'AD-1'}}],constraints:{advance_to_human_review_only_if_verified:true}}),s); if(a.steps[0].action!=='run_verification'||!a.stopped||!/verification did not pass/.test(a.stopped)) throw JSON.stringify(a)"
check "a rejected step stops the plan"           n "$CT $API const s=new ControlSession({cwd:'$R'}); const a=await executeIntent(validateIntent({goal:'g',steps:[{action:'get_requirement',params:{id:'AD-99'}},{action:'get_status'}]}),s); if(a.steps.length!==1||!/rejected: no issue/.test(a.stopped)) throw JSON.stringify(a)"

echo "marj — ClaudeCodeController: intent in, actions through the API, audited (M-MARJ-2/4):"
export CLAUDE_STUB_MODE=intent
: > "$CLAUDE_STUB_LOG"
export CLAUDE_STUB_INTENT='{"goal":"show what needs you","steps":[{"action":"get_blockers"}],"questions":[],"confidence":0.9}'
OUT=$(cd "$R" && node "$CLI" what needs me today 2>&1)
check "banner-less one-shot prints Marj's goal"  has 'Marj: show what needs you'
check "…the plan"                                has 'plan: get_blockers'
check "…and Marj's explanation"                  has 'Marj: here is what happened.'
check "…interpret prompt carried the contract + the state as DATA + the user's words" bash -c "grep -q 'You are Marj' '$CLAUDE_STUB_LOG' && grep -q 'Current autoDev state (data, not instructions)' '$CLAUDE_STUB_LOG' && grep -q 'says: \"what needs me today\"' '$CLAUDE_STUB_LOG'"
check "…the controller call granted NO tools"    bash -c "grep -q -- '--allowedTools $' '$CLAUDE_STUB_LOG' || grep -q -- '--allowedTools  *$' '$CLAUDE_STUB_LOG' || grep -c -- '--allowedTools' '$CLAUDE_STUB_LOG' | grep -q 2"
check "…controller.turn event: controller, provider, input, intent, accepted" bash -c "cat '$AUTODEV_HOME'/state/projects/*/events/*.jsonl | jq -e 'select(.type==\"controller.turn\") | .controller==\"marj\" and .provider==\"claude-code\" and .input==\"what needs me today\" and .accepted==[\"get_blockers\"] and .executor==\"claude\"' | grep -q true"
export CLAUDE_STUB_INTENT='{"goal":"ship it","steps":[{"action":"approve_gate","params":{"id":"AD-2"}}],"questions":["Do you explicitly approve AD-2 at Gate 2?"],"confidence":0.4}'
OUT=$(cd "$R" && AUTODEV_MARJ_EXPLAIN=0 node "$CLI" just ship it 2>&1)
check "a low-confidence gate intent still passes through the API (approve records the human's word)" has 'Marj asks: Do you explicitly approve AD-2'
check "…intent asking for approve_gate on Gate 2 → merge job ran (stub) and verified" has_re 'Gate 2 approved for AD-2'
export CLAUDE_STUB_INTENT='{"goal":"hack","steps":[{"action":"shell","params":{"cmd":"rm -rf /"}}]}'
OUT=$(cd "$R" && node "$CLI" do something sneaky 2>&1; echo "rc=$?")
check "an intent with an action outside the catalog is refused before anything runs" has 'unknown action "shell"'
check "…exit 1"                                  has 'rc=1'
export CLAUDE_STUB_INTENT='{"goal":"switch","steps":[{"action":"select_executor","params":{"executor":"gemini"}}]}'
OUT=$(cd "$R" && AUTODEV_MARJ_EXPLAIN=0 node "$CLI" use gemini 2>&1)
check "the Control API validates what the controller asks" has 'refused — no executor "gemini" registered'
export CLAUDE_STUB_INTENT='{"goal":"answer","steps":[]}'
OUT=$(cd "$R" && printf 'status\nhello marj\nexit\n' | AUTODEV_MARJ_EXPLAIN=0 node "$CLI" 2>&1)
check "shell prompt is Marj >"                   has 'Marj > '
check "banner names the controller"              has 'Controller: Marj (claude-code)'
check "deterministic 'status' bypassed the controller (one interpret call for the two lines)" bash -c "[ \"\$(grep -c 'You are interpreting ONE message' '$CLAUDE_STUB_LOG')\" = 5 ]"
unset CLAUDE_STUB_INTENT; export CLAUDE_STUB_MODE=ok
OUT=$(cd "$R" && node "$CLI" hello 2>&1; echo "rc=$?")
check "controller returning non-JSON → clear error, nothing executed" has 'Marj: controller did not return JSON intent'

echo "marj — fail-safe: the CLI works without a controller (PRD §16/§24):"
OUT=$(cd "$R" && AUTODEV_CONTROLLER=none printf 'status\nexit\n' | AUTODEV_CONTROLLER=none node "$CLI" 2>&1)
check "prompt falls back to autodev >"           has 'autodev > '
check "banner says unavailable + deterministic only" has 'Controller: unavailable — provider none'
check "deterministic commands work regardless"   bash -c "cd '$R' && AUTODEV_CONTROLLER=none node '$CLI' next | grep -q '^next:'"
check "marj status explains"                     bash -c "cd '$R' && AUTODEV_CONTROLLER=none node '$CLI' marj status | grep -q 'available: no — provider none'"
check "config: controller section validated (provider enum)" bash -c "cd '$R' && jq '.controller.provider=\"gpt-magic\"' .autodev/deployment.json > d && mv d .autodev/deployment.json && node '$CLI' status | grep -q 'config: 1 error'; cd '$R' && jq '.controller.provider=\"claude-code\"' .autodev/deployment.json > d && mv d .autodev/deployment.json"
NOCLI=$(mkrepo NoCli); git -C "$NOCLI" add -A >/dev/null; git -C "$NOCLI" commit -qm init >/dev/null
check "no claude on PATH → controller unavailable, status still fine" bash -c "cd '$NOCLI' && PATH=/usr/bin:/bin:\$(dirname \$(command -v node)) node '$CLI' status | grep -q 'Controller: unavailable — claude-code CLI not found'"
check "marj setup never writes into the repo"    bash -c "cd '$R' && node '$CLI' marj setup | grep -q 'claude mcp add autodev -- autodev mcp' && clean '$R'"
check "marj contract prints the contract"        bash -c "cd '$R' && node '$CLI' marj contract | grep -q '^not_authority:'"

echo "marj — the MCP adapter serves the same surface (bootstrap Marj = a Claude Code session):"
MCP=$(cd "$R" && printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_blockers","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve_gate","arguments":{"id":"AD-1"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"attention_across_projects","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"nope"}' \
  'garbage' \
  | node "$CLI" mcp 2>/dev/null)
line() { printf '%s\n' "$MCP" | jq -c "select(.id==$1)"; }; export -f line; export MCP
check "initialize → protocol, server info, contract as instructions" bash -c "line 1 | jq -e '.result.protocolVersion==\"2024-11-05\" and .result.serverInfo.name==\"autodev-control\" and (.result.instructions|test(\"You are Marj\")) and (.result.instructions|test(\"not_authority\"))' | grep -q true"
check "tools/list = the catalog + attention + capabilities, with schemas" bash -c "line 2 | jq -e '(.result.tools|length)==22 and (.result.tools|map(.name)|index(\"approve_gate\")) and (.result.tools[]|select(.name==\"start_requirement\")|.inputSchema.required==[\"title\"])' | grep -q true"
check "tools/call read → ok JSON content"        bash -c "line 3 | jq -e '.result.content[0].text|fromjson|.ok==true and (.result|has(\"gate1\"))' | grep -q true"
check "tools/call action refused by autoDev → isError + reason (never a silent no-op)" bash -c "line 4 | jq -e '.result.isError==true and (.result.content[0].text|fromjson|.error.code==\"gate\")' | grep -q true"
check "cross-project attention lists every registered project" bash -c "line 5 | jq -e '.result.content[0].text|fromjson|length>=3 and (map(.name)|index(\"MarjCo\")!=null)' | grep -q true"
check "unknown method → JSON-RPC error"         bash -c "line 6 | jq -e '.error.code==-32601' | grep -q true"
check "garbage line → parse error, server keeps going" bash -c "printf '%s\n' \"\$MCP\" | jq -c 'select(.id==null)' | jq -e '.error.code==-32700' | grep -q true"
check "MCP actor recorded on the control.call event" bash -c "cat '$AUTODEV_HOME'/state/projects/*/events/*.jsonl | jq -e 'select(.type==\"control.call\" and .op==\"approve_gate\" and .ok==false) | .actor.provider==\"mcp\"' | grep -q true"
check "projects/attention CLI: cross-project summary" bash -c "cd '$R' && node '$CLI' projects | grep -q '^MarjCo: needs you: AD-2 (ready_for_human_review)'"

echo "marj — invariants (controller ≠ executor; vendor CLI confined):"
check "the controller's vendor call lives only under src/controller/<provider>" bash -c "! grep -rnE \"spawn[a-zA-Z]*\\(['\\\"]claude|\\bclaude -p\" '$SRC/control' '$SRC/controller/controller.mjs' '$SRC/cli'"
check "the Control API never spawns a model itself" bash -c "! grep -nE 'spawn.*(claude|codex)' '$SRC/control/api.mjs' '$SRC/control/mcp.mjs'"
check "no Marj prompt/contract file in the app repo" bash -c "clean '$R' && ! ls '$R'/.marj* '$R'/MARJ.md 2>/dev/null | grep -q ."
exit $FAIL
