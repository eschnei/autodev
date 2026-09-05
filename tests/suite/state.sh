#!/usr/bin/env bash
# Milestone 5A — the sidecar state repo + private remote + one-writer rule, and
# `autodev init` for v3-native projects (nothing written into the application repo).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
SRC="$PLUGIN/src"
CLI="$PLUGIN/bin/autodev.mjs"
export AUTODEV_HOME="$SANDBOX/autodev-home-state"
export AUTODEV_MACHINE="macbook"
n() { node --input-type=module -e "$1"; }
ST="$AUTODEV_HOME/state"

echo "state repo — every mutation is a commit:"
R=$(mktemp -d "$SANDBOX/app.XXXXXX"); R="$(cd "$R" && pwd -P)"; git -C "$R" init -q; echo "# app" > "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm init; git -C "$R" remote add origin git@github.com:Acme/App.git
OUT=$(cd "$R" && node "$CLI" status)
check "registration created <root>/state as a git repo"   test -d "$ST/.git"
check "…with the registry + project inside it"            bash -c "test -f '$ST/registry.json' && ls '$ST/projects' | grep -qE '^prj_'"
check "…and a commit for the registration"                bash -c "git -C '$ST' log --oneline | grep -q 'registered app \[macbook\]'"
check "…gitignore excludes runtime/locks/.last_report"     bash -c "grep -q 'projects/\*/runtime/' '$ST/.gitignore' && grep -q 'projects/\*/locks/' '$ST/.gitignore'"
check "…working tree clean after the command"             bash -c "[ -z \"\$(git -C '$ST' status --porcelain)\" ]"
check "banner shows the state head + no remote hint"      has_re 'State: [0-9a-f]{7} · no remote \(autodev state remote <url>\)'
check "the application repo is untouched"                 bash -c "[ -z \"\$(git -C '$R' status --porcelain)\" ] && ! test -e '$R/.autodev'"

echo "autodev init — v3-native deployment in the sidecar:"
cat > "$R/package.json" <<'EOF'
{"name":"app","scripts":{"test":"vitest run","lint":"eslint .","build":"vite build","dev":"vite"}}
EOF
touch "$R/pnpm-lock.yaml"; git -C "$R" add -A; git -C "$R" commit -qm "pkg" >/dev/null
OUT=$(cd "$R" && node "$CLI" init); rc=$?
PID=$(jq -r '.projects[0].id' "$ST/registry.json")
check "init exits 0 and names the sidecar deployment"      bash -c "[ $rc -eq 0 ] && grep -q 'deployment: $ST/projects/$PID/deployment.json' <<<\"\$0\"" "$OUT"
check "…detected pnpm scripts"                             has 'test "pnpm test" · lint "pnpm lint" · build "pnpm build" · run "pnpm dev"'
check "…the deployment validates against the schema"       bash -c "node '$PLUGIN/bin/autodev-config.mjs' validate '$R' 2>&1 | grep -q 'no .*deployment.json'; jq -e '.tracker.kind==\"local\" and .planning.engine==\"agency\" and .client_name==\"app\" and .tracker.instance_label==\"autodev:app\" and .commands.test==\"pnpm test\"' '$ST/projects/$PID/deployment.json'"
check "…project.json points its board at the sidecar"      jq -e '.tracker.mode=="sidecar" and (.tracker.location|endswith("/board"))' "$ST/projects/$PID/project.json"
check "…git status of the app repo is STILL clean (G9)"     bash -c "[ -z \"\$(git -C '$R' status --porcelain)\" ] && ! test -e '$R/.autodev' && ! test -e '$R/CLAUDE.md'"
check "…init is refused a second time without --force"     bash -c "cd '$R' && node '$CLI' init 2>&1 | grep -q 'already initialized'"
check "…--force --test overrides"                          bash -c "cd '$R' && node '$CLI' init --force --test 'pnpm test -- --run' >/dev/null && jq -e '.commands.test==\"pnpm test -- --run\"' '$ST/projects/$PID/deployment.json'"
check "…state commit for init"                             bash -c "git -C '$ST' log --oneline | grep -q 'initialized app'"
OUT=$(cd "$R" && node "$CLI" status)
check "status now reads the sidecar deployment"           has 'sidecar deployment "app" · tracker local (sidecar board) · planning agency'
check "…doctor equivalent: no config errors"               bash -c "! grep -q 'config: [0-9]* error' <<<\"\$0\"" "$OUT"
LEG=$(mkrepo LegacyCo); git -C "$LEG" add -A >/dev/null; git -C "$LEG" commit -qm init >/dev/null
check "init refuses a repo that has a v2 deployment (migrate instead)" bash -c "cd '$LEG' && node '$CLI' init 2>&1 | grep -q 'already has a v2 deployment'"
check "legacy project still loads its repo-local board"    bash -c "cd '$LEG' && node '$CLI' status | grep -q 'v2 deployment \"LegacyCo\" · tracker local · planning'"

echo "the sidecar board — deterministic commands work on it, repo untouched:"
(cd "$R" && node "$CLI" create-noop 2>/dev/null; true)
check "tracker facade honors AUTODEV_BOARD_DIR"            bash -c "cd '$R' && AUTODEV_CONFIG='$ST/projects/$PID/deployment.json' AUTODEV_BOARD_DIR='$ST/projects/$PID/board' node '$TRK' create-issue --title 'Feature: sidecar' --stage prd_review --labels 'route:feature,autodev:app' | grep -qx AD-1 && test -f '$ST/projects/$PID/board/AD-1.json'"
check "…issues carry a canonical uid (req_ for features)"  bash -c "jq -e '.uid|startswith(\"req_\")' '$ST/projects/$PID/board/AD-1.json'"
check "…and task_ for stories"                             bash -c "cd '$R' && AUTODEV_CONFIG='$ST/projects/$PID/deployment.json' AUTODEV_BOARD_DIR='$ST/projects/$PID/board' node '$TRK' create-issue --title 'story' --stage ready_for_ai_dev --labels 'ai-eligible,autodev:app' >/dev/null && jq -e '.uid|startswith(\"task_\")' '$ST/projects/$PID/board/AD-2.json'"
check "…board html lands next to the sidecar board, not in the repo" bash -c "cd '$R' && AUTODEV_CONFIG='$ST/projects/$PID/deployment.json' AUTODEV_BOARD_DIR='$ST/projects/$PID/board' node '$TRK' board >/dev/null && test -f '$ST/projects/$PID/board.html' && ! test -e '$R/.autodev'"
check_out "autodev next reads the sidecar board"          "Gate 1 \(PRD Review \(H\)\): AD-1 Feature: sidecar" bash -c "cd '$R' && node '$CLI' next"
check_out "autodev status: Awaiting you from the sidecar board" "Awaiting you: Gate 1 AD-1" bash -c "cd '$R' && node '$CLI' status"
: > "$CLAUDE_STUB_LOG"
OUT=$(cd "$R" && node "$CLI" approve AD-1 go 2>&1)
check "approve on the sidecar board: recorded + job dispatched" has_re 'recorded: Gate 1 approved for AD-1 → breakdown'
check "…the board write was committed to state"            bash -c "git -C '$ST' log --oneline | grep -q 'board: move AD-1 breakdown'"
check "…the gate event was committed to state"             bash -c "git -C '$ST' log --oneline | grep -q 'event gate.approved AD-1'"
check "…the executor ran with the sidecar config's allowlist" bash -c "grep -q -- '--allowedTools Bash(pnpm test -- --run)' '$CLAUDE_STUB_LOG'"
check "…app repo STILL clean"                              bash -c "[ -z \"\$(git -C '$R' status --porcelain)\" ]"
check "tick on a sidecar project finds its config + board" bash -c ": > '$CLAUDE_STUB_LOG'; node '$CLI' tick '$R' 2>&1 | grep -q 'tick: completed' && grep -q -- '/autodev:loop' '$CLAUDE_STUB_LOG'"
check "runtime files are NOT committed to state"           bash -c "! git -C '$ST' ls-files | grep -qE 'runtime/|locks/|\.last_report'"

echo "private remote — sync, one writer, takeover:"
BARE=$(mktemp -d "$SANDBOX/state-remote.XXXXXX"); git init -q --bare -b main "$BARE"
check_out "state remote <url>"                            "remote: $BARE" bash -c "cd '$R' && node '$CLI' state remote '$BARE'"
check_out "state sync pushes"                             "push: ok" bash -c "cd '$R' && node '$CLI' state sync"
check "remote has the commits"                            bash -c "git -C '$BARE' log --oneline main | grep -q 'initialized app'"
check_out "state status shows ahead/behind + writer"      "ahead 0 · behind 0.*writer for $PID: macbook since" bash -c "cd '$R' && node '$CLI' state status | tr '\n' ' '"
# a SECOND machine: fresh data root cloned from the remote
M2="$SANDBOX/autodev-home-mini"; mkdir -p "$M2"; git clone -q "$BARE" "$M2/state"
check "second machine: same project id from the synced registry" bash -c "cd '$R' && AUTODEV_HOME='$M2' AUTODEV_MACHINE=mini node '$CLI' status | grep -q \"($PID)\""
check "second machine cannot approve while macbook holds the seat" bash -c "cd '$R' && AUTODEV_HOME='$M2' AUTODEV_MACHINE=mini node '$CLI' approve AD-2 2>&1 | grep -q 'being written by macbook'"
check "…takeover claims the seat and pushes"               bash -c "cd '$R' && AUTODEV_HOME='$M2' AUTODEV_MACHINE=mini node '$CLI' state takeover | grep -q 'writer: mini (took over from macbook) · push ok'"
check "macbook sees the takeover after sync"               bash -c "cd '$R' && node '$CLI' state sync | grep -q 'fast-forwarded' && node '$CLI' state status | grep -q 'writer for $PID: mini'"
check "macbook now refused until it takes over"            bash -c "cd '$R' && node '$CLI' approve AD-2 2>&1 | grep -q 'being written by mini'"
# divergence: both machines commit without syncing → surfaced, never merged
(cd "$R" && node "$CLI" state takeover >/dev/null)
git -C "$M2/state" -c user.name=x -c user.email=x@x commit -q --allow-empty -m "mini: offline edit"
git -C "$ST" -c user.name=x -c user.email=x@x commit -q --allow-empty -m "macbook: offline edit"
check_out "diverged remote is surfaced, not merged (mini has an offline commit; macbook's takeover is on the remote)" "diverged: local .* and remote .* both have new commits" bash -c "cd '$R' && AUTODEV_HOME='$M2' node '$CLI' state sync 2>&1; true"
check "…sync exits 1 on divergence"                        bash -c "cd '$R' && ! AUTODEV_HOME='$M2' node '$CLI' state sync >/dev/null 2>&1"
check "…the remote was not force-pushed over"              bash -c "git -C '$BARE' log --oneline main | head -1 | grep -q 'took over'"
check "state repo never contains application code or secrets" bash -c "! git -C '$ST' ls-files | grep -qE '\.(js|ts|mjs|py)$|token|\.env'"

echo "layout migration — early v3 data roots move under state/:"
OLD="$SANDBOX/autodev-home-old"; mkdir -p "$OLD/projects/prj_01J0000000000000000000000X" "$OLD"; echo '{"version":1,"projects":[]}' > "$OLD/registry.json"
check "projects/ + registry.json at the root are moved into state/ once" n "import {stateDir} from '$SRC/core/paths.mjs'; import {existsSync} from 'node:fs'; const s=stateDir({AUTODEV_HOME:'$OLD'}); if(!existsSync(s+'/registry.json')||!existsSync(s+'/projects/prj_01J0000000000000000000000X')||existsSync('$OLD/projects')) throw 'not moved'"

exit $FAIL
