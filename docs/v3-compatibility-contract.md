# v3 compatibility contract

**Status:** Active — Milestone 0-B deliverable
**Baseline:** tag `v2.3.0` (the last release before the v3 re-architecture)
**Companions:** [`guarantees.md`](guarantees.md) (the operator-facing promises) · [`v3/decisions.md`](v3/decisions.md) (architecture decisions) · `reference/manual.md` (the engine's own manual)

This document is the line v3 cannot cross. It records every behavior the current
Claude-plugin engine exhibits that must survive the re-architecture, splits that
behavior into what is **mechanically protected** (an executable regression test
fails if it changes) and what is **protected by contract** (prose the executor
interprets today, so only a human or a golden scenario catches a regression), and
assigns each row a migration milestone and a future deterministic test owner.

It is not a promise to automate everything before Milestone 1. Behavior moves from
the contract column into the mechanical column progressively, as workflow ownership
moves from Claude prose into autoDev Core (Milestone 8 onward).

---

## 1. How protection works

| Kind | What it means | Where it lives |
|---|---|---|
| **Mechanical** | An executable test in `tests/` exercises the real script/hook against a synthetic repo and fails on regression. Hermetic: no Claude, no network, no reads of the developer's home directory. | `tests/run.sh` → `tests/smoke.sh` + `tests/suite/*.sh`, run by CI on every push |
| **Contract** | The behavior is defined in Markdown that Claude reads at runtime (`commands/*.md`, `reference/*.md`). No shell test can drive it. It is pinned here, verified by the golden scenarios in §4, and owned by a milestone that will make it deterministic. | This document + `reference/manual.md` |

Run the mechanical suite:

```bash
bash tests/run.sh            # everything
bash tests/run.sh guards     # one suite by name substring
```

---

## 2. Mechanical regression protection (M0-A)

What the suite covers today, by area. Counts are approximate and will drift; the
suite itself is the source of truth.

| Area | Suite | What is pinned |
|---|---|---|
| Config loader (`scripts/lib/config.mjs`, `config.sh`) | `smoke` | Project + local file precedence, global `~/.config/autodev/<client>/` fallback, `$AUTODEV_CONFIG` / `$AUTODEV_LOCAL_CONFIG` overrides, legacy-inline detection, token-file overrides |
| Config upgrade + split (`scripts/upgrade-config.sh`) | `smoke`, `doctor` | Defaults added under operator values, `_note` keys stripped, identity fields never copied, legacy split into `deployment.local.json` + `.gitignore`, global-file awareness, idempotency, invalid JSON fails |
| Local tracker (`scripts/tracker.mjs`) | `smoke`, `tracker` | Sequential ids, atomic writes, lookup rules (exact / case-insensitive / title substring / ambiguity), every mutation and its history + comment side effects, stage-key validation, list/board/html escaping, project registry, mirror queue ordering, `flush-mirror` coalescing and deferral with a stubbed Linear driver, dispatch by `tracker.kind`, unknown-kind failure |
| Linear / Shortcut adapters | `smoke`, `tracker` | Facade delegation, token-file resolution and error wording, stage-key parity between drivers, local-only commands refused for API drivers. Live API behavior is **not** covered (network). |
| Push guard (`hooks/guard-push.sh`) | `smoke`, `guards` | Default-branch denial in every spelling (bare, `HEAD:`, `+`, `refs/heads/`, `src:dst`), blanket forms (`--all/--tags/--mirror`), ambiguous pushes (no ref, flags-only), chained commands, prefix/suffix false-positive avoidance, custom default branch, `local_diff` denies everything, unconfigured fails open, malformed config fails closed |
| Docs guard (`hooks/guard-docs.sh`) | `smoke`, `guards` | `AGENTS.md` / `CLAUDE.md` / `.claude/CLAUDE.md` denied for Edit and Write in any directory, near-miss filenames allowed, non-edit tools ignored, applies even when autoDev is unconfigured |
| Session engagement (`hooks/session-signal.sh`) | `smoke`, `doctor` | concierge / signal / silent modes, unconfigured repo is silent, history detection, assistant name, manual + conventions embedding, garbage stdin |
| Identity pointer (`scripts/write-identity-pointer.sh`) | `smoke` | Written only into an empty slot or over our own artifact, never over a team file |
| Doctor (`scripts/doctor.sh`) | `smoke`, `doctor` | **Hermetic safety**: prod endpoints in env + `qa.hermetic` off → FAIL; on with no overrides → FAIL; on with overrides → warn. Missing config, `local_diff` relaxations, `repo.local_path` mismatch, tracker preconditions (Shortcut hierarchy, missing tokens), branch protection warn vs FAIL when the timer is wired, toolchain pin warning |
| Convention detection (`scripts/detect-conventions.sh`) | `smoke`, `conventions-docs` | Stack / package manager / type-generation / design-system / test-framework detection, warnings when absent, measured comment-density buckets, vendored-dir exclusion, read-only on the repo |
| Docs conflict scan (`scripts/check-docs.sh`) | `smoke`, `conventions-docs` | Each workflow-conflict pattern flags the matching non-negotiable, line numbers shown, always exit 0 |
| Vendored migration (`scripts/migrate-vendored.sh`, `install.sh`) | `smoke` | Engine artifacts removed by content marker, team files restored, state preserved, idempotent, new-style vendored layout, plugin/vendored mutual exclusion |
| Persona resolution (`scripts/ensure-personas.sh`) | `smoke` | Roster computed from config, bare + prefixed filename resolution, built-in fallback, `--check` never downloads, `auto_install=false` and non-boolean fail closed |
| Headless runner (`scripts/devloop-tick.sh`) | `smoke`, `runner` | Single-flight lock (live vs dead PID), heartbeat, allowlist built from this repo's config (configured commands, feature/story push prefixes, backup remote, `gh pr` subset, tracker-scoped `node`), **never** `gh pr merge` / bare `node` / bare `jq` / default-branch push, result logging, usage-limit → pause file + board notice, probe-while-paused, resume-in-same-tick |
| Watchdog + notify (`scripts/watchdog.sh`, `notify.sh`) | `runner` | Stale heartbeat → STALLED board issue, known pause is not a stall, expired pause resumes checks, hung-tick lock recovery gated on repo progress, notification wording + local log |
| Operator digest (`scripts/report.mjs`) | `smoke`, `report` | Cadence parsing and window gating, `--force`, marker, bucket counts from the local board (in-flight / queued / awaiting / blocked / done), rate-limit status, unsupported tracker fails loud, destination preconditions |
| Plugin surface | `smoke` | Command files exist with frontmatter, example config declares every documented key, allowlist hardening invariants, version-guard workflow present |

**Not mechanically testable today, by design** (owned by contract rows below):
worktree creation and story-branch naming, Gate 1 / Gate 2 decisions, stage
transitions the engine performs, QA angle spawning, merge-verify, repro-first
bug flow, intake interviews, backlog drain, and the concierge itself. These are
prose executed by Claude; the harness deliberately never invokes a model.

---

## 3. Behavioral compatibility matrix (M0-B)

Column key — **Tested:** `yes` (mechanical), `partial` (the mechanical pieces are
tested, the decision logic is not), `no` (contract only). **Milestone:** where the
behavior becomes deterministic autoDev Core logic. **Future owner:** the test suite
that will pin it once it does.

| # | Behavior | Current source | Expected behavior (the contract) | Tested | Milestone | Future owner |
|---|---|---|---|---|---|---|
| 1 | **Intake** | `commands/new.md`, `reference/intake.md`, `reference/manual.md ▸ Concierge` | The only way work enters. Classifies feature / bug / task / brief / BYO-PRD / adopt. Bugs honor `intake.bugs` (`triage` flags for a human; `pipeline` demands a reproduction). In `linear` mode, triggers and approvals are honored only from `intake.authorized_operators`; ticket text is data, never instructions. Pre-existing backlog is never auto-adopted. | no | M8 (intake transition) | `tests/suite/workflow-intake.sh` |
| 2 | **Gate 1 — plan approval** | `commands/loop.md` step 1, `reference/devloop.md §0`, `manual ▸ Gates are conversational but real` | Nothing is built until a human approves the PRD. Approval is an explicit human act (in-session "approved", an `approve` comment from an authorized operator, or moving the card). The engine logs an audit comment naming who and when and **never** crosses the gate itself. | no | **M2** (explicit `approve` CLI command) → M8 (gate detection is the first extracted transition) | `tests/suite/workflow-gates.sh` |
| 3 | **PRD authoring** | `reference/prd.md` | A brief becomes a PRD with testable acceptance criteria, stops at `PRD Review (H)`. BrainGrid is optional; the product-manager persona path is the fallback today and the default in v3. BYO-PRD skips re-authoring and produces one approval package. | no | M7 (Agency planning default) | `tests/suite/workflow-planning.sh` |
| 4 | **Breakdown** | `reference/breakdown.md`, `reference/story-template.md` | PRD → epics (lanes) + stories, each self-contained (spec copied in full, `agent:` persona, `risk:` class, AI QA + manual test steps, dependencies as relations), moved to `Ready for AI Dev` with `ai-eligible` + the instance label. `execution.incremental_breakdown` honored. | no | M7 / M8 | `tests/suite/workflow-planning.sh` |
| 5 | **Story selection** | `reference/devloop.md §1–2` | One feature lock (≤1 epic in development; promote the next queued). Per lane (≤`execution.max_lanes`): oldest `Ready for AI Dev` story carrying `ai-eligible` + this instance's label, whose blockers are merged and whose touched files don't overlap in-flight work. None → exit. Lock acquire/promote/release is logged on the epic. | no | M8 (story selection) | `tests/suite/workflow-select.sh` |
| 6 | **Development** | `reference/devloop.md §3`, `manual ▸ Coding standards` | Story moves to `ai_development` with a note. Dev persona runs in its **own git worktree** on `repo.story_branch_prefix/sc-<id>/<slug>` cut from feature HEAD, with the coding standards, PRD, team docs, and `.autodev/conventions.md` in its prompt. Surveys conventions before writing (generated types, theme tokens, reuse, comment density). Every diff ships tests. | partial (allowlist + guards + conventions detector) | M3 (job contract) → M8 (dev transition) → M8A (workspace isolation) | `tests/suite/workflow-dev.sh` |
| 7 | **Self-review + self-check** | `reference/devloop.md §4–5` | ×`execution.self_review_rounds` against criteria; `commands.test` + `commands.lint` green; tests-for-criteria present; comment-density pass; missing human-only setup → Blocked. Commit `[sc-<id>]`, deliver per delivery mode (draft PR URL attached on first open), move to `ai_qa` naming the review artifact. | no | M8 (verification) | `tests/suite/workflow-verify.sh` |
| 8 | **AI QA** | `reference/devloop.md §6`, `reference/deep-qa.md` | Hermetic env first. Three fresh, independent angles (conformance · adversarial · regression) + conditional visual angle; verdict by `reality-checker`. Code-level gates block (tests, tests-for-criteria, real defects, CI); live browser and visual are advisory. Fail → back to dev with the specific defects; **no fixed retry cap while progress is made**; stuck-detector (`execution.max_dev_qa_loops` no-progress passes) → Blocked with the question. Can't evaluate → Blocked immediately. | no | M8 (QA transition) | `tests/suite/workflow-qa.sh` |
| 9 | **Gate 2 — result review** | `reference/devloop.md §7`, `manual ▸ Delivery mode` | `per_story`: QA reports + manual script posted, `ready_for_human_review`; human approves → squash-merge to the feature branch → `done`. `per_feature` (+`auto_merge_to_feature_branch`): auto-merge in the same tick; the human gate moves to feature acceptance. Either way nothing reaches the default branch without a human. | no | M2 (explicit `approve`) → M8 (review transition) | `tests/suite/workflow-gates.sh` |
| 10 | **Merge verify** | `reference/merge-verify.md §1–3`, `devloop §7–8` | After any squash-merge: clean-room check (fresh checkout, clean install, full gates, live smoke); fail → auto-revert + reopen. At close-out: leanness review, whole-feature acceptance QA + report, feature PR or local diff, version bump for plugin repos, feature stats to `.autodev/metrics.jsonl`. After the human merges: post-deploy smoke → human prod sign-off. | partial (version-guard CI) | M8 (verification transition) → M12A (contamination guard added here) | `tests/suite/workflow-verify.sh` |
| 11 | **Blocked behavior** | `devloop §3–6`, `manual ▸ principle 4` | Back-half questions never interrupt: the story moves to `Blocked (H)` with the exact question and the engine continues other eligible work. Headless runs never wait for input. Blocked cards are the operator's inbox. | no | M8 | `tests/suite/workflow-select.sh` |
| 12 | **Ask, don't invent** | `manual ▸ principle 4`, `intake ▸ Guardrails`, `devloop §4` | Missing, ambiguous, or contradictory information is asked about (live in the front half, via Blocked in the back half). Never pick an interpretation and ship it. A genuinely ambiguous convention is a requirements gap, not a coin flip. | no | M8 (job result validation: a `blockers[]` result is a first-class outcome) | `tests/suite/workflow-verify.sh` |
| 13 | **Only humans merge the default branch** | `hooks/guard-push.sh`, `scripts/devloop-tick.sh` allowlist, `scripts/doctor.sh` branch-protection check, `manual ▸ principle 3` | The engine never pushes `repo.default_branch`, never force-pushes, never merges a PR. `local_diff` never pushes at all. Branch protection is the mechanical backstop and doctor fails when it is missing under the unattended timer. | **yes** | M3 (guards re-homed executor-independently — Codex has no PreToolUse hooks) | `tests/suite/guards.sh` (kept) + executor-adapter tests |
| 14 | **Repro-first bugs** | `reference/repro.md`, `devloop §3`, `intake ▸ bugs` | Under `intake.bugs: pipeline` a bug is built only after a failing reproduction test is committed red; QA verifies red → green; a never-red repro is a gating fail. `/autodev:repro` is attempt-capped (`qa.repro.max_attempts`) and hands off either a verified ticket + failing test or a documented can't-reproduce matrix. It never fixes. | no | M8 | `tests/suite/workflow-bugs.sh` |
| 15 | **Production / hermetic protections** | `scripts/doctor.sh` (B3), `devloop §6 ▸ Hermetic FIRST`, `repro §1`, `deep-qa §2` | `qa.hermetic.env` is exported before **any** test/build/app/live run. Prod endpoints present with hermetic off → doctor FAILS and the engine refuses to run (Blocked). Credentials never enter the board, prompts, or git. | **yes** (doctor) / no (runtime export) | M8 (job permissions carry the hermetic env) → M12A | `tests/suite/doctor.sh` (kept) + `workflow-qa.sh` |
| 16 | **Own lane on a shared board** | `manual ▸ principle 10`, `devloop` preamble | Every read and write is scoped to issues carrying `tracker.instance_label`. Foreign tickets do not exist to the engine unless the operator adopts them. First connect to a populated board asks once. | no | M4 (tracker core) → M8 | `tests/suite/tracker.sh` (label filtering) |
| 17 | **Every action leaves a board trail** | `manual ▸ principle 9`, `devloop §9` | Status = where; comments = what + why. A floor in every `execution.logging` mode. Moves carry `--note`. Errors are posted on the affected story, never swallowed. One metrics line per tick in `.autodev/metrics.jsonl`. | partial (tracker records history + notes) | M4 / M8 (Core emits events; M13 mirrors handoffs to Brain) | `tests/suite/tracker.sh` + event-log tests |
| 18 | **Team docs are read-only** | `hooks/guard-docs.sh`, `manual ▸ principle 11`, `scripts/check-docs.sh` | `AGENTS.md`, root `CLAUDE.md`, `.claude/CLAUDE.md` are never edited; convention changes go out as a separate `docs(conventions):` PR with rationale. Workflow conflicts in team docs are flagged at init and reconciled once in-session. | **yes** | M3 (guard re-homed) · M8A | `tests/suite/guards.sh` |
| 19 | **Delivery modes** | `manual ▸ Delivery mode`, `hooks/guard-push.sh` | `draft_pr`: push feature/story branches only, open draft PRs, humans merge on GitHub. `local_diff`: no push, no `gh`, review artifact is a local diff on the ticket; an explicit "approve and merge" may run the local merge. Backup is a fast-forward push of the feature branch under `draft_pr` only. | partial (guard + allowlist) | M4 (git core) → M8 | `tests/suite/guards.sh` + git-core tests |
| 20 | **Unattended operation** | `scripts/devloop-tick.sh`, `watchdog.sh`, `notify.sh`, `ops/launchd-timer.md` | Stateless ticks, single-flight lock, rate-limit pause with probe-based resume, dead-man watchdog with hung-tick recovery, board notifications for every state change. | **yes** | M3 (the tick's `claude -p` call becomes `ClaudeCodeExecutor.execute`) | `tests/suite/runner.sh` (kept) + executor tests |
| 21 | **Concierge + session modes** | `hooks/session-signal.sh`, `manual ▸ Concierge` | `concierge` injects identity + manual + conventions; `signal` one line; `silent` nothing; unconfigured repos are never hijacked. Status snapshot on open; plain-English intent routing per the table; ambient updates are never approval requests. | partial (hook modes) | M2 (the `autodev` CLI becomes the primary surface; the plugin remains a compatibility surface per PRD §54) | `tests/suite/cli.sh` |
| 22 | **Backlog drain** | `reference/backlog.md` | Off by default. Entry gate per batch; context-first mini-pipeline replaces Gate 1 for unscoped tickets; unfit tickets are commented and skipped; Gate 2 never waived; real work preempts; team priority order never re-ranked. | no | M8 (late) | `tests/suite/workflow-backlog.sh` |
| 23 | **Config compatibility** | `scripts/lib/config.*`, `scripts/upgrade-config.sh`, `reference/deployment.example.json` | Existing `.autodev/deployment.json` + `deployment.local.json` keep loading unchanged. Upgrades add defaults under operator values and never delete or reorder operator keys. | **yes** | M5 (one schema) · M5A (sidecar registry reads legacy config through a compatibility layer) | `smoke` (kept) + schema tests |
| 24 | **Plugin commands keep working** | `commands/*.md`, `hooks/hooks.json`, `.claude-plugin/plugin.json` | `/autodev:init`, `new`, `loop`, `qa`, `repro` continue to work until the CLI reaches parity (PRD §54). The vendored `install.sh` mode continues to work. | partial (files + hook wiring + vendored install) | Throughout; retired only by explicit decision after M16 | `smoke` (kept) |

---

## 4. Golden scenarios

Scenarios that must keep working end to end at every milestone. **G1–G5** are
fully mechanical today and run in CI. **G6–G8** require a Claude session and are
run by hand before any milestone is declared done; each names the exact
observation that proves it.

| # | Scenario | Proof | Status |
|---|---|---|---|
| G1 | **Hermetic doctor refuses production.** A repo whose `.env` names a forbidden endpoint with `qa.hermetic.enabled=false` fails doctor naming the endpoint; enabling hermetic with overrides passes with a warning; enabling it without overrides fails. | `tests/suite/doctor.sh ▸ hermetic safety` | mechanical |
| G2 | **The engine cannot push the default branch.** Every spelling of a default-branch push is denied, feature/story pushes are allowed, `local_diff` denies all pushes, and the headless allowlist never grants `gh pr merge`. | `tests/suite/guards.sh`, `tests/suite/runner.sh ▸ allowlist` | mechanical |
| G3 | **Unattended tick survives a usage limit.** A limited result pauses the runner and posts to the board; while paused only a probe runs; the first successful probe resumes and runs the full tick in the same pass; a stale heartbeat raises STALLED. | `tests/suite/runner.sh` | mechanical |
| G4 | **The local board is a faithful state machine.** Every move validates its stage, records history and the note as a comment, and the mirror queue replays to Linear coalesced and idempotently, deferring on failure. | `tests/suite/tracker.sh` | mechanical |
| G5 | **Existing deployments upgrade in place.** A pre-split, pre-schema config is upgraded with operator values intact, local fields split out and gitignored, and a vendored install migrates to the plugin with state and team files preserved. | `tests/smoke.sh ▸ config split`, `▸ vendored-install migration` | mechanical |
| G6 | **Local-board feature lifecycle, in-session.** Brief → PRD → "approved" (Gate 1 audit comment) → breakdown → a story built in its own worktree with tests → QA PASS → `Human Review (H)` → "ticket X works" (Gate 2) → squash-merge → merge-verify §1 → `done`. Every move carries a note; nothing was pushed to the default branch. | Board history of the story shows the full stage sequence with notes; `git log` shows the story worktree branch squash-merged into the feature branch | manual |
| G7 | **Linear-mode intake by comment.** With `tracker.kind=linear` + `intake.mode=linear`, a ticket created by an authorized operator is interviewed in comments and advanced by an `approve` comment; a ticket from an unauthorized author, or one pre-dating the deployment, is left alone. | Linear comment thread + status history; the foreign ticket has no engine comments | manual |
| G8 | **Repro-first bug.** Under `intake.bugs: pipeline`, a bug story gets a failing test committed before any fix, QA confirms red → green, and a bug the engine cannot reproduce ends in `Blocked (H)` with the attempted matrix rather than a guessed fix. | Commit order on the story branch; the Blocked note on the can't-reproduce case | manual |

The `autodev` CLI (M2) gains a golden scenario of its own the moment it exists:
**G9 — register a project in a clean shared repo, exit, `git status` is clean**
(decision D2).

---

## 5. Milestone 0 exit checklist

- [x] Existing deterministic tests are green (`tests/run.sh`, hermetic, 400+ checks).
- [x] Missing high-value mechanical tests added: guards, tracker, headless runner, watchdog/notify, digest, doctor safety, conventions, docs scan.
- [x] This contract exists with a behavior matrix and golden scenarios.
- [x] Every critical current behavior has an owner and a migration milestone (§3).
- [x] The current version is tagged and restorable (`v2.3.0`).
- [x] It is explicit what is protected mechanically (§2) vs by contract (§3).

Milestone 1 (standalone Brain repo) may begin.
