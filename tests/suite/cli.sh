#!/usr/bin/env bash
# The `autodev` CLI (Milestone 2) + the executor seam it drives (Milestone 3).
# Sidecar registration must leave the application repo untouched (G9).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
CLI="$PLUGIN/bin/autodev.mjs"
export AUTODEV_HOME="$SANDBOX/autodev-home"
VER=$(jq -r .version "$PLUGIN/package.json")
ad() { node "$CLI" "$@"; }

echo "cli — non-interactive basics:"
check_out "version"                              "^$VER$" ad version
check_out "--version"                            "^$VER$" ad --version
check_out "help lists the commands"              "status.*continue|tick <repo>" bash -c "node '$CLI' help | tr '\n' ' '"
check "help exits 0"                             ad help

echo "cli — G9: register a clean shared repo without touching it:"
R=$(mktemp -d "$SANDBOX/shared.XXXXXX"); R="$(cd "$R" && pwd -P)"
git -C "$R" init -q; echo "# app" > "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm "init"
git -C "$R" remote add origin git@github.com:Acme/App.git
OUT=$(cd "$R" && ad status); rc=$?
check "status exits 0 in a fresh repo"           test $rc -eq 0
check "banner names the project from the remote" has 'Project: app  (prj_'
check "banner says it was registered sidecar"    has 'registered just now, sidecar'
check "banner shows the branch"                  has_re 'Branch: (main|master)'
check "Brain not configured"                     has 'Brain: not configured'
check "executor claude, subscription auth"       has_re 'Executor: claude'
check "no v2 deployment → says so, points at init" has 'no v2 deployment here'
check "git status stays completely clean"        bash -c "[ -z \"\$(git -C '$R' status --porcelain)\" ]"
check "no .autodev/ .brain/ .claude/ created in the repo" bash -c "! ls -d '$R/.autodev' '$R/.brain' '$R/.claude' 2>/dev/null | grep -q ."
check "registry written under AUTODEV_HOME"      test -f "$AUTODEV_HOME/registry.json"
PID=$(jq -r '.projects[0].id' "$AUTODEV_HOME/registry.json")
check "project id is prj_<ULID>"                 bash -c "grep -qE '^prj_[0-9A-HJKMNP-TV-Z]{26}$' <<<'$PID'"
check "project.json exists in the sidecar layout" test -f "$AUTODEV_HOME/projects/$PID/project.json"
check "board/events/locks/runtime dirs created"  bash -c "for d in board events locks runtime; do test -d '$AUTODEV_HOME/projects/$PID/'\$d || exit 1; done"
check "project.json records normalized remote + root commit + clone path" jq -e --arg r "$R" '.repository.remote=="github.com/acme/app" and (.repository.root_commit|length)==40 and (.clones|any(.path==$r))' "$AUTODEV_HOME/projects/$PID/project.json"
check "project.json has no machine secrets / prompts / memory" jq -e '(.legacy.deployment_json==null) and (has("memory")|not) and (has("prompts")|not)' "$AUTODEV_HOME/projects/$PID/project.json"
OUT=$(cd "$R" && ad status)
check "second run resolves to the SAME id (idempotent)" has "($PID)"
check "second run no longer says 'registered just now'" lacks 'registered just now'
check "registry still has exactly one project"   bash -c "[ \"\$(jq '.projects|length' '$AUTODEV_HOME/registry.json')\" = 1 ]"

echo "cli — identity survives clones + moves:"
BARE=$(mktemp -d "$SANDBOX/bare.XXXXXX"); git init -q --bare "$BARE"
git -C "$R" remote set-url origin "$BARE"; git -C "$R" push -q origin HEAD 2>/dev/null
C1=$(mktemp -d "$SANDBOX/c1.XXXXXX"); C2=$(mktemp -d "$SANDBOX/c2.XXXXXX")
git clone -q "$BARE" "$C1/app"; git clone -q "$BARE" "$C2/app"
ID1=$(cd "$C1/app" && ad status | grep -oE 'prj_[0-9A-Z]{26}'); ID2=$(cd "$C2/app" && ad status | grep -oE 'prj_[0-9A-Z]{26}')
check "two clones of one remote → one project id"   test -n "$ID1" -a "$ID1" = "$ID2"
check "…both clone paths recorded"                  jq -e --arg a "$C1/app" --arg b "$C2/app" '(.clones|any(.path==$a)) and (.clones|any(.path==$b))' "$AUTODEV_HOME/projects/$ID1/project.json"
MV=$(mktemp -d "$SANDBOX/mv.XXXXXX"); mv "$C2/app" "$MV/renamed"
ID3=$(cd "$MV/renamed" && ad status | grep -oE 'prj_[0-9A-Z]{26}')
check "a moved clone keeps its id"                  test "$ID3" = "$ID1"
NR=$(mktemp -d "$SANDBOX/noremote.XXXXXX"); git -C "$NR" init -q; echo x > "$NR/f"; git -C "$NR" add -A; git -C "$NR" commit -qm one
IDN=$(cd "$NR" && ad status | grep -oE 'prj_[0-9A-Z]{26}'); IDN2=$(cd "$NR" && ad status | grep -oE 'prj_[0-9A-Z]{26}')
check "no remote: root commit is the fingerprint (stable across runs)" test -n "$IDN" -a "$IDN" = "$IDN2" -a "$IDN" != "$ID1"
check "not a git repo → status still exits 0 and says so" bash -c "cd '$SANDBOX' && node '$CLI' status | grep -q 'not a git repository'"

echo "cli — executor selection:"
check_out "executor shows the default + available set" "^claude  \(available: claude\)$" bash -c "cd '$R' && node '$CLI' executor"
check_out "unknown executor is refused, lists available" 'no executor "codex" registered \(available: claude\)' bash -c "cd '$R' && node '$CLI' executor codex 2>&1; true"
check "unknown executor exits 1"                 bash -c "cd '$R' && ! node '$CLI' executor codex >/dev/null 2>&1"
check "setting a registered executor persists in project.json" bash -c "cd '$R' && node '$CLI' executor claude >/dev/null && jq -e '.executor.default==\"claude\"' '$AUTODEV_HOME/projects/$PID/project.json'"

echo "cli — proxying to the v2 engine through the executor seam:"
L=$(mkrepo CliCo '.commands.test="npm test"'); git -C "$L" add -A >/dev/null; git -C "$L" commit -qm init >/dev/null
check "registering a v2 repo leaves its git status clean too" bash -c "cd '$L' && node '$CLI' status >/dev/null && [ -z \"\$(git status --porcelain)\" ]"
: > "$CLAUDE_STUB_LOG"
check_out "natural language one-shot returns the executor's summary" "^ok$" bash -c "cd '$L' && node '$CLI' what is on the board"
check "…invoked claude with the text as the prompt"  grep -q -- '-p what is on the board --output-format json' "$CLAUDE_STUB_LOG"
check "…with this repo's allowlist"                  bash -c "grep -q -- '--allowedTools Bash(npm test)' '$CLAUDE_STUB_LOG' && ! grep -q 'gh pr merge' '$CLAUDE_STUB_LOG'"
: > "$CLAUDE_STUB_LOG"
check "continue = one /autodev:loop job"            bash -c "cd '$L' && node '$CLI' continue >/dev/null && grep -q -- '-p /autodev:loop' '$CLAUDE_STUB_LOG'"
: > "$CLAUDE_STUB_LOG"
check "approve <id> proxies a gate decision naming the id" bash -c "cd '$L' && node '$CLI' approve AD-3 looks good >/dev/null && grep -q -- '-p The operator approved AD-3 — looks good' '$CLAUDE_STUB_LOG'"
check_out "rate-limited executor → exit 75 + reason" "rate_limited" bash -c "cd '$L' && CLAUDE_STUB_MODE=limited node '$CLI' hello 2>&1; echo \"rc=\$?\""
check "rate-limited exit code is 75"                bash -c "cd '$L' && CLAUDE_STUB_MODE=limited node '$CLI' hello >/dev/null 2>&1; [ \$? -eq 75 ]"
check_out "unavailable executor → clear error"      "claude → unavailable" bash -c "cd '$L' && CLAUDE_STUB_MODE=fail node '$CLI' hello 2>&1; true"
check_out "no v2 deployment → refuses to proxy"     "no autoDev deployment yet" bash -c "cd '$R' && node '$CLI' hello 2>&1; true"
check "banner on a v2 repo shows the deployment + tracker + board" bash -c "cd '$L' && node '$PLUGIN/scripts/tracker.mjs' create-issue --title t >/dev/null && node '$CLI' status | grep -q 'v2 deployment \"CliCo\" · tracker local · board: New Request: 1'"
check "legacy deployment recorded on the project (read, never modified)" bash -c "id=\$(cd '$L' && node '$CLI' status | grep -oE 'prj_[0-9A-Z]{26}'); jq -e --arg p '$L/.autodev/deployment.json' '.legacy.deployment_json==\$p and .legacy.client_name==\"CliCo\" and .tracker.kind==\"local\"' \"$AUTODEV_HOME/projects/\$id/project.json\""

echo "cli — interactive shell:"
OUT=$(cd "$L" && printf 'status\nexecutor\nexit\n' | node "$CLI")
check "shell prints the banner"                     has "autoDev v$VER"
check "shell runs 'status' (banner twice)"          test "$(count_re 'Project: CliCo')" -eq 2
check "shell runs 'executor'"                       has 'claude  (available: claude)'
check "shell exit code follows the last command"   bash -c "cd '$L' && printf 'executor codex\nexit\n' | node '$CLI' >/dev/null 2>&1; [ \$? -eq 1 ]"
check "EOF ends the shell cleanly"                  bash -c "cd '$L' && printf 'help\n' | node '$CLI' >/dev/null"

echo "cli — headless tick goes through the seam (M3):"
: > "$CLAUDE_STUB_LOG"
check "autodev tick <repo> runs the loop job"       bash -c "node '$CLI' tick '$L' 2>/dev/null && grep -q -- '-p /autodev:loop --output-format json' '$CLAUDE_STUB_LOG'"
check "tick logs progress to stderr, nothing to stdout" bash -c "out=\$(node '$CLI' tick '$L' 2>/dev/null); [ -z \"\$out\" ]"
check_out "tick without a repo → usage, exit 2"     "usage: autodev tick" bash -c "node '$CLI' tick 2>&1; true"
check_out "tick on an unconfigured repo → clear error" "no .*deployment.json" bash -c "node '$CLI' tick '$R' 2>&1; true"
check "devloop-tick.sh delegates to the CLI (no claude call of its own)" bash -c "! grep -qE 'claude (-p|--)' '$PLUGIN/scripts/devloop-tick.sh'"
check "no vendor CLI invocation anywhere in src/core or src/cli" bash -c "! grep -rnE \"spawn[a-zA-Z]*\\(['\\\"](claude|codex)|\\bclaude -p|exec\\(['\\\"]claude\" '$PLUGIN/src/core' '$PLUGIN/src/cli'"

exit $FAIL
