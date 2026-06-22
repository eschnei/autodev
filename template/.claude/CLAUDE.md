# {{CLIENT_NAME}} — autoDev engine

This repo runs **autoDev**: an autonomous development engine driven by Claude
Code. You (the operator) talk to it in plain English; it turns approved PRDs
into QA'd, human-reviewable code through Linear, with two human gates.

You never need to remember a command. Just say what you want — the routing
below maps your intent to the right skill. (Slash commands `/intake` `/prd`
`/breakdown` `/devloop` exist as power-user shortcuts.)

---

## Concierge — how to respond to the operator

**Input stack:** BrainGrid (spec) + Linear (tracking + state) by default.
**Interface depends on `intake.mode`:** in `cli` the operator drives intake here,
in a session (below); in `linear` the operator drives everything from Linear —
they create a ticket, the engine interviews + drafts the PRD in **comments**, and
gates pass by an **`approve`** comment (the heartbeat handles it, see
`/devloop` §0). In `linear` mode this concierge is just for status questions.

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

- **Epic** (parallel lane) → Linear **Milestone**. **Story/task** → Linear
  **Issue**. **Dependency** → Linear issue relation (`blocks`/`blocked by`).
- **Pipeline stage = the issue's real STATUS** (a board column). Move it with the
  helper: `node scripts/autodev/linear.mjs move <issue> <stage_key>`. Full column
  set + setup: `.autodev/ops/linear-setup.md`.

### Hierarchy mode — `tracker.hierarchy` (toggle, like braingrid)
How a **feature** is represented. The default needs zero extra setup.
- **`issue` (default):** the feature rides a **feature ISSUE** through the gate
  columns (New Request → Clarifying (H) → PRD Review (H) → … → Done); a **Project
  + Milestones** group its stories. No org-level changes; gates are issue-status moves.
- **`project` (opt-in):** the feature **IS a Linear Project**, and its gates are
  **org-level project statuses** (`tracker.project_statuses`), moved with
  `linear.mjs set-project-status <projectId> <key>`. Cleaner Projects view, but the
  custom statuses are workspace-wide — use only in a workspace dedicated to this.
- **Tasks flow the issue board the same way in both modes.** The skills below are
  written for `issue` mode; in `project` mode, read "move the feature to <gate>"
  as a project-status move instead of an issue move.

### Delivery mode — `review.delivery` (toggle) — HOW work reaches a human
Governs whether the engine touches GitHub. **This is authoritative; every "push" /
"PR" step in the skills means the delivery-mode action below.**
- **`local_diff` (LOCAL-ONLY):** NO `git push`, NO `gh`/PRs — ever. All branches,
  commits, and merges stay **local**. Wherever a skill says "open/update a draft PR"
  or "push the branch," instead **keep the branch local and present a LOCAL DIFF**:
  put `git diff <base>...<branch>` (and `git log --stat`) on the Linear issue as the
  review artifact, with the branch name + the exact local command to view it. Gate 2
  = a human reviews that local diff and replies `approve`. "Merge to
  `{{DEFAULT_BRANCH}}`" becomes "present the assembled **local** feature branch diff;
  a human merges locally if they choose." CI parity is replaced by the **local**
  gates (tests/lint/build) since there's no remote CI. Enforced hard by
  `.git/hooks/pre-push` — a push attempt is a bug, not a step.
- **`draft_pr` (REMOTE, default):** the bot pushes `{{FEATURE_PREFIX}}*` /
  `{{STORY_PREFIX}}/*` and opens GitHub **draft PRs**; Gate 2 reviews the PR; humans
  merge to `{{DEFAULT_BRANCH}}` via GitHub (branch protection enforces it). Requires
  bot git identity + branch protection.

## Non-negotiable principles (apply at every stage)

1. **Linear is the only state machine.** Every transition is a Linear **status**
   move. BrainGrid holds *spec content* (Requirement = PRD + tasks) — and at
   `/breakdown` that content is **copied in full into the Linear issue** so each
   issue is **self-contained** (the dev agent never reads BrainGrid). BrainGrid is
   never read downstream; its status is at most a one-way mirror of Linear.
2. **Two human gates.** Gate 1 = PRD approval. Gate 2 = story review/merge. A
   gate passes only by a human decision.
3. **Only humans merge to `{{DEFAULT_BRANCH}}`** (and per the **Delivery mode**
   above, in `local_diff` the engine never touches GitHub at all — local branches +
   local diffs only). In `draft_pr` the bot pushes `{{FEATURE_PREFIX}}*` and
   `{{STORY_PREFIX}}/*` branches only and branch protection enforces Gate 2 even if
   an agent misbehaves.
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
8. **Hermetic always (SAFETY).** Every test/build/app/live run applies
   `qa.hermetic.env` so external calls hit local/sandbox or are blanked. The engine
   **never** drives tests or the live app against PRODUCTION services/creds. If prod
   endpoints are present and `qa.hermetic` is off, **stop** (`blocked`) — never run.

## Definition of done (per story)

- Acceptance criteria met (the contract).
- Diff includes tests covering those criteria; the suite passes.
- Diff is small and single-purpose where practical.
- Gates green per **Delivery mode**: `draft_pr` → CI green on the draft PR;
  `local_diff` → the local gates (tests · lint · build) green (no remote CI).
- Dev agent self-reviewed the diff against the criteria (×{{SELF_REVIEW}}).
- A `risk:` class is set; AI QA steps + manual test steps are on the story.

## Commands / how things run here

- Install deps: `{{CMD_INSTALL}}`  ·  Tests: `{{CMD_TEST}}`  ·  Lint: `{{CMD_LINT}}`
- Build: `{{CMD_BUILD}}`  ·  Run the app (for live QA): `{{CMD_APP_RUN}}` → `{{APP_URL}}`
- E2E / browser tests live in: `{{E2E_DIR}}/`
- Branches: feature `{{FEATURE_PREFIX}}<feature-slug>`; story
  `{{STORY_PREFIX}}/sc-<story-id>/<slug>`. Delivery to the feature branch follows
  **Delivery mode**: `draft_pr` → draft PR; `local_diff` → local diff, local merge.
- Merge: story → feature = **{{MERGE_S2F}}**; feature → `{{DEFAULT_BRANCH}}` =
  **{{MERGE_F2M}}** (human-merged).
- BrainGrid project: **{{BG_PROJECT}}**. Linear workspace: **{{LINEAR_TEAM}}**.
- **Linear ops — always use the helper, never hand-rolled curl:**
  `node scripts/autodev/linear.mjs <move|comment|create-issue|create-project|create-milestone|state-id|whoami|doctor> …`
  (robust retry/backoff; resolves stage keys + identifiers from `.autodev/deployment.json`).
- **Preflight before a run:** `scripts/autodev/doctor.sh` — validates tools, token, and
  config status ids against live Linear. Fix any ✗ before proceeding.

## Coding standards

> Fill in per project: language/style conventions, frameworks, testing patterns,
> file layout, anything the dev agent must follow. autoDev injects its workflow
> above; the project-specific rules go here. (For {{CLIENT_NAME}}: see also any
> existing AGENTS.md / docs in the repo.)
