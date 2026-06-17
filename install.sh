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
cp "$TMP/scripts/"*.sh "$REPO/scripts/autodev/"
chmod +x "$REPO/scripts/autodev/"*.sh
mkdir -p "$REPO/.autodev/ops"
cp -R "$TMP/ops/." "$REPO/.autodev/ops/"
cp "$CONFIG" "$REPO/.autodev/deployment.json"
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
else
  echo "ℹ︎ Skipped Linear board creation (need tracker.team_id in config + ~/.config/autodev/$CLIENT.linear.token)."
  echo "   Create the standard columns manually: .autodev/ops/linear-setup.md"
fi

# ---- report -----------------------------------------------------------------
cat <<EOF

✅ autoDev engine installed into: $REPO
   .claude/CLAUDE.md, .claude/skills/{intake,prd,breakdown,devloop}.md,
   .claude/settings.json, scripts/autodev/*.sh, .autodev/{deployment.json,ops/}

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
