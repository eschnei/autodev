# Shortcut setup for <your deployment's client_name>

Use the **client's own** Shortcut workspace. Never a different workspace.
Set `tracker.kind: "shortcut"` — all board ops still go through
`${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs`, which delegates to `scripts/shortcut.mjs`
(REST API v3, `Shortcut-Token` header, 200 req/min with retry/backoff).

> **Intake note:** comment-driven intake (`intake.mode: linear`) is Linear-only.
> Shortcut deployments use `intake.mode: cli` — the operator drives intake in a
> Claude Code session; the Shortcut board is the live state machine.

## Hierarchy mapping

| Engine concept | Shortcut |
|---|---|
| Feature | **Milestone** |
| Epic (parallel lane unit) | **Epic** (`milestone_id` links it to the feature) |
| Story | **Story** (`epic_id` links it to its lane) |
| Dependency | **Story Link** (`blocks` / `duplicates` / `relates to`) |
| Pipeline stage | the story's **Workflow State** (the standard set below) |

Heads-up: Shortcut is migrating Milestones → Objectives; the `POST /milestones`
endpoint is marked deprecated (still live). If your workspace only shows
"Objectives", they're the same object — the API accepts both today.

Stories can't reference Milestones directly — the lane Epic carries the feature
link; `create-issue --project <id>` is recorded as a `feature:<id>` label.

## The standard pipeline states (CANONICAL — every deployment is identical)

Create these **Workflow States** in ONE workflow (Settings → Workflows), left →
right. **`(H)` = a human gate/action** — keep the `(H)` in the name. Use Shortcut
state type `Started` for all except `Done` (type `Done`); `New Request` can be
type `Unstarted` if you prefer it in the backlog area.

| # | State | Role |
|---|---|---|
| 1 | **New Request** | Inbox for engine-created intake tickets. |
| 2 | **Clarifying (H)** | Engine asked a question; awaiting the operator (in-session). |
| 3 | **PRD Review (H)** | **Gate 1** — PRD drafted, awaiting approval. |
| 4 | **Breakdown** | Decomposing the approved PRD into stories. |
| 5 | **Ready for AI Dev** | Stories queued + `ai-eligible`. |
| 6 | **AI Development** | Engine coding (also where a rejected story returns). |
| 7 | **AI QA** | Three-angle QA running. |
| 8 | **Human Review (H)** | **Gate 2** — draft PR + manual test script (and per-feature acceptance). Paste this ONE state's id into BOTH config keys: `ready_for_human_review` *and* `ready_for_human_acceptance` — 11 keys, 10 states, this one does double duty (same as Linear). |
| 9 | **Blocked (H)** | Stuck mid-pipeline; needs human input. |
| 10 | **Done** | Merged / shipped. |

Shortcut's default states (`Unscheduled`, `Ready for Development`, …) can stay;
they're not part of the pipeline.

### Get the state ids (fast, repeatable)

Shortcut has no state-creation API — create the states in the UI once, then pull
their ids:

```bash
curl -s -H "Shortcut-Token: $SHORTCUT_API_TOKEN" \
  https://api.app.shortcut.com/api/v3/workflows \
  | jq -r '.[] | "workflow \(.id)  \(.name)", (.states[] | "  \(.id)  \(.name)")'
```

Paste the workflow id into `tracker.shortcut.workflow_id` and each state id into
`tracker.shortcut.statuses[*].id` (same stage keys as the Linear block — the
engine's vocabulary never changes). `doctor` then validates every id against the
live workflow.

## Labels to create

Shortcut auto-creates labels on first use, so nothing is required up front. The
engine will use: `ai-eligible` · `route:feature` · `route:task` · `route:bug` ·
`risk:trivial` · `risk:standard` · `risk:sensitive` · `agent:<persona>` · **the
instance tag** `tracker.instance_label` (e.g. `autodev:acmeco`) — each instance
reads/writes ONLY stories carrying its own tag on a shared board.

## Credentials (runner host — keep OFF the chat / out of git)

Create an API token in their workspace (Settings → API Tokens), then:

```bash
mkdir -p ~/.config/autodev
printf '%s' '<SHORTCUT_API_TOKEN>' > ~/.config/autodev/<your deployment's client_name>.shortcut.token
chmod 600 ~/.config/autodev/<your deployment's client_name>.shortcut.token
export SHORTCUT_API_TOKEN="$(cat ~/.config/autodev/<your deployment's client_name>.shortcut.token)"
```

Verify end-to-end: `node "${CLAUDE_PLUGIN_ROOT}/scripts/shortcut.mjs" doctor`.
