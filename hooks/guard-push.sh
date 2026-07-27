#!/usr/bin/env bash
# autoDev — push guard (PreToolUse hook). Blocks a Bash `git push` of the default
# branch, blanket push forms (--all/--mirror/--tags), ambiguous unqualified pushes
# (bare `git push` / `git push <remote>` with no ref, `git push ... HEAD`), and ALL
# pushes when review.delivery=local_diff — mirroring the old .git/hooks/pre-push
# guard without ever touching the repo's own git config. Reads
# .autodev/deployment.json from the tool call's cwd; fails open (allows) only when
# autoDev isn't configured in this repo at all (no .autodev/deployment.json) — a
# PRESENT but malformed config fails CLOSED (denies) instead, since silently
# allowing a push because the guard couldn't read its own rules would defeat the
# guard's purpose. Only guards pushes made through Claude Code — a human's own
# terminal is never affected (there is no hook installed outside this plugin). Also
# fails open unless THIS session has actually run an autoDev command — see
# session-mark.sh; a human's own `git push` alongside a configured-but-unused autoDev
# is not this guard's business.
set -uo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL" == "Bash" ]] || exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
echo "$CMD" | grep -qE '(^|;|&&|\|)\s*git\s+push\b' || exit 0

SID=$(echo "$INPUT" | jq -r '.session_id // empty')
SAFE_SID=$(echo "$SID" | tr -cd 'A-Za-z0-9_-')
[[ -n "$SAFE_SID" && -f "${TMPDIR:-/tmp}/autodev-sessions/$SAFE_SID" ]] || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
CONFIG="$CWD/.autodev/deployment.json"
[[ -f "$CONFIG" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# A present-but-broken config must not silently fail the guard open.
jq empty "$CONFIG" 2>/dev/null || deny "autoDev: .autodev/deployment.json exists but is not valid JSON — fix it before pushing (the push guard can't safely evaluate review.delivery/default_branch)."

DEFAULT_BRANCH=$(jq -r '.repo.default_branch // "main"' "$CONFIG")
DELIVERY=$(jq -r '.review.delivery // "draft_pr"' "$CONFIG")

if [[ "$DELIVERY" == "local_diff" ]]; then
  deny "autoDev: review.delivery=local_diff (LOCAL-ONLY mode) — never push; present a local diff instead (reference/manual.md ▸ Delivery mode)."
fi

# Blanket push forms are never legitimate from the engine.
if echo "$CMD" | grep -qE '(^|;|&&|\|)\s*git\s+push\b.*(--all|--mirror|--tags)\b'; then
  deny "autoDev: only humans merge '${DEFAULT_BRANCH}' (Gate 2 + branch protection) — a blanket push (--all/--mirror/--tags) is never allowed from the engine."
fi

# Pushing HEAD, or a bare `git push`/`git push <remote>` with no ref at all, pushes
# whatever the current branch happens to be — ambiguous without resolving repo
# state, and the engine always names an explicit feature/story branch anyway.
if echo "$CMD" | grep -qE '(^|;|&&|\|)\s*git\s+push\b.*[[:space:]:]HEAD([[:space:]:]|$)'; then
  deny "autoDev: only humans merge '${DEFAULT_BRANCH}' (Gate 2 + branch protection) — pushing HEAD is ambiguous; push an explicit feature/story branch instead."
fi
# A bare `git push`, or one with only flags before the remote (e.g. `-u origin`,
# `--force-with-lease origin`), pushes whatever the current branch happens to be —
# ambiguous without resolving repo state. Tokenize rather than regex-match here:
# an arbitrary run of dash-flags before the remote defeats a fixed-shape regex.
PUSH_TAIL=$(echo "$CMD" | grep -oE '(^|;|&&|\|)[[:space:]]*git[[:space:]]+push[^;&|]*' | sed -E 's/^.*git[[:space:]]+push//')
if [[ -n "$PUSH_TAIL" || "$CMD" == *"git push"* ]]; then
  NONFLAG_COUNT=0
  for tok in $PUSH_TAIL; do
    case "$tok" in
      -*) ;;                          # a flag — skip (errs toward "ambiguous" if it's actually a flag's value, which is the safe direction)
      *) NONFLAG_COUNT=$((NONFLAG_COUNT + 1)) ;;
    esac
  done
  if [[ "$NONFLAG_COUNT" -le 1 ]]; then
    deny "autoDev: only humans merge '${DEFAULT_BRANCH}' (Gate 2 + branch protection) — a push with no explicit branch named is ambiguous; push an explicit feature/story branch instead."
  fi
fi

# Harmonized boundary (both alternatives use the SAME whitespace/colon/EOL
# boundary — a bare \b would treat "-"/"." as boundaries and false-match
# "main-feature"/"main.bak" against a default branch named "main"). The leading
# class also includes "+" so a force-push shorthand like "+main" is still
# recognized as naming the default branch.
if echo "$CMD" | grep -qE "(refs/heads/${DEFAULT_BRANCH}([[:space:]:]|\$)|[[:space:]:+]${DEFAULT_BRANCH}([[:space:]:]|\$))"; then
  deny "autoDev: only humans merge '${DEFAULT_BRANCH}' (Gate 2 + branch protection) — the engine never pushes it."
fi

exit 0
