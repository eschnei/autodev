#!/usr/bin/env bash
# Milestone 6 — the Agency is model-neutral. Roles load from the built-ins + the
# sidecar store without touching ~/.claude/agents; the Claude adapter projects
# personas into Claude's format; nothing in a role names an executor.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
export AUTODEV_HOME="$SANDBOX/autodev-home-agency"   # per-suite data root (suites share one sandbox)
n() { node --input-type=module -e "$1"; }
nfail() { ! node --input-type=module -e "$1" >/dev/null 2>&1; }   # passes iff the snippet throws
nerr() { node --input-type=module -e "$1" 2>&1; true; }           # combined output, never fails
CFG=$(jq -c . "$PLUGIN/reference/deployment.example.json")

echo "roles — model-neutral, loaded without ~/.claude:"
check "no ~/.claude/agents exists in the sandbox (roles must not need it)" test ! -d "$HOME/.claude/agents"
check "10 built-in roles with stable ids"          n "import {loadRoles} from '$SRC/agency/roles.mjs'; const r=loadRoles({cfg:$CFG}); const ids=r.map(x=>x.id).join(','); if(ids!=='intake,product_manager,codebase,project_manager,architect,implementation,test,review,security_review,verification') throw ids"
check "every role: purpose, responsibilities, permissions, required_context, outputs" n "import {loadRoles} from '$SRC/agency/roles.mjs'; for(const r of loadRoles({cfg:$CFG})){ for(const k of ['purpose','responsibilities','permissions','required_context','outputs']) if(!r[k]||(Array.isArray(r[k])&&!r[k].length)) throw r.id+'.'+k }"
check "no role names an executor or model"         n "import {loadRoles} from '$SRC/agency/roles.mjs'; const txt=JSON.stringify(loadRoles({cfg:$CFG}).map(r=>({...r,eligible_executors:undefined}))).replace(/(CLAUDE|AGENTS)\\.md/g,'team-doc'); if(/\\b(claude|codex|anthropic|openai|gemini|gpt)\\b/i.test(txt)) throw 'executor word in roles'"
check "eligible_executors is ['*'] by default"     n "import {loadRoles} from '$SRC/agency/roles.mjs'; for(const r of loadRoles({cfg:$CFG})) if(JSON.stringify(r.eligible_executors)!=='[\"*\"]') throw r.id"
check "no role may push"                           n "import {loadRoles} from '$SRC/agency/roles.mjs'; for(const r of loadRoles({cfg:$CFG})) if(r.permissions.git_push!==false) throw r.id"
check "only implementation writes the repository"  n "import {loadRoles} from '$SRC/agency/roles.mjs'; const w=loadRoles({cfg:$CFG}).filter(r=>r.permissions.repository==='write').map(r=>r.id); if(w.join()!=='implementation') throw w.join()"
check "assertNeutral rejects a role that names a model" nfail "import {assertNeutral} from '$SRC/agency/roles.mjs'; assertNeutral({id:'x',purpose:'ask Claude'})"
check "…but a role may mention the team's CLAUDE.md / AGENTS.md files" n "import {assertNeutral} from '$SRC/agency/roles.mjs'; assertNeutral({id:'x',required_context:['team AGENTS.md / CLAUDE.md']})"

echo "roles — personas resolve from the deployment's routing:"
RJS="import {loadRole} from '$SRC/agency/roles.mjs'; const cfg=$CFG;"
check "product_manager ← personas.stage_defaults.prd"   n "$RJS const r=loadRole('product_manager',{cfg}); if(r.personas.join()!=='product-manager') throw r.personas"
check "project_manager ← stage_defaults.breakdown"      n "$RJS const r=loadRole('project_manager',{cfg}); if(r.personas.join()!=='project-manager-senior') throw r.personas"
check "implementation ← every dev_routing persona"       n "$RJS const r=loadRole('implementation',{cfg}); const want=[...new Set(cfg.personas.dev_routing.map(x=>x.persona))]; if(r.personas.join()!==want.join()) throw r.personas"
check "security_review ← qa_angles.adversarial"          n "$RJS const r=loadRole('security_review',{cfg}); if(r.personas.join()!==cfg.personas.qa_angles.adversarial.join()) throw r.personas"
check "test ← conformance + regression (deduped)"        n "$RJS const r=loadRole('test',{cfg}); if(!r.personas.includes('code-reviewer')||!r.personas.includes('reality-checker')||r.personas.length!==new Set(r.personas).size) throw r.personas"
check "verification ← qa_angles.verdict"                 n "$RJS const r=loadRole('verification',{cfg}); if(r.personas.join()!=='reality-checker') throw r.personas"
check "codebase ← roster member; absent from roster → fallback" n "$RJS if(loadRole('codebase',{cfg}).personas.join()!=='codebase-onboarding-engineer') throw 'roster'; const c2=structuredClone(cfg); c2.personas.roster=c2.personas.roster.filter(x=>x!=='codebase-onboarding-engineer'); if(loadRole('codebase',{cfg:c2}).personas.join()!=='general-purpose') throw 'fallback'"
check "empty personas config → every role falls back"     n "$RJS for(const r of ['intake','implementation','verification']) if(loadRole(r,{cfg:{}}).personas.join()!=='general-purpose') throw r"
check_out "unknown role id throws with the valid set"    'unknown role "wizard" \(intake, product_manager' nerr "import {loadRole} from '$SRC/agency/roles.mjs'; loadRole('wizard')"

echo "roles — store overrides (sidecar, per machine):"
mkdir -p "$AUTODEV_HOME/agents/roles"
echo '{"responsibilities":["do it my way"],"permissions":{"tests":false},"personas":["my-dev"]}' > "$AUTODEV_HOME/agents/roles/implementation.json"
check "override merges over the built-in (responsibilities, permissions, personas)" n "$RJS const r=loadRole('implementation',{cfg}); if(r.responsibilities.join()!=='do it my way'||r.permissions.tests!==false||r.permissions.repository!=='write'||r.personas.join()!=='my-dev'||!r.overridden) throw JSON.stringify(r)"
check "other roles untouched"                            n "$RJS if(loadRole('test',{cfg}).overridden) throw 'test overridden'"
echo '{"purpose":"use Codex for this"}' > "$AUTODEV_HOME/agents/roles/review.json"
check "an override that names an executor is rejected"   nfail "$RJS loadRole('review',{cfg})"
echo '{bad' > "$AUTODEV_HOME/agents/roles/review.json"
check_out "malformed override fails loudly (not silently ignored)" "not valid JSON" nerr "$RJS loadRole('review',{cfg})"
rm -f "$AUTODEV_HOME/agents/roles/review.json" "$AUTODEV_HOME/agents/roles/implementation.json"
check "renderRoleBrief carries responsibilities + permissions + outputs" n "import {loadRole,renderRoleBrief} from '$SRC/agency/roles.mjs'; const b=renderRoleBrief(loadRole('implementation',{cfg:$CFG})); for(const s of ['# Role: Implementation Agent','git push NEVER','repository write','Expected outputs:','add tests for every acceptance criterion']) if(!b.includes(s)) throw s"

echo "personas — format + store:"
PJS="import {PersonaStore,parsePersona,renderPersona} from '$SRC/agency/personas.mjs';"
FIX='---\nname: backend-architect\ndescription: Senior backend architect.\ncolor: blue\ntools: Read, Write\n---\n# Backend\n\nYou are **Sam**.\n'
check "parse: frontmatter → name/description/meta, body preserved" n "$PJS const p=parsePersona(\`$(printf -- "$FIX")\`); if(p.name!=='backend-architect'||p.description!=='Senior backend architect.'||p.meta.color!=='blue'||p.meta.tools!=='Read, Write'||!p.body.includes('You are **Sam**')) throw JSON.stringify(p)"
check "render ∘ parse round-trips"                       n "$PJS const src=\`$(printf -- "$FIX")\`; const p=parsePersona(src); if(renderPersona(p)!==src) throw JSON.stringify([renderPersona(p),src])"
check "parse without frontmatter → body only"            n "$PJS const p=parsePersona('# Just text'); if(p.name!==null||p.body!=='# Just text') throw JSON.stringify(p)"
S="$AUTODEV_HOME/agents/personas"
check "store.write is atomic + resolves bare slug"       n "$PJS const s=new PersonaStore({dir:'$S'}); s.write('backend-architect', \`$(printf -- "$FIX")\`); if(s.resolve('backend-architect')!=='$S/backend-architect.md') throw s.resolve('backend-architect'); import {existsSync} from 'node:fs'; if(existsSync('$S/backend-architect.md.tmp')) throw 'tmp left'"
check "store resolves the library's division-prefixed name (fuzzy, anchored)" n "$PJS const s=new PersonaStore({dir:'$S'}); s.write('code-reviewer','---\nname: code-reviewer\n---\nx',{file:'engineering-code-reviewer.md'}); if(!s.has('code-reviewer')) throw 'no'; if(s.has('reviewer')) throw 'unanchored match'"
check "store.list reports slug + division"               n "$PJS const s=new PersonaStore({dir:'$S'}); const l=s.list().find(x=>x.slug==='code-reviewer'); if(!l||l.division!=='engineering') throw JSON.stringify(s.list())"
check "store.read parses"                                n "$PJS const s=new PersonaStore({dir:'$S'}); const p=s.read('backend-architect'); if(p.name!=='backend-architect'||!p.file.endsWith('backend-architect.md')) throw JSON.stringify(p)"
check "store rejects a bad slug"                         nfail "$PJS new PersonaStore({dir:'$S'}).write('../evil','x')"
check "unknown slug → null, no throw"                    n "$PJS const s=new PersonaStore({dir:'$S'}); if(s.read('nope')!==null||s.resolve('nope')!==null) throw 'x'"
CA=$(mktemp -d "$SANDBOX/claude-agents.XXXXXX"); printf -- '---\nname: reality-checker\n---\nr\n' > "$CA/testing-reality-checker.md"; printf -- '---\nname: backend-architect\n---\nOLD\n' > "$CA/backend-architect.md"
check "importFrom adopts files the store lacks, never overwrites" n "$PJS const s=new PersonaStore({dir:'$S'}); const got=s.importFrom('$CA'); if(got.join()!=='testing-reality-checker.md') throw got; import {readFileSync} from 'node:fs'; if(readFileSync('$S/backend-architect.md','utf8').includes('OLD')) throw 'overwrote'"

echo "personas — needed set parity with scripts/ensure-personas.sh:"
P=$(mkrepo ParCo)
N_SH=$(AUTODEV_AGENTS_DIR="$SANDBOX/empty-agents" bash "$PLUGIN/scripts/ensure-personas.sh" --check "$P" | grep -oE '[0-9]+ needed' | grep -oE '[0-9]+')
check "neededSlugs(cfg) count == ensure-personas.sh 'needed'" n "import {neededSlugs} from '$SRC/agency/personas.mjs'; const n=neededSlugs($CFG).length; if(n!==$N_SH) throw n+' vs $N_SH'"
check "resolvePersonas classifies builtin / installed / unresolved" n "$PJS import {resolvePersonas} from '$SRC/agency/personas.mjs'; const s=new PersonaStore({dir:'$S'}); const r=resolvePersonas($CFG,s); const st=Object.fromEntries(r.map(x=>[x.slug,x.status])); if(st['general-purpose']!=='builtin'||st['backend-architect']!=='installed'||st['code-reviewer']!=='installed'||st['ui-designer']!=='unresolved') throw JSON.stringify(st)"

echo "personas — consent-gated install (stubbed network):"
STUBFETCH="const tree={ok:true,json:async()=>({tree:[{path:'design/design-ui-designer.md'},{path:'engineering/engineering-frontend-developer.md'},{path:'testing/wrong-name.md'}]})}; const raw={ok:true,text:async()=>'---\nname: ui-designer\n---\nUI'}; const calls=[]; const f=async(u)=>{calls.push(u); return u.includes('/git/trees/')?tree:raw};"
check "installs from the pinned ref into the store with the library filename" n "$PJS import {installPersona} from '$SRC/agency/personas.mjs'; $STUBFETCH const s=new PersonaStore({dir:'$S'}); const r=await installPersona('ui-designer',{store:s,repo:'x/y',ref:'abc123',fetchImpl:f}); if(r.status!=='downloaded'||!r.file.endsWith('design-ui-designer.md')||!s.has('ui-designer')) throw JSON.stringify(r); if(!calls[1].includes('/x/y/abc123/design/design-ui-designer.md')) throw calls[1]"
check "already installed → no network"                   n "$PJS import {installPersona} from '$SRC/agency/personas.mjs'; $STUBFETCH const s=new PersonaStore({dir:'$S'}); const r=await installPersona('ui-designer',{store:s,fetchImpl:f}); if(r.status!=='installed'||calls.length) throw JSON.stringify([r,calls])"
check "not in library → unresolved, nothing written"     n "$PJS import {installPersona} from '$SRC/agency/personas.mjs'; $STUBFETCH const s=new PersonaStore({dir:'$S'}); const r=await installPersona('wrong-name',{store:s,fetchImpl:f}); if(r.status!=='unresolved'||s.has('wrong-name')) throw JSON.stringify(r)"
check "empty download → unresolved, no partial file"     n "$PJS import {installPersona} from '$SRC/agency/personas.mjs'; const f=async(u)=>u.includes('/git/trees/')?{ok:true,json:async()=>({tree:[{path:'engineering/engineering-frontend-developer.md'}]})}:{ok:true,text:async()=>'  '}; const s=new PersonaStore({dir:'$S'}); const r=await installPersona('frontend-developer',{store:s,fetchImpl:f}); if(r.status!=='unresolved'||s.has('frontend-developer')) throw JSON.stringify(r); import {existsSync} from 'node:fs'; if(existsSync('$S/engineering-frontend-developer.md.tmp')) throw 'tmp'"
check "ensurePersonas: auto_install=false → no fetch at all" n "$PJS import {ensurePersonas} from '$SRC/agency/personas.mjs'; let called=0; const cfg=$CFG; cfg.personas.auto_install=false; const r=await ensurePersonas(cfg,{store:new PersonaStore({dir:'$S'}),fetchImpl:async()=>{called++; throw new Error('net')}}); if(called) throw 'fetched'; if(!r.unresolved) throw 'should report unresolved'"
check "ensurePersonas: non-boolean auto_install fails closed" n "$PJS import {ensurePersonas} from '$SRC/agency/personas.mjs'; let called=0; const cfg=$CFG; cfg.personas.auto_install='false'; await ensurePersonas(cfg,{store:new PersonaStore({dir:'$S'}),fetchImpl:async()=>{called++; throw new Error('net')}}); if(called) throw 'fetched'"
check "ensurePersonas: check=true never fetches"         n "$PJS import {ensurePersonas} from '$SRC/agency/personas.mjs'; let called=0; await ensurePersonas($CFG,{store:new PersonaStore({dir:'$S'}),check:true,fetchImpl:async()=>{called++; throw new Error('net')}}); if(called) throw 'fetched'"
check "ensurePersonas: consent → fetches only the missing ones" n "$PJS import {ensurePersonas,neededSlugs,resolvePersonas} from '$SRC/agency/personas.mjs'; const s=new PersonaStore({dir:'$S'}); const before=resolvePersonas($CFG,s).filter(x=>x.status==='unresolved').length; const tree={tree:[]}; let trees=0; const r=await ensurePersonas($CFG,{store:s,fetchImpl:async(u)=>{ if(u.includes('/git/trees/')){trees++; return {ok:true,json:async()=>tree}} return {ok:false,status:404} }}); if(trees!==before) throw 'tree fetched '+trees+' vs '+before; if(r.unresolved!==before) throw r.unresolved"

echo "claude projection (Agency → ~/.claude/agents):"
T=$(mktemp -d "$SANDBOX/target.XXXXXX")
AJS="$PJS import {projectPersonas} from '$SRC/executors/claude/agents.mjs'; const s=new PersonaStore({dir:'$S'});"
check "projects installed personas; reports missing; never writes outside target" n "$AJS const r=projectPersonas($CFG,s,{targetDir:'$T'}); if(!r.written.includes('backend-architect.md')||!r.written.includes('engineering-code-reviewer.md')||!r.missing.includes('frontend-developer')||!r.builtin.includes('general-purpose')) throw JSON.stringify(r); import {readdirSync} from 'node:fs'; if(readdirSync('$AUTODEV_HOME').includes('backend-architect.md')) throw 'leak'"
check "manifest records what we projected"               bash -c "jq -e '.files[\"backend-architect.md\"].slug==\"backend-architect\"' '$T/.autodev-projected.json'"
check "second projection: identical → kept, nothing rewritten" n "$AJS const r=projectPersonas($CFG,s,{targetDir:'$T'}); if(r.written.length||r.updated.length||!r.kept.includes('backend-architect.md')) throw JSON.stringify(r)"
check "store update flows to a file we projected"        n "$AJS s.write('backend-architect','---\nname: backend-architect\n---\nNEW'); const r=projectPersonas($CFG,s,{targetDir:'$T'}); if(!r.updated.includes('backend-architect.md')) throw JSON.stringify(r); import {readFileSync} from 'node:fs'; if(!readFileSync('$T/backend-architect.md','utf8').includes('NEW')) throw 'not updated'"
printf -- '---\nname: backend-architect\n---\nUSER EDIT\n' > "$T/backend-architect.md"
check "a user-edited file is never overwritten"          n "$AJS const r=projectPersonas($CFG,s,{targetDir:'$T'}); if(!r.kept.some(k=>k.startsWith('backend-architect.md (user-owned'))) throw JSON.stringify(r); import {readFileSync} from 'node:fs'; if(!readFileSync('$T/backend-architect.md','utf8').includes('USER EDIT')) throw 'overwrote'"
check "renderRolePrompt = role brief + persona body"     n "import {loadRole} from '$SRC/agency/roles.mjs'; import {renderRolePrompt} from '$SRC/executors/claude/agents.mjs'; const p=renderRolePrompt(loadRole('implementation',{cfg:$CFG}),{slug:'backend-architect',name:'backend-architect',body:'You are **Sam**.'}); if(!p.startsWith('# Role: Implementation Agent')||!p.includes('# Persona: backend-architect')||!p.includes('You are **Sam**')) throw p"
check "projected files are valid Claude subagents (frontmatter name)" bash -c "head -2 '$T/engineering-code-reviewer.md' | grep -q '^name: code-reviewer'"

echo "cli — autodev agents:"
L=$(mkrepo AgCo); git -C "$L" add -A >/dev/null; git -C "$L" commit -qm init >/dev/null
CLI="$PLUGIN/bin/autodev.mjs"
check_out "agents lists roles with persona resolution"   "implementation +Implementation Agent +persona: backend-architect" bash -c "cd '$L' && node '$CLI' agents"
check_out "…flags an uninstalled persona with its fallback" "test-results-analyzer \(not installed → general-purpose\)" bash -c "cd '$L' && node '$CLI' agents"
CA2=$(mktemp -d "$SANDBOX/ca2.XXXXXX"); printf -- '---\nname: evidence-collector\n---\nev\n' > "$CA2/testing-evidence-collector.md"
check_out "agents sync adopts from the executor dir and projects back" "adopted from .*testing-evidence-collector.md" bash -c "cd '$L' && AUTODEV_AGENTS_DIR='$CA2' node '$CLI' agents sync"
check "…store now has evidence-collector; executor dir has the projected code-reviewer" bash -c "test -f '$S/testing-evidence-collector.md' && test -f '$CA2/engineering-code-reviewer.md'"
check_out "agents install with consent off reports unresolved, exit 1" "unresolved \(→ general-purpose\)" bash -c "jq '.personas.auto_install=false' '$L/.autodev/deployment.json' > '$L/t' && mv '$L/t' '$L/.autodev/deployment.json'; cd '$L' && node '$CLI' agents install; true"
check "…exit 1 when personas are unresolved"             bash -c "cd '$L' && ! node '$CLI' agents install >/dev/null 2>&1"
check "roles never read ~/.claude/agents (sandbox HOME still has none)" test ! -d "$HOME/.claude/agents"

exit $FAIL
