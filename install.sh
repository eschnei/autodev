#!/usr/bin/env bash
#
# autoDev installer — render the engine template into a target client repo.
#
# Usage:  ./install.sh config/<client>.json
#
# Reads the per-client config, substitutes {{PLACEHOLDERS}} into every file
# under template/, copies the result into the target repo (.claude/ + scripts/),
# and prints the auth-bound manual steps that can't be automated.
#
# Idempotent: re-running re-renders. Existing files are overwritten — the engine
# is the source of truth, the target repo is just where it's installed.

set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-}"

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
  echo "usage: ./install.sh config/<client>.json" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "error: jq is required (brew install jq)" >&2; exit 1; }

# ---- pull config values -----------------------------------------------------
get() { jq -r "$1" "$CONFIG"; }

CLIENT=$(get '.client_name')
# Name prompt — fire ONLY if client_name is unset/placeholder, and only when we
# have a terminal. The normal render path stays non-interactive + re-runnable;
# set AUTODEV_NONINTERACTIVE=1 (or pipe with no TTY) to force-skip in CI/managed
# installs. The answer is written back to the config so deployment.json + any
# re-render stay consistent.
case "$CLIENT" in
  ""|null|AcmeCo)
    if [[ -t 0 && -t 1 && -z "${AUTODEV_NONINTERACTIVE:-}" ]]; then
      printf 'client_name is unset in %s — what should this deployment be named? > ' "$CONFIG" >&2
      read -r NAME_INPUT
      # trim leading/trailing whitespace
      NAME_INPUT="${NAME_INPUT#"${NAME_INPUT%%[![:space:]]*}"}"
      NAME_INPUT="${NAME_INPUT%"${NAME_INPUT##*[![:space:]]}"}"
      [[ -n "$NAME_INPUT" ]] || { echo "error: a name is required" >&2; exit 1; }
      CLIENT="$NAME_INPUT"
      TMPCFG=$(mktemp)
      jq --arg n "$CLIENT" '.client_name = $n' "$CONFIG" > "$TMPCFG" && mv "$TMPCFG" "$CONFIG"
      echo "  ✓ saved client_name=\"$CLIENT\" to $CONFIG" >&2
    else
      echo "error: .client_name is unset/placeholder in $CONFIG and there's no terminal to prompt (non-interactive). Set it and re-run." >&2
      exit 1
    fi
    ;;
esac
REPO=$(get '.repo.local_path')
DEFAULT_BRANCH=$(get '.repo.default_branch')
FEATURE_PREFIX=$(get '.repo.feature_branch_prefix')
STORY_PREFIX=$(get '.repo.story_branch_prefix')
BOT_NAME=$(get '.bot_identity.name')
BOT_EMAIL=$(get '.bot_identity.email')
BG_PROJECT=$(get '.braingrid.project_short_id')
LINEAR_TEAM=$(get '.tracker.team')
LINEAR_TEAM_KEY=$(get '.tracker.team_key')
LINEAR_TEAM_ID=$(get '.tracker.team_id // empty')
MAX_LANES=$(get '.execution.max_lanes')
TICK_MIN=$(get '.execution.tick_interval_minutes')
TICK_SECONDS=$(( TICK_MIN * 60 ))
MAX_LOOPS=$(get '.execution.max_dev_qa_loops')
SELF_REVIEW=$(get '.execution.self_review_rounds')
CMD_INSTALL=$(get '.commands.install')
CMD_TEST=$(get '.commands.test')
CMD_LINT=$(get '.commands.lint')
CMD_BUILD=$(get '.commands.build')
CMD_APP_RUN=$(get '.commands.app_run')
APP_URL=$(get '.commands.app_url')
E2E_DIR=$(get '.qa.e2e_dir')
RUN_HOME=$(get '.runner.home_dir')
MERGE_S2F=$(get '.merge_policy.story_to_feature')
MERGE_F2M=$(get '.merge_policy.feature_to_main')

# These values are interpolated into sed replacements; '&', '\' and the '|'
# delimiter are special there. Escape them so e.g. "a && b" stays literal
# (unescaped '&' was rendering as the matched pattern -> "{{CMD}}{{CMD}}").
# Only vars used EXCLUSIVELY in substitution are escaped (REPO/CLIENT/etc. are
# also used for filesystem ops and must stay raw).
for v in CMD_INSTALL CMD_TEST CMD_LINT CMD_BUILD CMD_APP_RUN APP_URL MERGE_S2F MERGE_F2M; do
  printf -v "$v" '%s' "$(printf '%s' "${!v}" | sed -e 's/[\\&|]/\\&/g')"
done

[[ -d "$REPO" ]] || { echo "error: repo.local_path '$REPO' not found" >&2; exit 1; }

# ---- render: copy template, substitute placeholders -------------------------
TMP=$(mktemp -d)
cp -R "$ENGINE_DIR/template/." "$TMP/"

substitute() {
  # portable in-place sed across files
  find "$TMP" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.template' \) -print0 |
  while IFS= read -r -d '' f; do
    sed -i.bak \
      -e "s|{{CLIENT_NAME}}|$CLIENT|g" \
      -e "s|{{REPO_PATH}}|$REPO|g" \
      -e "s|{{DEFAULT_BRANCH}}|$DEFAULT_BRANCH|g" \
      -e "s|{{FEATURE_PREFIX}}|$FEATURE_PREFIX|g" \
      -e "s|{{STORY_PREFIX}}|$STORY_PREFIX|g" \
      -e "s|{{BOT_NAME}}|$BOT_NAME|g" \
      -e "s|{{BOT_EMAIL}}|$BOT_EMAIL|g" \
      -e "s|{{BG_PROJECT}}|$BG_PROJECT|g" \
      -e "s|{{LINEAR_TEAM}}|$LINEAR_TEAM|g" \
      -e "s|{{LINEAR_TEAM_KEY}}|$LINEAR_TEAM_KEY|g" \
      -e "s|{{MAX_LANES}}|$MAX_LANES|g" \
      -e "s|{{TICK_MIN}}|$TICK_MIN|g" \
      -e "s|{{TICK_SECONDS}}|$TICK_SECONDS|g" \
      -e "s|{{MAX_LOOPS}}|$MAX_LOOPS|g" \
      -e "s|{{SELF_REVIEW}}|$SELF_REVIEW|g" \
      -e "s|{{CMD_INSTALL}}|$CMD_INSTALL|g" \
      -e "s|{{CMD_TEST}}|$CMD_TEST|g" \
      -e "s|{{CMD_LINT}}|$CMD_LINT|g" \
      -e "s|{{CMD_BUILD}}|$CMD_BUILD|g" \
      -e "s|{{CMD_APP_RUN}}|$CMD_APP_RUN|g" \
      -e "s|{{APP_URL}}|$APP_URL|g" \
      -e "s|{{E2E_DIR}}|$E2E_DIR|g" \
      -e "s|{{RUN_HOME}}|$RUN_HOME|g" \
      -e "s|{{MERGE_S2F}}|$MERGE_S2F|g" \
      -e "s|{{MERGE_F2M}}|$MERGE_F2M|g" \
      "$f"
    rm -f "$f.bak"
  done
}
substitute

# ---- install into the target repo -------------------------------------------
mkdir -p "$REPO/.claude" "$REPO/scripts/autodev"
cp -R "$TMP/.claude/." "$REPO/.claude/"
cp "$TMP/scripts/"* "$REPO/scripts/autodev/"
chmod +x "$REPO/scripts/autodev/"*.sh "$REPO/scripts/autodev/"*.mjs 2>/dev/null || true
mkdir -p "$REPO/.autodev/ops"
cp -R "$TMP/ops/." "$REPO/.autodev/ops/"
cp "$CONFIG" "$REPO/.autodev/deployment.json"

# Auto-detect house conventions (generated types · design system · data layer · tests)
# so the dev agent adopts them instead of hand-rolling types / hardcoding styles.
# CLAUDE.md imports this file; re-generated on every install.
if bash "$REPO/scripts/autodev/detect-conventions.sh" "$REPO" > "$REPO/.autodev/conventions.md" 2>/dev/null; then
  echo "✓ wrote .autodev/conventions.md (auto-detected project conventions)"
else
  echo "# Project conventions — auto-detect unavailable; declare them in CLAUDE.md." > "$REPO/.autodev/conventions.md"
  echo "ℹ︎ convention auto-detect skipped (wrote a stub .autodev/conventions.md)"
fi

rm -rf "$TMP"

# ---- create the standard Linear board (canonical columns; idempotent) -------
TOKEN_FILE="$HOME/.config/autodev/$CLIENT.linear.token"
if [[ -n "$LINEAR_TEAM_ID" && -f "$TOKEN_FILE" ]]; then
  echo "Creating the standard Linear board columns in team '$LINEAR_TEAM'…"
  TOKEN="$(cat "$TOKEN_FILE")"; API="https://api.linear.app/graphql"
  EXISTING=$(curl -s -X POST "$API" -H "Content-Type: application/json" -H "Authorization: $TOKEN" \
    -d "$(jq -n --arg t "$LINEAR_TEAM_ID" '{query:"query($t:String!){team(id:$t){states(first:50){nodes{name}}}}",variables:{t:$t}}')" \
    | jq -r '.data.team.states.nodes[].name')
  mk () {  # name type color position — skips if a column with that name already exists
    if grep -qxF "$1" <<<"$EXISTING"; then echo "  • exists: $1"; return; fi
    curl -s -X POST "$API" -H "Content-Type: application/json" -H "Authorization: $TOKEN" \
      -d "$(jq -n --arg t "$LINEAR_TEAM_ID" --arg n "$1" --arg ty "$2" --arg c "$3" --argjson p "$4" \
        '{query:"mutation($i:WorkflowStateCreateInput!){workflowStateCreate(input:$i){success workflowState{name}}}",variables:{i:{teamId:$t,name:$n,type:$ty,color:$c,position:$p}}}')" \
      | jq -r '.data.workflowStateCreate.workflowState.name as $n | if $n then "  ✓ created: "+$n else "  ✗ "+(.errors[0].message//"?") end'
  }
  mk "New Request"      started   "#95a2b3"  90
  mk "Clarifying (H)"   started   "#f2994a"  95
  mk "PRD Review (H)"   started   "#5e6ad2" 100
  mk "Breakdown"        started   "#5e6ad2" 110
  mk "Ready for AI Dev" started   "#0f7938" 120
  mk "AI Development"    started   "#0f7938" 130
  mk "AI QA"            started   "#f2c94c" 140
  mk "Human Review (H)" started   "#f2994a" 150
  mk "Blocked (H)"      started   "#eb5757" 160
  mk "Done"             completed "#0f7938" 170
  echo "  → paste each column's UUID into tracker.statuses[*].id (see linear-setup.md)"

  # hierarchy: "project" mode only — create ORG-LEVEL feature project statuses
  HIER=$(get '.tracker.hierarchy // "issue"')
  if [[ "$HIER" == "project" ]]; then
    echo "Hierarchy=project → creating ORG-LEVEL project statuses (workspace-wide)…"
    PSEXIST=$(curl -s -X POST "$API" -H "Content-Type: application/json" -H "Authorization: $TOKEN" \
      -d '{"query":"{organization{projectStatuses{name}}}"}' | jq -r '.data.organization.projectStatuses[].name')
    mkps () {  # name type color
      if grep -qxF "$1" <<<"$PSEXIST"; then echo "  • exists: $1"; return; fi
      curl -s -X POST "$API" -H "Content-Type: application/json" -H "Authorization: $TOKEN" \
        -d "$(jq -n --arg n "$1" --arg ty "$2" --arg c "$3" \
          '{query:"mutation($i:ProjectStatusCreateInput!){projectStatusCreate(input:$i){success projectStatus{name}}}",variables:{i:{name:$n,type:$ty,color:$c}}}')" \
        | jq -r '.data.projectStatusCreate.projectStatus.name as $n | if $n then "  ✓ created: "+$n else "  ✗ "+(.errors[0].message//"?") end'
    }
    mkps "New Request"    backlog   "#95a2b3"
    mkps "Clarifying (H)" planned   "#f2994a"
    mkps "PRD Review (H)" planned   "#5e6ad2"
    mkps "In Development" started   "#0f7938"
    mkps "Acceptance (H)" started   "#f2994a"
    mkps "Shipped"        completed "#0f7938"
    echo "  → paste each id into tracker.project_statuses[*].id (these are WORKSPACE-WIDE)"
  fi
else
  echo "ℹ︎ Skipped Linear board creation (need tracker.team_id in config + ~/.config/autodev/$CLIENT.linear.token)."
  echo "   Create the standard columns manually: .autodev/ops/linear-setup.md"
fi

# ---- report -----------------------------------------------------------------
cat <<EOF

✅ autoDev engine installed into: $REPO
   .claude/CLAUDE.md, .claude/skills/{intake,prd,breakdown,devloop}.md,
   .claude/settings.json (+ SessionStart hook), scripts/autodev/*.sh
   (incl. session-init.sh, detect-conventions.sh),
   .autodev/{deployment.json,conventions.md,ops/}

⚠️  MAKES AUTODEV DRIVE (do this first): open Claude Code in $REPO and ACCEPT the
   workspace-trust prompt. That activates the SessionStart hook in .claude/settings.json,
   which re-orients every session so the engine drives instead of ad-hoc Claude Code.
   Without trust, the hook won't run and Claude may "fight" the workflow. Verify the
   hook prints JSON: bash "$REPO/scripts/autodev/session-init.sh"

Now the auth-bound manual steps (these can't be automated for you):

  1. BrainGrid project (in $REPO):
       cd "$REPO" && braingrid init      # then set braingrid.project_short_id in the config

  2. Connect the client's Linear — workspace '$LINEAR_TEAM' (do NOT use any other):
       - put their Linear API key on disk (gitignored), never paste it in chat:
         ~/.config/autodev/$CLIENT.linear.token
       - export LINEAR_API_TOKEN=\$(cat ~/.config/autodev/$CLIENT.linear.token)
       - (interactive) connect a Linear MCP for their workspace if desired

  3. Linear board: the standard status columns were auto-created above (if a
       token was present) — paste their UUIDs into tracker.statuses[*].id.
       Create the control LABELS (ai-eligible, route:*, risk:*): .autodev/ops/linear-setup.md

  4. Bot git identity + branch protection (needs repo admin):
       protect '$DEFAULT_BRANCH' so ONLY humans merge; the bot ($BOT_NAME)
       pushes ${FEATURE_PREFIX}* and ${STORY_PREFIX}/* branches only

  5. (Phase 3, when going 24/7) install the timer:
       see .autodev/ops/launchd.plist.template

Engine is client-agnostic; everything client-specific lives in
.autodev/deployment.json. Re-run install.sh anytime to re-render.
EOF
