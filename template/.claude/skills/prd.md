---
name: prd
description: >
  Turn a captured brief into an approved PRD for {{CLIENT_NAME}}. Use after
  intake — when the operator says "draft the PRD", "let's spec X", or "the brief
  is ready". Produces a PRD (BrainGrid Requirement, or agent-authored fallback)
  and stops at Gate 1 for the operator's approval. Interactive, human-in-the-loop.
---

# PRD — author the spec, stop at Gate 1

Read deployment config from `.autodev/deployment.json` (personas, tracker
states, BrainGrid project). Drive this with the **product-manager** persona
(`personas.stage_defaults.prd`).

## Spec tool — BrainGrid preferred, agent fallback

Check `braingrid.enabled`:
- **`true` (preferred):** author the PRD as a **BrainGrid Requirement** (step 2a).
- **`false`, or BrainGrid is unavailable** (usage limit / error): use the
  **agent fallback** (step 2b) — the **product-manager** persona authors the PRD
  and **project-manager-senior** reviews it for completeness. Same structure, same
  Gate 1; the PRD just lives in `specs/<feature-slug>/prd.md` + the Linear issue
  instead of BrainGrid. If BrainGrid is configured `true` but errors at runtime,
  **fall back automatically** and note it in the Gate-1 summary.

## Steps

1. **Read the brief** (`specs/<feature-slug>/brief.md`) + relevant code context.
   If the codebase is unfamiliar, use **codebase-onboarding-engineer** first to
   map the relevant area.

2a. **(BrainGrid) Author the Requirement via `/specify`** (or `/save-requirement`
   after a working discussion). The Requirement is the structured PRD: problem
   statement, **testable acceptance criteria**, implementation considerations,
   edge cases, non-goals.

2b. **(Fallback) Author the PRD with the personas.** The **product-manager**
   drafts the same structured PRD (problem · metrics · user stories · *testable*
   acceptance criteria · edge cases · non-goals), grounded in the code; then
   **project-manager-senior** reviews it for completeness and testability before
   Gate 1. Write it to `specs/<feature-slug>/prd.md`.

3. **Completeness check — ask, don't invent.** Validate the Requirement covers:
   problem · metrics · user stories · *testable* acceptance criteria · non-goals
   · risks. Where anything is missing or ambiguous, **ask the operator now, in
   conversation** — never fill a gap with a guess. Flag any unavoidable
   assumption explicitly so the operator confirms it at Gate 1.

4. **Persist.** Commit the PRD markdown to `specs/<feature-slug>/prd.md` (working
   branch, never the default). With BrainGrid, the Requirement is canonical (run
   `/build <REQ>`); in fallback mode, `prd.md` + the Linear issue are canonical.

5. **Move to Gate 1.** Set the Linear feature-request issue to `PRD Review (H)`,
   linked to the PRD. **Stop.** Tell the operator the PRD is ready and summarize it
   in plain English for their review. Do not run breakdown until the operator
   approves (moves it out of `PRD Review (H)`, or comments/says "approve").

## Guardrails

- Never create stories or branches here — that's `/breakdown`, after Gate 1.
- Gate 1 is a human decision; the engine never moves the issue past `PRD Review (H)`
  on its own.
