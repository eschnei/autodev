---
name: prd
description: >
  Turn a captured brief into an approved PRD for {{CLIENT_NAME}}. Use after
  intake — when the operator says "draft the PRD", "let's spec X", or "the brief
  is ready". Produces a BrainGrid Requirement and stops at Gate 1 for the
  operator's approval. Interactive, human-in-the-loop.
---

# PRD — author the spec, stop at Gate 1

Read deployment config from `.autodev/deployment.json` (personas, tracker
states, BrainGrid project). Drive this with the **product-manager** persona
(`personas.stage_defaults.prd`).

## Steps

1. **Read the brief** (`specs/<feature-slug>/brief.md`) + relevant code context.
   If the codebase is unfamiliar, use **codebase-onboarding-engineer** first to
   map the relevant area.

2. **Author the Requirement via BrainGrid `/specify`** (or `/save-requirement`
   after a working discussion). The Requirement is the structured PRD: problem
   statement, **testable acceptance criteria**, implementation considerations,
   edge cases, non-goals.

3. **Completeness check — ask, don't invent.** Validate the Requirement covers:
   problem · metrics · user stories · *testable* acceptance criteria · non-goals
   · risks. Where anything is missing or ambiguous, **ask the operator now, in
   conversation** — never fill a gap with a guess. Flag any unavoidable
   assumption explicitly so the operator confirms it at Gate 1.

4. **Persist.** The Requirement is the canonical PRD (hosted in BrainGrid). Run
   `/build <REQ>` and commit its markdown to `specs/<feature-slug>/prd.md` for
   versioning (on a working branch, never the default branch).

5. **Move to Gate 1.** Set the Linear epic to `PRD Review`, linked to the
   Requirement. **Stop.** Tell the operator the PRD is ready and summarize it in
   plain English for their review. Do not run breakdown until the operator
   approves (moves the epic out of PRD Review, or says "approved").

## Guardrails

- Never create stories or branches here — that's `/breakdown`, after Gate 1.
- Gate 1 is a human decision; the engine never moves the epic past PRD Review
  on its own.
