# autoDev — a templatized autonomous development engine

autoDev turns an idea into **QA'd, human-reviewable, shipped code** through a
ticketing board (Linear), driven by Claude Code — mimicking a PM → dev team, made
operable by non-technical people. It's **reusable**: it installs into *any* client
repo from a single config file.

> Design rationale + the first deployment's docs:
> **https://autohaven-2cd4821c.vercel.app**. **Validated end-to-end** in a sandbox:
> a 15-story / 5-epic landing page built autonomously (144 unit + 24 e2e green),
> plus a proven dev↔QA bounce-back loop.

## What you get

```
autoDev/
├── config/deployment.example.json   # per-client config — copy + fill in
├── install.sh                       # render the engine in + auto-create the Linear board
├── template/
│   ├── .claude/
│   │   ├── CLAUDE.md                 # concierge + rulebook + hierarchy/mode toggles
│   │   ├── settings.json            # allowlisted permissions (bot can't merge to main)
│   │   └── skills/
│   │       ├── intake.md            # plain-English front door · feature-vs-bug gate · cli|linear mode
│   │       ├── prd.md               # PRD (BrainGrid preferred · agent fallback) → Gate 1
│   │       ├── breakdown.md         # → Project · Milestones · Issues (+ deps, risk, persona)
│   │       ├── devloop.md           # one heartbeat: dev → QA → merge, live board moves
│   │       ├── merge-verify.md      # post-merge clean-room QA + report + prod sign-off
│   │       └── _story-template.md   # the story contract
│   ├── scripts/
│   │   ├── linear.mjs               # one tested Linear helper (retry/backoff) — no ad-hoc curl
│   │   ├── doctor.sh                # preflight: tools + token + config ids vs LIVE Linear
│   │   ├── devloop-tick.sh          # timer entry: portable lock + rate-limit gate + tick
│   │   ├── watchdog.sh              # dead-man alarm → files a Linear story
│   │   └── notify.sh                # rate-limit pause/resume → Linear
│   └── ops/{launchd.plist.template, linear-setup.md}
└── docs/
```

## Deploy to a new client (rinse and repeat)

```bash
cp config/deployment.example.json config/<client>.json   # fill: repo, branch, Linear, commands…
./install.sh config/<client>.json                        # renders the engine + auto-creates the board
scripts/autodev/doctor.sh                                 # preflight — fix any ✗ before running
# then: braingrid init (optional) · connect Linear MCP · bot identity + branch protection
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
- **Post-merge clean-room verify** — fresh checkout + clean install + full suite +
  live smoke after every merge (auto-revert on fail) → report → **human prod sign-off**.
  Kills "worked on my local."
- **Feature-vs-bug gate** at intake — bugs are flagged for triage, not built (v1).
- **Stateless heartbeat** passes · rate-limit auto-pause/resume · dead-man watchdog.

## Toggles (preferred-optional, degrade gracefully)

| Toggle | Options | Default |
|---|---|---|
| `braingrid.enabled` | BrainGrid spec authoring **or** agent (PM + PjM) fallback | `true` |
| `intake.mode` | `cli` (in-session) **or** `linear` (ticket + comments, no terminal) | `cli` |
| `tracker.hierarchy` | `issue` (feature on the board) **or** `project` (feature-as-Project, org-wide statuses) | `issue` |
| `review.granularity` | `per_story` (review each) **or** `per_feature` (auto-merge to feature branch; review the whole) | `per_story` |

## Agent roster (agency-agents)

Specialist personas in `~/.claude/agents/`; routing in `config/*.json` (`personas.*`):

| Role | Persona |
|---|---|
| PRD · Breakdown | product-manager · project-manager-senior |
| Dev (routed by files) | backend-architect · frontend-developer · database-optimizer · architect-ux / ui-designer |
| QA — conformance · adversarial · regression/verdict | code-reviewer · test-results-analyzer · evidence-collector · application-security-engineer · api-tester · **reality-checker** |

## Status

**v1 — complete, hardened, validated.** Engine, installer, helper, doctor, and all
skills in place; proven end-to-end in a sandbox (full feature build + dev↔QA loop).
Next: deploy onto a dedicated always-on machine and enable the 24/7 timer.
