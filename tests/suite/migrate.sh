#!/usr/bin/env bash
# Milestone 14 — `autodev migrate --from claude`: discovers + classifies every
# artifact of a v2 Claude/autoDev project and the user's Claude config, imports the
# portable ones into the sidecar + Brain, leaves every original untouched.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
CLI="$PLUGIN/bin/autodev.mjs"
STUB="$PLUGIN/tests/fixtures/brain-stub.mjs"
export AUTODEV_HOME="$SANDBOX/autodev-home-migrate" AUTODEV_NO_KEYCHAIN=1 BRAIN_STUB_LOG="$SANDBOX/mig-requests.jsonl"
n() { node --input-type=module -e "$1"; }
reqs() { cat "$BRAIN_STUB_LOG" 2>/dev/null; }; export -f reqs

# ---- a realistic v2 project: team docs, .claude/, .mcp.json, .autodev state, specs, history
R=$(mkrepo MigCo '.braingrid.enabled=true | .braingrid.project_short_id="PROJ-9" | del(.planning) | .commands.test="npm test"')
cat > "$R/CLAUDE.md" <<'EOF'
# MigCo engineering rules

## Types
Use the generated GraphQL types. Never hand-write schema types.

## Styling
Use the MUI theme tokens; never hardcode colors.
EOF
printf '# Team\n\n## Testing\nEvery PR ships tests.\n' > "$R/AGENTS.md"
mkdir -p "$R/.claude/commands" "$R/.claude/agents" "$R/.claude/skills" "$R/specs/assign-owner"
printf -- '---\ndescription: deploy\n---\nRun the deploy.\n' > "$R/.claude/commands/deploy.md"
printf -- '---\nname: migco-reviewer\ndescription: our reviewer\n---\nReview like MigCo.\n' > "$R/.claude/agents/migco-reviewer.md"
printf 'skill\n' > "$R/.claude/skills/thing.md"
printf '{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}\n' > "$R/.claude/settings.json"
printf '{"mcpServers":{"playwright":{"command":"npx"}}}\n' > "$R/.mcp.json"
printf '# Assign owner\n\nProblem: nobody owns applications.\n\n## Acceptance criteria\n- [ ] owner is nullable for legacy rows\n- an owner can be assigned\n\n## Non-goals\n- bulk reassign\n' > "$R/specs/assign-owner/prd.md"
printf 'brief text\n' > "$R/specs/assign-owner/brief.md"
printf '# Detected project conventions\n\n## Stack\n- TypeScript\n\n## Comments\n- WHY not WHAT\n' > "$R/.autodev/conventions.md"
printf '{"tick":"x"}\n' > "$R/.autodev/metrics.jsonl"
(cd "$R" && node "$TRK" create-issue --title "Feature: ownership" --stage prd_review --labels "route:feature,autodev:migco" --desc $'spec\n\n## Acceptance criteria\n- owner nullable' >/dev/null && node "$TRK" create-issue --title "story A" --stage ready_for_ai_dev --labels "ai-eligible,autodev:migco" >/dev/null)
jq '.linear_id="LIN-1" | .description += "\n\nBrainGrid PROJ-9 / T-1"' "$R/.autodev/board/AD-2.json" > "$R/t" && mv "$R/t" "$R/.autodev/board/AD-2.json"
jq '.tracker.kind="linear"' "$R/.autodev/deployment.json" > "$R/t" && mv "$R/t" "$R/.autodev/deployment.json"   # a Linear deployment whose board was mirrored locally
git -C "$R" add -A >/dev/null; git -C "$R" commit -qm "v2 project" >/dev/null; git -C "$R" branch feature/ownership >/dev/null
# user-level Claude config in the sandbox HOME
mkdir -p "$HOME/.claude/agents" "$HOME/.claude/commands"
printf '# Eric rules\n\n## Never commit credentials\nNo tokens in git, ever.\n\n## Terse\nKeep replies short.\n' > "$HOME/.claude/CLAUDE.md"
printf -- '---\nname: shared-thing\n---\nx\n' > "$HOME/.claude/agents/shared-thing.md"
printf 'cmd\n' > "$HOME/.claude/commands/mine.md"
printf '{"enabledPlugins":{"autodev@autodev-marketplace":true}}\n' > "$HOME/.claude/settings.json"
BEFORE=$(cd "$R" && git rev-parse HEAD; find "$R" -type f -not -path '*/.git/*' -exec md5 -q {} \; 2>/dev/null | sort | md5 -q)

echo "discovery + classification:"
DJS="import {discoverProject,discoverUser,sectionsOf,parsePrd} from '$SRC/migrate/discover.mjs';"
check "team docs → portable (rules), sections counted"      n "$DJS const a=discoverProject('$R'); const c=a.find(x=>x.path==='CLAUDE.md'); if(!c||c.class!=='portable'||c.sections!==2) throw JSON.stringify(c); if(!a.find(x=>x.path==='AGENTS.md')) throw 'agents'"
check "deployment → portable, planning derived from the legacy braingrid flag" n "$DJS const a=discoverProject('$R'); const d=a.find(x=>x.kind==='deployment-config'); if(d.class!=='portable'||d.tracker!=='linear'||!/braingrid/.test(d.planning)) throw JSON.stringify(d)"
check "braingrid + linear mappings → legacy"                 n "$DJS const a=discoverProject('$R'); if(a.find(x=>x.kind==='braingrid-config').class!=='legacy'||a.find(x=>x.kind==='linear-mapping').class!=='legacy') throw 'x'"
check "board → portable with issue/feature/linear/braingrid counts" n "$DJS const b=discoverProject('$R').find(x=>x.kind==='board'); if(b.issues!==2||b.features!==1||b.linear_mirrored!==1||b.braingrid_refs!==1) throw JSON.stringify(b)"
check "conventions portable · metrics legacy"                n "$DJS const a=discoverProject('$R'); if(a.find(x=>x.kind==='conventions').class!=='portable'||a.find(x=>x.kind==='metrics').class!=='legacy') throw 'x'"
check "prd → portable with parsed acceptance criteria"       n "$DJS const p=discoverProject('$R').find(x=>x.kind==='prd'); if(p.slug!=='assign-owner'||p.title!=='Assign owner'||p.acceptance_criteria!==2) throw JSON.stringify(p)"
check "commands/skills → adaptable+executor · agents → adaptable+project" n "$DJS const a=discoverProject('$R'); if(a.find(x=>x.kind==='command').scope!=='executor'||a.find(x=>x.kind==='skill').class!=='adaptable'||a.find(x=>x.kind==='agent').scope!=='project') throw 'x'"
check "settings.json → vendor-specific (hooks + permissions counted)" n "$DJS const s=discoverProject('$R').find(x=>x.kind==='claude-settings'); if(s.class!=='vendor-specific'||s.hooks!==1||s.permissions!==1) throw JSON.stringify(s)"
check ".mcp.json → adaptable with server names"              n "$DJS const m=discoverProject('$R').find(x=>x.kind==='mcp-config'); if(m.servers.join()!=='playwright') throw JSON.stringify(m)"
check "git history referenced, in-flight branches listed"    n "$DJS const a=discoverProject('$R'); if(!a.find(x=>x.kind==='git-history')||a.find(x=>x.kind==='branches').branches.join()!=='feature/ownership') throw 'git'"
check "user-level: rules are CANDIDATES, agents/commands/settings classified" n "$DJS const u=discoverUser('$HOME'); const r=u.find(x=>x.kind==='user-rules'); if(r.class!=='portable'||r.scope!=='user'||!/CANDIDATE/.test(r.action)||r.sections!==2) throw JSON.stringify(r); if(u.find(x=>x.kind==='user-settings').class!=='vendor-specific'||u.find(x=>x.kind==='user-agents').count!==1) throw 'u'"
check "parsePrd handles checkbox + numbered bullets"          n "$DJS const p=parsePrd('# T\\n\\n## Acceptance criteria\\n- [x] a\\n1. b\\n\\n## Other\\n- c'); if(p.title!=='T'||p.acceptance_criteria.join()!=='a,b') throw JSON.stringify(p)"
check "sectionsOf skips the v2 identity pointer"             n "$DJS if(sectionsOf('# X (autoDev POINTER)\\n\\n> This file is an **autoDev POINTER**').length) throw 'pointer'"
check "discovery never writes"                               bash -c "[ \"\$(cd '$R' && git rev-parse HEAD; find '$R' -type f -not -path '*/.git/*' -exec md5 -q {} \\; 2>/dev/null | sort | md5 -q)\" = \"$BEFORE\" ]"

echo "dry run — nothing written anywhere:"
OUT=$(cd "$R" && node "$CLI" migrate --from claude --dry-run 2>&1); rc=$?
check "exit 0 with the report on stdout"                     bash -c "[ $rc -eq 0 ]"
check "report says DRY RUN"                                  has 'DRY RUN — nothing was written'
check "report tables list classes + actions"                 bash -c "grep -q '| portable | project | \`CLAUDE.md\` | team-docs (2 sections)' <<<\"\$0\" && grep -q '| legacy | project | \`.autodev/deployment.json#braingrid\`' <<<\"\$0\" && grep -q 'CANDIDATE user rules' <<<\"\$0\"" "$OUT"
PID=$(jq -r '.projects[] | select(.name=="MigCo") | .id' "$AUTODEV_HOME/state/registry.json")
check "no sidecar deployment/board/migration report written" bash -c "! test -e '$AUTODEV_HOME/state/projects/$PID/deployment.json' && ! test -e '$AUTODEV_HOME/state/projects/$PID/migrations' && [ -z \"\$(ls '$AUTODEV_HOME/state/projects/$PID/board' 2>/dev/null)\" ]"
check "repo byte-identical"                                  bash -c "[ \"\$(cd '$R' && git rev-parse HEAD; find '$R' -type f -not -path '*/.git/*' -exec md5 -q {} \\; 2>/dev/null | sort | md5 -q)\" = \"$BEFORE\" ]"
check "unsupported --from → exit 2"                          bash -c "cd '$R' && node '$CLI' migrate --from cursor >/dev/null 2>&1; [ \$? -eq 2 ]"

echo "apply without Brain — sidecar only, originals untouched:"
OUT=$(cd "$R" && node "$CLI" migrate --from claude 2>&1); rc=$?
check "exit 0"                                               bash -c "[ $rc -eq 0 ]"
check "sidecar deployment written, normalized: planning=braingrid (legacy flag honored), tracker=local, no _notes, no runner/local_path" bash -c "jq -e '.planning.engine==\"braingrid\" and .tracker.kind==\"local\" and (.runner==null) and (.repo.local_path==null) and (._migrated.original_tracker==\"linear\") and (has(\"_assistant_name_note\")|not)' '$AUTODEV_HOME/state/projects/$PID/deployment.json'"
check "…validates against the schema"                        has 'valid'
check "board copied into the sidecar (2 issues + counter), source left" bash -c "test -f '$AUTODEV_HOME/state/projects/$PID/board/AD-1.json' && test -f '$AUTODEV_HOME/state/projects/$PID/board/AD-2.json' && test -f '$AUTODEV_HOME/state/projects/$PID/board/.counter' && test -f '$R/.autodev/board/AD-1.json'"
check "project-level agent adopted into the Agency store"     bash -c "test -f '$AUTODEV_HOME/agents/personas/migco-reviewer.md' && grep -q 'adopted 1 persona' <<<\"\$0\"" "$OUT"
check "Brain steps reported as skipped, user rules listed as candidates" bash -c "grep -q 'skipped: Brain: not configured' <<<\"\$0\" && grep -q 'user-rule: \*\*Never commit credentials\*\*' <<<\"\$0\"" "$OUT"
check "migration report saved under the sidecar (md + json)" bash -c "ls '$AUTODEV_HOME/state/projects/$PID/migrations/' | grep -q '\.md$' && ls '$AUTODEV_HOME/state/projects/$PID/migrations/' | grep -q '\.json$'"
check "migration event + state commit"                       bash -c "cat '$AUTODEV_HOME/state/projects/$PID/events/'*.jsonl | grep -q '\"type\":\"migration.applied\"' && git -C '$AUTODEV_HOME/state' log --oneline | grep -q 'migrated from claude'"
check "REPO BYTE-IDENTICAL after apply (git status clean, hashes equal)" bash -c "[ -z \"\$(git -C '$R' status --porcelain)\" ] && [ \"\$(cd '$R' && git rev-parse HEAD; find '$R' -type f -not -path '*/.git/*' -exec md5 -q {} \\; 2>/dev/null | sort | md5 -q)\" = \"$BEFORE\" ]"
check "status now reads the SIDECAR deployment + board (migrated project)" bash -c "cd '$R' && node '$CLI' status | grep -q 'sidecar deployment \"MigCo\" · tracker local (sidecar board)'"
check "…AUTODEV_PREFER_LEGACY=1 still reads the v2 file (plugin path parity)" bash -c "cd '$R' && AUTODEV_PREFER_LEGACY=1 node '$CLI' status | grep -q 'v2 deployment \"MigCo\" · tracker linear'"
check "…the sidecar board serves next/gates"                 bash -c "cd '$R' && node '$CLI' next | grep -q 'Gate 1 (PRD Review (H)): AD-1 Feature: ownership'"
check "re-run is idempotent: board unchanged, second report"  bash -c "cd '$R' && node '$CLI' migrate 2>&1 | grep -q '0 copied, 3 unchanged' && [ \$(ls '$AUTODEV_HOME/state/projects/$PID/migrations/' | grep -c '\.md$') -eq 2 ]"

echo "apply with Brain — rules, conventions, requirements imported idempotently:"
: > "$BRAIN_STUB_LOG"
node "$STUB" > "$SANDBOX/mig.port" 2>/dev/null & SP=$!; for _ in $(seq 50); do [[ -s "$SANDBOX/mig.port" ]] && break; sleep 0.05; done
URL="http://127.0.0.1:$(cat "$SANDBOX/mig.port")"; export BRAIN_TOKEN=stub-token
jq --arg u "$URL" '.brain.enabled=true | .brain.url=$u' "$AUTODEV_HOME/state/projects/$PID/deployment.json" > "$SANDBOX/t" && mv "$SANDBOX/t" "$AUTODEV_HOME/state/projects/$PID/deployment.json"
OUT=$(cd "$R" && node "$CLI" migrate 2>&1); rc=$?
check "exit 0 with Brain connected"                          bash -c "[ $rc -eq 0 ] && grep -q 'brain: [0-9]* import' <<<\"\$0\"" "$OUT"
check "CLAUDE.md sections → rule candidates (project scope, documentation provenance)" bash -c "reqs | grep '/v1/memory' | jq -e 'select(.body.type==\"rule\") | .body.state==\"candidate\" and .body.provenance[0].type==\"documentation\" and (.idem|startswith(\"migrate:\"))' | grep -c true | grep -qx 3"
check "conventions → convention observations"               bash -c "reqs | grep '/v1/memory' | jq -e 'select(.body.type==\"convention\") | .body.state==\"observation\"' | grep -c true | grep -qx 2"
check "PRD → requirement with key + acceptance criteria"     bash -c "reqs | grep '/requirements' | jq -e 'select(.body.key==\"assign-owner\") | .body.title==\"Assign owner\" and (.body.acceptance_criteria|length)==2' | grep -q true"
check "board feature → requirement with legacy_autodev ref"  bash -c "reqs | grep '/requirements' | jq -e 'select(.body.key==\"AD-1\") | .body.external_refs.legacy_autodev==\"AD-1\"' | grep -q true"
check "user rules NOT imported without --import-user"        bash -c "! reqs | grep '/v1/memory' | jq -e 'select(.body.scope.type==\"user\")' | grep -q ."
: > "$BRAIN_STUB_LOG"
check "re-run: every import replayed (idempotency keys), nothing duplicated" bash -c "cd '$R' && node '$CLI' migrate 2>&1 | grep -q 'already present, replayed idempotently' && [ \$(reqs | grep -c '/v1/memory') -eq 5 ] && [ \$(reqs | grep '/v1/memory' | jq -r .idem | sort -u | wc -l) -eq 5 ]"
: > "$BRAIN_STUB_LOG"
check "--import-user → user-scope OBSERVATIONS (never canonical)" bash -c "cd '$R' && node '$CLI' migrate --import-user >/dev/null 2>&1; reqs | grep '/v1/memory' | jq -e 'select(.body.scope.type==\"user\") | .body.state==\"observation\" and .body.visibility==\"user\"' | grep -c true | grep -qx 2"
check "repo STILL byte-identical after everything"           bash -c "[ -z \"\$(git -C '$R' status --porcelain)\" ] && [ \"\$(cd '$R' && git rev-parse HEAD; find '$R' -type f -not -path '*/.git/*' -exec md5 -q {} \\; 2>/dev/null | sort | md5 -q)\" = \"$BEFORE\" ]"
check "user-level files untouched"                           bash -c "grep -q 'Never commit credentials' '$HOME/.claude/CLAUDE.md' && test -f '$HOME/.claude/agents/shared-thing.md'"
kill $SP 2>/dev/null; wait $SP 2>/dev/null

echo "edge cases:"
E=$(mktemp -d "$SANDBOX/empty.XXXXXX"); git -C "$E" init -q; echo x > "$E/f"; git -C "$E" add -A; git -C "$E" commit -qm i >/dev/null
check_out "a repo with nothing to migrate reports so"        "no .autodev/deployment.json — nothing to normalize" bash -c "cd '$E' && node '$CLI' migrate 2>&1"
check "…and stays clean"                                      bash -c "[ -z \"\$(git -C '$E' status --porcelain)\" ]"

exit $FAIL
