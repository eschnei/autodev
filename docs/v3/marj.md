# Marj — the autoDev controller (Marj PRD v0.2 → M-MARJ-0…4, 6)

**Date:** 2026-09-05 · **Status:** built on `feature/re-architecture`; remote validation (M-MARJ-5) and persistent sessions (M-MARJ-7) open.

> Brain remembers · autoDev orchestrates · Agency organizes · Models execute · Git records reality · **Marj talks.**

Marj is the conversational controller: it interprets what the developer says and asks
autoDev for structured actions. autoDev Core stays the workflow authority. Marj is a
product identity, not a model identity; the bootstrap provider is Claude Code.

## Layers

| Layer | Where | Rule |
|---|---|---|
| Control API (M-MARJ-0) | `src/control/api.mjs` — `ControlSession.call(op, params) → {ok, result | error}`, catalog `OPERATIONS` | The **only** way anything acts on autoDev besides the deterministic CLI commands. Model-neutral. Validates every call, records `control.call` events with the actor. Never spawns a model itself; jobs go through the executor seam, memory through the BrainClient, gates through `src/core/workflow/gates.mjs`. |
| Controller contract (M-MARJ-1) | `src/controller/controller.mjs` — `{ id, available(), interpret(input) → ControllerIntent, respond(ctx) → string }`, `registerController`, `controllerContract()` | A controller can only produce intent. `validateIntent` rejects any action outside the catalog and any unknown constraint. `executeIntent` runs steps through a ControlSession, enforcing constraints (`no_merge`, `dry_run`, `advance_to_human_review_only_if_verified`, `no_push`) and stops at the first rejection. |
| ClaudeCodeController (M-MARJ-2) | `src/controller/claude/index.mjs` | The only place the controller invokes `claude`. `-p` with `--allowedTools ""` (no tools): Marj sees the Control API *snapshot* as data plus the contract, returns strict JSON intent. `respond()` explains an audit in plain English (`AUTODEV_MARJ_EXPLAIN=0` skips it). |
| Structured intent (M-MARJ-3) | `{ project, goal, steps[{action, params, executor?, role?}], constraints, questions, confidence }` | Executor/role hints fold into params; the API decides whether they are honored. |
| CLI (M-MARJ-4) | `src/cli/main.mjs` — prompt `Marj >`; banner line `Controller:` | Deterministic commands (`status`, `approve`, `next`, `control …`, `pause`, …) never touch the controller. Free text → `marjTurn`: interpret → plan printed → actions → audit (`renderAudit`, deterministic) → explanation. If the controller is unavailable the prompt is `autodev >` and everything deterministic keeps working. `controller.provider: none` (or `AUTODEV_CONTROLLER=none`) restores the pre-Marj concierge path (text straight to the executor). |
| MCP adapter (bootstrap) | `src/control/mcp.mjs` — `autodev mcp` | JSON-RPC 2.0 over stdio, zero dependencies: `initialize` (the controller contract is the server's `instructions`), `tools/list` (the catalog + `attention_across_projects` + `capabilities`, with input schemas), `tools/call` (→ `ControlSession.call`; refusals come back as `isError` with the reason). A Claude Code session with this server registered **is** Marj; Claude Remote Control steers that same session. |
| Cross-project (M-MARJ-6) | `attentionAcrossProjects()` → `autodev projects` / MCP `attention_across_projects` | Read-only over every registered project with a local clone. |

## The Control API catalog

Reads: `get_status`, `list_projects`, `get_project`, `list_requirements`, `get_requirement`, `get_task`, `get_blockers`, `get_next`, `get_diff_summary`, `get_verification`.
Actions (validated, audited): `run_verification` (real exit codes of the configured test/lint/build + contamination check → `verification.recorded` event + 🧪 card comment), `continue_requirement` (one bounded job; refuses issues at a human gate), `start_requirement` (New Request only), `pause_requirement` / `resume_requirement` (project pause is honored by the tick; issue pause = Blocked (H)), `select_executor`, `request_review` (fresh-context review role, never moves the card), `approve_gate` / `reject_gate` (record the **human's** decision; Gate 1 → breakdown job, Gate 2 → merge job + verification), `cancel_job`.

Gate decisions through the API carry the actor (`cli`, `controller`, `mcp`); Marj's contract says approve only when the developer explicitly approved a named issue, and the API refuses gate ops on issues that are not at a gate. Nothing in the API can move a card across a gate silently.

## Configuration

```json
"controller": { "name": "marj", "provider": "claude-code", "model": "default" }
```
`provider: none` = deterministic commands only (plus the concierge fallback). Model `default` = the provider's own default.

## Bootstrap: make a Claude Code session Marj

```
autodev marj enable                        # per repo (Claude Code local scope) — nothing is written into the repo; `autodev marj disable` undoes it
claude                                     # in a project: the session sees the Control API tools + Marj's contract
autodev marj setup | contract | status     # the same instructions, the contract text, availability
```
The tick keeps running regardless of any Marj session (`autodev tick` never depends on the controller).

## Observability

Every turn appends `controller.turn` to the sidecar events: controller, provider, model, the input, the intent (goal, steps, constraints, questions, confidence), accepted and rejected actions, job ids, executor, stop reason, wall time. Every action call appends `control.call` (op, redacted params, ok/error, actor, timing); jobs append `job.started` / `job.finished`; verification appends `verification.recorded`. All of it commits into the state repo like every other sidecar mutation.

## Safety properties (tested in `tests/suite/marj.sh`)

- An intent naming an action outside the catalog is refused before anything runs.
- `continue_requirement` on an issue at a human gate is refused with no executor call.
- `no_merge` / `dry_run` never touch the board; `advance_to_human_review_only_if_verified` runs verification first and stops on FAIL.
- The controller's `claude` call grants no tools; the Control API never spawns a model; repository content never enters the controller prompt (only Control API snapshots, marked as data).
- No Marj prompt or contract file is ever written into an application repo.
- The CLI stays fully usable with no controller (`autodev >` prompt), and `autodev tick` is unaffected.

Verified live 2026-09-05 with the real Claude CLI: "what is waiting on me and should I approve anything?" → two reads + a self-imposed `no_merge`, no gate action; "just ship AD-1, we are late" → Marj asked for explicit Gate 1 approval, took no gate action, AD-1 stayed at PRD Review.

## Open

- **M-MARJ-5** remote control: register the MCP server on the Mac mini's Claude Code, drive a real turn through Claude Remote Control (needs the mini set up).
- **M-MARJ-7** persistent sessions: turn history is per-shell today; a durable session log per project in the sidecar is the next step.
- API-tracker deployments (Linear/Shortcut) still take the plugin path for board mutations; the Control API works on the local/sidecar board.
