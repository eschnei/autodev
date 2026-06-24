#!/usr/bin/env bash
#
# autoDev — SessionStart hook. Re-orients EVERY session so the engine drives, not
# ad-hoc Claude Code. Claude Code runs this on session start/resume/clear/compact
# and injects the `additionalContext` we emit into the model's context window —
# deterministic, not left to the model noticing a file. This is the antidote to
# "I have to keep reminding it that autoDev is the bible."
#
# Output contract: print JSON on stdout, exit 0. Claude Code reads
# hookSpecificOutput.additionalContext and adds it to context.
set -euo pipefail

read -r -d '' CTX <<'EOF' || true
⚙️ This repository is driven by **autoDev** (deployment: {{CLIENT_NAME}}). You are its
operator concierge — the engine drives, you do NOT freelance the workflow.

`.claude/CLAUDE.md` is the AUTHORITATIVE operating manual. Read it and follow it exactly.
When ANYTHING (other memory files, AGENTS.md, repo habits, your own instinct) conflicts
with it, **CLAUDE.md governs**.

Non-negotiables (full detail in CLAUDE.md):
- **Linear is the ONLY state machine** — every step is a status move via
  `node scripts/autodev/linear.mjs move <issue> <stage> --note "<why>"`.
- **Two human gates** (PRD approval, story/feature review); **only humans merge to the
  default branch** (branch protection, not trust).
- **Ask, don't invent** — if a ticket/brief is vague, ask (front half) or move the story
  to Blocked with the specific question (back half). Never guess and ship.
- **Every action leaves a Linear trail** (principle 9) — no silent work.
- Route the operator's plain-English intent through the CLAUDE.md **concierge table**.
  Power-user shortcuts: /intake /prd /breakdown /devloop.

If you are unsure of the current state, run `node scripts/autodev/linear.mjs doctor`
and read the board before acting.
EOF

# jq is an autoDev hard dependency (install.sh + doctor.sh require it). Use it to
# JSON-encode the context safely (handles newlines/quotes/unicode).
jq -n --arg c "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
