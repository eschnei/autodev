# Shortcut setup for {{CLIENT_NAME}}

One-time, in the **{{SC_WORKSPACE}}** workspace. Add these to the team's
workflow (don't replace existing states — add the AI lane).

## Workflow states (in order)

```
Backlog
  → PRD Review              🚦 GATE 1 (human moves card out)
  → Breakdown
  → Ready for AI Dev
  → AI Development
  → AI QA
  → Ready for Human Review  🚦 GATE 2 (per_story mode only)
  → Approved – Merge
  → Failed Human QA
  → Done
  → Ready for Human Acceptance  🚦 GATE 2 (per_feature mode — epic-level)
```

Plus a side column reachable from any engine state:

```
Blocked – Needs Human Input   ⛔  (question in comments; human answers + moves back)
```

> Which Gate-2 state is used depends on `review.granularity` in
> `.autodev/deployment.json`: **per_story** uses *Ready for Human Review* (one
> gate per story); **per_feature** uses *Ready for Human Acceptance* (one gate
> per feature — the PM/dev-team model).

## Labels

- `ai-eligible` — engine may pick the story up. **Created only by `/breakdown`.**
- `needs-resplit` — (optional) sizing escalation.
- `route:feature` · `route:task` · `route:bug` — intake routing (v1: feature).
- `risk:trivial` · `risk:standard` · `risk:sensitive` — drives review depth now,
  auto-merge graduation later.
- `agent:<persona>` — which dev persona built/owns the story (e.g.
  `agent:backend-architect`) — for visibility + override.

## Token

Create a Shortcut API token (member-scoped to this workspace) and export it on
the runner host as `SHORTCUT_API_TOKEN` (used by `notify.sh` for the watchdog /
rate-limit notices). The engine's interactive + devloop work uses the Shortcut
**MCP** (`{{TRACKER_MCP}}`), connected separately.
