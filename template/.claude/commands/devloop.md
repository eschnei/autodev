---
description: One heartbeat pass of the autoDev dev engine (timer entry point).
---

Run exactly **one heartbeat pass** of the autoDev dev engine now, then stop.

Follow the **devloop skill** at `.claude/skills/devloop.md` step by step against the
current Linear + git state, honoring `.autodev/deployment.json` (review mode, delivery
mode, personas, qa.*, execution.*). Do one bounded unit of work — reconcile the board,
pick the next eligible story, dev → AI-QA → deliver per the delivery mode — write all
results back to Linear + git, then exit.

This is a **non-interactive headless run**:
- Use only pre-allowed tools; do not wait for human input mid-pass.
- **Never push / open a PR** — this deployment is local-only (`review.delivery: local_diff`);
  a pre-push hook will reject any push regardless.
- If a story is genuinely blocked (ambiguous spec, missing human-only setup), move it to
  the Blocked column with the specific question and continue with other eligible work.
- Source the toolchain before running build/test commands:
  `source .autodev/env.sh` (puts mix/elixir/pnpm/node on PATH).
