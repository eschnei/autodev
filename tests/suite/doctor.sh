#!/usr/bin/env bash
# doctor.sh preflight + upgrade-config.sh edge cases + session-signal robustness.
# The hermetic-safety check is the one that matters most: doctor must FAIL when
# production endpoints are reachable and the hermetic overrides are off.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
DOC="$PLUGIN/scripts/doctor.sh"
UPG="$PLUGIN/scripts/upgrade-config.sh"
SIG="$PLUGIN/hooks/session-signal.sh"

doc() { (cd "$1" && bash "$DOC" 2>&1); }

echo "doctor — baseline on a healthy local-tracker repo:"
R=$(mkrepo DocCo)
OUT=$(doc "$R"); rc=$?
check "passes"                                       test $rc -eq 0
check "reports local board ok"                       has 'ok: local board'
check "repo.local_path matches this checkout"        has 'local_path matches'
check "gh needed for draft_pr (stub present)"        has_re '✓.* gh$'
check "branch protection: unprotected is a WARN when no timer is wired" has_re '!.*unprotected'
check "braingrid disabled → agent fallback"          has 'braingrid disabled'
check "hermetic on + no prod endpoints in env"       has 'hermetic on; no prod endpoints'
check "no split warning on a split config"           lacks 'still inline'
check "personas resolution is --check only (no ~/.claude/agents created)" test ! -d "$HOME/.claude/agents"

echo "doctor — hermetic safety (B3):"
RH=$(mkrepo HermCo '.qa.hermetic.enabled=false')
printf 'TWILIO_URL=https://api.twilio.com/v1\nSTRIPE=https://api.stripe.com\n' > "$RH/.env"
OUT=$(doc "$RH"); rc=$?
check "prod endpoints in .env + hermetic OFF → doctor FAILS" test $rc -ne 0
check "…names the endpoints"                         has_re 'PROD endpoints in env \(.*(twilio\.com.*stripe\.com|stripe\.com.*twilio\.com)'
check "…tells the operator to enable qa.hermetic"    has 'Enable qa.hermetic'
RH2=$(mkrepo HermOnCo '.qa.hermetic.enabled=true')
printf 'TWILIO_URL=https://api.twilio.com/v1\n' > "$RH2/.env.local"
OUT=$(doc "$RH2"); rc=$?
check "prod endpoints + hermetic ON with overrides → passes" test $rc -eq 0
check "…but warns the endpoints are present"         has 'OK only because qa.hermetic overrides'
check "…and confirms overrides are set"              has 'qa.hermetic.env overrides set'
RH3=$(mkrepo HermNoEnvCo '.qa.hermetic.enabled=true | .qa.hermetic.env={}')
mkdir -p "$RH3/config"; printf 'MAIL=https://api.sendgrid.com\n' > "$RH3/config/.env"
OUT=$(doc "$RH3"); rc=$?
check "hermetic ON but NO overrides defined → FAILS" test $rc -ne 0
check "…says overrides are missing"                  has 'no qa.hermetic.env overrides'

echo "doctor — other preflight failures:"
ND=$(mktemp -d "$SANDBOX/nd.XXXXXX"); git -C "$ND" init -q
check "no deployment.json → exit 1"                  bash -c "! (cd '$ND' && bash '$DOC' >/dev/null 2>&1)"
RL=$(mkrepo LocalDiffCo '.review.delivery="local_diff"')
OUT=$(doc "$RL")
check "local_diff: gh not required"                  has 'gh not required'
check "local_diff: branch protection n/a"            has 'branch protection n/a'
RM=$(mkrepo MismatchCo); printf '{"repo":{"local_path":"/elsewhere"},"runner":{"home_dir":"%s"}}\n' "$(runhome "$RM")" > "$RM/.autodev/deployment.local.json"
check_out "repo.local_path mismatch is flagged"      "doesn't match this checkout" doc "$RM"
RS=$(mkrepo ScHierCo '.tracker.kind="shortcut" | .tracker.hierarchy="project"')
OUT=$(doc "$RS"); rc=$?
check "shortcut + hierarchy=project → FAIL"          test $rc -ne 0
check "…names the constraint"                        has 'hierarchy=project needs kind=linear'
check "shortcut without a token → suggests local"    has_re 'no Shortcut token.*tracker.kind=local'
RLN=$(mkrepo LinNoTokCo '.tracker.kind="linear"')
check_out "linear without a token → FAIL, suggests local" "no Linear token.*tracker.kind=local" doc "$RLN"
RT=$(mkrepo TimerCo); TRH=$(runhome "$RT"); touch "$TRH/heartbeat"
printf '{"repo":{"local_path":"%s"},"runner":{"home_dir":"%s","heartbeat_file":"%s/heartbeat"}}\n' "$RT" "$TRH" "$TRH" > "$RT/.autodev/deployment.local.json"
OUT=$(doc "$RT"); rc=$?
check "unprotected default branch + timer wired → FAIL" test $rc -ne 0
check "…names the unattended-runner risk"            has 'UNPROTECTED with the 24/7 timer wired'
RTV=$(mkrepo ToolVersCo); printf 'nodejs 20.0.0\n' > "$RTV/.tool-versions"
check_out ".tool-versions without asdf → warn"       "asdf not installed" doc "$RTV"

echo "upgrade-config — edge cases:"
NU=$(mktemp -d "$SANDBOX/nu.XXXXXX")
check_out "missing config → nothing to upgrade, exit 0" "nothing to upgrade" bash "$UPG" "$NU"
RU=$(mkrepo UpCo); echo '{oops' > "$RU/.autodev/deployment.json"
check "invalid JSON → exit 1"                        bash -c "! bash '$UPG' '$RU' >/dev/null 2>&1"
check_out "invalid JSON message"                     "not valid JSON" bash -c "bash '$UPG' '$RU' 2>&1; true"
RU2=$(mkrepo UpNoteCo)
jq '{client_name, tracker:{kind:"local", _my_note:"keep me?"}, _top_note:"x"}' "$RU2/.autodev/deployment.json" > "$RU2/t" && mv "$RU2/t" "$RU2/.autodev/deployment.json"
bash "$UPG" "$RU2" >/dev/null
check "example's _note keys are NOT added"           jq -e '._assistant_name_note==null and .tracker._kind_note==null and .braingrid._enabled_note==null and .qa.hermetic._note==null' "$RU2/.autodev/deployment.json"
check "operator's own _ keys survive (right-biased merge)" jq -e '.tracker._my_note=="keep me?" and ._top_note=="x"' "$RU2/.autodev/deployment.json"
check "identity/example-only fields are not copied"  jq -e '.repo==null and .bot_identity==null and .commands==null and .engine==null and .client_name=="UpNoteCo"' "$RU2/.autodev/deployment.json"
check "schema defaults ARE added"                    jq -e '.session_mode=="concierge" and .review.delivery=="draft_pr" and .qa.hermetic.enabled==true' "$RU2/.autodev/deployment.json"
check "tracker.kind=local preserved"                 jq -e '.tracker.kind=="local"' "$RU2/.autodev/deployment.json"

echo "session-signal — robustness:"
RSG=$(mkrepo SigCo '.session_mode="signal"')
check_out "signal mode names the board count"        "0 stories on the board" bash -c "echo '{\"cwd\":\"$RSG\"}' | bash '$SIG' | jq -r '.hookSpecificOutput.additionalContext'"
check_no_out "garbage stdin → falls back to cwd; unconfigured cwd → silent" bash -c "cd '$SANDBOX' && echo 'not json' | bash '$SIG'"
check_no_out "empty stdin → silent"                  bash -c "cd '$SANDBOX' && printf '' | bash '$SIG'"
RSM=$(mkrepo SigMalCo); echo '{broken' > "$RSM/.autodev/deployment.json"
check "malformed config → still emits (defaults) rather than hijacking with garbage" bash -c "echo '{\"cwd\":\"$RSM\"}' | bash '$SIG' | jq -e '.hookSpecificOutput.hookEventName==\"SessionStart\"'"
RSN=$(mkrepo SigNameCo '.assistant_name="Ada" | .session_mode="concierge"')
check_out "concierge uses the configured assistant name" "You are\s+Ada|You are Ada" bash -c "echo '{\"cwd\":\"$RSN\"}' | bash '$SIG' | jq -r '.hookSpecificOutput.additionalContext' | tr '\n' ' '"
check_out "concierge embeds the manual"              "BEGIN reference/manual.md" bash -c "echo '{\"cwd\":\"$RSN\"}' | CLAUDE_PLUGIN_ROOT='$PLUGIN' bash '$SIG' | jq -r '.hookSpecificOutput.additionalContext'"
printf '# conv\nuse the theme\n' > "$RSN/.autodev/conventions.md"
check_out "concierge embeds conventions.md when present" "BEGIN .autodev/conventions.md" bash -c "echo '{\"cwd\":\"$RSN\"}' | bash '$SIG' | jq -r '.hookSpecificOutput.additionalContext'"

exit $FAIL
