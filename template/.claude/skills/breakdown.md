---
name: breakdown
description: >
  Break an approved PRD into Linear stories for {{CLIENT_NAME}}. Use after
  Gate 1 — when the operator approves the PRD / moves the epic out of PRD Review.
  Runs BrainGrid /breakdown, then copies each task's FULL spec into a
  self-contained Linear issue (so the dev agent never reads BrainGrid), adding
  persona routing, risk class, AI-QA steps, and manual test steps.
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
   Gate 1, never before). Per `tracker.hierarchy`:
   - **The Project (feature):** in **`issue` mode**, *create* a Project to group the
     stories and link it to the feature issue + PRD. In **`project` mode**, the
     Project already exists (from intake) — set its project-status to `in_development`.
   - **Epic → a Milestone** in that Project. Group the BrainGrid tasks into a small
     number of coherent epics; one Milestone each (the parallel lanes the devloop runs).
   - **Story/task → an Issue** in the Project, assigned to its Milestone (next step).

3. **Transfer each task → a SELF-CONTAINED Linear Issue.** Copy the task's **full
   spec into the Linear issue body** so Linear is the single source of truth the dev
   agent works from — it must NEVER need to open BrainGrid to build the story.
   - **(BrainGrid)** Pull the complete content per task:
     `braingrid task list -r <REQ> --format json` (get the task ids), then
     `braingrid task show <id> --format markdown` → the full task spec (description,
     acceptance criteria, implementation/build plan, test plan, edge cases).
     **Write that entire markdown into the issue body**, e.g.
     `node scripts/autodev/linear.mjs create-issue --title "<task>"
     --desc "<full task markdown>" --stage ready_for_ai_dev --labels "ai-eligible,…"`,
     assigned to its epic's Milestone. Don't summarize or link-only — copy the data in.
   - **(Fallback)** project-manager-senior writes the same complete spec (criteria,
     plan, tests, edge cases) directly into the issue body.
   - Then ensure these engine fields are present on the issue (add any the BrainGrid
     content didn't already cover):
     - **Acceptance criteria** (objective, testable — the contract) · **AI QA steps**
       + **manual test steps** · **Tests required** note.
     - **`blocked by` links** for dependencies — set them explicitly with
       `node scripts/autodev/linear.mjs relate <blocker> <story> --type blocks`
       (don't rely on creation order).
     - **Touched files** — feeds the lane file-overlap guard + persona routing.
     - **`risk:` class** — `trivial` / `standard` / `sensitive` (isolated+well-tested
       → trivial; auth/data/money/migrations/security → sensitive). Drives review depth.
     - **`agent:` persona** — routed from `personas.dev_routing` by touched files.
   - **Traceability (one-way mirror):** footer the issue with the source
     `BrainGrid <REQ> / <task-id>`. Linear stays authoritative; BrainGrid is never
     read again downstream.

4. **Ask, don't invent.** If the PRD is too thin to write *testable* criteria or
   QA steps for a task, **stop and ask the operator live** rather than emitting a
   hollow story. A story that can't be given checkable criteria is not created.

5. **Sizing.** Prefer small, single-purpose stories so reviews/QA stay tractable
   (guideline, not a hard line-count gate).

6. **Create the feature branch** `{{FEATURE_PREFIX}}<feature-slug>` from
   `{{DEFAULT_BRANCH}}`. **Establish the WIP backup (if `backup.enabled` AND delivery
   is `draft_pr`):** push the just-created feature branch to `backup.remote` (default
   `origin`) — `git push <remote> {{FEATURE_PREFIX}}<feature-slug>` — so the branch
   exists remotely from the start and every later task push has somewhere to land.
   This is a backup, not a PR — open nothing. Under `local_diff` (or `backup.enabled`
   false) skip this — push nothing. Apply `ai-eligible` to each story (this label — set
   ONLY here — is what makes a story eligible for the devloop; tickets typed directly
   into Linear never get it).

7. **Release to dev.** Move each story to `Ready for AI Dev`. The feature is now
   "in flight" — the devloop's **one-feature lock** allows only one feature's
   epics to run at a time; if another feature is already in flight, this one waits
   its turn by priority (its stories sit in `Ready for AI Dev`).
   🗒️ **Log on the feature** (the git actions aren't visible on the board otherwise):
   `🌱 breakdown done — feature branch <name> created · <N> stories across <M>
   epics released to AI Dev` (+ `· backup pushed → <remote>` if it ran in step 6).

> **Incremental breakdown (B6 — if `execution.incremental_breakdown`):** for a big
> feature, don't decompose everything at Gate 1. Break down **one milestone/epic at
> a time on demand** — create the next milestone's stories when the prior milestone
> is in flight — so the queue stays fed without one huge upfront pass.

## Output

Tell the operator: N stories created, the dependency shape, the risk-class mix,
and which agents will build what. The devloop takes it from here.
