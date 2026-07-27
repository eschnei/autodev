#!/usr/bin/env bash
# autoDev — persona resolution + on-demand install (agency-agents).
# Personas are subagent .md files in the agents dir ($AUTODEV_AGENTS_DIR, default
# ~/.claude/agents). This computes the set THIS deployment needs (personas.roster +
# stage_defaults + dev_routing + qa_angles + fallback), resolves each against the
# agents dir — bare <slug>.md or the library's division-prefixed *-<slug>.md — and,
# unless --check or personas.auto_install=false, downloads ONLY the missing ones from
# the pinned personas.library ref (MIT; attribution in README ▸ Agent roster). Fetch
# failures are soft: the persona reports UNRESOLVED and the engine spawns
# personas.fallback instead (reference/manual.md ▸ Commands). --check never touches
# the network. Exit non-zero only on a hard error (missing config / jq).
# Usage: ensure-personas.sh [--check] [repo]
set -uo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && { CHECK=1; shift; }
REPO="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
CFG="$REPO/.autodev/deployment.json"
[[ -f "$CFG" ]] || { echo "ensure-personas: no $CFG (run /autodev:init first)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ensure-personas: jq missing" >&2; exit 1; }
jq empty "$CFG" 2>/dev/null || { echo "ensure-personas: $CFG is not valid JSON — fix it first" >&2; exit 1; }

AGENTS_DIR="${AUTODEV_AGENTS_DIR:-$HOME/.claude/agents}"
# Consent tri-state: absent → true (documented default) · boolean → itself · anything
# else FAILS CLOSED (a mistyped "false" string must never re-enable the network).
# NOT `// true` — jq's // also treats an explicit false as absent.
AUTO=$(jq -r '.personas.auto_install | if type=="boolean" then tostring elif type=="null" then "true" else "invalid" end' "$CFG")
if [[ "$AUTO" == "invalid" ]]; then
  echo "ensure-personas: personas.auto_install is not a boolean — treating as false (consent fails closed)" >&2
  AUTO="false"
fi
FALLBACK=$(jq -r '.personas.fallback // "general-purpose"' "$CFG")
LIB_REPO=$(jq -r '.personas.library.repo // "msitarzewski/agency-agents"' "$CFG")
LIB_REF=$(jq -r '.personas.library.ref // "main"' "$CFG")

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
got()  { printf '  \033[32m⬇\033[0m %s\n' "$1"; }
miss() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

# every slug the config can route to, "_note" documentation keys excluded
NEEDED=$(jq -r '
  ([.personas.roster[]?]
   + [.personas.stage_defaults // {} | with_entries(select(.key|startswith("_")|not)) | .[]]
   + [.personas.dev_routing[]?.persona]
   + [.personas.qa_angles // {} | with_entries(select(.key|startswith("_")|not)) | .[]
      | if type=="array" then .[] else . end]
   + [.personas.fallback // "general-purpose"])
  | map(select(type=="string" and . != "")) | unique | .[]' "$CFG")
[[ -n "$NEEDED" ]] || { echo "ensure-personas: nothing to resolve (empty personas config)"; exit 0; }

# library divisions — anchors the fuzzy match so "architect" can't claim backend-architect.md
DIVS='academic|design|engineering|gis|government|marketing|product|project-management|sales|specialized|testing'
resolved() { # bare filename, or the library's division-prefixed one
  [[ -f "$AGENTS_DIR/$1.md" ]] && return 0
  local f
  for f in "$AGENTS_DIR"/*-"$1".md; do
    [[ -e "$f" ]] || break
    [[ "$(basename "$f")" =~ ^($DIVS)-$1\.md$ ]] && return 0
  done
  return 1
}

TREE=""   # one tree fetch per run, only when the first download needs it
tree() {
  [[ -n "$TREE" ]] && return 0
  TREE=$(curl -fsS --max-time 20 "https://api.github.com/repos/$LIB_REPO/git/trees/$LIB_REF?recursive=1" \
         | jq -r '.tree[]?.path' 2>/dev/null) || TREE=""
  [[ -n "$TREE" ]]
}

n_inst=0 n_dl=0 n_un=0
UNRES=""
while IFS= read -r slug; do
  if [[ ! "$slug" =~ ^[a-z0-9-]+$ ]]; then # slugs are data for regexes/URLs — reject anything else
    miss "$slug INVALID (slugs are [a-z0-9-]) — engine will run it as $FALLBACK"
    n_un=$((n_un+1)); UNRES+="$slug "; continue
  fi
  if [[ "$slug" == "general-purpose" ]]; then ok "$slug (built-in)"; n_inst=$((n_inst+1)); continue; fi
  if resolved "$slug"; then ok "$slug"; n_inst=$((n_inst+1)); continue; fi
  if [[ $CHECK -eq 1 || "$AUTO" != "true" ]]; then
    miss "$slug UNRESOLVED — engine will run it as $FALLBACK"
    n_un=$((n_un+1)); UNRES+="$slug "; continue
  fi
  # library layout is <division>/<division>-<slug>.md — require dirname/basename agreement
  path=""
  tree && path=$(printf '%s\n' "$TREE" | awk -F/ -v s="$slug" \
    'NF==2 && $2==$1"-"s".md"{print;exit} NF==1 && $1==s".md"{print;exit}')
  if [[ -n "$path" ]]; then
    mkdir -p "$AGENTS_DIR"
    dest="$AGENTS_DIR/$(basename "$path")"
    if curl -fsS --max-time 30 "https://raw.githubusercontent.com/$LIB_REPO/$LIB_REF/$path" -o "$dest.tmp" && [[ -s "$dest.tmp" ]]; then
      mv "$dest.tmp" "$dest" # atomic — a concurrent run never sees a half-written file
      got "$slug downloaded ($(basename "$path") @ ${LIB_REF:0:9})"; n_dl=$((n_dl+1)); continue
    fi
    rm -f "$dest.tmp"
  fi
  miss "$slug UNRESOLVED (not in library / fetch failed) — engine will run it as $FALLBACK"
  n_un=$((n_un+1)); UNRES+="$slug "
done <<< "$NEEDED"

# suffix built outside the expansion — bash 3.2 (macOS) mangles multibyte chars in ${:+}
SFX=""
[[ -n "$UNRES" ]] && SFX=" (${UNRES%% }-> $FALLBACK)"
echo "personas: $((n_inst+n_dl+n_un)) needed · $n_inst installed · $n_dl downloaded · $n_un unresolved$SFX"
exit 0
