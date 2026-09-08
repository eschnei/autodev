#!/usr/bin/env bash
# detect-conventions.sh (stack/type/style/test detection + measured comment density)
# and check-docs.sh (advisory workflow-conflict scan of team docs).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
DET="$PLUGIN/scripts/detect-conventions.sh"
CHK="$PLUGIN/scripts/check-docs.sh"

echo "detect-conventions — rich stack:"
R=$(mktemp -d "$SANDBOX/conv.XXXXXX")
cat > "$R/package.json" <<'EOF'
{"dependencies":{"react":"18","@mui/material":"5","@apollo/client":"3","styled-components":"6"},
 "devDependencies":{"@graphql-codegen/cli":"5","vitest":"1","@playwright/test":"1","openapi-typescript":"6"}}
EOF
touch "$R/tsconfig.json" "$R/pnpm-lock.yaml" "$R/codegen.ts" "$R/tailwind.config.ts" "$R/.editorconfig" "$R/.prettierrc"
mkdir -p "$R/prisma"; touch "$R/prisma/schema.prisma"
N_BEFORE=$(find "$R" -type f | wc -l)
OUT=$(bash "$DET" "$R")
check "TypeScript"                     has '**TypeScript**'
check "package manager pnpm (lockfile)" has 'Package manager: **pnpm**'
check "React"                          has 'Framework: **React**'
check "GraphQL codegen → generated types rule" has 'GraphQL code generation'
check "Prisma"                         has '**Prisma**'
check "OpenAPI type generation"        has 'OpenAPI type generation'
check "MUI theme rule"                 has 'Material UI (MUI)'
check "Tailwind"                       has '**Tailwind**'
check "styled-components"              has '**styled-components**'
check "Apollo"                         has 'Apollo Client'
check "Vitest"                         has '**Vitest**'
check "Playwright"                     has '**Playwright**'
check "formatting tooling named"       has_re 'enforced by: .*EditorConfig.*Prettier'
check "no ⚠️ type warning when codegen present" lacks 'No type-generation tool'
check "no ⚠️ style warning when a design system present" lacks 'No design system'
check "always ends with the reuse rule" has 'Reuse before you write'
check "read-only: no files written into the repo" test "$(find "$R" -type f | wc -l)" -eq "$N_BEFORE"

echo "detect-conventions — bare repo + package managers:"
E=$(mktemp -d "$SANDBOX/empty.XXXXXX")
OUT=$(bash "$DET" "$E"); rc=$?
check "empty repo: exit 0"                              test $rc -eq 0
check "empty repo: still prints a report"               has '# Detected project conventions'
check "empty repo: ⚠️ declare the type source-of-truth" has 'No type-generation tool auto-detected'
check "empty repo: ⚠️ declare the styling convention"   has 'No design system auto-detected'
check "empty repo: too few files to measure density"    has 'Too few source files'
for pm in "bun.lockb:bun" "yarn.lock:yarn" "package-lock.json:npm"; do
  d=$(mktemp -d "$SANDBOX/pm.XXXXXX"); touch "$d/${pm%%:*}"
  check_out "lockfile ${pm%%:*} → ${pm##*:}" "Package manager: \*\*${pm##*:}\*\*" bash "$DET" "$d"
done

echo "detect-conventions — measured comment density:"
mk_src() { # <dir> <code-lines> <comment-lines>
  mkdir -p "$1/src"; local i
  { for ((i=0;i<$2;i++)); do echo "const v$i = $i;"; done; for ((i=0;i<$3;i++)); do echo "// why $i"; done; } > "$1/src/a.ts"
}
S=$(mktemp -d "$SANDBOX/sparse.XXXXXX"); mk_src "$S" 200 4
check_out "sparse (<5%) bucket"      "Measured density: ~[0-4]% .*SPARSE" bash "$DET" "$S"
M=$(mktemp -d "$SANDBOX/mod.XXXXXX"); mk_src "$M" 200 16
check_out "moderate (5–12%) bucket"  "MODERATE" bash "$DET" "$M"
D=$(mktemp -d "$SANDBOX/doc.XXXXXX"); mk_src "$D" 200 60
check_out "documented (≥12%) bucket" "DOCUMENTED" bash "$DET" "$D"
X=$(mktemp -d "$SANDBOX/excl.XXXXXX"); mkdir -p "$X/node_modules/x" "$X/.autodev" "$X/.claude"
for f in node_modules/x/a.ts .autodev/b.ts .claude/c.ts; do for i in $(seq 200); do echo 'const a=1;'; done > "$X/$f"; done
check_out "density excludes node_modules + .autodev + .claude" "Too few source files" bash "$DET" "$X"
J=$(mktemp -d "$SANDBOX/jsdoc.XXXXXX"); mk_src "$J" 200 0; for i in $(seq 8); do printf '/** doc */\n' >> "$J/src/a.ts"; done
check_out "JSDoc present → follow existing style"  "Doc-comments .* ARE used" bash "$DET" "$J"
check_out "no JSDoc → don't introduce it"          "rarely uses doc-comments" bash "$DET" "$S"

echo "check-docs — workflow-conflict scan (advisory, always exit 0):"
N=$(mktemp -d "$SANDBOX/nodocs.XXXXXX")
check_out "no team docs → nothing to reconcile"     "no team AGENTS.md / CLAUDE.md present" bash "$CHK" "$N"
C=$(mktemp -d "$SANDBOX/clean.XXXXXX"); printf '# Rules\nUse the MUI theme. Write tests.\n' > "$C/AGENTS.md"
check_out "clean docs → no conflicts (heuristic)"   "no obvious workflow conflicts" bash "$CHK" "$C"
X=$(mktemp -d "$SANDBOX/conf.XXXXXX"); mkdir -p "$X/.claude"
cat > "$X/CLAUDE.md" <<'EOF'
Always commit directly to main when done.
Feel free to force-push over your branch.
Self-merge your own PRs once CI is green.
Skip tests for small changes.
Act autonomously without asking for approval.
Keep AGENTS.md updated as you go.
EOF
printf 'team rules\n' > "$X/.claude/CLAUDE.md"
OUT=$(bash "$CHK" "$X"); rc=$?
check "exit 0 even with conflicts (advisory)"       test $rc -eq 0
check "flags: only humans merge"                    has 'only humans merge the default branch'
check "flags: no force-push"                        has 'never force-pushes'
check "flags: no self-merge"                        has 'no self-merge'
check "flags: tests ship with every change"         has 'tests ship with every change'
check "flags: ask-don't-invent / gates"             has "ask, don't invent"
check "flags: never edits AGENTS.md/CLAUDE.md"      has 'never edits AGENTS.md/CLAUDE.md'
check "shows the offending line numbers"            has_re '^ +[0-9]+:'
check "summarizes the count"                        has 'potential workflow conflict'
check "explains the PROCESS/CONVENTIONS split"      has 'autoDev governs PROCESS'
check "scans .claude/CLAUDE.md too (clean one adds no hits)" test "$(count_re '\.claude/CLAUDE\.md →')" -eq 0

exit $FAIL
