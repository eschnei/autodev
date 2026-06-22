# autoDev — Backlog

Gaps + improvements, sourced largely from the **HavenConnect 20-hour autonomous
run** (the first real long build). Part A is shipped; Part B/C are planned, ranked.

---

## Part A — Shipped (engine-wide) ✅

Fixes hit + folded in during the run; they benefit every client.

| # | Fix | Why it mattered |
|---|-----|-----------------|
| A1 | **`/devloop` slash command** (`commands/devloop.md`) | The heartbeat `claude -p "/devloop"` returned "Unknown command" and silently no-op'd every tick. Skills ≠ slash commands. |
| A2 | **install.sh `&`-escape fix** | `&&` in a command config rendered as `{{CMD}}{{CMD}}`, breaking the permission allowlist. |
| A3 | **`review.delivery: local_diff \| draft_pr`** | The "no GitHub, local-only" mode — there was no way to run without pushing/PRs. |
| A4 | **`qa.seed_test` + persistent `.test_db_seeded` marker** | Without it the suite false-failed (~24 tests); naive per-session seeding corrupts the DB across stateless ticks. |
| A5 | **`qa._known_baseline`** | QA judges a layer against documented pre-existing failures instead of zero. |
| A6 | **`qa.docker_up` = data-services-only** | The app container clashed with the locally-run server/UI. |
| A7 | **`execution.logging` glass-box comments** | Per-tick Linear status/progress comments. |

---

## Part B — Planned (ranked)

### B1 · Feature-level acceptance QA stage — **HIGH** — ✅ SHIPPED
Per-story 3-angle QA + per-merge clean-room verify exist, but there's no final
**integrated, whole-branch** pass. In the run this caught cross-suite flakiness and
let the operator verify the system live "as a whole."
→ Extend `merge-verify` §2 (or a new acceptance skill) to run the **integrated
suites** across the assembled branch + a **live system smoke**, gated behind
`qa.acceptance.{integrated_suites, live_system}`.

### B2 · Code-quality / leanness review stage — **HIGH** — ✅ SHIPPED
The engine QAs for correctness, not bloat. A dedicated pass found a duplicated
security predicate, copy-paste components, stale comments (−98 lines, no behavior
change). → Optional **`quality_review`** stage at feature close-out (a
code-reviewer/simplify pass over the feature diff), config-toggled.

### B3 · Hermetic-env safety guard — **HIGH / SAFETY** 🔴
The biggest gap. `.env` pointed at **prod** Elastic Cloud + live Twilio/Mailgun/
Postgrid, and `:test` loaded it (HAV-40). Had to detect + build a hermetic override
by hand. → `doctor` flags prod-looking endpoints; a **`qa.hermetic`** mode overrides
external endpoints (local ES, blanked comms) for any QA/live run. **The engine must
never drive the live app against prod creds.**

### B4 · `reporting.cadence` progress-report toggle — **HIGH** (operator ask) — ✅ SHIPPED
Native periodic operator **digest** (`off | hourly | <N>m`), distinct from the
per-tick glass-box comments — a rollup of elapsed, merged/in-flight/blocked since
last, pace/ETA, wall status, anything awaiting a human → a destination
(notification / Slack / feature-issue comment). Replaces manual self-scheduled
check-ins. *(Small, self-contained.)*

### B5 · `linear.mjs` helper gaps — **MEDIUM** (quick win) — ✅ SHIPPED
Repeatedly fell back to raw GraphQL because the helper can't:
- **`update-issue`** — update an issue description/fields.
- **`relate` / `link`** — set `blocked-by` relations (dependency-gating leaned on creation order).
- **`show` / `list-comments`** — read status + comments.
Adding these makes the helper self-sufficient (no raw-GraphQL fallback).

### B6 · Heartbeat operability — **MEDIUM** — ✅ SHIPPED
- **Hung-tick detection** in the watchdog (no new commit/jsonl + lock age → recover / clear stale lock). "Long-but-productive vs hung" was judged by hand.
- **Status-reconcile timing** — in `per_feature`, the merge happened but Linear status lagged at AI-Dev/QA until the next reconcile (glass-box drift). Move → `done` in the merging tick.
- **Incremental breakdown** — engine breaks down the whole feature at Gate 1; per-milestone, on-demand breakdown keeps the queue fed without one huge upfront pass. Config option.

### B7 · Toolchain/env preflight — **LOW** — ✅ SHIPPED
`doctor` should validate the executable toolchain (asdf versions resolve, deps
installed) and flag loose `.tool-versions` pins (the `elixir 1.17` partial that
didn't resolve). Mostly deployment-env, not engine.

### B8 · Per-feature stats record — **MEDIUM** — ✅ SHIPPED
At feature close-out, emit a **stats record** for every feature the engine ships, so
there's a portfolio track record over time. Capture: **name**, started/shipped
**dates**, **elapsed wall time**, # epics/stories, **lines** added/removed + files
changed, **dev↔QA loop rounds**, QA verdicts (pass counts / what was caught), and
(optional) ticks/tokens spent.
→ Write **two ways**: a human-readable summary **comment on the feature** (Linear
issue / Project), and a machine-readable append to **`.autodev/metrics.jsonl`** so
they roll up across features (engine throughput, avg cycle time, $ saved vs. human
hours — sales-ready numbers). Config: `reporting.feature_stats` (on/off + destination).

---

## Part C — Visual fidelity gaps — C1 ✅ · C2 mechanism wired · C3 removed (client-specific)

| # | Gap | Fix |
|---|-----|-----|
| C1 | Intake/PRD **summarizes** wireframes as text, losing visual fidelity. | **Attach (or link) the wireframe images on the feature ticket** so they're preserved + reviewable. |
| C2 | Manual-QA step has no visual check against the design. | **Visual diff** of the built UI against those wireframes at the manual-QA step. |
| C3 | ~~ES mapping seed gap~~ — **REMOVED as client-specific.** Elasticsearch is HavenConnect's stack, not generic. | Generalized into **`qa.seed_test`**: it seeds *all* the app's test datastores (DB + any search index/queue/cache) — whatever the client configures. No ES-specific field in the engine. |

---

## Suggested order
B3 ✅ → B5 ✅ → B4 ✅ → B8 ✅ → B1 ✅ → B2 ✅ → B6 ✅ → C1 ✅ → C2 (mechanism; needs a wireframe to exercise) → ~~C3~~ removed (client-specific) → B7 ✅
**— backlog shipped; engine kept client-agnostic.**
