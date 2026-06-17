---
name: merge-verify
description: >
  Clean-room integration check after a merge. Reproduces CI/prod conditions
  (fresh checkout, clean install, full suite + build + e2e + live smoke) so
  "worked on my machine" can't slip through. Auto-reverts a bad merge and
  generates the report that backs the human's final prod sign-off.
---

# merge-verify — prove it works AFTER the merge, not just on the story branch

A story branch passing in isolation is NOT proof the *integrated* result works.
This is the engine's answer to classic "it worked on my local." Invoked by
`/devloop` after a squash-merge into the feature branch, and as the gate around
the human merge to `{{DEFAULT_BRANCH}}`.

## 1 · Clean-room integration check (after a merge into the feature branch)
- **Fresh state** — a clean checkout/worktree of the merged feature branch, NOT
  the dev's warm tree (`git clean -fdx` equivalent / separate worktree).
- **Clean install from the lockfile** — `{{CMD_INSTALL}}` (e.g. `npm ci`). Never
  reuse cached `node_modules`; this is what catches missing deps / lockfile drift.
- **Full gates on the integrated result** — `{{CMD_TEST}}` · `{{CMD_LINT}}` ·
  `{{CMD_BUILD}}` · the e2e suite in `{{E2E_DIR}}/`.
- **Live smoke** — start the app (`{{CMD_APP_RUN}}` → `{{APP_URL}}`) and exercise
  the feature's critical path live (evidence-collector / Playwright); attach
  screenshots.
- **CI parity** — confirm CI is green on the merge commit.

**Outcomes:**
- All green → record a short integration note; continue.
- **Any failure** = an integration regression the isolated branch hid → **auto-revert
  that merge** (`git revert` the squash commit on the feature branch, push), move the
  offending story back to `ai_development` with the failure as a comment (localize via
  the `[sc-<id>]` trailer), and re-enter the dev↔QA loop. **Never leave a broken
  shared branch.**

## 2 · Feature acceptance report (before the human gate)
When the feature is assembled and §1 is green, generate a **human-readable report**
(post on the feature issue / Project):
- stories shipped + their QA verdicts; full gate results on the *integrated* branch;
- live-smoke screenshots; CI status; anything QA flagged but didn't block;
- the manual test script for the reviewer.
Then move to the acceptance gate (issue mode: `ready_for_human_acceptance`; project
mode: `acceptance` project-status). **Stop — human decision.**

## 3 · Merge to `{{DEFAULT_BRANCH}}` + post-deploy sign-off (humans only)
- Only a **human** merges the feature PR to `{{DEFAULT_BRANCH}}` — branch protection
  enforces this; the bot never can.
- After it deploys, run a **post-deploy smoke** against the REAL environment (the
  deployed URL, not localhost) and regenerate the report.
- **Final prod sign-off is the human's** — the engine presents the post-deploy
  report; a person confirms it's good in production. If the post-deploy smoke fails,
  raise it immediately (`blocked`) with the evidence.

## Guardrails
- Clean install (`npm ci`-equivalent, no warm cache) is non-negotiable — it's the
  whole point of this skill.
- A **revert** is always preferable to a broken shared branch.
- The bot pushes `{{FEATURE_PREFIX}}*` / `{{STORY_PREFIX}}/*` and may merge
  story→feature; it NEVER merges anything into `{{DEFAULT_BRANCH}}` (needs a real
  bot git identity + branch protection — see `.autodev/ops/linear-setup.md` and the
  install report).
