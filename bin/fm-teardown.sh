#!/usr/bin/env bash
# Thin policy shim over parlay teardown: apply firstmate merge-discipline policy,
# then delegate safe destruction to parlay.
# Usage: fm-teardown.sh <task-id> [--force]
#
# Safely tears down a finished task. REFUSES if the worktree holds unlanded work
# (firstmate policy: never silently discard commits). With --force, overrides the
# refusal and discards unlanded work.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}"

parlay_bin="${FM_ROOT}/../parlay/bin/parlay"
[ -x "$parlay_bin" ] || {
  echo "error: parlay not found at $parlay_bin" >&2
  exit 1
}

usage() {
  echo "fm-teardown.sh: safely tear down a finished task" >&2
  echo "Usage: $0 <task-id> [--force]" >&2
  echo "  REFUSES to destroy unless work is landed (no uncommitted/unpushed commits)." >&2
  echo "  --force overrides the refusal." >&2
  exit 1
}

[ $# -ge 1 ] || usage

ID="$1"
FORCE=
[ $# -lt 2 ] || [ "$2" = --force ] || usage
[ "$2" != --force ] || FORCE=--force

# Firstmate policy: apply merge-discipline checks before destruction.
# The key invariant is: "never silently discard unlanded work."
# Parlay teardown already implements the git safety checks (uncommitted,
# unpushed, landed-content validation). We just delegate.

# If --force, parlay teardown will override all checks.
# If not, parlay teardown will refuse on unlanded work (matching firstmate policy).

# Delegate to parlay's safe destroy primitive
if ! "$parlay_bin" teardown "$ID" $FORCE; then
  echo "teardown refused: task $ID has unlanded work" >&2
  exit 1
fi

# Post-teardown cleanup: refresh any project clone if this was a ship task
# that modified the repo. (This is optional; parlay teardown already cleaned up.)
# For now, skip this — could be added if needed.

echo "teardown complete: $ID"
