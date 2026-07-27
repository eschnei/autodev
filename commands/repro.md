---
description: Reproduce a bug before anyone builds — "X is broken, can you reproduce it?" / "chase this bug down". Attempt-capped hunt; ships a verified ticket + failing repro test to the dev pipeline, or a documented can't-reproduce matrix. Never fixes the bug itself.
---

If `.autodev/deployment.json` doesn't exist in this repo, run the setup steps in
`${CLAUDE_PLUGIN_ROOT}/commands/init.md` first, then continue below. If it exists but
fails to parse as JSON, **stop and tell the operator** — point at the exact parse
error and the file path; do not run init over it (that would silently overwrite
whatever they were mid-editing). Only a missing file triggers the automatic bootstrap.

Read `${CLAUDE_PLUGIN_ROOT}/reference/manual.md` — it's authoritative for the workflow
(not auto-loaded, so read it explicitly here).

Then follow `${CLAUDE_PLUGIN_ROOT}/reference/repro.md` step by step against the bug
the operator just described: `$ARGUMENTS` if given inline (a description, or an
existing issue id to hunt), otherwise ask what's broken — a vague report is fine;
turning vague into reproducible is this command's whole job.

Scope guard: this command **reproduces**; it never fixes (the playbook's header
owns the deliverable contract). If the operator asks for the fix too, point them
at `/autodev:loop` — the handed-off ticket is already queued for it.

For coding conventions (the repro test is code), obey any team-authored
`AGENTS.md` / `CLAUDE.md` (authoritative) plus `.autodev/conventions.md`; never edit
those team files (non-negotiable 11 — the docs-guard hook enforces this independently).
