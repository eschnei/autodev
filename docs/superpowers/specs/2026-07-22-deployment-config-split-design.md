# Split deployment.json into project vs. local-environment config — design

## Motivation

`.autodev/deployment.json` is committed to the client repo (`docs/setup.md`:
"the committed `.autodev/deployment.json` does the rest") and is meant to be
shared across the team that operates a given autoDev deployment — tracker
config, commands, QA policy, review policy, personas, etc.

But the schema (`reference/deployment.example.json`) also carries fields
that are inherently per-machine / per-operator, not per-project:

- `repo.local_path` — an absolute filesystem path to the checkout on
  whichever machine set it up.
- `runner.home_dir`, `runner.heartbeat_file`, `runner.rate_limited_file`,
  `runner.logs_dir` — paths under the 24/7 runner's home directory.

Because these live inside the committed file, every operator who runs the
engine against the same client repo from their own machine either collides
on someone else's absolute path or has to hand-edit a shared, checked-in
file just to run locally — the opposite of what "committed" config is for.

## Goals

- `deployment.json` contains only fields that are genuinely shared across
  everyone operating this deployment; nothing in it assumes a specific
  machine or operator.
- Per-machine/per-operator values live in a file that is never committed,
  with a sane default location and an escape hatch for operators who run
  the engine against multiple client repos from one machine.
- Existing deployments (fields still inline in `deployment.json`) keep
  working unmodified — the split is additive/idempotent, matching this
  repo's existing `upgrade-config.sh` philosophy ("adds keys... NEVER
  changes a value the operator already set").
- Operators running an unmigrated deployment get nudged (not blocked) to
  migrate.
- The 8 existing config-loading call sites stop duplicating resolution
  logic further; the new merge step is added in one shared place per
  language, not copy-pasted 8 times.

## Non-goals

- Changing anything about *which* fields are considered project config
  beyond the ones identified above — this is not a general config-schema
  redesign.
- A central multi-client registry for local files (already a stated
  non-goal of the original plugin-conversion design; this stays per-repo /
  per-`client_name`).
- Retroactively rewriting already-deployed client repos automatically —
  migration is offered, not forced.

## Schema split

**Removed from `deployment.json` / `reference/deployment.example.json`:**

- `repo.local_path`
- `runner.home_dir`
- `runner.heartbeat_file`
- `runner.rate_limited_file`
- `runner.logs_dir`

**New file, `deployment.local.json` (never committed), documented by a new
`reference/deployment.local.example.json`:**

```json
{
  "repo": {
    "local_path": "/absolute/path/to/client/repo"
  },
  "runner": {
    "home_dir": "~/autodev",
    "heartbeat_file": "~/autodev/heartbeat",
    "rate_limited_file": "~/autodev/rate-limited-until",
    "logs_dir": "~/autodev/logs"
  },
  "tracker": {
    "instance_label": "",
    "_instance_label_note": "Optional. Overrides tracker.instance_label from deployment.json for THIS machine/operator only — e.g. running two autoDev instances against the same shared board from different runners. Leave empty to use the project default.",
    "linear": {
      "api_token_file": ""
    },
    "shortcut": {
      "api_token_file": ""
    },
    "_token_file_note": "Optional. Overrides the default ~/.config/autodev/<client_name>.<tracker>.token convention. Leave empty to use the default."
  }
}
```

Only `repo.local_path` and the four `runner.*` fields are *exclusively*
local (no equivalent lives in `deployment.json`). `tracker.instance_label`
and the two `api_token_file` fields are optional local *overrides* of
values that otherwise come from (or default relative to) the project file.

## File location and precedence

Resolved in this order; first one found wins in full (no partial merge
between the two local-file locations themselves):

1. `.autodev/deployment.local.json` — repo-local, gitignored.
2. `~/.config/autodev/<client_name>/deployment.local.json` — global,
   for operators who'd rather keep all their local overrides in one place
   outside every repo they work in.
3. Neither exists → **legacy fallback**: read the 5 exclusively-local
   fields directly from `deployment.json` (today's inline behavior). This
   is what keeps unmigrated deployments working.

`client_name` for step 2's path comes from the resolved `deployment.json`.

A new `$AUTODEV_LOCAL_CONFIG` env var can force an explicit local-file path,
mirroring the existing `$AUTODEV_CONFIG` override — mainly for tests/CI.

## Centralized loader

Today, `findConfig()` (walk up from cwd for `.autodev/deployment.json`,
honor `$AUTODEV_CONFIG`) is duplicated across `tracker.mjs`, `linear.mjs`,
`shortcut.mjs`, `report.mjs`, and re-implemented via inline `jq`/shell in
`doctor.sh`, `devloop-tick.sh`, `watchdog.sh`, `notify.sh`. Adding the local
overlay logic to all 8 sites separately would recreate the exact problem
this change fixes one layer down (drift between copies).

Two new shared modules, one per language, each call site switches to:

- **`scripts/lib/config.mjs`** — exports `loadConfig()`. Resolves
  `deployment.json` exactly as today, resolves the local file per the
  precedence above, deep-merges (local's migrated + override fields win),
  and returns `{ cfg, configPath, isLegacySplit }` where `isLegacySplit` is
  true iff the 5 exclusively-local fields were read from the fallback
  (inline in `deployment.json`) rather than a local file.
- **`scripts/lib/config.sh`** — a sourceable function, same contract,
  callers get the merged config as JSON on stdout (or an `AUTODEV_CFG` var)
  plus an `AUTODEV_CFG_LEGACY_SPLIT` flag.

`tracker.mjs`, `linear.mjs`, `shortcut.mjs`, `report.mjs` import
`config.mjs`; `doctor.sh`, `devloop-tick.sh`, `watchdog.sh`, `notify.sh`
source `config.sh`. No behavior changes to how `$AUTODEV_CONFIG` or the
walk-up resolution work today — this only adds the local-overlay step
around the existing resolution.

## Migration

**`upgrade-config.sh`** (already run by `/autodev:init`, idempotent) gains a
step: if `repo.local_path` or any `runner.*` key is present inline in
`deployment.json` and no local file exists yet at either location, write
`.autodev/deployment.local.json` with those values and remove them from
`deployment.json`. Reported the same way its existing additive-defaults
pass already reports what it changed. Never touches a value the operator
has already split out themselves.

**`doctor.sh`** gains a check: if the loader reports `isLegacySplit`, print
a `warn` (not `bad` — the fallback means nothing is actually broken) naming
`/autodev:init` as the fix.

**Command-level nudge:** `commands/loop.md` and `commands/new.md` each
already have an early check for "does `deployment.json` exist / does it
parse" before proceeding. A sibling clause is added: if invoked
interactively (not headless/timer) and the config is legacy-split, ask the
operator whether to run `/autodev:init` to migrate now before continuing
this pass. Headless/timer invocations skip the ask (per `loop.md`'s
existing headless rules), proceed on the fallback, and rely on `doctor.sh`
having already surfaced the warning at setup time.

**`commands/init.md`**: when writing config (step 4 of today's flow), the 5
exclusively-local fields are written to `.autodev/deployment.local.json`
instead of inline, and `.autodev/deployment.local.json` is appended to the
client repo's `.gitignore` (created if absent).

## Docs

`docs/setup.md`, `docs/faq.md`, `docs/guarantees.md`, `README.md`, and
`ops/launchd-timer.md` are updated wherever they currently describe
`deployment.json` as containing `repo.local_path` / `runner.*`, or
otherwise imply the committed file holds machine-specific paths.

## Testing

- `upgrade-config.sh` against a fixture `deployment.json` with the 5 fields
  inline: verify `deployment.local.json` is created with the right values,
  the 5 fields are gone from `deployment.json`, and re-running is a no-op.
- `config.mjs` / `config.sh`: unit-level checks for each precedence branch
  (repo-local present, global present, neither present/fallback,
  `$AUTODEV_LOCAL_CONFIG` override) and for the `tracker.instance_label` /
  `api_token_file` override behavior.
- `doctor.sh` against both a migrated and an unmigrated fixture config,
  confirming `warn` (not `bad`) on the unmigrated one.
- Existing `smoke`/doctor scripts for `tracker.mjs` / `linear.mjs` /
  `shortcut.mjs` re-run unchanged against a migrated fixture to confirm no
  regression in the non-local fields they read.
