# autoDev — a templatized autonomous development engine

autoDev turns an idea into **QA'd, human-reviewable, shipped code** through a
ticketing board (Linear), driven by Claude Code — mimicking a PM → dev team, made
operable by non-technical people. It's **reusable**: it installs into *any* client
repo from a single config file.

> **Validated end-to-end** in a sandbox (a 15-story landing page built autonomously,
> 144 unit + 24 e2e green) **and hardened by a 20-hour autonomous production run** —
> the gaps that surfaced are folded back in (see [`BACKLOG.md`](./BACKLOG.md)).
>
> **Open source (Apache-2.0).** Free to self-host. **Managed hosting + onboarding
> available** — see [Managed service](#managed-service).

## What you get

```
autoDev/
├── config/deployment.example.json   # per-client config — copy + fill in
├── install.sh                       # render the engine in + auto-create the Linear board
├── BACKLOG.md                       # roadmap + run-gap audit (what's shipped / planned)
├── template/
│   ├── .claude/
│   │   ├── CLAUDE.md                 # concierge + rulebook + all the toggles
│   │   ├── settings.json            # allowlisted permissions (bot can't merge to main)
│   │   ├── commands/devloop.md      # the /devloop SLASH command (heartbeat entry)
│   │   └── skills/
│   │       ├── intake.md            # plain-English front door · feature-vs-bug gate · cli|linear · attaches wireframes
│   │       ├── prd.md               # PRD (BrainGrid preferred · agent fallback) → Gate 1
│   │       ├── breakdown.md         # → Project · Milestones · Issues (full BrainGrid spec copied in)
│   │       ├── devloop.md           # one heartbeat: dev → QA → merge · live board moves + comment logging
│   │       ├── merge-verify.md      # acceptance QA + post-merge clean-room + report + prod sign-off
│   │       └── _story-template.md   # the story contract
│   ├── scripts/
│   │   ├── linear.mjs               # the Linear helper (move/comment/show/update/relate/attach/create-… )
│   │   ├── report.mjs               # periodic operator digest (reporting.cadence)
│   │   ├── doctor.sh                # preflight: tools · toolchain · token · config ids · hermetic safety
│   │   ├── devloop-tick.sh          # timer entry: portable lock + rate-limit gate + tick + digest
│   │   ├── watchdog.sh              # dead-man alarm + hung-tick recovery → Linear
│   │   └── notify.sh                # rate-limit pause/resume → Linear
│   └── ops/{launchd.plist.template, linear-setup.md}
└── docs/
```

## Deploy to a new client (rinse and repeat)

```bash
cp config/deployment.example.json config/<client>.json   # fill: repo, branch, Linear, commands…
./install.sh config/<client>.json                        # renders the engine + auto-creates the board
scripts/autodev/doctor.sh                                 # preflight — fix any ✗ before running
# then: wire BrainGrid (optional — see below) · connect Linear MCP · bot identity + branch protection
```

The engine is **client-agnostic**; everything per-client lives in the one config.

## The non-negotiables

- **The board is the only state machine** — every transition is a live status move
  (`linear.mjs move …`); cards flow through every column so non-technical operators
  watch work progress in real time. A per-tick reconcile self-heals dropped moves.
- **Two human gates** — PRD approval (Gate 1), story/feature review (Gate 2) — and
  **only humans merge to the default branch** (branch protection, not trust).
- **Tests ship with every change; QA runs for real** — three angles (conformance ·
  adversarial · regression), hidden adversarial tests, on an executable env. The
  **live-browser check is advisory**, never an auto-block.
- **dev↔QA loops until it passes** — QA fail → back to dev → retry, *unbounded while
  making progress*; a **stuck-detector** escalates to a human only on no-progress
  (= "ask, don't invent").
- **Post-merge clean-room verify + whole-feature acceptance** — fresh checkout +
  clean install + integrated suites + live smoke after every merge (auto-revert on
  fail) → acceptance report → **human prod sign-off**. Kills "worked on my local."
- **Hermetic always (safety)** — every test/build/app/live run applies
  `qa.hermetic` overrides; the engine **never** drives QA or the live app against
  production services/creds, and `doctor` fails on prod endpoints in `.env`.
- **Feature-vs-bug gate** at intake — bugs are flagged for triage, not built (v1).
- **Glass-box observability** — status moves + per-tick comment logging + an
  operator digest + a per-feature stats record (`.autodev/metrics.jsonl`).
- **Stateless heartbeat** passes · rate-limit auto-pause/resume · dead-man watchdog
  (with hung-tick recovery).

## Toggles (preferred-optional, degrade gracefully)

| Toggle | Options | Default |
|---|---|---|
| `braingrid.enabled` | BrainGrid spec authoring **or** agent (PM + PjM) fallback | `true` |
| `intake.mode` | `cli` (in-session) **or** `linear` (ticket + comments, no terminal) | `cli` |
| `tracker.hierarchy` | `issue` (feature on the board) **or** `project` (feature-as-Project, org-wide statuses) | `issue` |
| `review.granularity` | `per_story` (review each) **or** `per_feature` (auto-merge to branch; review the whole) | `per_story` |
| `review.delivery` | `draft_pr` (push + GitHub PRs) **or** `local_diff` (no GitHub — local branches + diffs only) | `draft_pr` |
| `review.quality_review` | leanness/dedup pass over the assembled feature diff at close-out | `true` |
| `execution.logging` | `quiet` (status only) · `normal` (checkpoint comments) · `verbose` (+ diffs) | `normal` |
| `execution.incremental_breakdown` | break down the whole feature at Gate 1 **or** per-milestone on demand | `false` |
| `reporting.cadence` | operator digest: `off` · `hourly` · `<N>m` → log / slack / linear | `off` |

## BrainGrid CLI + Claude Code (optional spec tool)

BrainGrid is the **preferred** spec tool (`braingrid.enabled: true`) — it authors the
PRD (`/specify`) and breakdown directly inside Claude Code. It's **optional**: with
no BrainGrid, the engine falls back to the product-manager + project-manager-senior
personas. To wire it up (needs Node 18+):

```bash
# 1. Install the CLI
npm install -g @braingrid/cli

# 2. Authenticate (opens a browser)
braingrid login

# 3. Install the Claude Code integration — adds the /specify, /breakdown, /build
#    slash commands to Claude Code (run --force to overwrite existing files)
braingrid setup claude-code

# 4. In the TARGET repo: create/link a BrainGrid project
cd /path/to/target-repo && braingrid init
#    (non-interactive: braingrid project create --name "<Name>" --repository owner/repo,
#     then braingrid init --project <id>)

# 5. Verify
braingrid status        # shows auth + the linked project
```

Then set `braingrid.enabled: true` and `braingrid.project_short_id` in the deployment
config. (`braingrid setup cursor` / `openclaw` exist too, but autoDev uses Claude Code.)

## Agent roster (agency-agents)

The engine routes work to specialist personas from **[agency-agents](https://github.com/msitarzewski/agency-agents)**
by [@msitarzewski](https://github.com/msitarzewski) (MIT). autoDev does **not** bundle
them — install them into `~/.claude/agents/` from that repo; routing lives in
`config/*.json` (`personas.*`):

| Role | Persona |
|---|---|
| PRD · Breakdown | product-manager · project-manager-senior |
| Dev (routed by files) | backend-architect · frontend-developer · database-optimizer · architect-ux / ui-designer |
| QA — conformance · adversarial · regression/verdict | code-reviewer · test-results-analyzer · evidence-collector · application-security-engineer · api-tester · **reality-checker** |

## Status

**v1 — complete, validated, and hardened by a real run.** Proven end-to-end in a
sandbox (full feature build + dev↔QA loop), then run **20 hours autonomously on a
production codebase** — every gap that surfaced is folded back in ([`BACKLOG.md`](./BACKLOG.md)):
hermetic safety, acceptance QA, leanness review, operator digest, per-feature metrics,
hung-tick recovery, a self-sufficient Linear helper, and more. Next: deploy onto a
dedicated always-on machine and enable the 24/7 timer.

## Managed service

autoDev is **free to self-host** under Apache-2.0. If you'd rather not run it
yourself, **managed hosting + onboarding** (we install it into your repo, wire up
Linear + GitHub + CI, and operate the engine for you) is available as a paid
service — reach out to the maintainer.

## Credits

- **[agency-agents](https://github.com/msitarzewski/agency-agents)** by
  [@msitarzewski](https://github.com/msitarzewski) — the specialist persona library
  the engine routes to (**MIT**). Installed by the operator; not redistributed here.
- Built to run on **[Linear](https://linear.app)** (board + state),
  **[BrainGrid](https://braingrid.ai)** (spec authoring, optional), and
  **[Claude Code](https://claude.com/claude-code)**.

## License

autoDev is licensed under **[Apache-2.0](./LICENSE)** — free to use, modify, and
self-host. Third-party components keep their own licenses (agency-agents is MIT;
see above).
