---
description: Capture new work (feature, bug, or brief) — the only way work enters autoDev.
---

If `.autodev/deployment.json` doesn't exist in this repo, run the setup steps in
`${CLAUDE_PLUGIN_ROOT}/commands/init.md` first, then continue below. If it exists but
fails to parse as JSON, **stop and tell the operator** — point at the exact parse
error and the file path; do not run init over it (that would silently overwrite
whatever they were mid-editing). Only a missing file triggers the automatic bootstrap.

If `repo.local_path` or any `runner.*` field is still inline in `.autodev/deployment.json`
(pre-split config — `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` flags this with a `!`), ask
the operator once whether to run `/autodev:init` to split them into
`.autodev/deployment.local.json` (gitignored) before continuing — proceed either way,
this never blocks intake.

Read `${CLAUDE_PLUGIN_ROOT}/reference/manual.md` — it's authoritative for the workflow
(not auto-loaded, so read it explicitly here). Also read `.autodev/conventions.md` if
present (auto-detected coding conventions) — generate it first via
`${CLAUDE_PLUGIN_ROOT}/scripts/detect-conventions.sh .` if it's missing.

Then follow `${CLAUDE_PLUGIN_ROOT}/reference/intake.md` step by step against whatever
the operator just told you: `$ARGUMENTS` if given inline, otherwise ask what they
want to add (a feature idea, a bug report, a brief, a finished PRD/spec, or a board
ticket to adopt).

This is a human-in-the-loop stage — stay conversational, ask rather than guess, and
stop where `reference/intake.md` says to stop (it hands off to `/autodev:loop` for
PRD drafting; it never proceeds past intake on its own).

For coding conventions (this may touch code, e.g. writing the brief to
`specs/<slug>/brief.md`), obey any team-authored `AGENTS.md` / `CLAUDE.md`
(authoritative) plus `.autodev/conventions.md`; never edit those team files
(non-negotiable 11 — the plugin's docs-guard hook enforces this independently).
