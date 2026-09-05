#!/usr/bin/env bash
# v3 core modules: canonical ids (D3), data paths (D2), the executor contract, the
# ported allowlist builder. Pure Node, no repo needed.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
n() { node --input-type=module -e "$1"; }   # run an ESM snippet

echo "ids — typed-prefix ULIDs:"
check "ulid is 26 Crockford chars" n "import {ulid} from '$SRC/core/ids.mjs'; const u=ulid(); if(!/^[0-9A-HJKMNP-TV-Z]{26}$/.test(u)) throw u"
check "1000 ulids are unique"       n "import {ulid} from '$SRC/core/ids.mjs'; const s=new Set(); for(let i=0;i<1000;i++) s.add(ulid()); if(s.size!==1000) throw s.size"
check "lexically sortable by time"  n "import {ulid} from '$SRC/core/ids.mjs'; const a=ulid(1000), b=ulid(2000), c=ulid(2000*1000); if(!(a<b && b<c)) throw 'order'"
check "time round-trips"            n "import {ulid,ulidTime} from '$SRC/core/ids.mjs'; const t=1725000000000; if(ulidTime(ulid(t))!==t) throw 'time'"
check "newId('project') → prj_…"    n "import {newId,isId,parseId} from '$SRC/core/ids.mjs'; const id=newId('project'); if(!id.startsWith('prj_')||!isId(id,'project')||parseId(id).type!=='project') throw id"
check "every entity type has a prefix" n "import {newId,PREFIXES,isId} from '$SRC/core/ids.mjs'; for(const t of Object.keys(PREFIXES)){ if(!isId(newId(t),t)) throw t }"
check "isId rejects the wrong type"  n "import {newId,isId} from '$SRC/core/ids.mjs'; if(isId(newId('task'),'project')) throw 'type'"
check "isId rejects tracker ids (AD-19 is an alias, not identity)" n "import {isId} from '$SRC/core/ids.mjs'; if(isId('AD-19')||isId('REQ-104')||isId('ENG-418')) throw 'alias'"
check "unknown entity type throws"   bash -c "! node --input-type=module -e \"import {newId} from '$SRC/core/ids.mjs'; newId('widget')\" 2>/dev/null"

echo "paths — sidecar data root (never the repo):"
check "AUTODEV_HOME overrides everything"     n "import {dataRoot} from '$SRC/core/paths.mjs'; if(dataRoot({AUTODEV_HOME:'/x'})!=='/x') throw dataRoot({AUTODEV_HOME:'/x'})"
check "macOS default is Application Support"  n "import {dataRoot} from '$SRC/core/paths.mjs'; import {platform} from 'node:os'; const r=dataRoot({HOME:'/h'}); if(platform()==='darwin' && r!=='/h/Library/Application Support/autoDev') throw r; if(platform()==='linux' && r!=='/h/.local/share/autodev') throw r"
check "Linux honors XDG_DATA_HOME"            n "import {dataRoot} from '$SRC/core/paths.mjs'; import {platform} from 'node:os'; if(platform()==='linux' && dataRoot({HOME:'/h',XDG_DATA_HOME:'/xdg'})!=='/xdg/autodev') throw 'xdg'"
check "project layout: board/events/locks/runtime" n "import {ensureProjectDirs,PROJECT_SUBDIRS} from '$SRC/core/paths.mjs'; import {existsSync} from 'node:fs'; const env={AUTODEV_HOME:'$SANDBOX/ah'}; const d=ensureProjectDirs('prj_01J00000000000000000000000',env); for(const s of PROJECT_SUBDIRS){ if(!existsSync(d+'/'+s)) throw s }"

echo "executor contract + registry:"
check "makeJob fills defaults + a job_ id"     n "import {makeJob} from '$SRC/executors/executor.mjs'; const j=makeJob({task:'x'}); if(!j.job_id.startsWith('job_')||j.role!=='implementation'||!Array.isArray(j.permissions.allowed_tools)) throw JSON.stringify(j)"
check "makeJob requires a task"                bash -c "! node --input-type=module -e \"import {makeJob} from '$SRC/executors/executor.mjs'; makeJob({})\" 2>/dev/null"
check "registerExecutor rejects an incomplete adapter" bash -c "! node --input-type=module -e \"import {registerExecutor} from '$SRC/executors/executor.mjs'; registerExecutor({id:'x',execute(){}})\" 2>/dev/null"
check "getExecutor names what IS registered on miss" bash -c "node --input-type=module -e \"import '$SRC/executors/claude/index.mjs'; import {getExecutor} from '$SRC/executors/executor.mjs'; getExecutor('codex')\" 2>&1 | grep -q 'no executor \"codex\" registered (available: claude)'"
check "claude adapter registers itself as 'claude'" n "import '$SRC/executors/claude/index.mjs'; import {listExecutors,getExecutor} from '$SRC/executors/executor.mjs'; if(!listExecutors().includes('claude')) throw 'reg'; const c=await getExecutor('claude').capabilities(); if(c.auth!=='subscription') throw 'auth'"
check "claude adapter: completed result is normalized" n "import {claude} from '$SRC/executors/claude/index.mjs'; import {makeJob} from '$SRC/executors/executor.mjs'; const r=await claude.execute(makeJob({task:'hi'})); if(r.status!=='completed'||r.summary!=='ok'||r.executor!=='claude'||!r.started_at) throw JSON.stringify(r)"
check "claude adapter: usage-limit → rate_limited + reset_at" bash -c "CLAUDE_STUB_MODE=limited node --input-type=module -e \"import {claude} from '$SRC/executors/claude/index.mjs'; import {makeJob} from '$SRC/executors/executor.mjs'; const r=await claude.execute(makeJob({task:'hi'})); if(r.status!=='rate_limited'||r.reset_at!==4102444800) throw JSON.stringify(r)\""
check "claude adapter: CLI failure → unavailable (never a fake success)" bash -c "CLAUDE_STUB_MODE=fail node --input-type=module -e \"import {claude} from '$SRC/executors/claude/index.mjs'; import {makeJob} from '$SRC/executors/executor.mjs'; const r=await claude.execute(makeJob({task:'hi'})); if(r.status!=='unavailable') throw JSON.stringify(r)\""
check "claude adapter passes the allowlist as --allowedTools" bash -c ": > '$CLAUDE_STUB_LOG'; node --input-type=module -e \"import {claude} from '$SRC/executors/claude/index.mjs'; import {makeJob} from '$SRC/executors/executor.mjs'; await claude.execute(makeJob({task:'go',permissions:{allowed_tools:['Bash(npm test)','mcp__x__*']}}))\" && grep -q -- '-p go --output-format json --allowedTools Bash(npm test) --allowedTools mcp__x__\*' '$CLAUDE_STUB_LOG'"
check "claude adapter: missing binary → unavailable" n "import {ClaudeCodeExecutor} from '$SRC/executors/claude/index.mjs'; const e=new ClaudeCodeExecutor({bin:'/nonexistent/claude'}); if(await e.available()) throw 'avail'; const r=await e.execute({job_id:'j',task:'x',permissions:{}}); if(r.status!=='unavailable') throw r.status"
check "no 'claude -p' outside the adapter (M3 invariant)" bash -c "! grep -rnE \"claude['\\\" ]+-p|spawn[a-zA-Z]*\\(['\\\"]claude\" '$SRC/core' '$SRC/cli' 2>/dev/null | grep -v '^\$'"

echo "codex executor (M15) — same Job contract, vendor CLI confined to the adapter:"
CJ="import {codex,CodexExecutor,inlineReferences,prohibitions} from '$SRC/executors/codex/index.mjs'; import {makeJob,getExecutor,listExecutors} from '$SRC/executors/executor.mjs';"
cx() { node --input-type=module -e "$CJ $1"; }
cx_run() { : > "$CODEX_STUB_LOG"; cx "await codex.execute(makeJob({task:'$1',cwd:'$SANDBOX'${2:-}}))"; }
check "registers as 'codex' next to claude"          cx "import '$SRC/executors/claude/index.mjs'; const l=listExecutors(); if(!l.includes('codex')||!l.includes('claude')) throw l"
check "capabilities: subscription, no mechanical allowlist, sandboxed" cx "const c=await codex.capabilities(); if(c.auth!=='subscription'||c.tool_allowlist!==false||c.sandbox!==true) throw JSON.stringify(c)"
check "execute: normalized completed result with files_changed from file_change events" cx "const r=await codex.execute(makeJob({task:'do it',cwd:'$SANDBOX'})); if(r.status!=='completed'||r.summary!=='ok'||r.executor!=='codex'||r.files_changed.join()!=='src/a.js,src/b.js'||!r.raw.usage) throw JSON.stringify(r)"
argv_ok() { cx_run 'hello there' && grep -q "ARGS: exec --json -a never -s workspace-write -C $SANDBOX -o .*last-message.txt --skip-git-repo-check -" "$CODEX_STUB_LOG" && grep -q 'PROMPT: .*hello there' "$CODEX_STUB_LOG"; }
check "argv: exec --json, never ask, workspace-write sandbox, -C cwd, -o last-message, prompt on stdin" argv_ok
net_ok() { cx_run 'x' && ! grep -q 'network_access=true' "$CODEX_STUB_LOG" && cx_run 'x' ",permissions:{allowed_tools:['Bash(git push origin feature/*)']}" && grep -q 'network_access=true' "$CODEX_STUB_LOG"; }
check "network stays OFF unless the allowlist grants push/gh"  net_ok
rules_ok() { cx_run 'x' && grep -q 'Never push, merge, or rebase onto the default branch' "$CODEX_STUB_LOG" && grep -q 'gh pr merge' "$CODEX_STUB_LOG" && grep -q 'Never edit AGENTS.md or CLAUDE.md' "$CODEX_STUB_LOG" && grep -q 'Do not push at all' "$CODEX_STUB_LOG"; }
check "prohibitions are in the prompt (no default-branch push, no gh pr merge, no team docs, no push when not granted)" rules_ok
check "reference/*.md mentions are inlined for Codex (bounded)" cx "const t=inlineReferences('run breakdown per reference/breakdown.md then reference/merge-verify.md §1'); if(!t.includes('===== reference/breakdown.md =====')||!t.includes('===== reference/merge-verify.md =====')||!t.includes('# Breakdown')) throw t.slice(0,200); if(inlineReferences('no refs here')!=='no refs here') throw 'changed'"
limited_ok() { CODEX_STUB_MODE=limited cx "const r=await codex.execute(makeJob({task:'x',cwd:'$SANDBOX'})); if(r.status!=='rate_limited') throw JSON.stringify(r)"; }
check "rate limit → rate_limited"                        limited_ok
failed_ok() { CODEX_STUB_MODE=failed cx "const r=await codex.execute(makeJob({task:'x',cwd:'$SANDBOX'})); if(r.status!=='failed'||r.summary!=='tests failed'||r.tests_failed.join()!=='npm test') throw JSON.stringify(r)"; }
check "turn.failed + failing test command → failed with tests_failed" failed_ok
unavail_ok() { CODEX_STUB_MODE=fail cx "const r=await codex.execute(makeJob({task:'x',cwd:'$SANDBOX'})); if(r.status!=='unavailable') throw JSON.stringify(r)" && cx "const e=new CodexExecutor({bin:'/nonexistent/codex'}); if(await e.available()) throw 'avail'; const r=await e.execute(makeJob({task:'x',cwd:'$SANDBOX'})); if(r.status!=='unavailable') throw r.status"; }
check "CLI missing/failing with no events → unavailable"  unavail_ok
probe_ok() { : > "$CODEX_STUB_LOG"; cx "if(!(await codex.probe())) throw 'probe'" && grep -q 'PROMPT: reply with exactly: ok' "$CODEX_STUB_LOG" && ! grep -q 'Hard rules' "$CODEX_STUB_LOG"; }
check "probe uses a bare prompt (no prohibitions block)"  probe_ok
no_codex_outside_adapter() { ! grep -rnE "codex['\" ]+exec|spawn[a-zA-Z]*\(['\"]codex" "$SRC/core" "$SRC/cli" "$SRC/brain" "$SRC/executors/claude" 2>/dev/null | grep -q .; }
check "no 'codex exec' outside the adapter"               no_codex_outside_adapter

echo "permissions — allowlist parity with the bash builder:"
CFG=$(jq -c '.commands={install:"",test:"npm test",lint:"npm run lint",build:"npm run build",app_run:"npm start"} | .repo.story_branch_prefix="autodev" | .backup.remote="backup"' "$PLUGIN/reference/deployment.example.json")
OUT=$(n "import {headlessAllowlist} from '$SRC/core/permissions.mjs'; console.log(headlessAllowlist($CFG).join('\n'))"); export OUT
check "configured commands granted"            has_re '^Bash\(npm test\)$'
check "empty command skipped"                  lacks 'Bash()'
check "feature-branch push"                    has_re '^Bash\(git push origin feature/\*\)$'
check "story-branch push"                      has_re '^Bash\(git push origin autodev/\*\)$'
check "backup-remote push"                     has_re '^Bash\(git push backup feature/\*\)$'
check "never gh pr merge / bare node / bare jq / default-branch push" bash -c '! grep -qE "gh pr merge|^Bash\(node \*\)|^Bash\(jq|git push [a-z]+ (main|master)" <<<"$OUT"'
check "tracker.mjs scoped (unquoted spelling)" has 'Bash(node ${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs *)'
check "tracker.mjs scoped (quoted spelling)"   has 'Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs" *)'
check "assertAllowlistInvariants rejects gh pr merge" bash -c "! node --input-type=module -e \"import {assertAllowlistInvariants} from '$SRC/core/permissions.mjs'; assertAllowlistInvariants(['Bash(gh pr merge:*)'],{})\" 2>/dev/null"
check "assertAllowlistInvariants rejects a default-branch push" bash -c "! node --input-type=module -e \"import {assertAllowlistInvariants} from '$SRC/core/permissions.mjs'; assertAllowlistInvariants(['Bash(git push origin main)'],{repo:{default_branch:'main'}})\" 2>/dev/null"
check "assertAllowlistInvariants passes the real list" n "import {headlessAllowlist,assertAllowlistInvariants} from '$SRC/core/permissions.mjs'; assertAllowlistInvariants(headlessAllowlist($CFG), $CFG)"

echo "core tracker wrapper (reads direct, writes through the facade):"
TR=$(mkrepo TrkCo '.tracker.instance_label="autodev:trkco"')
TJS="import {Tracker} from '$SRC/core/tracker.mjs'; const t=new Tracker({repoRoot:'$TR', configPath:'$TR/.autodev/deployment.json', cfg: JSON.parse(require('node:fs').readFileSync('$TR/.autodev/deployment.json','utf8'))});"
TJS="import {Tracker} from '$SRC/core/tracker.mjs'; import {readFileSync} from 'node:fs'; const t=new Tracker({repoRoot:'$TR', configPath:'$TR/.autodev/deployment.json', cfg: JSON.parse(readFileSync('$TR/.autodev/deployment.json','utf8'))});"
check "empty board reads as []"                     n "$TJS if(t.readIssues().length!==0) throw 'nonempty'"
check "createIssue returns the id (via the facade)"  n "$TJS const id=t.createIssue({title:'first', labels:['ai-eligible','autodev:trkco']}); if(id!=='AD-1') throw id"
check "move + note goes through the facade (history + comment recorded)" n "$TJS t.move('AD-1','ai_development','go'); const i=t.issue('AD-1'); if(i.stage!=='ai_development'||i.comments.at(-1).body!=='go'||i.history.at(-1).to!=='ai_development') throw JSON.stringify(i)"
check "ownIssues filters to the instance label (principle 10)" n "$TJS t.createIssue({title:'foreign'}); if(t.readIssues().length!==2) throw 'all'; const own=t.ownIssues(); if(own.length!==1||own[0].id!=='AD-1') throw JSON.stringify(own)"
check "inStage uses own lane"                       n "$TJS t.createIssue({title:'mine2', stage:'ai_qa', labels:['autodev:trkco']}); const s=t.inStage('ai_qa'); if(s.length!==1||s[0].title!=='mine2') throw JSON.stringify(s)"
check "no label configured → every issue is own"    n "import {Tracker} from '$SRC/core/tracker.mjs'; const t=new Tracker({repoRoot:'$TR', configPath:'$TR/.autodev/deployment.json', cfg:{tracker:{kind:'local'}}}); if(t.ownIssues().length!==3) throw t.ownIssues().length"
check "facade errors surface as TrackerError"       n "$TJS try { t.move('AD-1','nope'); throw new Error('no throw') } catch(e){ if(e.constructor.name!=='TrackerError'||!/unknown stage key/.test(e.message)) throw e }"
check "direct reads refuse non-local kinds"         n "import {Tracker} from '$SRC/core/tracker.mjs'; const t=new Tracker({repoRoot:'$TR', cfg:{tracker:{kind:'linear'}}}); try { t.readIssues(); throw new Error('no throw') } catch(e){ if(!/tracker.kind=local/.test(e.message)) throw e }"
check "readIssues ignores _projects.json + dotfiles" n "$TJS import {writeFileSync} from 'node:fs'; writeFileSync('$TR/.autodev/board/_projects.json','{}'); writeFileSync('$TR/.autodev/board/.mirror-queue.jsonl',''); if(t.readIssues().length!==3) throw t.readIssues().length"

echo "core git wrapper:"
G=$(mktemp -d "$SANDBOX/g.XXXXXX"); git -C "$G" init -q; echo a > "$G/a"; git -C "$G" add -A; git -C "$G" commit -qm one
GJS="import * as g from '$SRC/core/git.mjs';"
check "toplevel / currentBranch / headSha / isClean" n "$GJS const b=g.currentBranch('$G'); if(!['main','master'].includes(b)) throw b; if(g.toplevel('$G')!=='$(cd "$G" && pwd -P)') throw g.toplevel('$G'); if(g.headSha('$G').length!==40) throw 'sha'; if(!g.isClean('$G')) throw 'dirty'"
check "read helpers return null outside a repo, never throw" n "$GJS if(g.currentBranch('$SANDBOX')!==null||g.headSha('$SANDBOX')!==null) throw 'not null'"
check "worktreeAdd creates the branch + worktree; worktreeList sees it" n "$GJS import {existsSync} from 'node:fs'; g.worktreeAdd('$G','$G-wt','autodev/sc-1/x'); if(!existsSync('$G-wt/a')) throw 'no checkout'; const w=g.worktreeList('$G').find(x=>x.branch==='autodev/sc-1/x'); if(!w) throw JSON.stringify(g.worktreeList('$G'))"
check "commitsAhead / mergedInto"                   n "$GJS import {writeFileSync} from 'node:fs'; import {execSync} from 'node:child_process'; writeFileSync('$G-wt/b','b'); execSync('git add -A && git commit -qm two', {cwd:'$G-wt', env:process.env}); const base=g.currentBranch('$G'); const ahead=g.commitsAhead('$G','autodev/sc-1/x',base); if(ahead.length!==1||ahead[0].subject!=='two') throw JSON.stringify(ahead); if(g.mergedInto('$G','autodev/sc-1/x',base)) throw 'merged?'; execSync('git merge -q --squash autodev/sc-1/x && git commit -qm sq', {cwd:'$G', env:process.env}); if(g.commitsAhead('$G',base,'autodev/sc-1/x').length!==1) throw 'squash'"
check "worktreeRemove"                              n "$GJS import {existsSync} from 'node:fs'; g.worktreeRemove('$G','$G-wt',{force:true}); if(existsSync('$G-wt')) throw 'still there'; if(g.worktreeList('$G').length!==1) throw 'list'"
check "mutating helpers throw GitError"             n "$GJS try { g.worktreeRemove('$G','/nonexistent/wt'); throw new Error('no throw') } catch(e){ if(e.constructor.name!=='GitError') throw e }"

echo "package manifest:"
check "package.json version == plugin.json version (one release number)" bash -c "[ \"\$(jq -r .version '$PLUGIN/package.json')\" = \"\$(jq -r .version '$PLUGIN/.claude-plugin/plugin.json')\" ]"
check "bin → bin/autodev.mjs, executable"      bash -c "[ \"\$(jq -r '.bin.autodev' '$PLUGIN/package.json')\" = ./bin/autodev.mjs ] && test -x '$PLUGIN/bin/autodev.mjs'"
check "zero runtime dependencies"              bash -c "[ \"\$(jq -r '(.dependencies//{})|length' '$PLUGIN/package.json')\" = 0 ]"

exit $FAIL
