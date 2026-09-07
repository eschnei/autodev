# Production hardening — 2026-09-06

The checklist Eric set for the phase, what was done for each item, and how it was verified. Everything ran on the Mac mini against the live Brain and real repositories.

| Item | Done | How verified |
|---|---|---|
| files_changed fixed | `repoSnapshot` / `repoDelta` / `mergeDelta` in `src/executors/executor.mjs`; both adapters union the git delta (commits during the job + working tree) with what the vendor reports; `result.commits` added | suite: delta sees a commit + an untracked file, ignores pre-existing dirt; a stub job that creates a file reports it |
| all state mutations through one path | CLI `approve` / `reject` / `executor` are Control API calls (`control.call` events, actor `cli`); no gate or project write remains in `src/cli` outside `init` / `migrate`; controller and MCP already went through it | suite greps `src/cli/main.mjs`; events checked |
| Brain network exposure restricted | service bound to the Tailscale address only (`brain install-service --host 100.64.238.22`); loopback refused; autoDev points at that address; Brain CLI follows the recorded host (`serve.json`) | `lsof` shows one listener on 100.64.238.22:4741; `curl 127.0.0.1:4741` refused |
| isolated executor worktrees (M8A) | `src/core/workspace.mjs`: story jobs run in `<runtime>/worktrees/<id>` on `<story_branch_prefix>/sc-<id>/<slug>`, based on the parent feature branch when present, reused across ticks; `list_lanes`, `release_lane` (dirty refused unless force, branch kept); features / breakdown / review stay on the main checkout | suite: worktree created, model's file lands in the lane not the checkout, main branch untouched, release + re-create |
| contamination guard (M12A) | `src/core/contamination.mjs`: `.brain`, Brain db files, `MARJ.md`, `.marj*`, autodev-projected personas, `.autodev` in sidecar projects; scanned before/after every job (Control API + tick) → `result.contamination`, `contamination.detected` event; `run_verification` cannot PASS while contaminated; `get_status` exposes it. Never deletes. | suite: a stub job dropping `.brain` is recorded as contaminated and verify fails |
| one real shared project migrated | Cora API (`getCoraAI/cora-api`, 8 authors): 55 board issues + deployment into the sidecar, 20 Brain imports | `git status --porcelain` and `--ignored` byte-identical before and after |
| second unrelated project migrated | floppyInstruments: 13 issues, 16 Brain imports | status identical before and after |
| zero cross-project memory leakage | sentinel memory written in Cora; searched from floppy via CLI (scoped by repo) → none; floppy job context → none; raw API with floppy's project id → 0, with Cora's → 1; `contextForJob` always passes `project_id` | commands in the audit page |
| other devs see no repo changes | both migrations left tracked, untracked, and ignored sets unchanged; nothing is ever written into a repo by the sidecar path (G9) | diffs of `git status` snapshots |
| production artifact clean | `package.json` `files` allowlist; `npm pack` no longer ships `.autodev` board state, tests, or BACKLOG | suite check |
| remote Marj turn from phone | MCP server registered for the AutoDev repo (local scope), connected; the turn itself is Eric's to run | `claude mcp get autodev` |

## Still open after this phase

- **Per-project Brain tokens.** One operator token reaches every project when a query omits `project_id`. autoDev never omits it, but a model with a shell in project A could read the token file and query project B. Brain's token file already carries per-token permissions; project scoping is the next step there.
- **Plugin slash commands in a Marj session** can still move cards directly through the tracker facade. Enforcement would mean the facade refusing writes without an actor, which also affects the v2 plugin path; decision pending.
- **API trackers** (Linear, Shortcut) still take the plugin path for board mutations.
- The lane's branch base is the parent feature's branch only when the story carries a `child_of` / `parent` relation; otherwise the main checkout's current branch.

## Follow-up pass (Eric's ordered list, same day)

| # | Item | Done | Verified |
|---|---|---|---|
| 1 | Per-project Brain tokens | Brain: token lines carry `project=…`; the server refuses every request outside the set (path, query, body, entity lookups → 404, listings filtered, admin/cross-project routes closed, unscoped search/context → 403). `POST/GET/DELETE /v1/tokens` (admin), `brain token create\|list\|revoke`, live reload of the token file. autoDev: `autodev brain token` mints and stores a scoped token in the project's sidecar runtime dir (gitignored, 0600); resolution order env → project token → operator file → Keychain. | All three live projects use scoped tokens; the admin token is in the Keychain only (plaintext file removed); Cora's token gets 404 on floppy's project and `project_scope_required` on unscoped search. Brain 210 checks. Residual: any process running as this user can read the sidecar runtime dirs and Brain's own token file; scoping is least privilege on the wire, not OS isolation. |
| 2 | Plugin / Control API bypass | The tracker facade enforces human gates on sidecar boards: leaving a gate needs autoDev core's actor or a one-issue ticket the Control API hands the post-decision job. Executors strip both from the model's environment. v2 repo-local boards unchanged. | Suite: model/plugin move out of a gate refused, ticket for another issue refused, ticket for this issue allowed, core approve path works, env never leaks. Remaining bypass: non-gate stage moves by the model are by design (its job logging); API trackers still take the plugin path. |
| 3 | launchd tick timer | Installed for the AutoDev repo: `com.autodev.autodev-engine.tick` (15 min) + `.watchdog`, stable PATH (fnm default alias) and `AUTODEV_CLI` pinned, scripts copied to `~/.autodev/bin`. `main` on GitHub now requires a PR before merging (the ops doc's precondition). | Fired on load: heartbeat at `~/autodev/heartbeat`, launchd err log shows the tick ran and honored the project pause. The project is **paused** on purpose (`autodev resume` to start unattended ticks on this checkout). |
| 4 | Remote Marj turn from phone | MCP server registered (local scope) and connected. | Eric's turn. |
| 5 | Cleanup | AD-19 → Done with a note; M16Demo removed from Brain; Brain PR #1 merged; autoDev 2.4.0 and PR opened from `feature/re-architecture`. | — |
