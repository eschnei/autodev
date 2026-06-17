# Story template (used by /breakdown)

Each BrainGrid task becomes one Linear **Issue** with this body. Every field is
required; if a field can't be filled with something objective, the story is too
thin — **stop and ask the operator** (ask, don't invent) rather than emit a hollow
story.

```markdown
## Summary
<one sentence: what this story delivers and for whom>

## Acceptance criteria  (the contract — objective + testable)
- [ ] <criterion 1 — checkable, no ambiguity>
- [ ] <criterion 2>
- [ ] <criterion 3>

## Tests required
The diff MUST include tests covering each acceptance criterion above
(layer: unit / integration / e2e as appropriate). A diff without them fails self-check.

## AI QA steps
- Conformance: <what proves each criterion is met>
- Adversarial: <edge cases, bad/malicious inputs, error + authz paths>
- Regression: <adjacent flows / suites that must stay green>

## Manual test steps  (the human's script at Gate 2 / acceptance)
1. <step>
2. <step>
3. <expected result>

## Touched files
<paths/globs this task changes — feeds the lane file-overlap guard + persona routing>
```

## Linear fields set on the issue (not in the body)
- **`blocked by`** links — dependencies (a dependent waits for its blocker to be
  merged into the feature branch; no stacked branches in v1).
- **`risk:` class** — `risk:trivial` (isolated, well-tested, low blast radius) /
  `risk:standard` / `risk:sensitive` (auth, data, money, migrations, security
  surface). Drives review depth now and auto-merge graduation later.
- **`agent:` persona** — routed from `personas.dev_routing` by the touched files
  (e.g. `server/` → backend-architect, `ui/` → frontend-developer,
  schema/migration → database-optimizer; else the `default`).
- **`ai-eligible`** — applied ONLY here, at breakdown. This label is what makes a
  story eligible for the devloop; tickets typed directly into Linear never get it.
