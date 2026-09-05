#!/usr/bin/env bash
# autoDev test harness — shared by tests/smoke.sh and every tests/suite/*.sh.
#
# Sourcing this file makes the run HERMETIC: nothing on the developer's machine
# (user-level ~/.claude/settings.json, ~/.config/autodev/*, installed plugins, gh
# auth, launchd, macOS notifications) can leak into or be touched by a test.
#   - $HOME is redirected to a throwaway directory
#   - a stub bin dir is prepended to $PATH with no-op/recording fakes for the
#     external tools the scripts shell out to (claude, gh, launchctl, osascript)
#   - git identity is supplied via env so commits work without a ~/.gitconfig
#
# Helpers:
#   check <desc> <cmd...>        pass/fail on exit status (stdout/stderr hidden)
#   check_out <desc> <re> <cmd>  pass iff the command's combined output matches <re>
#   mkrepo <client_name>         synthetic git repo with a local-tracker deployment
#                                (prints the path; $RUNHOME is its runner home)
#   hook_input <tool> <json-tool_input> <cwd>   JSON a PreToolUse hook reads on stdin
#   old_touch <file>             set a file's mtime two hours in the past
set -uo pipefail

PLUGIN="${PLUGIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FAIL=${FAIL:-0}
PASSED=${PASSED:-0}
FAILED=${FAILED:-0}

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASSED=$((PASSED+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; FAILED=$((FAILED+1)); }
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
check_out() { # <desc> <grep -E pattern> <cmd...> — asserts on combined stdout+stderr
  local d="$1" re="$2"; shift 2
  local out; out=$("$@" 2>&1)
  if grep -qE -- "$re" <<<"$out"; then pass "$d"; else fail "$d"; printf '      output: %s\n' "$(head -c 300 <<<"$out" | tr '\n' ' ')"; fi
}
check_no_out() { # <desc> <cmd...> — passes iff the command exits 0 and prints nothing
  local d="$1"; shift
  local out; out=$("$@" 2>&1); local rc=$?
  if [[ $rc -eq 0 && -z "$out" ]]; then pass "$d"; else fail "$d"; fi
}

# ---- sandbox ----------------------------------------------------------------------
export SANDBOX="${SANDBOX:-$(mktemp -d)}"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"   # macOS: /var -> /private/var, match git rev-parse
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_AUTHOR_NAME="autodev-test" GIT_AUTHOR_EMAIL="test@autodev.invalid"
export GIT_COMMITTER_NAME="autodev-test" GIT_COMMITTER_EMAIL="test@autodev.invalid"
export GIT_CONFIG_NOSYSTEM=1
unset LINEAR_API_TOKEN SHORTCUT_API_TOKEN SLACK_WEBHOOK AUTODEV_CONFIG AUTODEV_LOCAL_CONFIG AUTODEV_AGENTS_DIR 2>/dev/null || true

export STUBBIN="$SANDBOX/bin"; mkdir -p "$STUBBIN"
export PATH="$STUBBIN:$PATH"
export CLAUDE_STUB_LOG="${CLAUDE_STUB_LOG:-$SANDBOX/claude-calls.log}"
export CLAUDE_STUB_MODE="${CLAUDE_STUB_MODE:-ok}"
# Suites exercise the executor seam with plain natural language; Marj (the
# controller) is opt-in per suite (tests/suite/marj.sh unsets this).
export AUTODEV_CONTROLLER="${AUTODEV_CONTROLLER:-none}"

# claude: records every argv line to $CLAUDE_STUB_LOG; behavior via $CLAUDE_STUB_MODE
#   ok      -> {"result":"ok","is_error":false}
#   limited -> a usage-limit error result (what devloop-tick.sh keys on)
#   fail    -> no output, exit 1 (network down / CLI missing auth)
cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAUDE_STUB_LOG:-/dev/null}"
case "${CLAUDE_STUB_MODE:-ok}" in
  ok)      echo '{"type":"result","is_error":false,"result":"ok"}' ;;
  limited) echo '{"type":"result","is_error":true,"result":"You have hit your usage limit. Try again later.","reset_at_epoch":4102444800}' ;;
  fail)    exit 1 ;;
  intent)  # Marj tests: interpret → $CLAUDE_STUB_INTENT (JSON); respond → a short line
           if printf '%s' "$*" | grep -q 'Audit (data)'; then echo '{"type":"result","is_error":false,"result":"Marj: here is what happened."}';
           else intent="${CLAUDE_STUB_INTENT:-}"; [ -n "$intent" ] || intent='{"goal":"status","steps":[{"action":"get_status"}]}'
                jq -cn --arg r "$intent" '{type:"result",is_error:false,result:$r}'; fi ;;
  *)       echo '{"type":"result","is_error":false,"result":"ok"}' ;;
esac
EOF
# codex: records argv + the stdin prompt to $CODEX_STUB_LOG; emits `codex exec --json`
# JSONL events per $CODEX_STUB_MODE (ok | limited | fail); honors -o <file>.
export CODEX_STUB_LOG="${CODEX_STUB_LOG:-$SANDBOX/codex-calls.log}"
export CODEX_STUB_MODE="${CODEX_STUB_MODE:-ok}"
cat > "$STUBBIN/codex" <<'EOF'
#!/usr/bin/env bash
PROMPT=$(cat)
printf 'ARGS: %s\nPROMPT: %s\n---\n' "$*" "$(printf '%s' "$PROMPT" | tr '\n' ' ')" >> "${CODEX_STUB_LOG:-/dev/null}"
OUT=""; prev=""; for a in "$@"; do [[ "$prev" == "-o" ]] && OUT="$a"; prev="$a"; done
case "${CODEX_STUB_MODE:-ok}" in
  ok)
    echo '{"type":"thread.started","thread_id":"t1"}'
    echo '{"type":"item.completed","item":{"type":"command_execution","command":"npm test","exit_code":0,"aggregated_output":"ok"}}'
    echo '{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"src/a.js","kind":"update"},{"path":"src/b.js","kind":"add"}]}}'
    echo '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
    [[ -n "$OUT" ]] && printf 'ok' > "$OUT"; exit 0 ;;
  limited)
    echo '{"type":"thread.started","thread_id":"t1"}'
    echo '{"type":"error","message":"You have hit your usage limit (rate limit). Try again later."}'
    exit 1 ;;
  failed)
    echo '{"type":"item.completed","item":{"type":"command_execution","command":"npm test","exit_code":1,"aggregated_output":"2 failing"}}'
    echo '{"type":"turn.failed","error":{"message":"tests failed"}}'
    exit 1 ;;
  fail) exit 1 ;;
  *) echo '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'; exit 0 ;;
esac
EOF
# gh: pretends the default branch is unprotected and never talks to GitHub
cat > "$STUBBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then echo '{"message":"Branch not protected"}' >&2; exit 1; fi
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/launchctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/osascript"
chmod +x "$STUBBIN"/*

# ---- fixtures ---------------------------------------------------------------------
# mkrepo <client_name> [extra-jq-filter]  → path to a git repo with a local-tracker
# deployment.json (project) + deployment.local.json (repo path + runner home).
# runhome <repo> → the runner home dir mkrepo assigned to that repo (deterministic, so
# it survives mkrepo running inside a $(…) subshell).
runhome() { printf '%s/run/%s' "$SANDBOX" "$(basename "$1")"; }
mkrepo() {
  local client="$1" filter="${2:-.}" repo RUNHOME
  repo=$(mktemp -d "$SANDBOX/repo.XXXXXX"); repo="$(cd "$repo" && pwd -P)"
  git -C "$repo" init -q
  mkdir -p "$repo/.autodev"
  RUNHOME=$(runhome "$repo"); mkdir -p "$RUNHOME"
  # instance_label derived from client_name exactly like upgrade-config.sh does
  jq --arg c "$client" ".client_name=\$c | .tracker.kind=\"local\" | .braingrid.enabled=false | .tracker.instance_label=(\"autodev:\" + (\$c | ascii_downcase | gsub(\"[^a-z0-9]+\"; \"-\") | gsub(\"^-+|-+\$\"; \"\"))) | $filter" \
    "$PLUGIN/reference/deployment.example.json" > "$repo/.autodev/deployment.json"
  printf '{"repo":{"local_path":"%s"},"runner":{"home_dir":"%s"}}\n' "$repo" "$RUNHOME" > "$repo/.autodev/deployment.local.json"
  printf '.autodev/deployment.local.json\n' > "$repo/.gitignore"
  printf '%s' "$repo"
}

hook_input() { # <tool_name> <tool_input-json> <cwd>
  jq -cn --arg t "$1" --argjson i "$2" --arg c "$3" '{tool_name:$t, tool_input:$i, cwd:$c}'
}
old_touch() { touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$1"; }

# grep helpers over a captured $OUT (avoid interpolating output into bash -c strings)
has()    { grep -qF  -- "$1" <<<"${OUT:-}"; }
has_re() { grep -qE  -- "$1" <<<"${OUT:-}"; }
lacks()  { ! grep -qF -- "$1" <<<"${OUT:-}"; }
count_re() { grep -cE -- "$1" <<<"${OUT:-}"; }

TRK="$PLUGIN/scripts/tracker.mjs"
export -f hook_input old_touch runhome
