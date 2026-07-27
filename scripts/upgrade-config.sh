#!/usr/bin/env bash
# autoDev — upgrade an existing .autodev/deployment.json to the current schema.
# Adds keys the config predates (session_mode, intake.bugs, preview, backup,
# tracker.instance_label/mirror, qa.visual_qa/test_layers, …) with their defaults;
# NEVER changes a value the operator already set (existing values always win).
# The example's "_note" documentation keys are stripped so client configs stay lean.
# Also splits legacy-inline local-only fields (repo.local_path, runner.*) out into
# .autodev/deployment.local.json (and gitignores it) the first time it runs on an
# unsplit config — never touches a local file that already exists, and never creates
# a repo-local one when a global ~/.config/autodev/<client>/deployment.local.json
# already covers those fields (it just drops the redundant inline copies).
# Idempotent; prints exactly what it added/split. Usage: upgrade-config.sh [repo]
set -uo pipefail

REPO="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
CFG="$REPO/.autodev/deployment.json"
LOCAL="$REPO/.autodev/deployment.local.json"
EXAMPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/reference/deployment.example.json"
[[ -f "$CFG" ]] || { echo "no $CFG — nothing to upgrade (run /autodev:init to configure)"; exit 0; }
jq empty "$CFG" 2>/dev/null || { echo "✗ $CFG is not valid JSON — fix it first" >&2; exit 1; }

# Strip ONLY the enumerated local-only leaves from deployment.json — never the whole
# .runner object, or an operator's custom//future runner.* key would vanish from both
# files. .runner itself goes away only once it's left empty.
strip_legacy_inline() {
  jq 'del(.repo.local_path, .runner.home_dir, .runner.heartbeat_file, .runner.rate_limited_file, .runner.logs_dir)
      | if (.runner // {} | length) == 0 then del(.runner) else . end' \
    "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
}

# The local file must never be committed; make sure .gitignore says so (idempotent).
ensure_gitignored() {
  local gi="$REPO/.gitignore" entry=".autodev/deployment.local.json"
  if [[ ! -f "$gi" ]]; then
    echo "$entry" > "$gi"
    echo "✓ created $gi ignoring $entry"
  elif grep -qxF "$entry" "$gi" || grep -qxF "/$entry" "$gi"; then
    : # already covered
  else
    [[ -n "$(tail -c1 "$gi")" ]] && echo "" >> "$gi"
    echo "$entry" >> "$gi"
    echo "✓ added $entry to $gi"
  fi
}

# --- split: move legacy-inline local-only fields out to deployment.local.json ---
# Resolution mirrors scripts/lib/config.sh's autodev_resolve_config: a global local
# file counts as already-split. Shadowing it with a fresh repo-local file built from
# the stale inline values would take precedence over the operator's real config.
GLOBAL_LOCAL=""
CLIENT=$(jq -r '.client_name // ""' "$CFG" 2>/dev/null)
if [[ -n "$CLIENT" && -f "$HOME/.config/autodev/$CLIENT/deployment.local.json" ]]; then
  GLOBAL_LOCAL="$HOME/.config/autodev/$CLIENT/deployment.local.json"
fi

if [[ ! -f "$LOCAL" ]]; then
  LOCAL_CONTENT=$(jq '
    def paths_list: [["repo","local_path"],["runner","home_dir"],["runner","heartbeat_file"],["runner","rate_limited_file"],["runner","logs_dir"]];
    . as $cfg
    | reduce paths_list[] as $p
        ({}; ($cfg | getpath($p)) as $v | if $v != null then setpath($p; $v) else . end)
  ' "$CFG")
  if [[ "$(jq -c . <<<"$LOCAL_CONTENT")" != "{}" ]]; then
    if [[ -n "$GLOBAL_LOCAL" ]]; then
      strip_legacy_inline
      echo "✓ existing local config found at $GLOBAL_LOCAL — used it instead of creating $LOCAL"
      echo "  stripped the now-redundant legacy fields from $CFG:"
      jq -r '[paths(scalars)] | map(join(".")) | .[] | "    - " + .' <<<"$LOCAL_CONTENT"
    else
      echo "$LOCAL_CONTENT" > "$LOCAL"
      strip_legacy_inline
      echo "✓ split legacy local fields into $LOCAL:"
      jq -r '[paths(scalars)] | map(join(".")) | .[] | "    + " + .' <<<"$LOCAL_CONTENT"
      ensure_gitignored
    fi
  fi
fi

BEFORE=$(jq -c '[paths(scalars)]' "$CFG")
# defaults (notes stripped, identity/example-only fields dropped) deep-merged UNDER
# the existing config — jq's * is right-biased, so operator values always win
jq -s '
  (.[0]
    | walk(if type=="object" then with_entries(select(.key|startswith("_")|not)) else . end)
    | del(.client_name, .assistant_name, .repo, .bot_identity, .tracker.team, .tracker.team_key, .tracker.team_id, .braingrid.project_short_id, .commands, .engine)
  ) * .[1]
' "$EXAMPLE" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

# the example's literal instance label must not leak — derive it from client_name
if [[ "$(jq -r '.tracker.instance_label // ""' "$CFG")" == "autodev:acmeco" ]]; then
  jq '.tracker.instance_label = ("autodev:" + (.client_name // "client" | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")))' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
fi

ADDED=$(jq -n --argjson a "$BEFORE" --argjson b "$(jq -c '[paths(scalars)]' "$CFG")" \
  '($b - $a) | map(join(".")) | sort')
N=$(echo "$ADDED" | jq 'length')
if [[ "$N" -eq 0 ]]; then
  echo "✓ config already current — nothing added"
else
  echo "✓ config upgraded — $N key(s) added with defaults (your existing values untouched):"
  echo "$ADDED" | jq -r '.[] | "    + " + .'
  echo "  review the additions: git diff .autodev/deployment.json"
fi
