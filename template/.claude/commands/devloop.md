---
description: One heartbeat pass of the autoDev dev engine (timer entry point).
---

Run exactly **one heartbeat pass** of the autoDev dev engine now, then stop.

**First, read the operating manual `.claude/autodev.md`** — it is authoritative for the
workflow (it is NOT auto-loaded as memory, so read it explicitly here). Then follow the
**devloop skill** at `.claude/skills/devloop.md` step by step against the current Linear +
git state, honoring `.autodev/deployment.json` (review mode, delivery mode, personas, qa.*,
execution.*). Do one bounded unit of work — reconcile the board, pick the next eligible
story, dev → AI-QA → deliver per the delivery mode — write all results back to Linear + git,
then exit. For coding conventions, obey any team-authored `AGENTS.md` / `CLAUDE.md`
(authoritative) plus `.autodev/conventions.md`; never edit those team files.

This is a **non-interactive headless run**:
- Use only pre-allowed tools; do not wait for human input mid-pass.
- **Honor `review.delivery`** (autodev.md): in `local_diff`, never push / open a PR — keep
  everything local (a pre-push hook rejects pushes); in `draft_pr`, push feature/story
  branches + open draft PRs (never merge the default branch).
- If a story is genuinely blocked (ambiguous spec, missing human-only setup), move it to
  the Blocked column with the specific question and continue with other eligible work.
- If the repo needs its toolchain on PATH first, source it (e.g. `source .autodev/env.sh`)
  before running the configured build/test commands.
