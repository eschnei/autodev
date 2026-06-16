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
| Pipeline stage | a `stage:*` **label** (authoritative) + coarse native status |

> Linear's API/MCP can create **labels** but not custom statuses, so the engine
> tracks the fine-grained stage in a `stage:` label and mirrors a coarse status
> (Backlog / Todo / In Progress / Done) for the human board. If you'd rather have
> real Linear statuses (a nicer board), add them in the Linear UI and set
> `tracker.state_model: "status"` in `.autodev/deployment.json`.

## Labels to create (workspace/team)

Stage labels: `stage:prd-review` · `stage:breakdown` · `stage:ready-for-ai-dev` ·
`stage:ai-development` · `stage:ai-qa` · `stage:human-review` ·
`stage:human-acceptance` · `stage:approved-merge` · `stage:failed-human-qa` ·
`stage:done` · `stage:blocked`

Control labels: `ai-eligible` (set ONLY by `/breakdown`) · `route:feature` ·
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
