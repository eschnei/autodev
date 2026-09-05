#!/usr/bin/env bash
# autoDev regression suite runner — the single entry point CI and humans use.
# Runs the original smoke suite plus every tests/suite/*.sh (each in its own
# process, sharing one hermetic sandbox from tests/lib.sh). Exit 1 if any check
# failed anywhere. Usage: tests/run.sh [suite-name-substring...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

FILTER=("$@")
want() { # run this suite? (no filter = all)
  [[ ${#FILTER[@]} -eq 0 ]] && return 0
  local f; for f in "${FILTER[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done
  return 1
}

rc=0
run_suite() {
  local f="$1" name; name=$(basename "$f" .sh)
  want "$name" || return 0
  echo "━━━ $name"
  if ! bash "$f"; then rc=1; fi
  echo
}

run_suite "$HERE/smoke.sh"
for f in "$HERE"/suite/*.sh; do [[ -f "$f" ]] && run_suite "$f"; done

if [[ $rc -eq 0 ]]; then echo "tests: PASS"; else echo "tests: FAIL"; fi
exit $rc
