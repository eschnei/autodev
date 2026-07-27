#!/usr/bin/env bash
# autoDev smoke test — exercises the plugin's scripts and hooks directly against a
# synthetic client repo, asserting the contracts that have bitten us in real
# deployments. No Claude invocation (the commands themselves are prose, interpreted
# by Claude at runtime — not something a shell script can drive). Run: tests/smoke.sh
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}

# ---- synthetic client repo: team docs + foreign settings + a pre-existing git hook + MUI/codegen ----
TGT=$(mktemp -d); trap 'rm -rf "$TGT"' EXIT
git -C "$TGT" init -q
printf '# Team conventions\n- Commit directly to main for hotfixes.\n- Use the MUI theme.\n' > "$TGT/AGENTS.md"
mkdir -p "$TGT/.claude"; echo 'team rules' > "$TGT/.claude/CLAUDE.md"
echo '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$TGT/.claude/settings.json"
mkdir -p "$TGT/.git/hooks"; printf '#!/bin/sh\nexit 0\n' > "$TGT/.git/hooks/pre-push"; chmod +x "$TGT/.git/hooks/pre-push"
echo '{"dependencies":{"react":"18","@mui/material":"5"},"devDependencies":{"@graphql-codegen/cli":"5"}}' > "$TGT/package.json"
echo '{}' > "$TGT/tsconfig.json"; touch "$TGT/codegen.ts"

# Simulates what /autodev:init would have written — there's no shell entry point for
# the actual command (it's prose, interpreted by Claude), so this test starts from
# its output instead of driving it.
mkdir -p "$TGT/.autodev"
jq '.client_name="SmokeCo" | .repo.local_path=$p | .tracker.kind="local"' \
  --arg p "$TGT" "$PLUGIN/reference/deployment.example.json" > "$TGT/.autodev/deployment.json"
bash "$PLUGIN/scripts/write-identity-pointer.sh" "$TGT" >/dev/null 2>&1

echo "footprint (the whole point of the plugin conversion):"
check "no .claude/skills written" bash -c "! test -d '$TGT/.claude/skills'"
check "no .claude/autodev.md written" bash -c "! test -f '$TGT/.claude/autodev.md'"
check "no scripts/autodev written" bash -c "! test -d '$TGT/scripts'"
check "team .claude/settings.json untouched" grep -q "Bash(ls" "$TGT/.claude/settings.json"
check "team AGENTS.md untouched" grep -q "Use the MUI theme" "$TGT/AGENTS.md"
check "team .claude/CLAUDE.md untouched" grep -q "team rules" "$TGT/.claude/CLAUDE.md"
check "pre-existing .git/hooks/pre-push untouched" grep -q "exit 0" "$TGT/.git/hooks/pre-push"
check "no {{ left unrendered in the plugin itself" bash -c \
  "! grep -rl '{{' '$PLUGIN/commands' '$PLUGIN/reference' '$PLUGIN/hooks' '$PLUGIN/scripts' 2>/dev/null"

echo "conventions:"
bash "$PLUGIN/scripts/detect-conventions.sh" "$TGT" > "$TGT/.autodev/conventions.md"
check "codegen rule detected" grep -q "GraphQL code generation" "$TGT/.autodev/conventions.md"
check "MUI theme rule detected" grep -q "Material UI" "$TGT/.autodev/conventions.md"
check "comment rule present" grep -q "explain WHY" "$TGT/.autodev/conventions.md"

echo "docs conflict scan:"
check "flags 'commit directly to main'" bash -c "bash '$PLUGIN/scripts/check-docs.sh' '$TGT' | grep -q 'only humans merge'"

echo "identity pointer (hook-less fallback):"
# scenario A: the main TGT has a TEAM CLAUDE.md — must have been preserved (asserted
# above). scenario B: bare repo -> pointer written. C: our stale pointer -> replaced.
T2=$(mktemp -d); git -C "$T2" init -q; echo '{}' > "$T2/package.json"
mkdir -p "$T2/.autodev"
jq '.client_name="BareCo" | .repo.local_path=$p | .tracker.kind="local"' \
  --arg p "$T2" "$PLUGIN/reference/deployment.example.json" > "$T2/.autodev/deployment.json"
bash "$PLUGIN/scripts/write-identity-pointer.sh" "$T2" >/dev/null 2>&1
check "bare repo gets the pointer" grep -q "autoDev POINTER" "$T2/.claude/CLAUDE.md"
check "pointer names the command surface" grep -q "/autodev:loop" "$T2/.claude/CLAUDE.md"
printf '# BareCo — autoDev engine\nold stale rulebook\n' > "$T2/.claude/CLAUDE.md"
bash "$PLUGIN/scripts/write-identity-pointer.sh" "$T2" >/dev/null 2>&1
check "our stale pointer is replaced (not treated as a team file)" grep -q "autoDev POINTER" "$T2/.claude/CLAUDE.md"
rm -rf "$T2"

echo "session engagement (session_mode: concierge | signal | silent):"
check "concierge (default): full identity + manual + conventions injected" bash -c \
  "echo '{\"cwd\":\"$TGT\"}' | CLAUDE_PLUGIN_ROOT='$PLUGIN' '$PLUGIN/hooks/session-signal.sh' | jq -e '.hookSpecificOutput.additionalContext | contains(\"You are\") and contains(\"concierge\") and contains(\"Non-negotiable\")'"
jq '.session_mode="signal"' "$TGT/.autodev/deployment.json" > "$TGT/.autodev/t" && mv "$TGT/.autodev/t" "$TGT/.autodev/deployment.json"
check "signal: one short line naming both commands" bash -c \
  "echo '{\"cwd\":\"$TGT\"}' | '$PLUGIN/hooks/session-signal.sh' | jq -e '.hookSpecificOutput.additionalContext | contains(\"/autodev:loop\") and contains(\"/autodev:new\") and (length < 200)'"
jq '.session_mode="silent"' "$TGT/.autodev/deployment.json" > "$TGT/.autodev/t" && mv "$TGT/.autodev/t" "$TGT/.autodev/deployment.json"
check "silent: nothing" bash -c \
  "test -z \"\$(echo '{\"cwd\":\"$TGT\"}' | '$PLUGIN/hooks/session-signal.sh')\""
jq 'del(.session_mode)' "$TGT/.autodev/deployment.json" > "$TGT/.autodev/t" && mv "$TGT/.autodev/t" "$TGT/.autodev/deployment.json"
UNCONF=$(mktemp -d)
check "silent when unconfigured" bash -c \
  "test -z \"\$(echo '{\"cwd\":\"$UNCONF\"}' | '$PLUGIN/hooks/session-signal.sh')\""
rmdir "$UNCONF"

echo "session marker (UserPromptSubmit — gates the guards below to sessions that engaged autoDev):"
MARKDIR="${TMPDIR:-/tmp}/autodev-sessions"
SID="smoke-engaged-$$"
UNSID="smoke-unengaged-$$"
rm -f "$MARKDIR/$SID" "$MARKDIR/$UNSID"
check "an autoDev slash command stamps the session marker" bash -c \
  "echo '{\"session_id\":\"$SID\",\"prompt\":\"/autodev:loop\"}' | '$PLUGIN/hooks/session-mark.sh' >/dev/null 2>&1; test -f '$MARKDIR/$SID'"
check "an ordinary prompt does not stamp a marker" bash -c \
  "echo '{\"session_id\":\"$UNSID\",\"prompt\":\"please push my branch\"}' | '$PLUGIN/hooks/session-mark.sh' >/dev/null 2>&1; ! test -f '$MARKDIR/$UNSID'"

echo "push guard (PreToolUse — replaces .git/hooks/pre-push; only active once the session engaged autoDev):"
check "unengaged session: even a main-branch push is a no-op" bash -c \
  "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"},\"cwd\":\"$TGT\",\"session_id\":\"$UNSID\"}' | '$PLUGIN/hooks/guard-push.sh' | wc -c | tr -d '[:space:]' | grep -qx 0"
check "feature branch push allowed" bash -c \
  "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin feature/x\"},\"cwd\":\"$TGT\",\"session_id\":\"$SID\"}' | '$PLUGIN/hooks/guard-push.sh' | wc -c | tr -d '[:space:]' | grep -qx 0"
check "main branch push denied" bash -c \
  "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"},\"cwd\":\"$TGT\",\"session_id\":\"$SID\"}' | '$PLUGIN/hooks/guard-push.sh' | jq -e '.hookSpecificOutput.permissionDecision == \"deny\"'"
jq '.review.delivery="local_diff"' "$TGT/.autodev/deployment.json" > "$TGT/.autodev/t" && mv "$TGT/.autodev/t" "$TGT/.autodev/deployment.json"
check "local_diff: even a feature push is denied" bash -c \
  "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin feature/x\"},\"cwd\":\"$TGT\",\"session_id\":\"$SID\"}' | '$PLUGIN/hooks/guard-push.sh' | jq -e '.hookSpecificOutput.permissionDecision == \"deny\"'"
jq '.review.delivery="draft_pr"' "$TGT/.autodev/deployment.json" > "$TGT/.autodev/t" && mv "$TGT/.autodev/t" "$TGT/.autodev/deployment.json"

echo "docs guard (PreToolUse — replaces the settings.json deny rule; only active once the session engaged autoDev):"
check "unengaged session: Edit on AGENTS.md is a no-op" bash -c \
  "echo '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TGT/AGENTS.md\"},\"session_id\":\"$UNSID\"}' | '$PLUGIN/hooks/guard-docs.sh' | wc -c | tr -d '[:space:]' | grep -qx 0"
check "Edit on AGENTS.md denied" bash -c \
  "echo '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TGT/AGENTS.md\"},\"session_id\":\"$SID\"}' | '$PLUGIN/hooks/guard-docs.sh' | jq -e '.hookSpecificOutput.permissionDecision == \"deny\"'"
check "Edit elsewhere allowed" bash -c \
  "echo '{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TGT/src/foo.ts\"},\"session_id\":\"$SID\"}' | '$PLUGIN/hooks/guard-docs.sh' | wc -c | tr -d '[:space:]' | grep -qx 0"

echo "local tracker (git-native board):"
TRK="$PLUGIN/scripts/tracker.mjs"
LID=$(cd "$TGT" && node "$TRK" create-issue --title "Smoke story" --stage ready_for_ai_dev --labels ai-eligible 2>/dev/null)
check "create-issue returns an id" test -n "$LID"
check "move + note" bash -c "cd '$TGT' && node '$TRK' move '$LID' ai_development --note 'dev started' | grep -q 'AI Development'"
check "comment" bash -c "cd '$TGT' && node '$TRK' comment '$LID' 'progress'"
check "history recorded in issue file" bash -c "jq -e '.history | length >= 2' '$TGT/.autodev/board/$LID.json'"
check "board renders html" bash -c "cd '$TGT' && node '$TRK' board >/dev/null && test -f '$TGT/.autodev/board.html'"
check "tracker doctor ok" bash -c "cd '$TGT' && node '$TRK' doctor | grep -q 'local board'"

echo "vendored-install migration:"
T3=$(mktemp -d); git -C "$T3" init -q
mkdir -p "$T3/.claude/skills" "$T3/scripts/autodev" "$T3/.autodev/board" "$T3/.git/hooks"
echo "# X — autoDev engine manual" > "$T3/.claude/autodev.md"
echo "autoDev skill" > "$T3/.claude/skills/intake.md"
echo "team skill, unrelated" > "$T3/.claude/skills/myteam.md"
echo "old" > "$T3/scripts/autodev/linear.mjs"
echo '{"_comment":"autoDev headless permissions","permissions":{}}' > "$T3/.claude/settings.json"
echo '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$T3/.claude/settings.json.pre-autodev"
printf '#!/bin/sh\n# autoDev pre-push guard\nexit 1\n' > "$T3/.git/hooks/pre-push"
echo '{"client_name":"X","tracker":{"kind":"local"}}' > "$T3/.autodev/deployment.json"
echo '{"id":"AD-1"}' > "$T3/.autodev/board/AD-1.json"
bash "$PLUGIN/scripts/migrate-vendored.sh" "$T3" >/dev/null 2>&1
check "engine artifacts removed" bash -c "! test -f '$T3/.claude/autodev.md' && ! test -f '$T3/.claude/skills/intake.md' && ! test -d '$T3/scripts/autodev'"
check "team skill survives" test -f "$T3/.claude/skills/myteam.md"
check "team settings restored" grep -q "Bash(ls" "$T3/.claude/settings.json"
check "our pre-push removed" bash -c "! test -f '$T3/.git/hooks/pre-push'"
check "state preserved" bash -c "test -f '$T3/.autodev/deployment.json' && test -f '$T3/.autodev/board/AD-1.json'"
check "backup populated" test -f "$T3/.autodev/backup-vendored/.claude/autodev.md"
check "idempotent (2nd run finds nothing)" bash -c "bash '$PLUGIN/scripts/migrate-vendored.sh' '$T3' | grep -q 'no vendored install found'"
rm -rf "$T3"

echo "config schema upgrade + history detection:"
T5=$(mktemp -d); mkdir -p "$T5/.autodev" "$T5/scripts/autodev"; git -C "$T5" init -q
echo old > "$T5/scripts/autodev/linear.mjs"
jq 'del(.session_mode, .preview, .backup, .backlog, .intake.bugs, .tracker.instance_label, .qa.visual_qa)
    | .client_name="Hist Co" | .execution.max_lanes=2' "$PLUGIN/reference/deployment.example.json" > "$T5/.autodev/deployment.json"
check "session hook flags HISTORY (artifacts+schema) with the update steps" bash -c \
  "echo '{\"cwd\":\"$T5\"}' | CLAUDE_PLUGIN_ROOT='$PLUGIN' '$PLUGIN/hooks/session-signal.sh' | jq -e '.hookSpecificOutput.additionalContext | contains(\"HISTORY detected (artifacts+schema)\") and contains(\"upgrade-config.sh\") and contains(\"in flight\")'"
bash "$PLUGIN/scripts/upgrade-config.sh" "$T5" >/dev/null
check "upgrade adds new keys with defaults" bash -c "jq -e '.session_mode==\"concierge\" and .preview.enabled==true and (.intake.bugs==\"triage\") and (.backlog.enabled==false) and (.backlog.batch==3)' '$T5/.autodev/deployment.json'"
check "operator values preserved" bash -c "jq -e '.execution.max_lanes==2 and .client_name==\"Hist Co\"' '$T5/.autodev/deployment.json'"
check "instance label derived from client_name (not the example's)" bash -c "jq -e '.tracker.instance_label==\"autodev:hist-co\"' '$T5/.autodev/deployment.json'"
check "upgrade idempotent" bash -c "bash '$PLUGIN/scripts/upgrade-config.sh' '$T5' | grep -q 'already current'"
bash "$PLUGIN/scripts/migrate-vendored.sh" "$T5" >/dev/null 2>&1
check "after update: session hook no longer flags history" bash -c \
  "echo '{\"cwd\":\"$T5\"}' | CLAUDE_PLUGIN_ROOT='$PLUGIN' '$PLUGIN/hooks/session-signal.sh' | jq -e '.hookSpecificOutput.additionalContext | contains(\"HISTORY detected\") | not'"
rm -rf "$T5"

echo "autoQA surface (deep-dive QA + repro hunt):"
check "commands/qa.md exists" test -f "$PLUGIN/commands/qa.md"
check "commands/repro.md exists" test -f "$PLUGIN/commands/repro.md"
check "reference/deep-qa.md exists" test -f "$PLUGIN/reference/deep-qa.md"
check "reference/repro.md exists" test -f "$PLUGIN/reference/repro.md"
check "qa.md frontmatter has a description" bash -c \
  "sed -n '2,/^---\$/p' '$PLUGIN/commands/qa.md' | grep -q '^description: .'"
check "repro.md frontmatter has a description" bash -c \
  "sed -n '2,/^---\$/p' '$PLUGIN/commands/repro.md' | grep -q '^description: .'"
check "example config declares deep_dive.final_review" bash -c \
  "jq -e '.qa.deep_dive.final_review' '$PLUGIN/reference/deployment.example.json'"
check "example config declares the repro caps" bash -c \
  "jq -e '.qa.repro.max_attempts and .qa.repro.wall_clock_minutes' '$PLUGIN/reference/deployment.example.json'"
# a config that predates the autoQA keys must gain them on upgrade, operator values intact
T6=$(mktemp -d); mkdir -p "$T6/.autodev"
jq 'del(.qa.deep_dive, .qa.repro) | .commands.test="npm run custom-test"' \
  "$PLUGIN/reference/deployment.example.json" > "$T6/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$T6" >/dev/null
check "upgrade adds autoQA keys with defaults" bash -c \
  "jq -e '.qa.deep_dive.final_review==true and .qa.repro.max_attempts==7 and .qa.repro.wall_clock_minutes==45' '$T6/.autodev/deployment.json'"
check "operator commands.test survives the merge" bash -c \
  "jq -e '.commands.test==\"npm run custom-test\"' '$T6/.autodev/deployment.json'"
rm -rf "$T6"

echo "shortcut tracker (driver + schema, no network):"
check "shortcut.mjs parses" node --check "$PLUGIN/scripts/shortcut.mjs"
check "tracker.mjs parses" node --check "$PLUGIN/scripts/tracker.mjs"
check "tracker.mjs dispatches kind=shortcut" bash -c \
  "grep -q \"KIND === 'shortcut'\" '$PLUGIN/scripts/tracker.mjs' && grep -q 'shortcut.mjs' '$PLUGIN/scripts/tracker.mjs'"
check "example config has the shortcut block" bash -c \
  "jq -e '.tracker.shortcut.api_token_env==\"SHORTCUT_API_TOKEN\" and .tracker.shortcut.workflow_id and .tracker.shortcut.statuses' '$PLUGIN/reference/deployment.example.json'"
# the engine's stage vocabulary must be identical across API trackers
check "stage-key parity: shortcut statuses == linear statuses" bash -c \
  "jq -e '(.tracker.statuses | keys) == (.tracker.shortcut.statuses | keys)' '$PLUGIN/reference/deployment.example.json'"
check "ops/shortcut-setup.md exists" test -f "$PLUGIN/ops/shortcut-setup.md"

echo "persona resolution (ensure-personas.sh — no network in any of these):"
check "ensure-personas.sh parses" bash -n "$PLUGIN/scripts/ensure-personas.sh"
check "example config declares auto_install / fallback / pinned library" bash -c \
  "jq -e '.personas.auto_install==true and .personas.fallback==\"general-purpose\" and (.personas.library.ref|length>10)' '$PLUGIN/reference/deployment.example.json'"
T7=$(mktemp -d); mkdir -p "$T7/.autodev" "$T7/agents"
# needed set: bare-file resolve, prefixed-file resolve, builtin, and two genuinely missing
jq '.personas.roster=["backend-architect","code-reviewer"]
    | .personas.stage_defaults={}
    | .personas.dev_routing=[{"match":"x","persona":"frontend-developer"}]
    | .personas.qa_angles={"verdict":"reality-checker"}' \
  "$PLUGIN/reference/deployment.example.json" > "$T7/.autodev/deployment.json"
touch "$T7/agents/backend-architect.md" "$T7/agents/engineering-code-reviewer.md"
POUT=$(AUTODEV_AGENTS_DIR="$T7/agents" bash "$PLUGIN/scripts/ensure-personas.sh" --check "$T7")
# match on the text, not the ✓ glyph — ANSI reset codes sit between them
check "bare filename resolves" bash -c "echo '$POUT' | grep -q ' backend-architect\$'"
check "prefixed library filename resolves (fuzzy)" bash -c "echo '$POUT' | grep -q ' code-reviewer\$'"
check "fallback persona counts as built-in" bash -c "echo '$POUT' | grep -q 'general-purpose (built-in)'"
check "missing personas report UNRESOLVED with the fallback" bash -c \
  "echo '$POUT' | grep 'reality-checker UNRESOLVED' | grep -q 'general-purpose'"
check "summary line totals the sets" bash -c "echo '$POUT' | grep -q '5 needed · 3 installed · 0 downloaded · 2 unresolved'"
check "--check downloads nothing" bash -c "test \$(ls '$T7/agents' | wc -l) -eq 2"
jq '.personas.auto_install=false' "$T7/.autodev/deployment.json" > "$T7/t" && mv "$T7/t" "$T7/.autodev/deployment.json"
check "auto_install=false full run: no download side effects, still reports" bash -c \
  "AUTODEV_AGENTS_DIR='$T7/agents' bash '$PLUGIN/scripts/ensure-personas.sh' '$T7' | grep -q '2 unresolved' && test \$(ls '$T7/agents' | wc -l) -eq 2"
# consent fails CLOSED: a mistyped string "false" must behave like false, never re-enable downloads
jq '.personas.auto_install="false"' "$T7/.autodev/deployment.json" > "$T7/t" && mv "$T7/t" "$T7/.autodev/deployment.json"
check "non-boolean auto_install fails closed (no download attempt)" bash -c \
  "AUTODEV_AGENTS_DIR='$T7/agents' bash '$PLUGIN/scripts/ensure-personas.sh' '$T7' 2>/dev/null | grep -q '2 unresolved' && test \$(ls '$T7/agents' | wc -l) -eq 2"
# a config predating the persona keys gains them on upgrade
jq 'del(.personas.auto_install, .personas.fallback, .personas.library)' \
  "$PLUGIN/reference/deployment.example.json" > "$T7/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$T7" >/dev/null
check "upgrade adds persona-resolution keys" bash -c \
  "jq -e '.personas.auto_install==true and .personas.fallback==\"general-purpose\" and .personas.library.repo==\"msitarzewski/agency-agents\"' '$T7/.autodev/deployment.json'"
rm -rf "$T7"

echo "headless allowlist hardening (AD-17 / external issue #9):"
check "devloop-tick.sh parses" bash -n "$PLUGIN/scripts/devloop-tick.sh"
check "doctor.sh parses" bash -n "$PLUGIN/scripts/doctor.sh"
check "allowlist never grants gh pr merge (only humans merge)" bash -c \
  "! grep -q 'gh pr merge' '$PLUGIN/scripts/devloop-tick.sh'"
check "allowlist never grants bare node (node -e = arbitrary exec)" bash -c \
  "! grep -qF 'Bash(node *)' '$PLUGIN/scripts/devloop-tick.sh'"
check "allowlist never grants bare jq" bash -c \
  "! grep -qF 'Bash(jq' '$PLUGIN/scripts/devloop-tick.sh'"
check "node is scoped to the engine's tracker.mjs" bash -c \
  "grep -qF 'Bash(node \${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs' '$PLUGIN/scripts/devloop-tick.sh'"
check "doctor has the branch-protection check" bash -c \
  "grep -qF 'branches/\$BRANCH/protection' '$PLUGIN/scripts/doctor.sh'"
check "intake authorizes nobody by default (no more '*')" bash -c \
  "jq -e '.intake.authorized_operators == []' '$PLUGIN/reference/deployment.example.json'"
# right-biased merge: an operator's existing list must survive the schema upgrade
T8=$(mktemp -d); mkdir -p "$T8/.autodev"
jq '.intake.authorized_operators=["alice@acme.co"]' \
  "$PLUGIN/reference/deployment.example.json" > "$T8/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$T8" >/dev/null
check "operator's authorized_operators survives config upgrade" bash -c \
  "jq -e '.intake.authorized_operators == [\"alice@acme.co\"]' '$T8/.autodev/deployment.json'"
rm -rf "$T8"

echo "vendored install mode (install.sh — the plugin's sibling):"
T4=$(mktemp -d); git -C "$T4" init -q; mkdir -p "$T4/.autodev" "$T4/.claude"
echo '{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo team-hook"}]}]}}' > "$T4/.claude/settings.json"
jq '.client_name="VendCo" | .tracker.kind="local"' "$PLUGIN/reference/deployment.example.json" > "$T4/.autodev/deployment.json"
check "installs cleanly" bash "$PLUGIN/install.sh" "$T4"
check "engine copied + paths rewritten (no plugin-root refs in commands)" bash -c "! grep -rl 'CLAUDE_PLUGIN_ROOT' '$T4/.claude/commands'"
check "namespace rewritten (/autodev-*)" bash -c "! grep -rq '/autodev:' '$T4/.claude/commands'"
check "team settings merged, not clobbered" bash -c "jq -e '.permissions.allow[0]==\"Bash(ls:*)\" and ([.hooks.SessionStart[].hooks[].command] | any(contains(\"team-hook\")))' '$T4/.claude/settings.json'"
check "vendored concierge hook runs standalone" bash -c "echo '{\"cwd\":\"$T4\"}' | '$T4/.autodev/engine/hooks/session-signal.sh' | jq -e '.hookSpecificOutput.additionalContext | contains(\"You are\")'"
check "vendored push guard denies main" bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"},\"cwd\":\"$T4\",\"session_id\":\"$SID\"}' | '$T4/.autodev/engine/hooks/guard-push.sh' | jq -e '.hookSpecificOutput.permissionDecision==\"deny\"'"
check "engine stamped vendored + versioned" bash -c "jq -e '.engine.mode==\"vendored\" and .engine.version' '$T4/.autodev/deployment.json'"
bash "$PLUGIN/install.sh" "$T4" >/dev/null 2>&1
check "re-install idempotent (our hook once)" bash -c "jq -e '[.hooks.SessionStart[].hooks[].command | select(contains(\".autodev/engine\"))] | length == 1' '$T4/.claude/settings.json'"
jq '.enabledPlugins={"autodev@x":true}' "$T4/.claude/settings.json" > "$T4/t" && mv "$T4/t" "$T4/.claude/settings.json"
check "refuses when plugin enabled (one mode per repo)" bash -c "! bash '$PLUGIN/install.sh' '$T4'"
jq 'del(.enabledPlugins)' "$T4/.claude/settings.json" > "$T4/t" && mv "$T4/t" "$T4/.claude/settings.json"
bash "$PLUGIN/scripts/migrate-vendored.sh" "$T4" >/dev/null 2>&1
check "migrate cleans NEW vendored layout too (engine dir + commands + hooks)" bash -c \
  "! test -d '$T4/.autodev/engine' && ! test -f '$T4/.claude/commands/autodev-loop.md' && jq -e '[.hooks[]?[]?.hooks[]?.command // empty] | all(contains(\".autodev/engine\") | not)' '$T4/.claude/settings.json' && jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains(\"team-hook\"))' '$T4/.claude/settings.json'"
rm -rf "$T4"
rm -f "$MARKDIR/$SID" "$MARKDIR/$UNSID"

echo "config split — schema (reference/deployment.example.json vs deployment.local.example.json):"
check "example config no longer has repo.local_path" bash -c \
  "! jq -e '.repo.local_path' '$PLUGIN/reference/deployment.example.json' >/dev/null 2>&1"
check "example config no longer has a runner block" bash -c \
  "! jq -e '.runner' '$PLUGIN/reference/deployment.example.json' >/dev/null 2>&1"
check "local example declares repo.local_path + all 4 runner.* fields" bash -c \
  "jq -e '.repo.local_path and .runner.home_dir and .runner.heartbeat_file and .runner.rate_limited_file and .runner.logs_dir' '$PLUGIN/reference/deployment.local.example.json'"
check "local example declares the optional overrides" bash -c \
  "jq -e '(.tracker.instance_label == \"\") and (.tracker.linear.api_token_file == \"\") and (.tracker.shortcut.api_token_file == \"\")' '$PLUGIN/reference/deployment.local.example.json'"

echo "shared config loader (scripts/lib/config.mjs precedence):"
CFGLIB="$PLUGIN/scripts/lib/config.mjs"
PROBE="$PLUGIN/tests/probe-config.mjs"

CA=$(mktemp -d); mkdir -p "$CA/.autodev"
jq '.client_name="CfgA" | .repo.local_path="/legacy/path"' "$PLUGIN/reference/deployment.example.json" > "$CA/.autodev/deployment.json"
check "legacy fallback: inline repo.local_path read, isLegacySplit=true" node "$PROBE" "$CFGLIB" "$CA" "/legacy/path" true

CB=$(mktemp -d); mkdir -p "$CB/.autodev"
jq '.client_name="CfgB"' "$PLUGIN/reference/deployment.example.json" > "$CB/.autodev/deployment.json"
echo '{"repo":{"local_path":"/repo-local/path"}}' > "$CB/.autodev/deployment.local.json"
check "repo-local file wins, not legacy" node "$PROBE" "$CFGLIB" "$CB" "/repo-local/path" false

CC=$(mktemp -d); mkdir -p "$CC/.autodev"
jq '.client_name="CfgC"' "$PLUGIN/reference/deployment.example.json" > "$CC/.autodev/deployment.json"
FAKEHOME=$(mktemp -d); mkdir -p "$FAKEHOME/.config/autodev/CfgC"
echo '{"repo":{"local_path":"/global/path"}}' > "$FAKEHOME/.config/autodev/CfgC/deployment.local.json"
check "global file used when no repo-local file" bash -c "HOME='$FAKEHOME' node '$PROBE' '$CFGLIB' '$CC' /global/path false"
rm -rf "$FAKEHOME"

CD=$(mktemp -d); mkdir -p "$CD/.autodev"
jq '.client_name="CfgD"' "$PLUGIN/reference/deployment.example.json" > "$CD/.autodev/deployment.json"
echo '{"repo":{"local_path":"/repo-local/wins"}}' > "$CD/.autodev/deployment.local.json"
FAKEHOME2=$(mktemp -d); mkdir -p "$FAKEHOME2/.config/autodev/CfgD"
echo '{"repo":{"local_path":"/should-not-be-used"}}' > "$FAKEHOME2/.config/autodev/CfgD/deployment.local.json"
check "repo-local wins over global when both present" bash -c "HOME='$FAKEHOME2' node '$PROBE' '$CFGLIB' '$CD' /repo-local/wins false"
rm -rf "$FAKEHOME2"

CE=$(mktemp -d); mkdir -p "$CE/.autodev"
jq '.client_name="CfgE"' "$PLUGIN/reference/deployment.example.json" > "$CE/.autodev/deployment.json"
echo '{"repo":{"local_path":"/repo-local/ignored"}}' > "$CE/.autodev/deployment.local.json"
FORCED_DIR=$(mktemp -d); FORCED="$FORCED_DIR/forced.json"
echo '{"repo":{"local_path":"/forced/path"}}' > "$FORCED"
check "AUTODEV_LOCAL_CONFIG override wins over repo-local" bash -c "AUTODEV_LOCAL_CONFIG='$FORCED' node '$PROBE' '$CFGLIB' '$CE' /forced/path false"
rm -rf "$FORCED_DIR"

CF=$(mktemp -d); mkdir -p "$CF/.autodev"
jq '.client_name="CfgF" | .tracker.instance_label="autodev:cfgf"' "$PLUGIN/reference/deployment.example.json" > "$CF/.autodev/deployment.json"
echo '{"tracker":{"instance_label":"autodev:cfgf-machine2"}}' > "$CF/.autodev/deployment.local.json"
check "tracker.instance_label local override wins" node "$PROBE" "$CFGLIB" "$CF" "" false "autodev:cfgf-machine2"

rm -rf "$CA" "$CB" "$CC" "$CD" "$CE" "$CF"

echo "config split — .mjs callers wired to scripts/lib/config.mjs:"
CGR=$(mktemp -d); mkdir -p "$CGR/.autodev"; git -C "$CGR" init -q
jq '.client_name="CfgReport" | .tracker.kind="local" | .reporting.cadence="1m"' \
  "$PLUGIN/reference/deployment.example.json" > "$CGR/.autodev/deployment.json"
RUNHOME=$(mktemp -d)
cat > "$CGR/.autodev/deployment.local.json" <<EOF
{"repo":{"local_path":"$CGR"},"runner":{"home_dir":"$RUNHOME"}}
EOF
check "report.mjs picks up runner.home_dir from deployment.local.json" bash -c \
  "cd '$CGR' && node '$PLUGIN/scripts/report.mjs' --force >/dev/null && test -f '$RUNHOME/logs/report.log'"
rm -rf "$CGR" "$RUNHOME"

echo "token file override (tracker.linear.api_token_file / tracker.shortcut.api_token_file):"
CTOK=$(mktemp -d); mkdir -p "$CTOK/.autodev"
jq '.client_name="CfgTok"' "$PLUGIN/reference/deployment.example.json" > "$CTOK/.autodev/deployment.json"
TOKDIR=$(mktemp -d)
echo "{\"tracker\":{\"linear\":{\"api_token_file\":\"$TOKDIR/my.linear.token\"}}}" > "$CTOK/.autodev/deployment.local.json"
check "linear.mjs token-missing error names the overridden api_token_file path" bash -c \
  "cd '$CTOK' && LINEAR_API_TOKEN= node '$PLUGIN/scripts/linear.mjs' whoami 2>&1 | grep -qF '$TOKDIR/my.linear.token'"
rm -rf "$CTOK" "$TOKDIR"

CTOK2=$(mktemp -d); mkdir -p "$CTOK2/.autodev"
jq '.client_name="CfgTok2"' "$PLUGIN/reference/deployment.example.json" > "$CTOK2/.autodev/deployment.json"
TOKDIR2=$(mktemp -d)
echo "{\"tracker\":{\"shortcut\":{\"api_token_file\":\"$TOKDIR2/my.shortcut.token\"}}}" > "$CTOK2/.autodev/deployment.local.json"
check "shortcut.mjs token-missing error names the overridden api_token_file path" bash -c \
  "cd '$CTOK2' && SHORTCUT_API_TOKEN= node '$PLUGIN/scripts/shortcut.mjs' whoami 2>&1 | grep -qF '$TOKDIR2/my.shortcut.token'"
rm -rf "$CTOK2" "$TOKDIR2"

# report.mjs is the 4th direct Linear consumer — it must honor the same override.
# The override points at a missing file while the DEFAULT location has a real token:
# before the fix report.mjs read the default and tried to post; now it resolves the
# override, finds nothing, and reports no token (its loadToken() stays soft — null,
# not a die — which is the pre-existing failure mode and is preserved).
CTOK3=$(mktemp -d); git -C "$CTOK3" init -q; mkdir -p "$CTOK3/.autodev"
jq '.client_name="CfgTok3" | .tracker.kind="local" | .reporting.cadence="1m" | .reporting.destination="linear" | .reporting.linear_issue="ISSUE-1"' \
  "$PLUGIN/reference/deployment.example.json" > "$CTOK3/.autodev/deployment.json"
TOKHOME=$(mktemp -d); mkdir -p "$TOKHOME/.config/autodev"
echo "default-location-token" > "$TOKHOME/.config/autodev/CfgTok3.linear.token"
RUNHOME3=$(mktemp -d)
cat > "$CTOK3/.autodev/deployment.local.json" <<EOF
{"repo":{"local_path":"$CTOK3"},"runner":{"home_dir":"$RUNHOME3"},"tracker":{"linear":{"api_token_file":"$TOKHOME/absent.linear.token"}}}
EOF
check "report.mjs honors tracker.linear.api_token_file (no fallback to the default path)" bash -c \
  "cd '$CTOK3' && LINEAR_API_TOKEN= HOME='$TOKHOME' node '$PLUGIN/scripts/report.mjs' --force 2>&1 >/dev/null | grep -q 'no linear_issue/token'"
rm -rf "$CTOK3" "$TOKHOME" "$RUNHOME3"

echo "shared config loader (scripts/lib/config.sh precedence):"
CFGSH="$PLUGIN/scripts/lib/config.sh"

SA=$(mktemp -d); mkdir -p "$SA/.autodev"
jq '.client_name="ShA" | .repo.local_path="/legacy/sh"' "$PLUGIN/reference/deployment.example.json" > "$SA/.autodev/deployment.json"
cat > "$SA/probe.sh" <<EOF
#!/usr/bin/env bash
source "$CFGSH"
autodev_resolve_config "$SA"
[[ "\$(autodev_cfg_get repo.local_path)" == "/legacy/sh" && "\$AUTODEV_CFG_LEGACY_SPLIT" == "true" ]]
EOF
check "legacy fallback: repo.local_path readable, legacy flag true" bash "$SA/probe.sh"

SB=$(mktemp -d); mkdir -p "$SB/.autodev"
jq '.client_name="ShB"' "$PLUGIN/reference/deployment.example.json" > "$SB/.autodev/deployment.json"
echo '{"repo":{"local_path":"/repo-local/sh"},"runner":{"home_dir":"/rh"}}' > "$SB/.autodev/deployment.local.json"
cat > "$SB/probe.sh" <<EOF
#!/usr/bin/env bash
source "$CFGSH"
autodev_resolve_config "$SB"
[[ "\$(autodev_cfg_get repo.local_path)" == "/repo-local/sh" && "\$(autodev_cfg_get runner.home_dir '~/.autodev')" == "/rh" && "\$AUTODEV_CFG_LEGACY_SPLIT" == "false" ]]
EOF
check "repo-local file resolved, not legacy" bash "$SB/probe.sh"

SC=$(mktemp -d); mkdir -p "$SC/.autodev"
jq '.client_name="ShC"' "$PLUGIN/reference/deployment.example.json" > "$SC/.autodev/deployment.json"
FAKEHOME3=$(mktemp -d); mkdir -p "$FAKEHOME3/.config/autodev/ShC"
echo '{"repo":{"local_path":"/global/sh"}}' > "$FAKEHOME3/.config/autodev/ShC/deployment.local.json"
cat > "$SC/probe.sh" <<EOF
#!/usr/bin/env bash
source "$CFGSH"
autodev_resolve_config "$SC"
[[ "\$(autodev_cfg_get repo.local_path)" == "/global/sh" ]]
EOF
check "global file used when no repo-local file" bash -c "HOME='$FAKEHOME3' bash '$SC/probe.sh'"

SD=$(mktemp -d); mkdir -p "$SD/.autodev"
jq '.client_name="ShD"' "$PLUGIN/reference/deployment.example.json" > "$SD/.autodev/deployment.json"
cat > "$SD/probe.sh" <<EOF
#!/usr/bin/env bash
source "$CFGSH"
autodev_resolve_config "$SD"
[[ "\$(autodev_cfg_get runner.home_dir '~/.autodev')" == "~/.autodev" && "\$AUTODEV_CFG_LEGACY_SPLIT" == "false" ]]
EOF
check "default returned when neither local file nor inline value exists" bash "$SD/probe.sh"

# $AUTODEV_LOCAL_CONFIG is an explicit override: when it points at a path that isn't
# there, resolution ends with NO local file — it must not silently fall back to the
# repo-local file (config.mjs's findLocalConfig() returns null outright; the two
# implementations have to agree or doctor.sh and report.mjs contradict each other).
SE=$(mktemp -d); mkdir -p "$SE/.autodev"
jq '.client_name="ShE"' "$PLUGIN/reference/deployment.example.json" > "$SE/.autodev/deployment.json"
echo '{"repo":{"local_path":"/repo-local/must-not-be-used"}}' > "$SE/.autodev/deployment.local.json"
cat > "$SE/probe.sh" <<EOF
#!/usr/bin/env bash
source "$CFGSH"
autodev_resolve_config "$SE"
[[ -z "\$AUTODEV_LOCAL_CONFIG" && "\$(autodev_cfg_get repo.local_path NONE)" == "NONE" ]]
EOF
check "forced AUTODEV_LOCAL_CONFIG at a missing path does not fall back to repo-local" \
  bash -c "AUTODEV_LOCAL_CONFIG='$SE/nonexistent.json' bash '$SE/probe.sh'"
check "…and config.mjs agrees (same env, same repo, no local file resolved)" \
  bash -c "AUTODEV_LOCAL_CONFIG='$SE/nonexistent.json' node '$PROBE' '$CFGLIB' '$SE' '' false"
check "unset AUTODEV_LOCAL_CONFIG still falls through to repo-local" \
  bash -c "unset AUTODEV_LOCAL_CONFIG; source '$CFGSH'; autodev_resolve_config '$SE'; [[ \"\$(autodev_cfg_get repo.local_path NONE)\" == '/repo-local/must-not-be-used' ]]"

rm -rf "$SA" "$SB" "$SC" "$FAKEHOME3" "$SD" "$SE"

echo "24/7 timer scripts (devloop-tick.sh / watchdog.sh / notify.sh) — config.sh wiring:"
check "devloop-tick.sh parses" bash -n "$PLUGIN/scripts/devloop-tick.sh"
check "watchdog.sh parses" bash -n "$PLUGIN/scripts/watchdog.sh"
check "notify.sh parses" bash -n "$PLUGIN/scripts/notify.sh"

# These run without `set -e`, so a missing sibling lib/config.sh used to leave RUN_HOME
# empty and exit 0 — watchdog.sh would become a silent permanent no-op after a vendored
# copy that forgot scripts/lib/. Must be a loud, immediate failure instead.
NOLIB=$(mktemp -d); NOLIBR=$(mktemp -d); mkdir -p "$NOLIBR/.autodev"
jq '.client_name="NoLib" | .tracker.kind="local"' "$PLUGIN/reference/deployment.example.json" > "$NOLIBR/.autodev/deployment.json"
cp "$PLUGIN/scripts/"{devloop-tick.sh,watchdog.sh,notify.sh} "$NOLIB/"
for s in devloop-tick watchdog; do
  check "$s.sh fails loudly when lib/config.sh isn't a sibling" bash -c \
    "out=\$(bash '$NOLIB/$s.sh' '$NOLIBR' 2>&1); rc=\$?; [[ \$rc -ne 0 ]] && printf '%s' \"\$out\" | grep -q 'missing lib/config.sh'"
done
check "notify.sh fails loudly when lib/config.sh isn't a sibling" bash -c \
  "out=\$(bash '$NOLIB/notify.sh' '$NOLIBR' stalled 60 2>&1); rc=\$?; [[ \$rc -ne 0 ]] && printf '%s' \"\$out\" | grep -q 'missing lib/config.sh'"
rm -rf "$NOLIB" "$NOLIBR"

# …and the documented vendoring step actually copies scripts/lib/ (the reason the above
# failure mode was reachable at all).
check "ops/launchd-timer.md's copy step includes scripts/lib/" \
  grep -q 'cp -R "${CLAUDE_PLUGIN_ROOT}/scripts/lib" ~/.autodev/bin/' "$PLUGIN/ops/launchd-timer.md"

WD=$(mktemp -d); git -C "$WD" init -q; mkdir -p "$WD/.autodev"
jq '.client_name="WdCo" | .tracker.kind="local"' "$PLUGIN/reference/deployment.example.json" > "$WD/.autodev/deployment.json"
WDHOME=$(mktemp -d)
echo "{\"runner\":{\"home_dir\":\"$WDHOME\"}}" > "$WD/.autodev/deployment.local.json"
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$WDHOME/heartbeat"
bash "$PLUGIN/scripts/watchdog.sh" "$WD" >/dev/null 2>&1
check "watchdog reads runner.home_dir from deployment.local.json (stalled issue filed on the board)" bash -c \
  "cd '$WD' && node '$PLUGIN/scripts/tracker.mjs' list 2>/dev/null | grep -qi 'STALLED'"
rm -rf "$WD" "$WDHOME"

echo "doctor.sh — config split awareness:"
DA=$(mktemp -d); git -C "$DA" init -q; mkdir -p "$DA/.autodev"
jq '.client_name="DrA" | .tracker.kind="local" | .repo.local_path="/legacy/doctor" | .review.delivery="local_diff"' \
  "$PLUGIN/reference/deployment.example.json" > "$DA/.autodev/deployment.json"
DAOUT=$(cd "$DA" && bash "$PLUGIN/scripts/doctor.sh" 2>&1 || true)
check "doctor warns on legacy-split (pre-split) config" env DAOUT="$DAOUT" bash -c \
  'echo "$DAOUT" | grep -q "run /autodev:init or scripts/upgrade-config.sh"'
rm -rf "$DA"

DB=$(mktemp -d); DB=$(cd "$DB" && pwd -P); git -C "$DB" init -q; mkdir -p "$DB/.autodev"
jq '.client_name="DrB" | .tracker.kind="local" | .review.delivery="local_diff"' "$PLUGIN/reference/deployment.example.json" > "$DB/.autodev/deployment.json"
echo "{\"repo\":{\"local_path\":\"$DB\"}}" > "$DB/.autodev/deployment.local.json"
DBOUT=$(cd "$DB" && bash "$PLUGIN/scripts/doctor.sh" 2>&1 || true)
check "doctor does not warn once split (repo.local_path matches this checkout)" env DBOUT="$DBOUT" bash -c \
  'echo "$DBOUT" | grep -q "repo.local_path matches this checkout" && ! echo "$DBOUT" | grep -q "run /autodev:init or scripts/upgrade-config.sh"'
rm -rf "$DB"

DC=$(mktemp -d); git -C "$DC" init -q; mkdir -p "$DC/.autodev"
jq '.client_name="DrC" | .tracker.kind="linear" | .review.delivery="local_diff"' "$PLUGIN/reference/deployment.example.json" > "$DC/.autodev/deployment.json"
TOKDIR3=$(mktemp -d)
echo "{\"tracker\":{\"linear\":{\"api_token_file\":\"$TOKDIR3/custom.token\"}}}" > "$DC/.autodev/deployment.local.json"
DCOUT=$(cd "$DC" && LINEAR_API_TOKEN= bash "$PLUGIN/scripts/doctor.sh" 2>&1 || true)
check "doctor's missing-token message names the overridden api_token_file path" env DCOUT="$DCOUT" TOKDIR3="$TOKDIR3" bash -c \
  'echo "$DCOUT" | grep -qF "$TOKDIR3/custom.token"'
rm -rf "$DC" "$TOKDIR3"

echo "config split — upgrade-config.sh migration:"
UA=$(mktemp -d); mkdir -p "$UA/.autodev"
jq '.client_name="UpA" | .repo.local_path="/old/inline/path" | .runner.home_dir="/old/run"' \
  "$PLUGIN/reference/deployment.example.json" > "$UA/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$UA" >/dev/null
check "split creates deployment.local.json with the moved values" bash -c \
  "jq -e '.repo.local_path==\"/old/inline/path\" and .runner.home_dir==\"/old/run\"' '$UA/.autodev/deployment.local.json'"
check "split removes the fields from deployment.json" bash -c \
  "jq -e '(.repo.local_path == null) and (.runner == null)' '$UA/.autodev/deployment.json'"
check "split is idempotent (second run leaves local file untouched)" bash -c \
  "cp '$UA/.autodev/deployment.local.json' '$UA/before.json'; bash '$PLUGIN/scripts/upgrade-config.sh' '$UA' >/dev/null; diff -q '$UA/before.json' '$UA/.autodev/deployment.local.json' >/dev/null"
rm -rf "$UA"

UB=$(mktemp -d); mkdir -p "$UB/.autodev"
jq '.client_name="UpB"' "$PLUGIN/reference/deployment.example.json" > "$UB/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$UB" >/dev/null
check "no legacy fields present -> no local file created" bash -c "! test -f '$UB/.autodev/deployment.local.json'"
check "no legacy fields present -> no .gitignore conjured up" bash -c "! test -f '$UB/.gitignore'"
rm -rf "$UB"

# The split writes a never-committed file — it has to gitignore it too. /autodev:init
# does this in prose, but loop.md runs upgrade-config.sh standalone then says "commit".
UC=$(mktemp -d); mkdir -p "$UC/.autodev"
jq '.client_name="UpC" | .repo.local_path="/old/inline"' "$PLUGIN/reference/deployment.example.json" > "$UC/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$UC" >/dev/null
check "split creates .gitignore covering the local file when none exists" bash -c \
  "grep -qxF '.autodev/deployment.local.json' '$UC/.gitignore'"
rm -rf "$UC"

UD=$(mktemp -d); mkdir -p "$UD/.autodev"
jq '.client_name="UpD" | .repo.local_path="/old/inline"' "$PLUGIN/reference/deployment.example.json" > "$UD/.autodev/deployment.json"
printf 'node_modules' > "$UD/.gitignore"   # no trailing newline — must not glue lines
bash "$PLUGIN/scripts/upgrade-config.sh" "$UD" >/dev/null
check "split appends to an existing .gitignore without clobbering it" bash -c \
  "grep -qxF 'node_modules' '$UD/.gitignore' && grep -qxF '.autodev/deployment.local.json' '$UD/.gitignore'"
rm -f "$UD/.autodev/deployment.local.json"
jq '.repo.local_path="/old/inline/again"' "$UD/.autodev/deployment.json" > "$UD/t" && mv "$UD/t" "$UD/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$UD" >/dev/null
check "gitignore entry is added once, not duplicated on a later split" bash -c \
  "[[ \$(grep -cxF '.autodev/deployment.local.json' '$UD/.gitignore') -eq 1 ]]"
rm -rf "$UD"

# The split must move only the 5 enumerated leaves — deleting the whole .runner object
# silently destroyed any custom/future runner.* key (present in neither file).
UE=$(mktemp -d); mkdir -p "$UE/.autodev"
jq '.client_name="UpE" | .repo.local_path="/old/inline" | .runner.home_dir="/old/run" | .runner.future_key="KEEP_ME"' \
  "$PLUGIN/reference/deployment.example.json" > "$UE/.autodev/deployment.json"
bash "$PLUGIN/scripts/upgrade-config.sh" "$UE" >/dev/null
check "split preserves an unknown runner.* key in deployment.json" bash -c \
  "jq -e '.runner.future_key==\"KEEP_ME\" and (.runner.home_dir==null)' '$UE/.autodev/deployment.json'"
check "split still moves the enumerated runner.* leaves to the local file" bash -c \
  "jq -e '.runner.home_dir==\"/old/run\" and (.runner.future_key==null)' '$UE/.autodev/deployment.local.json'"
rm -rf "$UE"

# A global local file is authoritative — creating a repo-local one from the stale
# inline values would shadow it (repo-local wins the documented precedence order).
UF=$(mktemp -d); mkdir -p "$UF/.autodev"
jq '.client_name="UpF" | .repo.local_path="/stale/inline" | .runner.home_dir="/stale/run"' \
  "$PLUGIN/reference/deployment.example.json" > "$UF/.autodev/deployment.json"
FAKEHOME4=$(mktemp -d); mkdir -p "$FAKEHOME4/.config/autodev/UpF"
echo '{"repo":{"local_path":"/real/global"},"runner":{"home_dir":"/real/run"}}' > "$FAKEHOME4/.config/autodev/UpF/deployment.local.json"
UFOUT=$(HOME="$FAKEHOME4" bash "$PLUGIN/scripts/upgrade-config.sh" "$UF" 2>&1)
check "global local file present -> no shadowing repo-local file created" bash -c \
  "! test -f '$UF/.autodev/deployment.local.json'"
check "global local file present -> redundant inline fields still stripped" bash -c \
  "jq -e '(.repo.local_path == null) and (.runner == null)' '$UF/.autodev/deployment.json'"
check "global local file present -> operator is told it was used" env UFOUT="$UFOUT" bash -c \
  'echo "$UFOUT" | grep -q "used it instead of creating"'
check "global local file itself is left untouched" bash -c \
  "jq -e '.repo.local_path==\"/real/global\"' '$FAKEHOME4/.config/autodev/UpF/deployment.local.json'"
rm -rf "$UF" "$FAKEHOME4"

echo
if [[ $FAIL -eq 0 ]]; then echo "smoke: PASS"; else echo "smoke: FAIL"; fi
exit $FAIL
