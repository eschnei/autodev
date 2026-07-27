# autoDev setup guide

The quickstart lives in the [README](../README.md); this is the reference for
everything around it.

## Preflight (doctor)

`doctor` runs at the end of `/autodev:init`; re-run it any time by asking in Claude
Code, *"run the autoDev preflight (doctor)"* — it's a script the assistant runs for
you. It checks tools, config, board connectivity, and browser-driver availability,
and prints the fix for anything it flags.

## Teammates

Anyone who pulls a configured repo just installs the plugin (the README's install
step) — the committed `.autodev/deployment.json` does the rest. One thing is
per-machine and never committed: `.autodev/deployment.local.json` (repo path,
runner paths). Run `/autodev:init` once (safe to re-run — it won't touch anything
already configured) and it writes yours; `doctor` flags it when it's missing. For
build updates on your phone, run `/remote-control` in Claude Code and pair the
Claude mobile app.

## Optional enhancements — each has a built-in fallback

- **Linear** (`tracker.kind: linear`) — the board lives in Linear instead of local
  files. Needs a Linear team + API token; `ops/linear-setup.md` is the walkthrough,
  and `/autodev:init` prints exactly what's left to wire. Without it: the local
  board, which needs nothing.
- **Shortcut** (`tracker.kind: shortcut`) — the board lives in Shortcut. Needs a
  workflow with the standard states + an API token; `ops/shortcut-setup.md` is the
  walkthrough. Intake stays in-session (`cli`) — comment-driven intake is
  Linear-only.
- **BrainGrid** (`braingrid.enabled`, default on) — a spec-authoring tool the engine
  prefers for PRDs. **Not installed? Nothing breaks** — the engine detects that and
  falls back to its own PM personas automatically. Wiring it up is a 5-step CLI
  install (below).
- **Branch protection** on your default branch — enforces "only humans merge"
  mechanically. Two minutes on GitHub: repo **Settings → Branches → Add branch
  protection rule** on `main`, check *"Require a pull request before merging"*.
  Strongly recommended.

## Unattended (24/7) mode

Wiring the timer (`ops/launchd-timer.md`) means an unattended agent working in your
repo with your credentials — enable it only for a repo and account you trust it
with. In that mode, branch protection on the default branch is the *enforcement* of
"only humans merge", not just a nicety: run `doctor` before loading the timer — it
fails the preflight when the timer is wired and the branch is unprotected (fix per
the bullet above).

## One default worth knowing

`backup.enabled` is on — after each ticket merges to the feature branch, that branch
is pushed to `origin` as a work-in-progress backup (fast-forward only, never your
default branch, never a PR). Working somewhere the robot shouldn't push? Turn it
off, or use `local_diff` delivery which disables all pushing.

## Two ways to ship the same engine

- **Plugin (default):** versioned updates from the marketplace, zero engine files in
  your repo.
- **Vendored (`./install.sh <repo>`):** the engine *copied into* the repo at
  `.autodev/engine/` — auditable and pinned in your git history, for teams that
  can't run third-party plugins. Vendored commands are `/autodev-init` ·
  `/autodev-new` · `/autodev-loop` (the qa/repro commands are plugin-only today).
  Pick **one mode per repo** — the installer refuses to run where the plugin is
  enabled, and `/autodev:init` migrates a vendored repo to the plugin automatically.

## Updating

**Plugin installs:** open `/plugin` → Manage plugins → update `autodev` (or turn on
marketplace auto-update). New engine behavior applies to every configured repo on
its next session; your per-repo config is never touched.

**A repo with autoDev history (pre-plugin install, or an old config):** enabling the
plugin is the whole upgrade — the first session detects history, migrates old engine
files (backed up to `.autodev/backup-vendored/`), upgrades the config schema (new
keys get defaults; your values always win), and reports what was in flight. Review +
commit what it changes. Manual equivalents:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-vendored.sh" .   # old engine files → backup
bash "${CLAUDE_PLUGIN_ROOT}/scripts/upgrade-config.sh" .     # adds new keys; your values win
```

**Vendored installs:** re-run `./install.sh /path/to/repo` from a current checkout —
idempotent, config preserved, and the engine version is re-stamped into
`deployment.json` so you can see exactly what's deployed.

## BrainGrid CLI + Claude Code (optional spec tool)

BrainGrid is the **preferred** spec tool (`braingrid.enabled: true`) — it authors the
PRD (`/specify`) and breakdown inside Claude Code. It's **optional**: without it, the
engine falls back to its product-manager + project-manager-senior personas
automatically. To wire it up (needs Node 18+):

```bash
# in your terminal:
npm install -g @braingrid/cli          # 1. install the CLI
braingrid login                        # 2. authenticate (opens a browser)
braingrid setup claude-code            # 3. adds /specify, /breakdown, /build to Claude Code
cd /path/to/target-repo && braingrid init   # 4. create/link a BrainGrid project
braingrid status                       # 5. verify: auth + linked project
```

Then set `braingrid.enabled: true` and `braingrid.project_short_id` in
`.autodev/deployment.json`.
