#!/usr/bin/env bash
#
# autoDev — VENDORED install (the plugin's sibling distribution mode).
#
# Copies the engine INTO a repo at .autodev/engine/ so clients who can't/won't run a
# marketplace plugin get the same engine, reviewable and pinned in their own git
# history. Everything is the SAME de-templated content the plugin ships — this script
# only rewrites two things in the copy:
#   ${CLAUDE_PLUGIN_ROOT}  →  the in-repo engine path (via $CLAUDE_PROJECT_DIR)
#   /autodev:<cmd>         →  /autodev-<cmd>   (repo-local commands can't use ':')
#
# Usage:  ./install.sh /path/to/client/repo [--force]
# Idempotent; re-run to upgrade the vendored engine. Pick ONE mode per repo — this
# refuses to install where the autodev plugin is enabled (override with --force).
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-}"; FORCE="${2:-}"
[[ -n "$REPO" && -d "$REPO" ]] || { echo "usage: ./install.sh /path/to/client/repo [--force]" >&2; exit 1; }
[[ -d "$REPO/.git" ]] || { echo "error: $REPO is not a git repo" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq is required (brew install jq)" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd -P)"

# ---- one mode per repo: refuse if the plugin is enabled (best-effort detection) ----
plugin_enabled() {
  for s in "$REPO/.claude/settings.json" "$HOME/.claude/settings.json"; do
    [[ -f "$s" ]] && jq -e '.enabledPlugins // {} | keys[] | select(startswith("autodev@"))' "$s" >/dev/null 2>&1 && return 0
  done
  return 1
}
if plugin_enabled && [[ "$FORCE" != "--force" ]]; then
  echo "✗ the autodev PLUGIN is enabled for this repo/user — running both modes doubles every hook and skill." >&2
  echo "  Either stay on the plugin (nothing to install), or disable it and re-run (or pass --force)." >&2
  exit 1
fi

# ---- copy the engine into the repo, rewriting plugin-isms ------------------------
ENG="$REPO/.autodev/engine"
rm -rf "$ENG"; mkdir -p "$ENG"
for d in commands reference scripts hooks ops; do cp -R "$ENGINE_DIR/$d" "$ENG/$d"; done
cp "$ENGINE_DIR/.claude-plugin/plugin.json" "$ENG/plugin.json" 2>/dev/null || true
find "$ENG" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.mjs' \) -print0 |
while IFS= read -r -d '' f; do
  sed -i.bak \
    -e 's|"\${CLAUDE_PLUGIN_ROOT}|"$CLAUDE_PROJECT_DIR/.autodev/engine|g' \
    -e 's|\${CLAUDE_PLUGIN_ROOT}|.autodev/engine|g' \
    -e 's|/autodev:|/autodev-|g' \
    "$f" && rm -f "$f.bak"
done
chmod +x "$ENG/scripts/"*.sh "$ENG/scripts/"*.mjs "$ENG/hooks/"*.sh 2>/dev/null || true

# ---- repo-local commands: /autodev-init /autodev-new /autodev-loop ---------------
mkdir -p "$REPO/.claude/commands"
for c in init new loop; do cp "$ENG/commands/$c.md" "$REPO/.claude/commands/autodev-$c.md"; done

# ---- hooks: MERGE into .claude/settings.json (never clobber a team file) ---------
S="$REPO/.claude/settings.json"
HOOKS_JSON=$(sed -e 's|"\${CLAUDE_PLUGIN_ROOT}|"$CLAUDE_PROJECT_DIR/.autodev/engine|g' "$ENGINE_DIR/hooks/hooks.json")
if [[ -f "$S" ]]; then
  cp "$S" "$S.pre-autodev-$(date +%Y%m%d%H%M%S)" 2>/dev/null || cp "$S" "$S.pre-autodev"
  # drop any hook entries we injected before (idempotent re-install), then append ours
  MERGED=$(jq --argjson add "$HOOKS_JSON" '
    .hooks = ((.hooks // {}) | with_entries(.value |= (map(.hooks |= map(select((.command // "") | contains(".autodev/engine") | not))) | map(select(.hooks | length > 0)))))
    | .hooks.SessionStart = ((.hooks.SessionStart // []) + $add.hooks.SessionStart)
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + $add.hooks.UserPromptSubmit)
    | .hooks.PreToolUse  = ((.hooks.PreToolUse  // []) + $add.hooks.PreToolUse)
  ' "$S")
  printf '%s\n' "$MERGED" > "$S"
  echo "✓ merged autoDev hooks into your existing .claude/settings.json (backup kept; your entries untouched)"
else
  printf '%s\n' "$HOOKS_JSON" > "$S"
  echo "✓ wrote .claude/settings.json (hooks only — guards enforce push/docs rules)"
fi

# ---- identity pointer + version stamp ---------------------------------------------
bash "$ENG/scripts/write-identity-pointer.sh" "$REPO" >/dev/null 2>&1 || true
V=$(jq -r '.version // "unknown"' "$ENG/plugin.json" 2>/dev/null || echo unknown)
SHA=$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
CFG="$REPO/.autodev/deployment.json"
if [[ -f "$CFG" ]]; then
  jq --arg v "$V" --arg s "$SHA" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.engine = {mode: "vendored", version: $v, sha: $s, installed_at: $t}' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "✓ engine stamped: vendored $V @ $SHA"
else
  echo "ℹ︎ no .autodev/deployment.json yet — run /autodev-init in Claude Code to configure"
fi

cat <<EOF

✅ autoDev VENDORED install → $REPO/.autodev/engine ($V @ $SHA)
   commands: /autodev-init · /autodev-new · /autodev-loop (repo-local)
   Commit the changes so the engine travels with the repo. One-time: accept the
   workspace trust prompt so the repo hooks (session identity + push/docs guards) run.
   Upgrading later: re-run this script. Switching to the plugin later: /autodev:init
   migrates a vendored install automatically.
EOF
