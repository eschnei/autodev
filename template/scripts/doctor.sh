#!/usr/bin/env bash
# autoDev — preflight. Fail fast on setup mistakes BEFORE a run.
# Client-agnostic: reads .autodev/deployment.json. Run from anywhere in the repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HERE/../..")"
CONFIG="$ROOT/.autodev/deployment.json"
export AUTODEV_CONFIG="$CONFIG"

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "autoDev doctor — $CONFIG"

[[ -f "$CONFIG" ]] || { bad "no deployment.json at $CONFIG"; exit 1; }
command -v jq >/dev/null && ok "jq" || bad "jq missing (brew install jq)"

echo "tooling:"
for t in node git gh claude; do
  command -v "$t" >/dev/null && ok "$t" || bad "$t missing"
done
command -v braingrid >/dev/null && ok "braingrid" || warn "braingrid missing — engine will use the agent PRD/breakdown fallback"

echo "repo:"
REPO=$(jq -r '.repo.local_path' "$CONFIG")
BRANCH=$(jq -r '.repo.default_branch' "$CONFIG")
[[ -d "$REPO/.git" ]] && ok "repo at $REPO" || bad "repo.local_path not a git repo: $REPO"
git -C "$REPO" remote get-url origin >/dev/null 2>&1 && ok "origin remote present" || warn "no origin remote"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null \
  || git -C "$REPO" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
  && ok "default branch '$BRANCH' exists" || warn "default branch '$BRANCH' not found locally/remotely"

echo "toolchain (B7):"
if [[ -f "$REPO/.tool-versions" ]]; then
  if command -v asdf >/dev/null; then
    # flag any partial/loose pin (a major.minor with no installed patch won't resolve)
    if (cd "$REPO" && asdf current 2>&1 | grep -qiE "not installed|no version|No preset"); then
      bad ".tool-versions has unresolved/uninstalled pins — run 'asdf install' (a loose 'lang X.Y' with no installed patch doesn't resolve)"
      (cd "$REPO" && asdf current 2>&1 | grep -iE "not installed|no version" | sed 's/^/      /')
    else
      ok ".tool-versions resolves (asdf)"
    fi
  else
    warn ".tool-versions present but asdf not installed — can't verify the toolchain"
  fi
else
  ok "no .tool-versions (toolchain check skipped)"
fi

echo "linear (live):"
CLIENT=$(jq -r '.client_name' "$CONFIG")
if [[ -n "${LINEAR_API_TOKEN:-}" ]] || [[ -f "$HOME/.config/autodev/$CLIENT.linear.token" ]]; then
  ok "token present"
  # validates token + team + every configured status id against live Linear
  if OUT=$(node "$HERE/linear.mjs" doctor 2>&1); then ok "$OUT"; else bad "$OUT"; fi
else
  bad "no Linear token (\$LINEAR_API_TOKEN or ~/.config/autodev/$CLIENT.linear.token)"
fi

echo "braingrid:"
BG=$(jq -r '.braingrid.enabled' "$CONFIG")
PID=$(jq -r '.braingrid.project_short_id' "$CONFIG")
if [[ "$BG" == "true" ]]; then
  [[ "$PID" != "PENDING_BRAINGRID_INIT" && "$PID" != "PROJ-XX" ]] && ok "braingrid project $PID" || warn "braingrid.enabled but project_short_id not set (run braingrid init)"
else
  ok "braingrid disabled — agent fallback in use"
fi

echo "hermetic safety (B3):"
HERM=$(jq -r '.qa.hermetic.enabled // false' "$CONFIG")
# scan local env files for prod-looking external endpoints (fixed-string match on
# the de-globbed core domain: "*.twilio.com" -> "twilio.com")
ENVHITS=""
while IFS= read -r pat; do
  [[ -z "$pat" ]] && continue
  core=${pat#\*}; core=${core#.}
  for ef in "$REPO/.env" "$REPO/.env.test" "$REPO/.env.local" "$REPO/config/.env"; do
    [[ -f "$ef" ]] || continue
    grep -qiF "$core" "$ef" 2>/dev/null && ENVHITS+="$core "
  done
done < <(jq -r '.qa.hermetic.forbid_endpoints[]?' "$CONFIG")
ENVHITS=$(printf '%s' "$ENVHITS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ *$//')
if [[ -n "$ENVHITS" ]]; then
  if [[ "$HERM" == "true" ]]; then
    warn "prod-looking endpoints in env: $ENVHITS — OK only because qa.hermetic overrides them at run time"
    [[ "$(jq -r '.qa.hermetic.env | length' "$CONFIG")" -gt 0 ]] && ok "qa.hermetic.env overrides set" || bad "qa.hermetic.enabled but no qa.hermetic.env overrides defined"
  else
    bad "PROD endpoints in env ($ENVHITS) and qa.hermetic.enabled=false — the engine could drive tests/live against PRODUCTION. Enable qa.hermetic."
  fi
else
  [[ "$HERM" == "true" ]] && ok "hermetic on; no prod endpoints detected in env" || warn "qa.hermetic disabled (fine if there are no external prod services)"
fi

# team docs vs the autoDev workflow (advisory — never fails the preflight)
if [[ -f "$HERE/check-docs.sh" ]]; then
  bash "$HERE/check-docs.sh" "$REPO" || true
fi

echo
[[ $fail -eq 0 ]] && { echo "doctor: PASS"; exit 0; } || { echo "doctor: FAIL — fix the ✗ items above"; exit 1; }
