#!/usr/bin/env bash
# autoDev — SessionStart engagement, per .autodev/deployment.json `session_mode`:
#   concierge (default) — full identity: the operator talks to the assistant BY NAME and
#                          it drives the workflow; injects the header + manual + conventions.
#   signal              — one line naming the commands; nothing else ambient.
#   silent              — nothing.
# Unconfigured repos (no deployment.json) always get nothing — a dual-use repo where
# autoDev merely happens to be installed must not be hijacked.
set -uo pipefail

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
CONFIG="$CWD/.autodev/deployment.json"
[[ -f "$CONFIG" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

MODE=$(jq -r '.session_mode // "concierge"' "$CONFIG")
[[ "$MODE" == "silent" ]] && exit 0

CLIENT=$(jq -r '.client_name // "this deployment"' "$CONFIG")
NAME=$(jq -r '.assistant_name // "Marj"' "$CONFIG")
KIND=$(jq -r '.tracker.kind // "linear"' "$CONFIG")

# autoDev HISTORY detection: a pre-plugin vendored install and/or a config that
# predates the current schema means this repo should be updated before real work.
HIST=""
{ [[ -e "$CWD/.claude/autodev.md" || -d "$CWD/scripts/autodev" || -d "$CWD/.autodev/engine" ]]; } && HIST="artifacts"
if [[ "$(jq -r 'has("session_mode")' "$CONFIG")" == "false" ]]; then HIST="${HIST:+$HIST+}schema"; fi
COUNT_TXT=""
if [[ "$KIND" == "local" ]]; then
  N=$(find "$CWD/.autodev/board" -maxdepth 1 -name '*.json' ! -name '_*' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  COUNT_TXT=" — ${N:-0} stories on the board"
fi

HIST_TXT=""
if [[ -n "$HIST" ]]; then
  HIST_TXT=" ⚠ autoDev HISTORY detected ($HIST): this repo has a pre-plugin install and/or an
older config schema. UPDATE FIRST, before any other work: run
\`bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/migrate-vendored.sh\" .\` then
\`bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/upgrade-config.sh\" .\` — both idempotent, state
and operator settings preserved. Then report what was already in flight (feature/*
branches, board stories and their stages) so the operator knows exactly where the
deployment stands — history continues, it doesn't restart. Have the operator review +
commit the changes."
fi

if [[ "$MODE" == "signal" ]]; then
  MSG="⚙️ autoDev is configured here (${CLIENT}${COUNT_TXT}). Run \`/autodev:loop\` to continue, \`/autodev:new\` to add work — or \`/autodev:qa\` / \`/autodev:repro\` for a deep QA dive or a bug hunt.${HIST_TXT}"
  jq -n --arg c "$MSG" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
  exit 0
fi

# concierge — the full engine identity, every session
MANUAL="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/reference/manual.md"
CONV="$CWD/.autodev/conventions.md"
CTX="⚙️ This repository is operated by **autoDev** (deployment: ${CLIENT}${COUNT_TXT}). **You are
${NAME}**, its operator concierge — introduce yourself and sign off by that name. Greet with a
short status snapshot, route the operator's plain-English intent per the manual's concierge
table, and narrate build milestones ambiently (updates are FYI, never approval requests).
The commands (/autodev:new · /autodev:loop · /autodev:qa · /autodev:repro) exist as
power-user shortcuts — the operator never needs to remember them. WORKFLOW is governed by the manual below; HOW CODE IS WRITTEN
is governed by the team's AGENTS.md/CLAUDE.md (read-only) + the conventions below.
(To make sessions quieter, set session_mode: \"signal\" or \"silent\" in .autodev/deployment.json.)
${HIST_TXT}
"
CTX="$CTX"$'\n'"===== BEGIN reference/manual.md — operating manual (authoritative for WORKFLOW) ====="$'\n'
if [[ -f "$MANUAL" ]]; then CTX="$CTX$(cat "$MANUAL")"$'\n'; else CTX="$CTX(manual not found at $MANUAL)"$'\n'; fi
CTX="$CTX===== END manual ====="$'\n'
if [[ -f "$CONV" ]]; then
  CTX="$CTX"$'\n'"===== BEGIN .autodev/conventions.md — BINDING where the team's files are silent ====="$'\n'"$(cat "$CONV")"$'\n'"===== END conventions ====="$'\n'
fi

jq -n --arg c "$CTX" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
