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
- **Honor `review.delivery`** (CLAUDE.md): in `local_diff`, never push / open a PR — keep
  everything local (a pre-push hook rejects pushes); in `draft_pr`, push feature/story
  branches + open draft PRs (never merge the default branch).
- If a story is genuinely blocked (ambiguous spec, missing human-only setup), move it to
  the Blocked column with the specific question and continue with other eligible work.
- If the repo needs its toolchain on PATH first, source it (e.g. `source .autodev/env.sh`)
  before running the configured build/test commands.
