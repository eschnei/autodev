# Brief — autoQA & autoPR: new engine roles

**Status:** reviewed — **v1 scope is autoQA only**; autoPR is designed below but
**deferred to a later round** · **Author:** Eric + assistant session, 2026-07-10
**Feeds:** `/autodev:new` (brief → PRD path, `reference/prd.md`)

## Problem

Two throughput bottlenecks sit at the edges of the current pipeline:

1. **QA depth is bounded.** The heartbeat's AI QA (§6 `devloop.md`) is one bounded
   pass per story; live-browser evidence is advisory. There is no way to say "take
   this ticket and go *deep*" — exploratory, unbounded, evidence-heavy QA on demand.
   Bug reproduction has the same seam: `intake.bugs: pipeline` reproduces inside the
   dev stage, and an un-reproducible bug just lands in `Blocked` after burning a dev
   cycle.
2. **Gate 2 is the queue.** Teams running autoDev report the engine produces QA'd
   PRs faster than humans review them. PRs rot: fall behind main, conflict, CI goes
   stale, review comments sit unanswered. The review *loop* itself needs an operator.

## What we're building

Two new **roles of the same engine** — not forks, not separate plugins
(**decided**). Same `tracker.mjs` facade, same hermetic-QA infra (`qa.hermetic`,
non-negotiable 8), same personas pool, new commands + `reference/*` playbooks (the
same pattern as `loop` → `devloop.md`). **The board is the hand-off bus:** roles
exchange work by creating/moving tickets carrying the target instance's
`tracker.instance_label` (principle 10) — no new IPC.

**Invocation — slash AND natural language (decided), one code path:** every
capability is a slash command, and plain English routes **to** that command —
never a parallel implementation. Two existing mechanisms carry this:

- **Frontmatter descriptions** (Claude Code model-invocation): the new commands'
  `description:` is written with trigger phrasings in mind ("QA this deeply",
  "reproduce this bug") so the model can invoke `/autodev:qa` / `/autodev:repro`
  from an operator's plain sentence — same command file either way, and the
  invocation is a visible, auditable tool call. `disable-model-invocation` stays
  unset, matching `new`/`loop`/`init`.
- **Concierge table** (`manual.md`): new rows route in-session phrasing —
  "test ticket X thoroughly" → deep-dive; "X is broken, can you reproduce it?" →
  repro (and how that interacts with `intake.bugs` routing).

This preserves "nothing runs from plain conversation alone" in spirit: work still
starts only via a command — the operator's sentence is another way of pressing
the same button.

**Discoverability ships with the commands (README update is in-scope, not a
follow-up):** the README's install/commands sections and the `/autodev:init`
onboarding summary both present `/autodev:qa` and `/autodev:repro` alongside
`new`/`loop` — including a line that plain English works ("or just ask: 'can you
reproduce this bug?'"). A command nobody knows about didn't ship.

### autoQA — two modes

**Mode 1 · Deep-dive QA** (`/autodev:qa <ticket>`) — human-invoked, unbounded
exploratory QA on a ticket that's ready to test.

1. Read ticket + PRD criteria + wireframes → derive an explicit **test plan**
   (ideal paths, edge paths, viewport/browser matrix) and **post it to the ticket
   first** — the plan is reviewable, and it becomes the contract the final review
   audits against.
2. Hermetic env up → walk each path with Playwright, screenshotting every step;
   capture console errors, network failures, a11y snapshots.
3. Emit a **structured report** on the ticket: per-path verdicts with evidence,
   deviations from criteria, plus an off-script "things I noticed" section — the
   exploratory tail the bounded loop can't afford.
4. Report **feeds Gate 2, never replaces it** — the goal is a 3-minute human
   review, not zero human review.

**Mode 2 · Bug reproduction** (`/autodev:repro`) — front-load reproduction into its
own pipeline, before a dev cycle is spent.

1. Bug dropped in (vague is fine — that's the point).
2. Repro hunt loop: parse → hypothesize steps → drive the app, screenshot →
   reproduced? If not, **vary the hypothesis** (data, user state, viewport,
   timing/race, browser) and retry — **attempt-capped: `qa.repro.max_attempts`
   (default 7, operator-tunable; 5–10 is the intended range), with a wall-clock
   ceiling as backstop. On exhaustion, STOP** — no heroics, no "one more idea";
   go straight to the can't-reproduce deliverable (step 4).
3. **On success:** author the complete ticket — numbered repro steps, environment,
   expected-vs-actual screenshots, suspected code area (grep / `git bisect` when a
   known-good ref exists), severity — **and commit the failing repro test to a
   branch.** Handoff = label the ticket for the dev instance, status
   `Ready for AI Dev`. The dev stage's repro-test-first step receives its red test
   pre-written.
4. **On failure:** post the **attempted matrix** ("tried these N variations, saw
   this") back to the human — a documented can't-reproduce is still a deliverable,
   and no dev cycle was burned.

**Final review (both modes)** — `qa.deep_dive.final_review` (default on). Once the
report is generated, a **fresh agent that did not run the session** (persona:
`reality-checker`) audits it adversarially before it posts:

- **Claim-to-evidence:** every verdict must trace to an artifact; unsupported
  claims are struck or bounced.
- **Coverage:** diff the report against the posted test plan — silently dropped
  paths are the failure this catches.
- **Verdict soundness:** findings must support the overall verdict (three ⚠️s
  concluding PASS gets challenged; a ✓ contradicted by its own screenshot too).
- **Spot re-execution:** re-drive the 1–2 highest-risk claims and compare — the
  teeth that make this verification, not an LLM agreeing with an LLM.
- For repro mode: the reviewer re-runs the repro **from the ticket text alone,
  cold.** If the written steps don't reproduce for a fresh reader, the handoff
  would have failed downstream — caught here instead.
- Outcome: **countersign** ("QA by X, verified by Y" on the ticket) or **bounce
  with specifics**; bounces are budget-bounded so two agents can't loop politely
  forever.

### autoPR — PR queue steward (`/autodev:pr`, or as loop work) — **DEFERRED**

> **Not in v1.** Parked by decision (2026-07-10) to focus this round on autoQA.
> The design below is kept so the thinking isn't lost; open questions 4–5 stay
> open with it.

**A toggle, shipped OFF** — `autopr.enabled: false` by default, same pattern as
the backlog drain (`backlog` — toggle, OFF). Nothing about this role runs, triages,
comments, or merges until a deployment explicitly opts in; enabling it is the
consent step, surfaced during `/autodev:init` but never defaulted on.
**Enabling triggers a guided risk-map setup (decided):** flipping the toggle
drafts the risk map from the detected stack (migrations dir, auth paths, payment
SDKs) and **does not proceed until a human confirms it** — no confirmed map, no
autoPR.

PRs are usually autoDev-born (already story-QA'd); autoPR operates at the altitude
story QA can't see, and pulls the review loop that currently waits on humans.

**Triage (gate 1 of the role):** a risk classifier over the diff routes each PR:
auto-track vs human-required. Inputs: paths touched vs an explicit **risk map**
(config in `deployment.json`: path globs → tiers; auth/payments/migrations/infra
always human), diff size, coverage delta, tests-changed-with-code, schema changes.
Config-only in v1 — a triage decision the operator can't read violates the spirit
of principle 9.

**Review loop:** reuse the three QA angles (conformance / adversarial / regression
— they review a diff from artifacts and don't care who authored it) at the
**integrated-diff** level: the PR against everything merged since, cross-PR
interactions, drift vs main. Findings route through the **existing** QA-fail
transition: post findings + `move <issue> ai_development` — the dev loop fixes and
re-delivers, autoPR re-reviews. The return path already exists; this adds an entry
point. Non-autoDev PRs (a teammate's branch) enter via the adopt flow (principle
10): adoption labels them and gives them a ticket, then the same loop applies —
**never force-push a human's branch**; fixes land as fixup commits with consent
(opt-in PR label) or bounce back as a proper story.

**Shepherding:** keep the queue mergeable between reviews — rebase when behind,
resolve trivial conflicts, re-run flaky CI, draft responses to human review
comments. Likely the half teams actually feel day-to-day.

**Merge ceiling:** autoPR may merge autonomously **to a staging branch only**;
`repo.default_branch` stays human-only (non-negotiable 3 holds). Requires a scoped
push-guard carve-out for the staging ref — a small, contained hook change.

## Policy change — named explicitly

autoPR makes **Gate 2 risk-tiered instead of universal**: low-risk PRs that pass
the review loop flow to staging autonomously; high-risk ones stop for a human.
This modifies non-negotiable 2 for teams that opt in, so it is **double-gated in
config**: `autopr.enabled: true` (the role runs at all — ships OFF) and
`review.gate2.mode: human | risk_tiered` (whether it may merge; `human` keeps
autoPR review-and-shepherd only, every merge still a human). Never emergent
behavior. The staging ceiling keeps a human between everything and production.

**Closed-loop risk & the sampling gate:** autoDev building + autoPR merging means
AI-authored code can reach staging with no human in the path. Mitigations: the
audit trail (every verdict is a reasoned comment, principle 9), the stuck-detector
(N dev↔review rounds → escalate to human), and a **sampling gate** — every Nth
auto-merged PR is flagged for retroactive human review. Sampling turns "do we
trust autoPR?" into a measurable ramp: start at 100% (identical to today), dial
down as retroactive reviews come back clean.

## Sequencing

1. **autoQA repro mode** — highest leverage, smallest new surface (intake + existing
   QA tooling recomposed); immediately improves the existing bug pipeline.
2. **autoQA deep-dive** — largely promotes `merge-verify.md` §2 + the visual angle
   to an on-demand command; final-review pattern ships here.
3. Onboarding + README updates land **with** 1–2, not after.
4. ~~autoPR~~ — **deferred to a later round** (see the autoPR section); resumes
   with the risk-map enable flow, gate-2 mode, and push-guard change as its
   entry criteria.

## Out of scope (v1)

- Learned/adaptive risk maps (config-only first; sampling data informs v2).
- autoPR merging to `repo.default_branch` under any setting.
- Cross-repo autoQA (one repo per deployment, as today).
- Video capture in deep-dive reports (screenshots + console/network logs only).

## Decisions (2026-07-10 review)

1. **Packaging — DECIDED:** new commands inside the one plugin; README command
   list and `/autodev:init` onboarding updated so operators discover them.
   **Invocation is both slash and natural language** — plain English routes to
   the same command via frontmatter descriptions + concierge-table rows; never a
   second code path.
2. **Repro budget — DECIDED:** attempt-capped, `qa.repro.max_attempts` default 7
   (tunable, 5–10 intended range) + wall-clock backstop. On exhaustion **stop** —
   post the attempted matrix, no extension.
3. **Risk map (autoPR) — DIRECTION SET, work deferred:** creating the risk map is
   part of the enable flow — flipping `autopr.enabled` drafts it from the detected
   stack and requires human confirmation before the role activates.

## Open questions (deferred with autoPR)

4. **autoPR emphasis:** review verdicts vs. queue stewardship — pending signal
   from teams on which pain leads ("nobody reviews my PRs" vs. "PRs go stale").
5. **Staging model:** one long-lived staging branch vs. per-feature preview —
   interacts with existing `preview.enabled`.
