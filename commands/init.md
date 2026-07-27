---
description: Guided one-time setup — writes .autodev/deployment.json for this repo. Safe to re-run to reconfigure.
---

Set up autoDev for **this repo**. Safe to re-run any time to reconfigure.

0. **Vendored-install migration (always, first).** Run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-vendored.sh" .` — it detects a
   pre-plugin install (committed `.claude/autodev.md`, engine skills,
   `scripts/autodev/`, our old settings/hook artifacts), backs them up to
   `.autodev/backup-vendored/`, restores anything of the team's the old installer
   displaced, and preserves all state. No-op when nothing vendored exists. Without
   this, enabling the plugin over an old install doubles every hook and skill. If it
   migrated anything, tell the operator to review + commit the removals.
   Then run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/upgrade-config.sh" .` — it adds any
   config keys the schema has grown since this repo was configured (defaults only;
   operator values never change) and reports exactly what it added. After a migration,
   also report what was already IN FLIGHT (`feature/*` branches, board stories + their
   stages) — history continues, it doesn't restart.
1. Check for an existing `.autodev/deployment.json`. If present, tell the operator
   you're reconfiguring it (not creating fresh) and show a one-line summary of the
   current settings before continuing.
2. Detect what you can from the repo, silently, before asking anything:
   - Default branch: `git symbolic-ref --short refs/remotes/origin/HEAD` (fall back
     to the current branch via `git symbolic-ref --short HEAD`).
   - Absolute repo path (for `repo.local_path`, written to the local config in step 4):
     `git rev-parse --show-toplevel`.
   - Package manager: `bun.lockb`/`bun.lock` → bun · `pnpm-lock.yaml` → pnpm ·
     `yarn.lock` → yarn · `package.json` present (else) → npm.
   - If a package manager was detected, read its `package.json` `scripts` for
     `test`, `lint`, `build`, and one of `dev`/`start`/`serve` (in that order) to
     propose `commands.*` defaults.
3. Ask the operator (one question at a time, propose the detected value as the
   default, accept a bare Enter to take it):
   - Deployment name (`client_name`) — default: the repo's directory name.
   - Assistant name (`assistant_name`) — default: `"Marj"`.
   - Session greeting (`session_mode`) — default `"concierge"` (the assistant greets
     as the concierge and drives from plain English — no commands to remember); offer
     `"signal"` (one-line pointer, dormant until `/autodev:loop`) for repos where
     autoDev shares the space with normal dev work, or `"silent"`.
   - Default branch — default: detected above.
   - Test command (`commands.test`) — default: detected above, else ask directly.
   - Install / lint / build / run commands (`commands.install` / `commands.lint` /
     `commands.build` / `commands.app_run`) — same pattern; leave `""` if none.
   - App URL (`commands.app_url`) — default `http://localhost:3000` if a run
     command was set, else `""`.
   - Tracker (`tracker.kind`): `local` (git-native board, zero setup — recommended
     for a new deployment) or `linear` (needs a Linear team + token later).
     Default: `local`.
   - Mode: `hands-on` (review every story — recommended for a first feature) or
     `autopilot` (one PRD approval, then builds + merges to the feature branch
     autonomously until acceptance). Default: `hands-on`.
     - `hands-on` → `review.granularity: "per_story"`, `review.auto_merge_to_feature_branch: false`.
     - `autopilot` → `review.granularity: "per_feature"`, `review.auto_merge_to_feature_branch: true`.
4. Read `${CLAUDE_PLUGIN_ROOT}/reference/deployment.example.json` as the schema —
   every field it contains is valid in `.autodev/deployment.json`. Write
   `.autodev/deployment.json` with that same structure, the operator's answers
   substituted in, and everything else left at the example's defaults. In
   particular: leave `tracker.statuses.*.id` / `tracker.team_id` as
   `"FILL_AT_SETUP"` when `tracker.kind` is `linear` — those are filled by hand
   after the Linear board is created (step 7 below). Drop the `install` block
   entirely (`docs_policy` was an `install.sh`-era concept; this plugin never
   writes into `.claude/settings.json` or over a team-authored file — its only
   `.claude/` artifact is step 6's identity pointer, so there is nothing to
   preserve-vs-overwrite).

   Then read `${CLAUDE_PLUGIN_ROOT}/reference/deployment.local.example.json` and
   write `.autodev/deployment.local.json` with that structure: `repo.local_path`
   = the absolute path detected in step 2, `runner.*` left at the example's
   defaults. If that file already exists, leave the values already configured in
   it alone — only add keys it's missing and refresh `repo.local_path` to the path
   detected in step 2 (a re-run must never reset a customized `runner.home_dir`,
   `runner.logs_dir`, or a token-file override back to the example's default).
   This file is per-machine and must never be committed — append
   `.autodev/deployment.local.json` to the repo's `.gitignore` (create the file
   with just that one line if it doesn't exist yet; if it exists and already
   ignores it, leave it alone).
5. Create the `.autodev` runtime directories: `mkdir -p .autodev/board .autodev/logs`
   (harmless if `tracker.kind` ends up `linear` — `board/` just stays empty; the
   git-native board and the operator digest log both land here on first use).
6. Run `${CLAUDE_PLUGIN_ROOT}/scripts/write-identity-pointer.sh` from the repo root.
   This writes (or refreshes) a small identity pointer at `.claude/CLAUDE.md` so a
   session that hasn't granted workspace trust yet — and so never runs the
   SessionStart hook — still learns the engine identity, since `CLAUDE.md` auto-loads
   as memory regardless of hook trust. It never touches a team-authored file in that
   slot; it only writes an empty slot or replaces its own prior pointer.
7. Print the manual next-steps report — nothing here is automated, all of it needs
   a human with the right auth:
   - If `tracker.kind` is `linear`: point at
     `${CLAUDE_PLUGIN_ROOT}/ops/linear-setup.md` for creating the board columns +
     labels and getting a Linear API token on disk at
     `~/.config/autodev/<client_name>.linear.token`.
   - If `braingrid.enabled` (default true): run `braingrid init` in this repo,
     then set `braingrid.project_short_id` in `.autodev/deployment.json`.
   - Bot git identity + branch protection (needs repo admin): protect the default
     branch so only humans merge; the bot pushes feature/story branches only.
   - 24/7 timer (optional — skip this unless the operator asks for it): see
     `${CLAUDE_PLUGIN_ROOT}/ops/launchd-timer.md`.
8. Run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` from the repo root and show the
   operator anything it flags with a ✗.
9. Confirm: "`.autodev/deployment.json` is ready. Run `/autodev:new` to capture the
   first piece of work, or `/autodev:loop` once stories are queued. Any time after
   that: `/autodev:qa <ticket>` for a deep-dive QA pass on a ready-to-test ticket,
   and `/autodev:repro` to turn 'X is broken' into a reproduced, buildable ticket —
   or just ask in plain English ('can you reproduce this bug?')."
