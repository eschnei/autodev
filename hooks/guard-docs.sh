#!/usr/bin/env bash
# autoDev — docs guard (PreToolUse hook). AGENTS.md / CLAUDE.md / .claude/CLAUDE.md are
# the team's authority on coding conventions; autoDev reads them and never edits them
# (reference/manual.md non-negotiable 11). Replaces the old settings.json `deny` rule
# now that autoDev ships no settings.json at all. Not a per-deployment toggle, but it
# IS scoped to the session: only active once THIS session has actually run an autoDev
# command (see session-mark.sh) — a human editing these files through Claude Code
# without ever invoking autoDev is not this guard's business.
set -uo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL" == "Edit" || "$TOOL" == "Write" ]] || exit 0
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -n "$FILE_PATH" ]] || exit 0

SID=$(echo "$INPUT" | jq -r '.session_id // empty')
SAFE_SID=$(echo "$SID" | tr -cd 'A-Za-z0-9_-')
[[ -n "$SAFE_SID" && -f "${TMPDIR:-/tmp}/autodev-sessions/$SAFE_SID" ]] || exit 0

if echo "$FILE_PATH" | grep -qE '(^|/)(AGENTS|CLAUDE)\.md$'; then
  jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "autoDev never edits AGENTS.md/CLAUDE.md (reference/manual.md non-negotiable 11) — propose a convention change as a separate PR with a Rationale section instead."}}'
  exit 0
fi
exit 0
