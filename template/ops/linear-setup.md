# Linear setup for {{CLIENT_NAME}}

Use the **client's own** Linear workspace/team (`{{LINEAR_TEAM}}`). Never a
different workspace.

## Hierarchy mapping

| Engine concept | Linear |
|---|---|
| Feature | **Project** |
| Epic (parallel lane unit) | **Milestone** (within the feature's Project) |
| Story | **Issue** (assigned to its milestone) |
| Dependency | **Issue relation** (`blocks` / `blocked by`) |
| Pipeline stage | the issue's **status column** (the standard set below) |

## The standard pipeline columns (CANONICAL — every deployment is identical)

This exact set is what makes autoDev portable: the engine moves an issue's
**status** at each step, so the board *is* the live pipeline. Create these
columns (left → right). **`(H)` = a human gate/action** — keep the `(H)` in the
name; the engine reads it as "human". All are Linear type `started` except where
noted, so they appear as one kanban flow.

| # | Column | Role |
|---|---|---|
| 1 | **New Request** | Drop zone / inbox. In `linear` mode the operator creates a ticket here; the engine picks it up. |
| 2 | **Clarifying (H)** | Engine asked a question; awaiting the operator's reply (intake/PRD). |
| 3 | **PRD Review (H)** | **Gate 1** — PRD drafted, awaiting `approve`. |
| 4 | **Breakdown** | Decomposing the approved PRD into stories. |
| 5 | **Ready for AI Dev** | Stories queued + `ai-eligible`. |
| 6 | **AI Development** | Engine coding (also where a rejected story returns). |
| 7 | **AI QA** | Three-angle QA running. |
| 8 | **Human Review (H)** | **Gate 2** — draft PR + manual test script, awaiting `approve` (and per-feature acceptance). |
| 9 | **Blocked (H)** | Stuck mid-pipeline; needs human input. |
| 10 | **Done** | Merged / shipped. |

Linear's reserved states (`Backlog`, `Todo`, `Canceled`, `Duplicate`) can stay;
they're not part of the pipeline. `Backlog` is fine as a generic holding area.

### Create them via API (fast, repeatable)
Linear's MCP can't create statuses, so use the GraphQL API with the client's key.
Set `TOKEN` and `TEAM` (the team UUID), then:

```bash
API=https://api.linear.app/graphql
create () {  # name  type  color  position
  curl -s -X POST "$API" -H "Content-Type: application/json" -H "Authorization: $TOKEN" \
    -d "$(jq -n --arg t "$TEAM" --arg n "$1" --arg ty "$2" --arg c "$3" --argjson p "$4" \
      '{query:"mutation($i:WorkflowStateCreateInput!){workflowStateCreate(input:$i){success workflowState{id name}}}",variables:{i:{teamId:$t,name:$n,type:$ty,color:$c,position:$p}}}')" \
    | jq -r '.data.workflowStateCreate.workflowState | "\(.id)  \(.name)"'
}
create "New Request"      started "#95a2b3"  90
create "Clarifying (H)"   started "#f2994a"  95
create "PRD Review (H)"   started "#5e6ad2" 100
create "Breakdown"        started "#5e6ad2" 110
create "Ready for AI Dev" started "#0f7938" 120
create "AI Development"    started "#0f7938" 130
create "AI QA"            started "#f2c94c" 140
create "Human Review (H)" started "#f2994a" 150
create "Blocked (H)"      started "#eb5757" 160
create "Done"             completed "#0f7938" 170
```
Then paste each printed UUID into `tracker.statuses[*].id` in the deployment
config (`state_model: "status"`).

## Labels to create (workspace/team)

Control labels: `ai-eligible` (applied ONLY by `/breakdown`) · `route:feature` ·
`route:task` · `route:bug` · `risk:trivial` · `risk:standard` · `risk:sensitive` ·
`agent:<persona>` (e.g. `agent:backend-architect` — visibility + override).

## Credentials (runner host — keep OFF the chat / out of git)

Create a Linear API key in their workspace (Settings → API → Personal API keys),
then on the runner host:

```bash
mkdir -p ~/.config/autodev
printf '%s' '<LINEAR_API_KEY>' > ~/.config/autodev/{{CLIENT_NAME}}.linear.token
chmod 600 ~/.config/autodev/{{CLIENT_NAME}}.linear.token
export LINEAR_API_TOKEN="$(cat ~/.config/autodev/{{CLIENT_NAME}}.linear.token)"
export LINEAR_TEAM_ID="<team-uuid>"   # used by notify.sh
```

`notify.sh` (rate-limit / watchdog alerts) uses these. The interactive +
devloop work uses a Linear MCP connected to **their** workspace.
