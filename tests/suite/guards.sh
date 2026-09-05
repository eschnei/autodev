#!/usr/bin/env bash
# PreToolUse guards — the mechanical half of "only humans merge the default branch"
# and "never edit the team's docs". These hooks are Claude-plugin surfaces today; v3
# re-homes the same rules executor-independently, so every edge here is a contract.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
PUSH="$PLUGIN/hooks/guard-push.sh"
DOCS="$PLUGIN/hooks/guard-docs.sh"

push_decision() { # <repo> <command> -> "deny" | "allow" (allow = hook printed nothing)
  local out; out=$(hook_input Bash "$(jq -cn --arg c "$2" '{command:$c}')" "$1" | bash "$PUSH")
  if [[ -z "$out" ]]; then echo allow; else jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"; fi
}
push_reason() { hook_input Bash "$(jq -cn --arg c "$2" '{command:$c}')" "$1" | bash "$PUSH" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
is() { [[ "$(push_decision "$1" "$2")" == "$3" ]]; }

R=$(mkrepo GuardCo)

echo "push guard — allowed shapes (explicit feature/story branch):"
check "git push origin feature/x"                     is "$R" 'git push origin feature/x' allow
check "git push -u origin feature/x"                  is "$R" 'git push -u origin feature/x' allow
check "git push origin autodev/sc-4/slug"             is "$R" 'git push origin autodev/sc-4/slug' allow
check "src:dst refspec to a feature branch"           is "$R" 'git push origin feature/x:feature/x' allow
check "default-branch name as a PREFIX is not a match (main-feature)" is "$R" 'git push origin main-feature' allow
check "default-branch name with a dot suffix is not a match (main.bak)" is "$R" 'git push origin main.bak' allow
check_no_out "non-push git command is ignored (git status)" bash -c "hook_input Bash '{\"command\":\"git status\"}' '$R' | bash '$PUSH'"
check_no_out "non-Bash tool is ignored"               bash -c "hook_input Edit '{\"file_path\":\"x\"}' '$R' | bash '$PUSH'"
check_no_out "'push' inside another word (git pushy) is ignored" bash -c "hook_input Bash '{\"command\":\"git pushy\"}' '$R' | bash '$PUSH'"

echo "push guard — denied shapes:"
check "git push origin main"                          is "$R" 'git push origin main' deny
check "HEAD:main refspec"                             is "$R" 'git push origin HEAD:main' deny
check "pushing HEAD (ambiguous)"                      is "$R" 'git push origin HEAD' deny
check "bare git push (ambiguous)"                     is "$R" 'git push' deny
check "git push <remote> with no ref (ambiguous)"     is "$R" 'git push origin' deny
check "flags only before the remote (-u origin)"      is "$R" 'git push -u origin' deny
check "--force-with-lease origin, no ref"             is "$R" 'git push --force-with-lease origin' deny
check "--all"                                         is "$R" 'git push --all origin' deny
check "--tags"                                        is "$R" 'git push origin --tags' deny
check "--mirror"                                      is "$R" 'git push --mirror origin' deny
check "+main force shorthand"                         is "$R" 'git push origin +main' deny
check "refs/heads/main"                               is "$R" 'git push origin refs/heads/main' deny
check "feature:main refspec (dst is default branch)"  is "$R" 'git push origin feature/x:main' deny
check "chained after && (cd repo && git push origin main)" is "$R" 'cd /tmp/x && git push origin main' deny
check "chained after ; (git fetch; git push origin main)"  is "$R" 'git fetch; git push origin main' deny
check "chained after | "                              is "$R" 'echo y | git push origin main' deny
check_out "deny reason names the branch + Gate 2"     "only humans merge 'main'.*Gate 2" push_reason "$R" 'git push origin main'

echo "push guard — config-driven behavior:"
RT=$(mkrepo TrunkCo '.repo.default_branch="trunk"')
check "custom default_branch=trunk is denied"         is "$RT" 'git push origin trunk' deny
check "with default_branch=trunk, main is just a branch" is "$RT" 'git push origin main' allow
RL=$(mkrepo LocalCo '.review.delivery="local_diff"')
check "local_diff denies even a feature push"         is "$RL" 'git push origin feature/x' deny
check_out "local_diff reason names the mode"          "local_diff" push_reason "$RL" 'git push origin feature/x'
RU=$(mktemp -d "$SANDBOX/unconf.XXXXXX")
check "unconfigured repo (no deployment.json) fails OPEN — even main" is "$RU" 'git push origin main' allow
RB=$(mkrepo BrokenCo); echo '{not json' > "$RB/.autodev/deployment.json"
check "present-but-malformed config fails CLOSED"    is "$RB" 'git push origin feature/x' deny
check_out "malformed-config reason says so"           "not valid JSON" push_reason "$RB" 'git push origin feature/x'
RC=$(mkrepo CwdCo); mkdir -p "$RC/sub"
check "cwd is the config lookup root — a subdir cwd sees no config (fails open)" is "$RC/sub" 'git push origin main' allow

echo "docs guard — team docs are read-only:"
docs_decision() { # <tool> <file_path>
  local out; out=$(hook_input "$1" "$(jq -cn --arg f "$2" '{file_path:$f}')" "$R" | bash "$DOCS")
  if [[ -z "$out" ]]; then echo allow; else jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"; fi
}
dis() { [[ "$(docs_decision "$1" "$2")" == "$3" ]]; }
check "Edit AGENTS.md denied"                          dis Edit 'AGENTS.md' deny
check "Write AGENTS.md denied"                         dis Write 'AGENTS.md' deny
check "Edit CLAUDE.md denied"                          dis Edit 'CLAUDE.md' deny
check "absolute path /repo/CLAUDE.md denied"           dis Edit '/some/repo/CLAUDE.md' deny
check ".claude/CLAUDE.md denied"                       dis Edit '.claude/CLAUDE.md' deny
check "nested docs/AGENTS.md denied (any directory)"   dis Edit 'docs/AGENTS.md' deny
check "README.md allowed"                              dis Edit 'README.md' allow
check "CLAUDE.md.bak allowed (suffix)"                  dis Edit 'CLAUDE.md.bak' allow
check "MYCLAUDE.md allowed (prefix)"                    dis Edit 'MYCLAUDE.md' allow
check "AGENTS.markdown allowed (different extension)"  dis Edit 'AGENTS.markdown' allow
check ".autodev/conventions.md allowed"                dis Write '.autodev/conventions.md' allow
check "Bash tool is ignored"                           dis Bash 'AGENTS.md' allow
check_no_out "empty file_path prints nothing"          bash -c "hook_input Edit '{}' '$R' | bash '$DOCS'"
check "docs guard applies even in an unconfigured repo (hard rule)" bash -c "hook_input Edit '{\"file_path\":\"CLAUDE.md\"}' '$RU' | bash '$DOCS' | jq -e '.hookSpecificOutput.permissionDecision==\"deny\"'"
check_out "deny reason cites non-negotiable 11"        "non-negotiable 11" bash -c "hook_input Edit '{\"file_path\":\"CLAUDE.md\"}' '$R' | bash '$DOCS'"

exit $FAIL
