#!/usr/bin/env bash
# Milestone 13 — autoDev is a Brain client. Against a stub Brain (tests/fixtures/
# brain-stub.mjs) that speaks the /v1 contract and logs every request: negotiation,
# token resolution, sidecar registration, context in front of jobs with provenance,
# handoffs after jobs (idempotent by job id), gate decisions, and DEGRADED mode.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
CLI="$PLUGIN/bin/autodev.mjs"
STUB="$PLUGIN/tests/fixtures/brain-stub.mjs"
export AUTODEV_HOME="$SANDBOX/autodev-home-brain"
export AUTODEV_NO_KEYCHAIN=1
export BRAIN_STUB_LOG="$SANDBOX/brain-requests.jsonl"
n() { node --input-type=module -e "$1"; }

start_stub() { # [api-version]
  : > "$BRAIN_STUB_LOG"
  BRAIN_STUB_API="${1:-1.0.0}" node "$STUB" > "$SANDBOX/stub.port" 2>/dev/null & STUB_PID=$!
  for _ in $(seq 50); do [[ -s "$SANDBOX/stub.port" ]] && break; sleep 0.05; done
  STUB_URL="http://127.0.0.1:$(cat "$SANDBOX/stub.port")"
}
stop_stub() { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; true; }
reqs() { cat "$BRAIN_STUB_LOG" 2>/dev/null; }
export -f reqs

echo "client — negotiation + token resolution:"
start_stub
C="import {BrainClient,satisfies,resolveToken,BrainIncompatible,BrainUnreachable} from '$SRC/brain/client.mjs';"
check "satisfies: >=1.0.0 <2.0.0"                    n "$C for(const [v,e] of [['1.0.0',true],['1.9.3',true],['2.0.0',false],['0.9.9',false]]) if(satisfies(v,'>=1.0.0 <2.0.0')!==e) throw v"
check "connect negotiates + exposes capabilities"    n "$C const c=new BrainClient({url:'$STUB_URL',token:'stub-token'}); const i=await c.connect(); if(i.api!=='1.0.0'||!c.has('handoffs')) throw JSON.stringify(i)"
check "unreachable → BrainUnreachable (no hang: 5s timeout)" n "$C const c=new BrainClient({url:'http://127.0.0.1:1',token:'x',timeoutMs:500}); try { await c.connect(); throw new Error('no throw') } catch(e){ if(!(e instanceof BrainUnreachable)) throw e }"
check "resolveToken: env wins"                        n "$C process.env.BRAIN_TOKEN='from-env'; const t=resolveToken(process.env); if(t.token!=='from-env'||t.source!=='env') throw JSON.stringify(t)"
mkdir -p "$HOME/.config/autodev"; printf 'from-file extra-fields\n' > "$HOME/.config/autodev/brain.token"
check "resolveToken: ~/.config/autodev/brain.token (first field)" n "$C delete process.env.BRAIN_TOKEN; const t=resolveToken({...process.env,BRAIN_TOKEN:undefined}); if(t.token!=='from-file'||!t.source.endsWith('brain.token')) throw JSON.stringify(t)"
rm -f "$HOME/.config/autodev/brain.token"
check "resolveToken: nothing → null (keychain disabled in tests)" n "$C const t=resolveToken({HOME:process.env.HOME,AUTODEV_NO_KEYCHAIN:'1'}); if(t.token!==null) throw JSON.stringify(t)"
check "writes carry X-Brain-Client + Idempotency-Key" n "$C const c=new BrainClient({url:'$STUB_URL',token:'stub-token',clientId:'Eric-MacBook-autoDev'}); await c.handoff({project_id:'p',summary:'s'},{idempotencyKey:'job_1'}); const r=await c.handoff({project_id:'p',summary:'s'},{idempotencyKey:'job_1'}); if(!r.replayed) throw 'not replayed'"
check "…as the stub saw them"                          bash -c "reqs | grep -c '\"idem\":\"job_1\"' | grep -qx 2 && reqs | grep -q '\"client\":\"Eric-MacBook-autoDev\"'"
check "bad token → 401 error with code"               n "$C const c=new BrainClient({url:'$STUB_URL',token:'wrong'}); try { await c.handoff({project_id:'p',summary:'s'}); throw new Error('no throw') } catch(e){ if(e.status!==401||e.code!=='unauthorized') throw e }"
stop_stub

echo "integration — not configured (brain.enabled=false) → no Brain calls, v2 behavior:"
start_stub
R0=$(mkrepo OffCo); git -C "$R0" add -A >/dev/null; git -C "$R0" commit -qm init >/dev/null
: > "$CLAUDE_STUB_LOG"
check_out "banner: Brain not configured"              "Brain: not configured" bash -c "cd '$R0' && BRAIN_TOKEN=stub-token node '$CLI' status"
check "a job runs with no Brain request at all"       bash -c "cd '$R0' && BRAIN_TOKEN=stub-token node '$CLI' hello >/dev/null && ! grep -q . '$BRAIN_STUB_LOG' && ! grep -q 'Brain context' '$CLAUDE_STUB_LOG'"
check_out "autodev brain status → not configured, exit 0" "Brain: not configured" bash -c "cd '$R0' && node '$CLI' brain status"
stop_stub

echo "integration — connected:"
start_stub
R=$(mkrepo BrainCo ".brain.enabled=true | .brain.url=\"$STUB_URL\" | .commands.test=\"npm test\""); git -C "$R" add -A >/dev/null; git -C "$R" commit -qm init >/dev/null
export BRAIN_TOKEN=stub-token
OUT=$(cd "$R" && node "$CLI" status 2>&1)
check "banner: connected with api + the registered prj_ id" has_re 'Brain: connected \(http://127.0.0.1:[0-9]+ · api 1.0.0 · prj_'
check "project registered in Brain by key, repository registered" bash -c "reqs | grep -q '\"path\":\"/v1/projects\",.*\"key\":\"braincoslug\"' || reqs | grep -qE '\"method\":\"POST\",\"path\":\"/v1/projects\"' && reqs | grep -qE '\"path\":\"/v1/projects/prj_[^/]+/repositories\"'"
check "…the Brain project id is stored in the SIDECAR project.json, not the repo" bash -c "id=\$(grep 'Project:' <<<\"\$0\" | grep -oE 'prj_[0-9A-Z]{26}' | head -1); jq -e '.brain.enabled==true and (.brain.project_id|startswith(\"prj_\"))' \"$AUTODEV_HOME/state/projects/\$id/project.json\" && [ -z \"\$(git -C '$R' status --porcelain)\" ]" "$OUT"
: > "$BRAIN_STUB_LOG"
OUT=$(cd "$R" && node "$CLI" status 2>&1)
check "second run: no re-registration (GET by id only)" bash -c "! reqs | grep -q '\"method\":\"POST\",\"path\":\"/v1/projects\"'"
: > "$BRAIN_STUB_LOG"; : > "$CLAUDE_STUB_LOG"
OUT=$(cd "$R" && node "$CLI" what is next 2>&1); rc=$?
check "a job: context fetched BEFORE the executor ran"  bash -c "reqs | grep -q '\"path\":\"/v1/context\"' && [ \$(reqs | grep -n '/v1/context' | head -1 | cut -d: -f1) -lt \$(reqs | grep -n '/v1/handoffs' | head -1 | cut -d: -f1) ]"
check "…context request names executor + role + branch" bash -c "reqs | grep '/v1/context' | jq -e '.body.executor==\"claude\" and .body.role==\"concierge\" and (.body.branch|type)==\"string\"'"
check "…the executor's prompt starts with the Brain context (rules + failures) then the task" bash -c "grep -q '## Brain context (ctx_' '$CLAUDE_STUB_LOG' && grep -q 'workflow state machine' '$CLAUDE_STUB_LOG' && grep -q 'Known failures' '$CLAUDE_STUB_LOG' && grep -q -- '--- what is next' \"\$(echo '$CLAUDE_STUB_LOG')\" || (tr '\n' ' ' < '$CLAUDE_STUB_LOG' | grep -q -- '---  what is next --output-format json')"
check "…a handoff recorded AFTER the job, idempotent by job id, naming the executor + bundle" bash -c "reqs | grep '/v1/handoffs' | jq -e '(.idem|startswith(\"job_\")) and .body.executor==\"claude\" and .body.summary==\"ok\" and (.body.payload.context_bundle_id|startswith(\"ctx_\")) and .body.payload.status==\"completed\"'"
check "…provenance event in the sidecar: bundle id + memory revisions" bash -c "id=\$(cd '$R' && node '$CLI' status 2>/dev/null | grep -oE 'prj_[0-9A-Z]{26}' | head -1); cat \"$AUTODEV_HOME/state/projects/\$id/events/\"*.jsonl | jq -e 'select(.type==\"brain.context.supplied\") | (.context_bundle_id|startswith(\"ctx_\")) and (.memories|length)==2 and (.memories[0].revision|type)==\"number\"' | grep -q true"
check "…handoff event recorded"                         bash -c "id=\$(cd '$R' && node '$CLI' status 2>/dev/null | grep -oE 'prj_[0-9A-Z]{26}' | head -1); cat \"$AUTODEV_HOME/state/projects/\$id/events/\"*.jsonl | grep -q '\"type\":\"brain.handoff.recorded\"'"
(cd "$R" && node "$TRK" create-issue --title "Feature X" --stage prd_review --labels "route:feature,autodev:brainco" >/dev/null)
: > "$BRAIN_STUB_LOG"
check "gate approval → a decision in Brain (human provenance, idempotent by event id)" bash -c "cd '$R' && node '$CLI' approve AD-1 ship it >/dev/null 2>&1; reqs | grep '/v1/decisions' | jq -e '(.idem|startswith(\"evt_\")) and (.body.title|test(\"Gate 1 approved: AD-1\")) and (.body.decision|test(\"ship it\"))'"
check "…the breakdown job also got Brain context + a handoff" bash -c "reqs | grep -c '/v1/context' | grep -qx 1 && reqs | grep -c '/v1/handoffs' | grep -qx 1"
check_out "autodev brain status"                        "Brain: connected .* · token from env · caps" bash -c "cd '$R' && node '$CLI' brain status"
check_out "autodev brain context renders the bundle"    "## Brain context \(ctx_" bash -c "cd '$R' && node '$CLI' brain context"
check_out "autodev brain search"                        "workflow state machine" bash -c "cd '$R' && node '$CLI' brain search tracker"
check "autodev tick (headless) also uses Brain: context + handoff" bash -c ": > '$BRAIN_STUB_LOG'; node '$CLI' tick '$R' 2>/dev/null; reqs | grep -q '/v1/context' && reqs | grep '/v1/handoffs' | jq -e '.body.payload.role==\"loop\"' >/dev/null"
stop_stub

echo "integration — degraded + incompatible (Brain optional; never a crash):"
: > "$CLAUDE_STUB_LOG"
OUT=$(cd "$R" && node "$CLI" status 2>&1); rc=$?
check "Brain down → banner says DEGRADED, status still exits 0" bash -c "[ $rc -eq 0 ] && grep -q 'Brain: DEGRADED — Brain at http://127.0.0.1' <<<\"\$0\"" "$OUT"
check "…a job still runs, without Brain context, no crash" bash -c "cd '$R' && node '$CLI' hello >/dev/null 2>&1; grep -q -- '-p hello' '$CLAUDE_STUB_LOG' && ! grep -q 'Brain context' '$CLAUDE_STUB_LOG'"
check "…tick still runs in degraded mode"              bash -c "node '$CLI' tick '$R' 2>&1 | grep -q 'brain DEGRADED' && grep -q -- '/autodev:loop' '$CLAUDE_STUB_LOG'"
check "autodev brain status → exit 1 when degraded"    bash -c "cd '$R' && ! node '$CLI' brain status >/dev/null 2>&1"
check_out "no token → degraded with the three places to put one" "DEGRADED — no token" bash -c "cd '$R' && BRAIN_TOKEN= node '$CLI' status"
start_stub 2.3.0
R2=$(mkrepo IncCo ".brain.enabled=true | .brain.url=\"$STUB_URL\""); git -C "$R2" add -A >/dev/null; git -C "$R2" commit -qm init >/dev/null
check_out "incompatible Brain → INCOMPATIBLE with required/detected, never misread" "Brain: INCOMPATIBLE — Brain connected but incompatible. Required: >=1.0.0 <2.0.0. Detected: 2.3.0" bash -c "cd '$R2' && node '$CLI' status"
check "…no writes were attempted against it"           bash -c "! reqs | grep -qE '\"method\":\"POST\"'"
stop_stub
check "no vendor CLI / no SQLite in autoDev's Brain layer (public API only)" bash -c "! grep -rniE 'sqlite|brain\\.db|spawn.*claude' '$SRC/brain'"
check "the application repo never received Brain files" bash -c "! test -e '$R/.brain' && ! test -e '$R/CLAUDE.md' && ! git -C '$R' status --porcelain | grep -v '^?? .autodev/board' | grep -q ."

exit $FAIL
