# autoDev — describe work in plain English; get QA'd, human-reviewed code

A [Claude Code](https://claude.com/claude-code) plugin that runs a PM → dev → QA
pipeline on your repo. You describe the work; it writes the spec, builds it ticket by
ticket on a board you can watch, and QA's its own work with fresh agents. **You stay
in charge at exactly two moments:** you approve the plan before anything is built
(Gate 1), and you approve the result before anything ships (Gate 2). Only humans
merge — and nothing advances until you run the next `/autodev:loop`.

> **Validated end-to-end** in a sandbox (a 15-story landing page built autonomously,
> 144 unit + 24 e2e tests green) and **hardened by a 20-hour autonomous production
> run** ([`BACKLOG.md`](./BACKLOG.md)). Apache-2.0, free to self-host —
> [managed service](#managed-service) available.

## Install

In Claude Code, once per machine:

```
/plugin marketplace add eschnei/autodev
/plugin install autodev@autodev-marketplace
```

## Quickstart

You need `git`, `node` 18+, `jq` — plus `gh` and a GitHub remote for the default
draft-PR delivery (no GitHub? pick `review.delivery: local_diff` at setup and skip
both). Don't audit the list by hand: setup ends with a preflight that verifies every
tool and prints the fix for anything missing.

1. **In Claude Code, in the repo you want it to work on:** `/autodev:init` — guided
   setup, roughly a dozen questions, Enter accepts the defaults. Start **hands-on**;
   the default local board needs zero setup.
2. `/autodev:new` — describe the feature like you'd brief a colleague: *"I want a
   waitlist page for the beta."*
3. `/autodev:loop` — each call advances one step. **The first loop drafts the spec
   (a PRD) and stops, waiting for you** — the summary appears right in the chat;
   type **"approved"** (or say what to change). Keep looping: spec → breakdown →
   one to three calls per ticket (a small feature ≈ a dozen calls). Watch anytime:
   ask *"what's the status?"* or open `.autodev/board.html` (re-ask to refresh it).
4. **Review the result (Gate 2) — you never need to read the code.** Each finished
   ticket arrives as a GitHub *draft* PR with QA reports and a **manual test
   script**; the assembled feature is **launched for you** (preview on by default):
   a URL plus a do-X-expect-Y checklist. Judge it like a customer, then mark the PR
   **"Ready for review"** and **Merge**.

From then on, plain English drives everything — a configured repo greets you by name
(the assistant is **Marj**; rename her in config) with a status snapshot; the slash
commands remain as shortcuts.

**Pace and cost:** nothing runs between your `/autodev:loop` calls — no daemon —
unless you wire the optional 24/7 timer (`ops/launchd-timer.md`). It runs on your
existing Claude subscription (no API key); a feature is many agent-hours, so expect
meaningful quota use. You control the burn by how often you run the loop.

## What it never does

- **Repos you never configure: nothing.** The hooks check for
  `.autodev/deployment.json` and exit silently. One exception, by design: in any
  repo, *Claude Code* is blocked from editing `AGENTS.md`/`CLAUDE.md` — your own
  editor and terminal are never touched.
- **Your terminal is never guarded** — the push guard only inspects pushes Claude
  Code itself makes, and only in configured repos.
- **Only humans merge to your default branch.** The engine pushes feature/story
  branches and opens *draft* PRs; `local_diff` mode blocks all pushing.
- **No telemetry.** Network calls happen only for tools you configure (GitHub,
  Linear, Slack, BrainGrid) plus one consent-gated persona download from a pinned
  ref — [details](docs/guarantees.md#agent-roster-agency-agents);
  `personas.auto_install: false` turns it off.
- **QA never touches production** — hermetic overrides on every run; the preflight
  fails when prod endpoints are present and the overrides are off.
- **Tiny footprint:** `.autodev/deployment.json` (commit it) plus
  `.autodev/deployment.local.json` (never committed — per-machine paths only),
  runtime state under `.autodev/`, and a small identity pointer at
  `.claude/CLAUDE.md` that never overwrites a team-authored file. Never
  `.claude/settings.json`, never git config.

## How it works

Every ticket is built by a specialist agent in its own git worktree, must ship tests,
then is QA'd by **fresh agents that didn't write the code** — three angles (meets the
criteria · can it be broken · did anything regress), looping dev ↔ QA until green.
Missing or ambiguous info at *any* stage → it asks you (or parks the ticket as
Blocked), never guesses. After merges, a clean-room verify rebuilds from scratch and
auto-reverts on failure. The board is local by default; Linear and Shortcut are
optional (`tracker.kind`) — Linear adds a no-terminal mode driven entirely from
tickets and comments.

- **`/autodev:qa <ticket>`** — deep exploratory QA: posts a test plan, walks every
  path hermetically with screenshots, and writes an evidence-backed report that a
  second, fresh agent audits adversarially and countersigns.
- **`/autodev:repro`** — turns "X is broken" into a reproduced ticket plus a failing
  repro test, verified by a cold reader; attempt-capped (default 7), then it
  **stops** and posts what it tried.

Both feed the human gates, never replace them.

## Dependencies

| Dependency | Needed for | If missing |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) (subscription login) + `git` · `node` 18+ · `jq` | the engine itself | setup's preflight (`doctor`) flags it with the fix |
| `gh` + a GitHub remote | default draft-PR delivery | set `review.delivery: local_diff` — fully local |
| [agency-agents](https://github.com/msitarzewski/agency-agents) personas (MIT) | specialist dev/QA agents | auto-installed on demand from a pinned ref (`personas.auto_install`); otherwise runs on the built-in fallback agent |
| Playwright (MCP) | screenshots for live/visual QA and bug repro | `/autodev:qa` / `/autodev:repro` offer to install it (with your consent); visual checks flag instead of block |
| [BrainGrid CLI](https://braingrid.ai) | spec authoring | agents author the PRD/breakdown instead — nothing breaks |
| Linear or Shortcut | `tracker.kind: linear` / `shortcut` | the zero-setup local board (default) |

## Toggles (preferred-optional, degrade gracefully)

| Toggle | Options | Default |
|---|---|---|
| `tracker.kind` | `local` (git-native board — zero setup, no tokens, `tracker.mjs board` view) · `linear` (the board is Linear, live) · `shortcut` (the board is Shortcut, live; cli intake) | `local` for new setups (init's default) |
| `tracker.mirror.linear` | local mode: also mirror to Linear async (queued, off the critical path) | `false` |
| `braingrid.enabled` | BrainGrid spec authoring **or** agent (PM + PjM) fallback | `true` (auto-falls-back if absent) |
| `session_mode` | `concierge` (Marj greets, plain English drives) · `signal` (one-line pointer, dormant until invoked) · `silent` | `concierge` |
| `intake.mode` | `cli` (in-session) **or** `linear` (tickets + comments, no terminal) | `cli` |
| `intake.bugs` | `triage` (flag for a human) **or** `pipeline` (repro-test-first fixing) | `triage` |
| `preview.enabled` | launch the assembled feature at acceptance + post URL/relaunch cmd | `true` |
| `backlog.enabled` | idle-time backlog drain (entry-gated batches, own PR each) | `false` |
| `tracker.hierarchy` | `issue` (feature as a board issue) **or** `project` (feature as a Linear Project) | `issue` |
| `review.granularity` | `per_story` (review each ticket) **or** `per_feature` (auto-merge to the feature branch; review the whole) | `per_story` |
| `review.delivery` | `draft_pr` (push + GitHub draft PRs) **or** `local_diff` (no GitHub — local branches + diffs, pushes blocked) | `draft_pr` |
| `review.quality_review` | leanness/dedup pass over the assembled feature at close-out | `true` |
| `backup.enabled` | WIP durability — push the feature branch to `backup.remote` after each story merge (never a PR; no-op under `local_diff`) | `true` |
| `personas.auto_install` | download missing specialist personas on demand (pinned ref) **or** run everything as the fallback agent | `true` |
| `execution.logging` | `quiet` (one line per action) · `normal` (checkpoint comments) · `verbose` (+ diffs) | `normal` |
| `execution.incremental_breakdown` | whole feature at Gate 1 **or** per-milestone on demand | `false` |
| `reporting.cadence` | operator digest: `off` · `hourly` · `<N>m` → log / slack / linear | `off` |

## Docs

- [`docs/setup.md`](docs/setup.md) — the preflight (doctor), teammates, Linear /
  BrainGrid / branch protection, plugin vs vendored, updating.
- [`docs/faq.md`](docs/faq.md) — cost, undo, GitHub-or-not, "do I need to read
  code?", team use, and more.
- [`docs/guarantees.md`](docs/guarantees.md) — the non-negotiables and the agent
  roster.
- `reference/manual.md` — the operating manual the engine itself follows.

## Status

**v2 (2.1.0)** — sandbox-validated, then hardened by a 20-hour autonomous production
run; every gap folded back in ([`BACKLOG.md`](./BACKLOG.md)). Recent: the autoQA
commands (`/autodev:qa`, `/autodev:repro`) and on-demand persona install.

## Managed service

Free to self-host (Apache-2.0). Prefer not to run it yourself? **Managed hosting +
onboarding** — we install, wire up Linear + GitHub + CI, and operate the engine for
you — is available as a paid service; reach out to the maintainer.

## Credits

- **[agency-agents](https://github.com/msitarzewski/agency-agents)** by
  [@msitarzewski](https://github.com/msitarzewski) (MIT) — the specialist persona
  library, fetched on demand at a pinned ref; not redistributed here.
- Built to run on **[Claude Code](https://claude.com/claude-code)**, with optional
  **[Linear](https://linear.app)** and **[BrainGrid](https://braingrid.ai)**.

## License

**[Apache-2.0](./LICENSE)**. Third-party components keep their own licenses.
