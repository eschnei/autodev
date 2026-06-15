---
name: breakdown
description: >
  Break an approved PRD into Shortcut stories for {{CLIENT_NAME}}. Use after
  Gate 1 — when the operator approves the PRD / moves the epic out of PRD Review.
  Runs BrainGrid /breakdown, then maps tasks to stories with persona routing,
  risk class, AI-QA steps, and manual test steps.
---

# Breakdown — Requirement → Shortcut stories

Read `.autodev/deployment.json` for: tracker states/labels, BrainGrid project,
`personas.dev_routing`, `review.granularity`. Drive this with the
**project-manager-senior** persona (`personas.stage_defaults.breakdown`).

## Steps

1. **BrainGrid breakdown.** Run `/breakdown <REQ>` → AI-ready tasks; `/build
   <REQ>` → the implementation plan. Both grounded in the codebase via Claude
   Code.

2. **Map each BrainGrid task → one Shortcut story** using the story template
   (`.claude/skills/_story-template.md` / the format in CLAUDE.md). Per story set:
   - **Acceptance criteria** (objective, testable — the contract).
   - **AI QA steps** + **manual test steps** (the latter is the human's script
     at acceptance).
   - **Tests required** note — the diff must include tests for the criteria.
   - **`blocked by` links** for dependencies (Shortcut story links).
   - **Touched files** — record what the task touches (feeds the lane
     file-overlap guard and the persona routing).
   - **`risk:` class** — `trivial` / `standard` / `sensitive`. Be deliberate:
     trivial = isolated, well-tested, low blast radius; sensitive = auth, data,
     money, migrations, security surface. This drives review depth now and
     auto-merge graduation later.
   - **`agent:` persona** — route from `personas.dev_routing` by the touched
     files (e.g. `server/` → backend-architect, `ui/` → frontend-developer,
     schema/migration → database-optimizer; else the `default`). This is the
     "best agent for the job" tag the devloop dispatches.

3. **Ask, don't invent.** If the PRD is too thin to write *testable* criteria or
   QA steps for a task, **stop and ask the operator live** rather than emitting a
   hollow story. A story that can't be given checkable criteria is not created.

4. **Sizing.** Prefer small, single-purpose stories so reviews/QA stay tractable
   (guideline, not a hard line-count gate).

5. **Create the feature branch** `{{FEATURE_PREFIX}}<feature-slug>` from
   `{{DEFAULT_BRANCH}}`. Apply `ai-eligible` to each story (this label — set ONLY
   here — is what makes a story eligible for the devloop; tickets typed directly
   into Shortcut never get it).

6. **Release to dev.** Move stories to `Ready for AI Dev`; set the epic to
   `In Development` **only if the one-feature lock is free** (no other epic is in
   development) — otherwise queue it by priority.

## Output

Tell the operator: N stories created, the dependency shape, the risk-class mix,
and which agents will build what. The devloop takes it from here.
