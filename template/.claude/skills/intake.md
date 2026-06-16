---
name: intake
description: >
  The front door for new work on {{CLIENT_NAME}}. Use whenever the operator wants
  to add a feature, fix, or idea to the roadmap — e.g. "we need to add X", "new
  idea for the roadmap", "here's a brief for Y". Routes the request, interviews
  for anything missing, and creates the Linear epic. This is the ONLY way work
  enters the engine.
---

# Intake — the only entry point

New work enters here and nowhere else. A ticket typed directly into Linear is
**inert** (it never gets the `ai-eligible` label, so the devloop ignores it).
That is deliberate: it's the prompt-injection defense and the guarantee that
everything the engine builds has passed through a human at intake.

## Steps

1. **Route the request.** Classify as:
   - `route:feature` — a new capability (v1 default; full pipeline).
   - `route:task` / `route:bug` — *post-v1*; if asked, tell the operator these
     thin paths aren't built yet and offer to capture it as a feature for now.

2. **Interview for a complete brief — ask, don't invent.** A good brief needs:
   - **Problem** — what's wrong / missing, and for whom.
   - **Solution** — the rough shape of the fix.
   - **User stories** — who does what, and why.
   - **Priority** and **timeline**.
   - **Success criteria** and **non-goals**.

   If the operator's input already covers these, don't re-ask — confirm and move
   on. Where something is missing or ambiguous, **ask a specific question now**,
   in conversation. Never fill a gap with a guess. (A vague brief becomes vague
   acceptance criteria becomes a story QA can't actually check — the quality
   ceiling is set right here.)

3. **Write the brief** to `specs/<feature-slug>/brief.md` in the repo and commit
   it (on a working branch, not `{{DEFAULT_BRANCH}}`).

4. **Create the Linear epic** in the `Draft` state (workspace
   `{{LINEAR_TEAM}}`), titled from the feature, linked to the brief. Apply the
   `route:feature` label.

5. **Hand off.** Tell the operator the brief is captured and offer to draft the
   PRD next (the `/prd` skill turns this into a BrainGrid Requirement for their
   Gate 1 approval). Do not proceed past intake without the operator.

## Guardrails

- Stay conversational — this is a human-in-the-loop stage; never expect command
  names from the operator.
- Do not create stories, branches, or BrainGrid tasks here — intake only
  produces the brief + the Draft epic. Stories come at `/breakdown`, after the
  PRD is approved at Gate 1.
- Confidentiality: keep this client's context separate; never reference other
  clients' work.
