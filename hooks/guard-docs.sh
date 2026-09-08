#!/usr/bin/env bash
# autoDev — docs guard (PreToolUse hook). AGENTS.md / CLAUDE.md / .claude/CLAUDE.md are
# the team's authority on coding conventions; autoDev reads them and never edits them
# (reference/manual.md non-negotiable 11). Replaces the old settings.json `deny` rule
# now that autoDev ships no settings.json at all.
#
# Scope (v2.3.1): the rule binds autoDev, not every repository on the machine. It
# applies when the edit happens inside an autoDev project (a .autodev/deployment.json
# above the file or the tool's cwd) or inside an autoDev job (AUTODEV_CONFIG /
# AUTODEV_BOARD_DIR in the environment — v3 sidecar projects carry no .autodev/).
# A human working in an unrelated repo is never blocked.
set -uo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL" == "Edit" || "$TOOL" == "Write" ]] || exit 0
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -n "$FILE_PATH" ]] || exit 0
echo "$FILE_PATH" | grep -qE '(^|/)(AGENTS|CLAUDE)\.md$' || exit 0

in_autodev_project() {
  [[ -n "${AUTODEV_CONFIG:-}" || -n "${AUTODEV_BOARD_DIR:-}" ]] && return 0
  local cwd start dir
  cwd=$(echo "$INPUT" | jq -r '.cwd // empty'); [[ -n "$cwd" ]] || cwd=$PWD
  if [[ "$FILE_PATH" == /* ]]; then start=$(dirname "$FILE_PATH"); else start="$cwd/$(dirname "$FILE_PATH")"; fi
  dir=$start
  while [[ -n "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    [[ -f "$dir/.autodev/deployment.json" ]] && return 0
    dir=$(dirname "$dir")
  done
  return 1
}
in_autodev_project || exit 0

jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "autoDev never edits AGENTS.md/CLAUDE.md in a project it operates (reference/manual.md non-negotiable 11) — propose a convention change as a separate PR with a Rationale section instead."}}'
exit 0
