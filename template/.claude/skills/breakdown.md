---
name: breakdown
description: >
  Break an approved PRD into Linear stories for {{CLIENT_NAME}}. Use after
  Gate 1 — when the operator approves the PRD / moves the epic out of PRD Review.
  Runs BrainGrid /breakdown, then maps tasks to stories with persona routing,
  risk class, AI-QA steps, and manual test steps.
---

# Breakdown — Requirement → Linear stories

Read `.autodev/deployment.json` for: tracker states/labels, BrainGrid project,
`personas.dev_routing`, `review.granularity`. Drive this with the
**project-manager-senior** persona (`personas.stage_defaults.breakdown`).

## Steps

1. **Decompose the PRD into tasks** (BrainGrid preferred, agent fallback — mirror
   `braingrid.enabled` / availability from `/prd`):
   - **(BrainGrid)** Run `/breakdown <REQ>` → AI-ready tasks; `/build <REQ>` → the
     implementation plan. Both grounded in the codebase via Claude Code.
   - **(Fallback)** **project-manager-senior** decomposes the PRD into the same
     AI-ready tasks directly, grounded in the codebase — coherent epics, small
     single-purpose tasks, explicit dependencies.

2. **Build the Linear hierarchy** (this is where the feature fans out — *after*
   Gate 1, never before). Per the mapping:
   - **Feature → a Linear Project.** Create the Project for this feature; link the
     approved PRD (BrainGrid Requirement) + the original feature-request issue to it.
   - **Epic → a Milestone** in that Project. Group the BrainGrid tasks into a small
     number of coherent epics and create one Milestone each (these are the parallel
     lanes the devloop runs).
   - **Story/task → an Issue** in the Project, assigned to its Milestone (next step).

3. **Map each BrainGrid task → one Linear story (Issue)** using the story template
   (`.claude/skills/_story-template.md` / the format in CLAUDE.md), assigned to its
   epic's Milestone. Per story set:
   - **Acceptance criteria** (objective, testable — the contract).
   - **AI QA steps** + **manual test steps** (the latter is the human's script
     at acceptance).
   - **Tests required** note — the diff must include tests for the criteria.
   - **`blocked by` links** for dependencies (Linear story links).
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

4. **Ask, don't invent.** If the PRD is too thin to write *testable* criteria or
   QA steps for a task, **stop and ask the operator live** rather than emitting a
   hollow story. A story that can't be given checkable criteria is not created.

5. **Sizing.** Prefer small, single-purpose stories so reviews/QA stay tractable
   (guideline, not a hard line-count gate).

6. **Create the feature branch** `{{FEATURE_PREFIX}}<feature-slug>` from
   `{{DEFAULT_BRANCH}}`. Apply `ai-eligible` to each story (this label — set ONLY
   here — is what makes a story eligible for the devloop; tickets typed directly
   into Linear never get it).

7. **Release to dev.** Move each story to `Ready for AI Dev`. The feature is now
   "in flight" — the devloop's **one-feature lock** allows only one feature's
   epics to run at a time; if another feature is already in flight, this one waits
   its turn by priority (its stories sit in `Ready for AI Dev`).

## Output

Tell the operator: N stories created, the dependency shape, the risk-class mix,
and which agents will build what. The devloop takes it from here.
