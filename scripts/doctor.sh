#!/usr/bin/env bash
# autoDev — preflight. Fail fast on setup mistakes BEFORE a run.
# Client-agnostic: reads .autodev/deployment.json. Run from anywhere in the repo.
# Invoked by /autodev:init and available any time as ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh.
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
source "$HERE/lib/config.sh"
autodev_resolve_config "$ROOT"
if [[ "$AUTODEV_CFG_LEGACY_SPLIT" == "true" ]]; then
  warn "repo.local_path/runner.* still inline in deployment.json (pre-split config) — run /autodev:init or scripts/upgrade-config.sh to move them into .autodev/deployment.local.json"
fi

echo "tooling:"
for t in node git claude; do
  command -v "$t" >/dev/null && ok "$t" || bad "$t missing"
done
# gh only serves draft-PR delivery — a local_diff deployment never opens PRs or pushes
if [[ "$(jq -r '.review.delivery // "draft_pr"' "$CONFIG")" == "local_diff" ]]; then
  ok "gh not required (review.delivery=local_diff — no PRs, no pushes)"
else
  command -v gh >/dev/null && ok "gh" || bad "gh missing (draft_pr delivery opens GitHub PRs — brew install gh, or set review.delivery=local_diff)"
fi
command -v braingrid >/dev/null && ok "braingrid" || warn "braingrid missing — engine will use the agent PRD/breakdown fallback"

echo "repo:"
REPO="$ROOT"
BRANCH=$(jq -r '.repo.default_branch' "$CONFIG")
[[ -d "$REPO/.git" ]] && ok "running inside a git repo ($REPO)" || bad "not a git repo: $REPO"
CONFIGURED_LOCAL_PATH=$(autodev_cfg_get repo.local_path "")
if [[ -z "$CONFIGURED_LOCAL_PATH" ]]; then
  warn "repo.local_path not set in .autodev/deployment.local.json — needed by report.mjs and the 24/7 timer (doctor itself uses this checkout directly)"
elif [[ "$CONFIGURED_LOCAL_PATH" != "$REPO" ]]; then
  warn "repo.local_path ($CONFIGURED_LOCAL_PATH) doesn't match this checkout ($REPO) — fix .autodev/deployment.local.json"
else
  ok "repo.local_path matches this checkout"
fi
git -C "$REPO" remote get-url origin >/dev/null 2>&1 && ok "origin remote present" || warn "no origin remote"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null \
  || git -C "$REPO" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
  && ok "default branch '$BRANCH' exists" || warn "default branch '$BRANCH' not found locally/remotely"
# branch protection — the mechanical enforcement of "only humans merge" (manual.md
# non-negotiable 3). draft_pr only: local_diff never pushes, so there's nothing to protect.
if [[ "$(jq -r '.review.delivery // "draft_pr"' "$CONFIG")" == "draft_pr" ]]; then
  # unprotected is a warn interactively but a FAIL once the 24/7 timer is wired — an
  # unattended runner must never be one weak setting away from merging to $BRANCH itself
  TIMER_WIRED=0
  launchctl list 2>/dev/null | grep -q "com.autodev" && TIMER_WIRED=1
  HB="$(jq -r '.runner.heartbeat_file // ""' "$CONFIG")"; HB="${HB/#\~/$HOME}"
  [[ -n "$HB" && -f "$HB" ]] && TIMER_WIRED=1
  PROT_FIX="GitHub → Settings → Branches → add a rule on '$BRANCH' with 'Require a pull request before merging'"
  if ! command -v gh >/dev/null; then
    warn "gh missing — can't verify branch protection on '$BRANCH'; check by hand: $PROT_FIX"
  elif PERR=$( (cd "$REPO" && gh api "repos/{owner}/{repo}/branches/$BRANCH/protection") 2>&1 >/dev/null ); then
    ok "branch protection active on '$BRANCH'"
  elif grep -qi "not protected" <<<"$PERR"; then
    if [[ "$TIMER_WIRED" -eq 1 ]]; then
      bad "default branch '$BRANCH' is UNPROTECTED with the 24/7 timer wired — protect it before unattended runs: $PROT_FIX"
    else
      warn "default branch '$BRANCH' is unprotected — 'only humans merge' has no mechanical backstop; $PROT_FIX"
    fi
  else
    warn "couldn't verify branch protection on '$BRANCH' ($(head -1 <<<"$PERR")) — check by hand: $PROT_FIX"
  fi
else
  ok "branch protection n/a (review.delivery=local_diff — no pushes, no PRs)"
fi

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

echo "tracker ($(jq -r '.tracker.kind // "linear"' "$CONFIG")):"
CLIENT=$(jq -r '.client_name' "$CONFIG")
KIND=$(jq -r '.tracker.kind // "linear"' "$CONFIG")
MIRROR=$(jq -r '.tracker.mirror.linear // false' "$CONFIG")
LINEAR_TOKEN_FILE=$(autodev_cfg_get tracker.linear.api_token_file "$HOME/.config/autodev/$CLIENT.linear.token")
SHORTCUT_TOKEN_FILE=$(autodev_cfg_get tracker.shortcut.api_token_file "$HOME/.config/autodev/$CLIENT.shortcut.token")
if [[ "$KIND" == "local" ]]; then
  if OUT=$(node "$HERE/tracker.mjs" doctor 2>&1); then ok "$OUT"; else bad "$OUT"; fi
  if [[ "$MIRROR" == "true" ]]; then
    # mirroring is async/best-effort, so a missing token is a warn, not a fail
    if [[ -n "${LINEAR_API_TOKEN:-}" ]] || [[ -f "$LINEAR_TOKEN_FILE" ]]; then
      ok "mirror token present (flush with: node $HERE/tracker.mjs flush-mirror)"
    else
      warn "tracker.mirror.linear is on but no Linear token — ops will queue until one exists"
    fi
  fi
elif [[ "$KIND" == "shortcut" ]]; then
  # jq's // doesn't default an empty string — mirror the driver's ||-falsy behavior
  SC_ENV=$(jq -r '.tracker.shortcut.api_token_env // ""' "$CONFIG"); [[ -n "$SC_ENV" ]] || SC_ENV="SHORTCUT_API_TOKEN"
  [[ "$(jq -r '.tracker.hierarchy // "issue"' "$CONFIG")" == "project" ]] && bad "tracker.hierarchy=project needs kind=linear (project statuses are Linear-only) — use hierarchy=issue with Shortcut"
  [[ "$(jq -r '.intake.mode // "cli"' "$CONFIG")" == "cli" ]] || bad "intake.mode=linear needs tracker.kind=linear — Shortcut deployments use cli intake"
  if [[ -n "${!SC_ENV:-}" ]] || [[ -f "$SHORTCUT_TOKEN_FILE" ]]; then
    ok "token present"
    # validates token + workflow + every configured state id against live Shortcut
    if OUT=$(node "$HERE/shortcut.mjs" doctor 2>&1); then ok "$OUT"; else bad "$OUT"; fi
  else
    bad "no Shortcut token (\$$SC_ENV or $SHORTCUT_TOKEN_FILE) — or set tracker.kind=local (no token needed)"
  fi
elif [[ -n "${LINEAR_API_TOKEN:-}" ]] || [[ -f "$LINEAR_TOKEN_FILE" ]]; then
  ok "token present"
  # validates token + team + every configured status id against live Linear
  if OUT=$(node "$HERE/linear.mjs" doctor 2>&1); then ok "$OUT"; else bad "$OUT"; fi
else
  bad "no Linear token (\$LINEAR_API_TOKEN or $LINEAR_TOKEN_FILE) — or set tracker.kind=local (no token needed)"
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

echo "visual qa (UI screenshots):"
VQA=$(jq -r '.qa.visual_qa.enabled // false' "$CONFIG")
if [[ "$VQA" != "true" ]]; then
  ok "qa.visual_qa disabled — skipping (no UI screenshot driver needed)"
else
  VMODE=$(jq -r '.qa.visual_qa.mode // "advisory"' "$CONFIG")
  DRIVER=$(jq -r '.qa.live_browser_driver // "playwright_mcp"' "$CONFIG")
  case "$DRIVER" in
    *mcp*)
      if command -v claude >/dev/null && claude mcp list 2>/dev/null | grep -qi playwright; then
        ok "Playwright MCP configured — visual QA can capture screenshots"
      else
        ADD="add it:  claude mcp add playwright npx @playwright/mcp@latest"
        if [[ "$VMODE" == "gating" ]]; then
          bad "qa.visual_qa enabled in GATING mode but Playwright MCP not found — the visual gate can't run. $ADD (or set qa.visual_qa.mode=advisory / enabled=false)"
        else
          warn "qa.visual_qa enabled but Playwright MCP not found — UI stories won't get visual screenshots (the angle will flag 'driver unavailable'). $ADD"
        fi
      fi
      ;;
    *)
      if command -v npx >/dev/null && npx --no-install playwright --version >/dev/null 2>&1; then
        ok "playwright available (driver '$DRIVER')"
      else
        warn "qa.visual_qa enabled but driver '$DRIVER' not verifiable — ensure it's installed (e.g. 'npx playwright install'), or switch qa.live_browser_driver to playwright_mcp"
      fi
      ;;
  esac
fi

echo "personas (agency-agents):"
# --check only — doctor never downloads; run-time ensure-personas.sh does (or fallback covers it)
if POUT=$(bash "$HERE/ensure-personas.sh" --check "$REPO" 2>&1); then
  PMISS=$(printf '%s\n' "$POUT" | grep -c "UNRESOLVED" || true)
  if [[ "$PMISS" -eq 0 ]]; then
    ok "$(printf '%s\n' "$POUT" | tail -1)"
  elif [[ "$(jq -r '.personas.auto_install | if type=="boolean" then tostring elif type=="null" then "true" else "false" end' "$CONFIG")" == "true" ]]; then
    warn "$PMISS persona(s) not installed — auto-installed at first run from $(jq -r '.personas.library.repo // "msitarzewski/agency-agents"' "$CONFIG") (doctor never downloads)"
    printf '%s\n' "$POUT" | grep "UNRESOLVED" | sed 's/^/    /'
  else
    warn "$PMISS persona(s) not installed and personas.auto_install=false — they will run as personas.fallback"
    printf '%s\n' "$POUT" | grep "UNRESOLVED" | sed 's/^/    /'
  fi
else
  bad "ensure-personas.sh --check failed: $POUT"
fi

# team docs vs the autoDev workflow (advisory — never fails the preflight)
if [[ -f "$HERE/check-docs.sh" ]]; then
  bash "$HERE/check-docs.sh" "$REPO" || true
fi

echo
[[ $fail -eq 0 ]] && { echo "doctor: PASS"; exit 0; } || { echo "doctor: FAIL — fix the ✗ items above"; exit 1; }
