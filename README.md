# autoDev — a templatized autonomous development engine

autoDev is a **reusable, rinse-and-repeat** version of the autonomous 24/7
development engine. It turns approved PRDs into QA'd, human-reviewable code
through a ticketing board (Linear today, tracker-agnostic by design), driven
by Claude Code — and it installs into *any* client repo from a single config
file.

> The full design rationale lives in the autoHaven docs (the first deployment):
> **https://autohaven-2cd4821c.vercel.app** — Project Brief + Implementation
> Spec + Logic Model. autoDev is that engine, extracted and parameterized.

## What you get

```
autoDev/
├── config/deployment.example.json   # per-client config — copy + fill in
├── install.sh                       # render the template into a target repo
├── template/                        # the engine, with {{PLACEHOLDERS}}
│   ├── .claude/
│   │   ├── CLAUDE.md                 # concierge + dev-agent rulebook
│   │   ├── settings.json            # allowlisted permissions for headless runs
│   │   └── skills/
│   │       ├── intake.md            # plain-English front door → routes intent
│   │       ├── prd.md               # BrainGrid /specify → Requirement (=PRD)
│   │       ├── breakdown.md         # BrainGrid /breakdown → Linear stories
│   │       └── devloop.md           # one autonomous heartbeat pass
│   ├── scripts/
│   │   ├── devloop-tick.sh          # timer entry: flock + rate-limit gate + tick
│   │   ├── watchdog.sh              # dead-man alarm → files a Linear story
│   │   └── notify.sh                # rate-limit pause/resume → Linear comment
│   └── ops/
│       ├── launchd.plist.template   # macOS timer (tick + watchdog)
│       └── linear-setup.md        # the workflow states + labels to create
└── docs/                            # links back to the spec
```

## Deploy to a new client (rinse and repeat)

```bash
# 1. Copy + fill in the config for this client
cp config/deployment.example.json config/<client>.json
$EDITOR config/<client>.json        # repo path, branch, BrainGrid project, Linear, commands…

# 2. Render the engine into the target repo's .claude/ + scripts
./install.sh config/<client>.json

# 3. Follow the printed manual steps (the auth-bound ones):
#    - braingrid init            (in the target repo)
#    - connect the Linear MCP  (claude mcp add … + authenticate)
#    - create the Linear workflow states/labels (template/ops/linear-setup.md)
#    - bot git identity + branch protection on the default branch (needs repo admin)
#    - install the launchd timer (template/ops/launchd.plist.template) — Phase 3 only
```

The engine itself is **client-agnostic**; everything that varies per client
lives in the one config file. `install.sh` substitutes the config values into
the template and copies it in — nothing is hardcoded.

## The non-negotiables it carries (from the spec)

- **The tracker is the only state machine** — every transition is a card move.
  BrainGrid holds spec content (Requirement = PRD + tasks), never workflow state.
- **Spec tooling: BrainGrid preferred, agent fallback** — we support and prefer
  **BrainGrid** for authoring the PRD + breakdown (`braingrid.enabled: true`). When
  BrainGrid is unavailable (over a usage limit, offline, or `enabled: false`), the
  engine **falls back** to the **product-manager** + **project-manager-senior**
  personas authoring the PRD and breakdown directly — same structure, same gates.
- **Two human gates** — PRD approval (Gate 1), story review (Gate 2) — and **only
  humans merge to the default branch** (branch protection, not trust).
- **One feature at a time, parallel epic lanes inside it**; v1 = no stacked
  branches (a dependent waits for its blocker to merge into the feature branch).
- **Three-angle AI QA** (conformance · adversarial · regression) + CI gate; the
  **live browser check is advisory evidence, never an auto-block**.
- **Self-review** before QA; **ask, don't invent** at any stage (live in the
  interactive front half, Blocked card in the autonomous back half).
- **Stateless heartbeat passes**; **rate-limit auto-pause/resume**; **dead-man
  watchdog**.
- **Build for the future** — per-story squash, a `(target, gate)` merge-policy
  seam, and a `risk:` class on every story so auto-merge later is a config
  graduation, not a rebuild.

## Agent roster (agency-agents)

The engine routes work to specialist personas (in `~/.claude/agents/`). QA in
particular runs on purpose-built agents, not a generalist:

| Pipeline role | Persona |
|---|---|
| PRD authoring | product-manager |
| Breakdown / ticketization | project-manager-senior |
| Dev — backend / frontend / DB / design | backend-architect · frontend-developer · database-optimizer · architect-ux |
| QA conformance | code-reviewer · test-results-analyzer · **evidence-collector** (live screenshots) |
| QA adversarial | application-security-engineer · api-tester |
| QA regression + verdict | test-results-analyzer · **reality-checker** |
| Support | software-architect · git-workflow-master · devops-automator · codebase-onboarding-engineer |

Roster + routing live in `config/*.json` (`personas.*`); swap per client/stack.

## Status

Template **v1 — complete and installable**. Skills (intake/prd/breakdown/devloop),
runner scripts, ops, settings, config + installer all in place and validated.
First deployment: **autoHaven** → HavenConnect (next: install into a sandbox, run
the `assignOwner` feature end-to-end, then point at the real monorepo).
