---
description: Deep-dive exploratory QA on one ticket that's ready to test — takes a ticket id, spins the app up hermetically, walks every path with screenshots, and posts an evidence-backed, independently verified report that feeds Gate 2. Use when the operator says "QA this deeply", "test ticket X thoroughly before I review", or "run through the flows on X".
---

If `.autodev/deployment.json` doesn't exist in this repo, run the setup steps in
`${CLAUDE_PLUGIN_ROOT}/commands/init.md` first, then continue below. If it exists but
fails to parse as JSON, **stop and tell the operator** — point at the exact parse
error and the file path; do not run init over it (that would silently overwrite
whatever they were mid-editing). Only a missing file triggers the automatic bootstrap.

**First, read the operating manual** at `${CLAUDE_PLUGIN_ROOT}/reference/manual.md` —
it is authoritative for the workflow (not auto-loaded, so read it explicitly here).

This command takes **one ticket id**: `$ARGUMENTS` if given inline, otherwise ask the
operator which ticket to dive on. Read the ticket, its PRD/criteria, and any attached
wireframes via `node "${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs" show <issue>` /
`list-comments <issue>`, then follow
`${CLAUDE_PLUGIN_ROOT}/reference/deep-qa.md` step by step.

The playbook's two boundaries — the report **feeds Gate 2, never passes one**, and
**hermetic first** — are absolute; this command never overrides them.
