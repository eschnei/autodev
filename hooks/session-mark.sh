#!/usr/bin/env bash
# autoDev — session marker (UserPromptSubmit hook, fires on every prompt — this event
# has no matcher). When the prompt IS an autoDev slash command, stamps a per-session
# marker file so guard-push.sh / guard-docs.sh can tell whether THIS session actually
# engaged autoDev, not just that the repo happens to have it configured — a human
# doing ordinary git/docs work alongside a configured-but-unused autoDev must not trip
# either guard. Keyed by session_id, which Claude Code holds stable across every hook
# invocation in one session (SessionStart, UserPromptSubmit, PreToolUse, ...).
set -uo pipefail

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
SID=$(echo "$INPUT" | jq -r '.session_id // empty')
[[ -n "$SID" ]] || exit 0
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

echo "$PROMPT" | grep -qE '^[[:space:]]*/autodev:' || exit 0

SAFE_SID=$(echo "$SID" | tr -cd 'A-Za-z0-9_-')
[[ -n "$SAFE_SID" ]] || exit 0
MARKDIR="${TMPDIR:-/tmp}/autodev-sessions"
mkdir -p "$MARKDIR" 2>/dev/null && touch "$MARKDIR/$SAFE_SID" 2>/dev/null
exit 0
