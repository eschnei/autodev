# autoDev v3 — Architecture Decisions

**Date:** 2026-09-05
**Status:** Accepted — these are invariants for the v3 re-architecture.

Companion to the v3 PRD and milestone plan. Each decision below resolved a
question raised during PRD review before implementation began.

---

## D1. Runtime and install path

- Plain Node ESM, matching the existing `scripts/*.mjs`. No TypeScript, no build step for M2/M3.
- Preserve the repo's current Node compatibility; do not mix a runtime upgrade into the re-architecture.
- Standard `package.json` `bin` entry:

  ```json
  { "bin": { "autodev": "./bin/autodev.mjs" } }
  ```

- Development install is `npm link` from the repo root. Never hand-copy an executable into `/usr/local/bin`.
- Distribution (npm / GitHub package / Homebrew) is out of scope for M2.

## D2. Sidecar board location, backup, and sync

- For new v3 projects the board must **not** live in the application repo.
- Canonical local location:

  ```text
  ~/Library/Application Support/autoDev/projects/<project-id>/
  ├── project.json
  ├── board/
  ├── events/
  ├── locks/
  └── runtime/
  ```

- The local board remains canonical workflow state. Brain does not own it. The application's Git does not own it.
- Durability comes from a **separate autoDev sidecar state Git repository**, never the application repository. The Mac mini hosts a private bare remote over SSH/Tailscale (conceptually `~/Library/Application Support/autoDev/state.git`). Each machine keeps a local sidecar checkout and syncs to that remote.
- Every meaningful workflow mutation is: atomic local write → append event → sidecar-state commit → push/sync.
- v1 assumes **one active writer per project**. No multi-master sync. A machine taking over explicitly pulls the latest sidecar state first.
- The state remote is durability infrastructure only. It is not Brain and it is never the customer/application repo.
- Legacy `.autodev/board/` remains readable during migration.

**M2 starts sidecar-native.** When `autodev` first recognizes/registers a repo it writes project identity and machine-local metadata to the Application Support location above, never into the application repo. M5A therefore becomes "formalize, harden, and sync the sidecar registry/state model introduced in M2" rather than "move state out of the repo."

M2 acceptance criterion (isolation guarantee from the first CLI milestone):

```text
Run autodev in a clean shared repo
→ register project
→ exit
→ git status remains completely clean
```

## D3. Canonical ID space

- Tracker IDs such as `AD-19` are **not** canonical identity.
- Every entity gets a globally unique stable internal ID: typed prefix + ULID.

  ```json
  {
    "id": "req_01K4ABC...",
    "key": "REQ-104",
    "type": "requirement",
    "external_refs": { "legacy_autodev": "AD-19", "linear": "ENG-418" }
  }
  ```

- `id` never changes. `key` is the human-friendly handle the operator sees and types. Legacy and external tracker IDs are aliases in `external_refs`.
- Brain and autoDev share the same canonical ID.
- Applies to: project, repository, requirement, task, job, memory, handoff.

## D4. Milestone 0 scope

Split into two halves so M0 is finite.

**M0-A — Mechanical regression protection.** Executable tests for what is already deterministic: config loader, config migration, local tracker, Linear/Shortcut adapters, Git guards, docs guards, worktree mechanics, doctor, convention detection, vendored migration, reporting, headless runner mechanics, side-effect protections.

**M0-B — Behavioral compatibility contract.** `docs/v3-compatibility-contract.md` with a matrix over: intake, Gate 1, PRD, breakdown, story selection, development, self-review, QA, Gate 2, merge verify, blocked behavior, ask-don't-invent, human-only default-branch merge, repro-first bugs, production/hermetic protections. For each: current source, expected behavior, mechanically tested today (y/n), migration milestone, future deterministic test owner. Plus a small set of golden scenarios that must keep working during migration.

M0 does **not** require turning every Markdown instruction into an automated test. That happens progressively as workflow ownership moves from Claude prose into autoDev Core.

M0 is done when: existing deterministic tests are green; missing high-value mechanical tests are added; the compatibility contract exists; critical behavior has an owner and migration milestone; the current version is tagged and restorable; and it is explicit what is protected mechanically vs by contract.

---

## Resulting ownership (invariant)

```text
Application Git repo     = code reality
autoDev sidecar state    = workflow reality
Brain                    = semantic knowledge / memory
ULID                     = canonical entity identity
REQ-104 / AD-19 / ENG-418 = human / external aliases
```
