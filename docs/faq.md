# autoDev FAQ

**What does installing this do to my other repos?**
Nothing. In repos without `.autodev/deployment.json`, the hooks exit silently — no
greeting, no files, no behavior change. One deliberate exception, disclosed in the
README's ["What it never does"](../README.md#what-it-never-does) section: in any
repo, *Claude Code* is blocked from editing `AGENTS.md`/`CLAUDE.md` (your own editor
and terminal never are).

**Does it phone home?**
No telemetry. Network calls happen only for tools you configure (GitHub, Linear,
Slack, BrainGrid) plus the consent-gated persona download from a pinned ref —
`personas.auto_install: false` disables that too.

**Can it merge to `main` or mess up my GitHub?**
No. Only humans merge; the engine pushes feature/story branches and opens *draft*
PRs. With branch protection on, GitHub enforces that mechanically. `local_diff` mode
blocks all pushing.

**Can I undo what it builds?**
Yes. Everything lands on branches behind unmerged PRs — close the PR, delete the
branch, done. After a merge, the clean-room verify auto-reverts anything that breaks
the integrated build.

**What does it cost?**
Your existing Claude subscription — no API key, no separate bill. A feature is many
agent-hours, so expect meaningful quota use; you control the burn by how often you
run `/autodev:loop`, and nothing runs between calls.

**How long does a feature take?**
Each `/autodev:loop` call is one bounded step: a small three-ticket feature is
roughly one call for the spec, one for the breakdown, one to three per ticket, and
a close-out — call it a dozen for a small feature, spread however you like.

**Is anything running when I'm not looking?**
No — no daemon, no background work between calls, unless you deliberately wire the
optional 24/7 timer (`ops/launchd-timer.md`).

**Do I need to be able to read code?**
No. Every ticket arrives with QA reports and a manual test script, and the
assembled feature is launched for you at acceptance — a URL plus a do-X-expect-Y
checklist. Judge it like a customer.

**Does my project need to be on GitHub?**
Only for the default draft-PR delivery. `review.delivery: local_diff` keeps
everything local — branches and diffs, no pushes, no `gh` needed.

**What if I don't know git?**
The engine drives git. Your verbs are "approved", "what's the status?", and
GitHub's Merge button.

**How do I re-run the health check?**
In Claude Code, ask: *"run the autoDev preflight (doctor)"*. It checks tools,
config, board connectivity, and the browser driver, and prints the fix for
anything it flags.

**What happens if I run `/autodev:loop` in a repo I never set up?**
It notices there's no config and walks you through setup first (the same questions
as `/autodev:init`), then continues with your work.

**How is this different from just asking Claude Code to build the feature?**
Structure and audit: a board as the single source of truth, two human gates, QA by
fresh agents that didn't write the code, tests required with every change, and a
comment trail for every action — instead of one long chat you have to babysit.

**Can my team use it — or several instances on one board?**
Yes. Teammates just install the plugin; the committed `.autodev/deployment.json`
does the rest — each teammate additionally gets their own
`.autodev/deployment.local.json` (never committed; `/autodev:init` writes it) for
their repo path and runner paths. Each instance only touches tickets tagged with
its own label (optionally overridden per-machine in the local file), so several
autoDevs — and your team's own tickets — coexist on one board safely.
