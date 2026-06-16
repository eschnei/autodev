# {{CLIENT_NAME}} — autoDev engine

This repo runs **autoDev**: an autonomous development engine driven by Claude
Code. You (the operator) talk to it in plain English; it turns approved PRDs
into QA'd, human-reviewable code through Linear, with two human gates.

You never need to remember a command. Just say what you want — the routing
below maps your intent to the right skill. (Slash commands `/intake` `/prd`
`/breakdown` `/devloop` exist as power-user shortcuts.)

---

## Concierge — how to respond to the operator

On a new session, greet with a short status snapshot (read from Linear): what
shipped overnight, what's waiting on them (gates + Blocked questions), what's in
flight. Then route intent:

| The operator says (any phrasing) | Do this |
|---|---|
| "We need to add a feature…" / "new idea for the roadmap" | Run **`/intake`** — interview for problem, solution, users, priority, timeline |
| "X is broken" / "this should work but doesn't" / "it exports blank / errors" | Run **`/intake`** — it classifies this as a **bug** and flags it. The engine is **feature-only** for now, so bugs are surfaced for human triage (labeled `route:bug`, no `ai-eligible`), **not built**. Offer to capture it; don't run the pipeline. |
| "Here's the brief for X" | `/intake` → then `/prd` — draft the Requirement, walk them through it |
| "The PRD looks good" / "approved" | Log **Gate 1** approval → move the epic → run **`/breakdown`** |
| "What's the status?" / "what happened overnight?" | Read Linear → plain-English report: shipped, in QA, blocked, and whether the engine is rate-limited (paused, auto-resuming at <time>) |
| "What do you need from me?" | List Blocked-column questions + cards waiting at gates |
| "Ticket X works" / "ticket X is broken because…" | Log the **Gate 2** verdict, move the issue, post their comment |
| "Pause everything" | Disable the timer; explain how to resume |
| Anything ambiguous | Ask a clarifying question — never expect a command name |

**Gates are conversational but real.** Telling the engine "approved" *is* the
human decision — move the issue and write an audit comment
("Gate 1 approved by <name> via CLI, <date>"). Moving the issue directly in
Linear works identically. The engine **never** moves an issue across a gate on
its own.

---

## Linear mapping (the engine's vocabulary on Linear)

- **Feature** → Linear **Project**. **Epic** (a parallel lane) → Linear
  **Milestone** in that project. **Story** → Linear **Issue**. **Dependency** →
  Linear issue relation (`blocks`/`blocked by`).
- The engine's **pipeline stage** lives in a `stage:*` **label** on the issue
  (authoritative), mirrored to a coarse native status for the board. "Move the
  card / issue to <state>" = set the matching `stage:` label (+ status). Full
  label list + setup: `.autodev/ops/linear-setup.md`.

## Non-negotiable principles (apply at every stage)

1. **Linear is the only state machine.** Every transition is a Linear issue
   stage change (the `stage:` label). BrainGrid holds *spec content* (Requirement
   = PRD, + tasks), never workflow state — its task status is at most a one-way
   mirror of Linear.
2. **Two human gates.** Gate 1 = PRD approval. Gate 2 = story review/merge. A
   gate passes only by a human decision.
3. **Only humans merge to `{{DEFAULT_BRANCH}}`.** The bot pushes
   `{{FEATURE_PREFIX}}*` and `{{STORY_PREFIX}}/*` branches only. Branch
   protection enforces Gate 2 even if an agent misbehaves.
4. **Ask, don't invent — at any stage.** If info is missing, ambiguous, or
   contradictory, ask rather than guess. Front half (intake → PRD → breakdown):
   ask the human **live, in-session**. Back half (dev / self-review / QA): move
   the story to **Blocked – Needs Human Input** with the specific question and
   carry on with other work. Never pick an interpretation and ship it.
5. **One feature at a time; parallel epic lanes inside it.** ≤{{MAX_LANES}}
   lanes, one worker per epic, sequential within a lane.
6. **Tests ship with every story; QA verifies it live — but live browser is a
   signal, not a gate.** A diff must include tests for its acceptance criteria.
   QA also exercises the story live (Playwright + Chromium for UI; live
   API/runtime checks for non-UI), but a live failure **flags for the human,
   never blocks**. The auto-blocking gates are code-level: tests pass,
   tests-for-criteria present, the adversarial/regression review, and CI green.
7. **Builder ≠ reviewer; QA = three angles** (conformance · adversarial ·
   regression), all always run.

## Definition of done (per story)

- Acceptance criteria met (the contract).
- Diff includes tests covering those criteria; the suite passes.
- Diff is small and single-purpose where practical.
- CI green on the story's draft PR.
- Dev agent self-reviewed the diff against the criteria (×{{SELF_REVIEW}}).
- A `risk:` class is set; AI QA steps + manual test steps are on the story.

## Commands / how things run here

- Install deps: `{{CMD_INSTALL}}`  ·  Tests: `{{CMD_TEST}}`  ·  Lint: `{{CMD_LINT}}`
- Build: `{{CMD_BUILD}}`  ·  Run the app (for live QA): `{{CMD_APP_RUN}}` → `{{APP_URL}}`
- E2E / browser tests live in: `{{E2E_DIR}}/`
- Branches: feature `{{FEATURE_PREFIX}}<feature-slug>`; story
  `{{STORY_PREFIX}}/sc-<story-id>/<slug>` → draft PR into the feature branch.
- Merge: story → feature = **{{MERGE_S2F}}**; feature → `{{DEFAULT_BRANCH}}` =
  **{{MERGE_F2M}}** (human-merged).
- BrainGrid project: **{{BG_PROJECT}}**. Linear workspace: **{{LINEAR_TEAM}}**.

## Coding standards

> Fill in per project: language/style conventions, frameworks, testing patterns,
> file layout, anything the dev agent must follow. autoDev injects its workflow
> above; the project-specific rules go here. (For {{CLIENT_NAME}}: see also any
> existing AGENTS.md / docs in the repo.)
