#!/usr/bin/env bash
#
# autoDev — SessionStart hook. Loads the engine manual EVERY session so autoDev drives,
# without colonising the team's CLAUDE.md. The manual lives at .claude/autodev.md (NOT
# .claude/CLAUDE.md), so it does not auto-load as memory — this hook injects it (plus the
# auto-detected conventions) into context, and points the agent at the team's own
# AGENTS.md / CLAUDE.md as the read-only authority on coding conventions.
#
# Output contract: print JSON on stdout, exit 0. Claude Code reads
# hookSpecificOutput.additionalContext and adds it to context.
# (jq is an autoDev hard dependency — used to JSON-encode safely.)
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-.}"
MANUAL="$DIR/.claude/autodev.md"
CONV="$DIR/.autodev/conventions.md"

read -r -d '' HEADER <<'EOF' || true
⚙️ This repository is operated by **autoDev** (deployment: {{CLIENT_NAME}}). Two scopes,
and they do not overlap:
- **WORKFLOW / PROCESS → governed by the autoDev manual below** (`.claude/autodev.md`).
  You are the operator concierge — route every unit of work through Linear + the two human
  gates; only humans merge the default branch; don't freelance or "just fix it".
- **HOW CODE IS WRITTEN → governed by the team's own `AGENTS.md` / `CLAUDE.md`** if the repo
  has them. **Read and OBEY them; on conventions their files win — and NEVER edit, overwrite,
  or "update" them.** Propose any convention change in a separate PR with rationale.

Unsure of state? `node scripts/autodev/linear.mjs doctor`, then read the board. The full
manual and the auto-detected conventions follow; also read any AGENTS.md / CLAUDE.md present.
EOF

CTX="$HEADER"$'\n\n'"===== BEGIN .claude/autodev.md — operating manual (authoritative for WORKFLOW) ====="$'\n'
if [ -f "$MANUAL" ]; then CTX="$CTX$(cat "$MANUAL")"$'\n'; else CTX="$CTX(manual not found at $MANUAL)"$'\n'; fi
CTX="$CTX===== END manual ====="$'\n'

if [ -f "$CONV" ]; then
  CTX="$CTX"$'\n'"===== BEGIN .autodev/conventions.md — auto-detected, BINDING where the team's files are silent ====="$'\n'"$(cat "$CONV")"$'\n'"===== END conventions ====="$'\n'
fi

jq -n --arg c "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
