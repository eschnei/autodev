#!/usr/bin/env bash
# Milestone 5 — one authoritative config schema. The example config, the local
# example, upgrade-config.sh, and doctor all agree with src/core/config/schema.mjs.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
EX="$PLUGIN/reference/deployment.example.json"
LEX="$PLUGIN/reference/deployment.local.example.json"
CFGBIN="$PLUGIN/bin/autodev-config.mjs"
n() { node --input-type=module -e "$1"; }

echo "schema ↔ example parity (the example is derived from the schema):"
check "every non-note leaf in the example is declared by the schema" n "
  import {leafPaths} from '$SRC/core/config/schema.mjs'; import {readFileSync} from 'node:fs';
  const ex=JSON.parse(readFileSync('$EX','utf8')); const declared=new Set(leafPaths());
  const leaves=[]; (function walk(v,p){ if(v&&typeof v==='object'&&!Array.isArray(v)){ for(const [k,x] of Object.entries(v)){ if(k.startsWith('_')) continue; walk(x,[...p,k]); } } else leaves.push(p); })(ex,[]);
  // a leaf is declared if its path, or a prefix of it (array/map field), is a schema leaf
  const undeclared=leaves.filter(p=>!p.some((_,i)=>declared.has(p.slice(0,i+1).join('.'))));
  if(undeclared.length) throw new Error('undeclared in schema: '+undeclared.map(p=>p.join('.')).join(', '))"
check "every non-identity, non-local schema default equals the example's value" n "
  import {walk,SCHEMA} from '$SRC/core/config/schema.mjs'; import {readFileSync} from 'node:fs';
  const ex=JSON.parse(readFileSync('$EX','utf8')); const bad=[];
  walk(SCHEMA,(p,f)=>{ if(f.identity||f.local||f.default===undefined) return; let v=ex; for(const k of p){ v=v?.[k]; }
    if(JSON.stringify(v)!==JSON.stringify(f.default)) bad.push(p.join('.')+' example='+JSON.stringify(v)+' schema='+JSON.stringify(f.default)); });
  if(bad.length) throw new Error(bad.join('; '))"
check "identity fields in the example are declared identity (never copied by upgrade)" n "
  import {walk,SCHEMA} from '$SRC/core/config/schema.mjs';
  const must=['client_name','assistant_name','repo.default_branch','commands.test','tracker.instance_label','tracker.team_id','personas.dev_routing','qa.hermetic.env'];
  const idents=new Set(); walk(SCHEMA,(p,f)=>{ if(f.identity) idents.add(p.join('.')); });
  // an object marked identity marks its subtree
  const isIdent=(path)=>[...idents].some(i=>path===i||path.startsWith(i+'.'));
  for(const m of must) if(!isIdent(m)) throw new Error(m+' should be identity')"
check "local-only fields match the loader's LOCAL_ONLY_PATHS + the local example" n "
  import {walk,SCHEMA} from '$SRC/core/config/schema.mjs'; import {readFileSync} from 'node:fs';
  const lex=JSON.parse(readFileSync('$LEX','utf8')); const local=new Set(); walk(SCHEMA,(p,f)=>{ if(f.local) local.add(p.join('.')); });
  for(const p of ['repo.local_path','runner.home_dir','runner.heartbeat_file','runner.rate_limited_file','runner.logs_dir','tracker.linear.api_token_file','tracker.shortcut.api_token_file']) if(!local.has(p)) throw new Error(p+' should be local');
  const leaves=[]; (function w(v,p){ if(v&&typeof v==='object'){ for(const [k,x] of Object.entries(v)){ if(k.startsWith('_')) continue; w(x,[...p,k]); } } else leaves.push(p.join('.')); })(lex,[]);
  for(const l of leaves) if(!local.has(l) && l!=='tracker.instance_label') throw new Error('local example leaf not declared local: '+l)"
check "example config validates with zero errors"  bash -c "d=\$(mktemp -d '$SANDBOX/ex.XXXXXX'); mkdir -p \$d/.autodev; cp '$EX' \$d/.autodev/deployment.json; node '$CFGBIN' validate \$d"
check "…with zero warnings (the example is a clean local-tracker deployment)" bash -c "d=\$(mktemp -d '$SANDBOX/ex2.XXXXXX'); mkdir -p \$d/.autodev; cp '$EX' \$d/.autodev/deployment.json; node '$CFGBIN' validate \$d | grep -q 'conforms to the schema\$'"
check "example defaults to the local tracker (M5: no more implied-Linear default)" jq -e '.tracker.kind=="local"' "$EX"
PL=$(mkrepo PreLocal 'del(.tracker.kind) | del(.planning)')
bash "$PLUGIN/scripts/upgrade-config.sh" "$PL" >/dev/null
check "upgrade pins a pre-local (kind-less, has team_id) config to linear, not local" jq -e '.tracker.kind=="linear"' "$PL/.autodev/deployment.json"
check "example declares the v3 sections: planning · executor · brain" jq -e '.planning.engine=="agency" and .executor.default=="claude" and .brain.enabled==false and (.brain|has("project_id")) and (.brain|has("url"))' "$EX"
check "example no longer calls BrainGrid preferred"  jq -e '(.braingrid._enabled_note | test("PREFERRED") | not) and (.intake._note | test("BrainGrid") | not)' "$EX"

echo "validation:"
V=$(mkrepo ValCo)
check "a fresh local-tracker deployment validates clean (no warnings)" bash -c "node '$CFGBIN' validate '$V' | grep -q 'conforms to the schema\$'"
jq '.review.delivery="email"' "$V/.autodev/deployment.json" > "$V/t" && mv "$V/t" "$V/.autodev/deployment.json"
check_out "bad enum → error naming the allowed values" 'review.delivery: must be one of draft_pr \| local_diff, got "email"' bash -c "node '$CFGBIN' validate '$V'; true"
check "bad enum → exit 1"                            bash -c "! node '$CFGBIN' validate '$V' >/dev/null 2>&1"
jq '.review.delivery="draft_pr" | .execution.max_lanes="five"' "$V/.autodev/deployment.json" > "$V/t" && mv "$V/t" "$V/.autodev/deployment.json"
check_out "wrong type → error"                       'execution.max_lanes: must be an integer' bash -c "node '$CFGBIN' validate '$V'; true"
jq '.execution.max_lanes=5 | .personas.auto_install="false"' "$V/.autodev/deployment.json" > "$V/t" && mv "$V/t" "$V/.autodev/deployment.json"
check_out "string 'false' where a boolean belongs → error (fail closed, never coerced)" 'personas.auto_install: must be true/false' bash -c "node '$CFGBIN' validate '$V'; true"
jq '.personas.auto_install=true | .qa.live_browser_driver=""' "$V/.autodev/deployment.json" > "$V/t" && mv "$V/t" "$V/.autodev/deployment.json"
check_out "empty string on an enum = 'use the default' → note, not error (v2 init writes these)" '· qa.live_browser_driver: empty — the default "playwright_mcp" applies' bash -c "node '$CFGBIN' validate '$V'"
check "…still exit 0"                                node "$CFGBIN" validate "$V"
check_out "…normalize resolves it to the default"    '"live_browser_driver": "playwright_mcp"' node "$CFGBIN" normalize "$V"
jq '.qa.live_browser_driver="playwright_mcp" | .my_custom={x:1} | .tracker._my_note="hi"' "$V/.autodev/deployment.json" > "$V/t" && mv "$V/t" "$V/.autodev/deployment.json"
check_out "unknown key → warning, not error; _notes ignored" 'my_custom: unknown key' bash -c "node '$CFGBIN' validate '$V'"
check "…still exit 0"                                node "$CFGBIN" validate "$V"
S=$(mkrepo ScCo '.tracker.kind="shortcut" | .tracker.hierarchy="project"')
check_out "cross-field: shortcut + hierarchy=project → error" "hierarchy=project needs tracker.kind=linear" bash -c "node '$CFGBIN' validate '$S'; true"
I=$(mkrepo IntCo '.intake.mode="linear"')
check_out "cross-field: intake.mode=linear needs kind=linear" "intake.mode=linear needs tracker.kind=linear" bash -c "node '$CFGBIN' validate '$I'; true"
B=$(mkrepo BrCo '.brain.enabled=true')
check_out "cross-field: brain.enabled needs brain.url"   "brain.enabled but brain.url" bash -c "node '$CFGBIN' validate '$B'; true"
H=$(mkrepo HermCo '.qa.hermetic.env={}')
check_out "cross-field: hermetic on with empty env → warning" "qa.hermetic.env is empty" bash -c "node '$CFGBIN' validate '$H'"
check_out "no deployment → exit 3 with a clear message" "no .*deployment.json" bash -c "node '$CFGBIN' validate '$SANDBOX'; true"
check "no deployment → exit code 3"                  bash -c "node '$CFGBIN' validate '$SANDBOX' >/dev/null 2>&1; [ \$? -eq 3 ]"
M=$(mkrepo MalCo); echo '{nope' > "$M/.autodev/deployment.json"
check "malformed JSON → exit 1"                      bash -c "node '$CFGBIN' validate '$M' >/dev/null 2>&1; [ \$? -eq 1 ]"

echo "legacy normalization (in memory — files untouched):"
L1=$(mkrepo Leg1 'del(.planning) | del(.executor) | del(.brain) | .braingrid.enabled=true | .braingrid.project_short_id="PROJ-7"')
check_out "braingrid.enabled=true + no planning → planning.engine=braingrid" '"engine": "braingrid"' node "$CFGBIN" normalize "$L1"
check_out "…with a note explaining the derivation"   "derived from legacy braingrid.enabled" node "$CFGBIN" validate "$L1"
L2=$(mkrepo Leg2 'del(.planning) | del(.executor) | del(.brain) | .braingrid.enabled=false')
check_out "braingrid.enabled=false + no planning → agency" '"engine": "agency"' node "$CFGBIN" normalize "$L2"
L3=$(mkrepo Leg3 'del(.planning) | del(.executor) | del(.brain) | del(.braingrid)')
check_out "no planning, no braingrid → agency (the v3 default)" '"engine": "agency"' node "$CFGBIN" normalize "$L3"
check_out "…executor defaults to claude"             '"default": "claude"' node "$CFGBIN" normalize "$L3"
check_out "…brain defaults to disabled"              '"enabled":false' bash -c "node '$CFGBIN' normalize '$L3' | jq -c .brain"
L4=$(mkrepo Leg4 '.planning.engine="agency" | .braingrid.enabled=true')
check_out "explicit planning.engine wins over legacy braingrid.enabled" '"engine": "agency"' node "$CFGBIN" normalize "$L4"
check "normalize never writes the file"              bash -c "before=\$(md5 -q '$L1/.autodev/deployment.json' 2>/dev/null || md5sum '$L1/.autodev/deployment.json'); node '$CFGBIN' normalize '$L1' >/dev/null; after=\$(md5 -q '$L1/.autodev/deployment.json' 2>/dev/null || md5sum '$L1/.autodev/deployment.json'); [ \"\$before\" = \"\$after\" ]"

echo "upgrade-config.sh derives from the schema:"
U=$(mkrepo UpCo 'del(.planning) | del(.executor) | del(.brain) | .braingrid.enabled=true | .braingrid.project_short_id="PROJ-9"')
OUT=$(bash "$PLUGIN/scripts/upgrade-config.sh" "$U")
check "adds planning/executor/brain with defaults"   jq -e '.executor.default=="claude" and .brain.enabled==false' "$U/.autodev/deployment.json"
check "legacy braingrid user KEEPS braingrid (planning.engine=braingrid on disk)" jq -e '.planning.engine=="braingrid" and .braingrid.project_short_id=="PROJ-9"' "$U/.autodev/deployment.json"
check "…and is told about the migration"             has_re 'planning.engine.*braingrid'
U2=$(mkrepo UpCo2 'del(.planning) | del(.executor) | del(.brain) | .braingrid.enabled=false')
bash "$PLUGIN/scripts/upgrade-config.sh" "$U2" >/dev/null
check "legacy non-braingrid user gets agency"        jq -e '.planning.engine=="agency"' "$U2/.autodev/deployment.json"
check "upgraded config validates clean"              node "$CFGBIN" validate "$U2"
check "upgrade is idempotent after the migration"    bash -c "bash '$PLUGIN/scripts/upgrade-config.sh' '$U2' | grep -q 'already current'"
check "schema defaults (non-identity) == what upgrade merges under a config" n "
  import {defaults} from '$SRC/core/config/schema.mjs'; import {readFileSync} from 'node:fs'; import {execSync} from 'node:child_process';
  const d=defaults({identity:false,local:false});
  for(const k of ['client_name','assistant_name','repo','bot_identity','commands','engine','runner']) if(k in d) throw new Error(k+' must not be in non-identity defaults');
  if(d.tracker.kind!=='local'||d.planning.engine!=='agency'||d.executor.default!=='claude') throw new Error('v3 defaults: '+JSON.stringify({t:d.tracker.kind,p:d.planning.engine,e:d.executor.default}))"

echo "doctor validates against the schema:"
D=$(mkrepo DocCo '.review.granularity="weekly"')
check_out "doctor FAILS on a schema error"           "review.granularity: must be one of" bash -c "cd '$D' && bash '$PLUGIN/scripts/doctor.sh' 2>&1; true"
check "…exit 1"                                      bash -c "cd '$D' && ! bash '$PLUGIN/scripts/doctor.sh' >/dev/null 2>&1"
D2=$(mkrepo DocOk)
check_out "doctor reports schema conformance on a good config" "conforms to the schema" bash -c "cd '$D2' && bash '$PLUGIN/scripts/doctor.sh' 2>&1; true"
D3=$(mkrepo DocBg 'del(.planning) | .braingrid.enabled=true | .braingrid.project_short_id="PROJ-1"')
check_out "doctor: planning section reads the (derived) engine" "planning: braingrid" bash -c "cd '$D3' && bash '$PLUGIN/scripts/doctor.sh' 2>&1; true"
check_out "doctor: agency planning needs no braingrid binary" "planning: agency" bash -c "cd '$D2' && bash '$PLUGIN/scripts/doctor.sh' 2>&1; true"

exit $FAIL
