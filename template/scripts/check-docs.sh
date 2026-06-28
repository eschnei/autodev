#!/usr/bin/env bash
#
# autoDev — first-install docs conflict scan. A pre-existing AGENTS.md / CLAUDE.md is
# EXPECTED and good (autoDev defers to it for coding conventions). But if it also carries
# rules that fight the autoDev WORKFLOW — commit straight to main, skip tests, self-merge,
# "act autonomously without approval" — the engine and the repo pull against each other and
# the operator only finds out mid-run. This flags those up front so they're reconciled
# before a run. ADVISORY: heuristic, warnings only, never blocks (it always exits 0). The
# first Claude session also reconciles semantically (autodev.md concierge).
#
# Usage: check-docs.sh [repo_path]
set -uo pipefail
REPO="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"

flag() { printf '  \033[33m!\033[0m %s\n' "$1"; }
hits=0

# Parallel arrays: a high-signal regex (-Ei) and the autoDev non-negotiable it may threaten.
PATTERNS=(
  '(commit|push|merge)[^.]{0,24}(to |into )(main|master|trunk|the default branch)'
  '(auto[- ]?merge|self[- ]?merge|merge (your|its) own)'
  "(skip|no|without|don'?t (write|add|need))[^.]{0,16}tests?\b"
  'force[- ]?push'
  '(work|act|proceed|run)[^.]{0,20}(autonomous|without (asking|approval|confirmation|review|a human))'
  '(updat|edit|maintain|modif|refresh)[^.]{0,20}(AGENTS|CLAUDE)\.md|(AGENTS|CLAUDE)\.md[^.]{0,20}(updat|current|edit|maintain|fresh)'
)
RULES=(
  "only humans merge the default branch (Gate 2 + branch protection)"
  "every change passes a human gate before merge (no self-merge)"
  "tests ship with every change — a diff without tests fails self-check"
  "the engine never force-pushes"
  "ask, don't invent + the two human gates — autoDev is not free-running"
  "autoDev never edits AGENTS.md/CLAUDE.md (rule 10 — convention changes go via a separate PR)"
)

scan() { # <file> <label>
  local f="$1" label="$2" i m
  [[ -f "$f" ]] || return 0
  for i in "${!PATTERNS[@]}"; do
    m=$(grep -nEi "${PATTERNS[$i]}" "$f" 2>/dev/null | head -3) || true
    if [[ -n "$m" ]]; then
      hits=$((hits+1))
      flag "$label → may conflict with: ${RULES[$i]}"
      printf '%s\n' "$m" | sed 's/^/        /'
    fi
  done
  return 0
}

echo "docs / workflow-conflict scan:"
found=0
for rel in "AGENTS.md" "CLAUDE.md" ".claude/CLAUDE.md"; do
  [[ -f "$REPO/$rel" ]] || continue
  found=1
  scan "$REPO/$rel" "$rel"
done

if [[ "$found" == 0 ]]; then
  printf '  \033[32m✓\033[0m no team AGENTS.md / CLAUDE.md present — nothing to reconcile\n'
elif [[ "$hits" == 0 ]]; then
  printf '  \033[32m✓\033[0m team docs present; no obvious workflow conflicts detected (heuristic)\n'
  echo "    The first Claude session still reconciles them semantically before any work."
else
  echo
  echo "  → $hits potential workflow conflict(s) — NOT auto-resolved. Before a run, either"
  echo "    edit your AGENTS.md/CLAUDE.md, or confirm the split: autoDev governs PROCESS"
  echo "    (board · gates · who-merges); your files govern CONVENTIONS (how code is written)."
fi
exit 0
