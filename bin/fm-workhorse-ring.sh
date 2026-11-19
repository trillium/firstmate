#!/usr/bin/env bash
# fm-workhorse-ring.sh - ring the workhorse mate about one filed workhorse bead.
#
# Usage: fm-workhorse-ring.sh <bead-id>
#
# Reads the bead back from the pinned task store first (bin/fm-workhorse-lib.sh)
# and refuses a bead that is absent or lacks the `workhorse` label, so a
# doorbell is never rung for nothing. It then sends one line through
# bin/fm-send.sh to the workhorse mate, with FM_HOME explicit: the home that
# records the mate is FM_WORKHORSE_HOME, else FM_HOME, and neither being set
# is refused, because fm-send would otherwise resolve the target against a
# home nobody chose. The mate id is FM_WORKHORSE_MATE (default workhorse-mate).
#
# The send is an ordinary marked secondmate request, not fire-and-forget, so
# the parent's pending-reply recovery and escalation re-ring a doorbell the
# mate never answers; fm-send's exit 0 means the steer is durably recorded in
# the mate's inbox. Any other exit is reported as unconfirmed with fm-send's
# own output, and this script exits 3 so the caller never mistakes a lost
# doorbell for a delivered one. Exit 2 is a refused request and 1 a store
# failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-workhorse-lib.sh
. "$SCRIPT_DIR/fm-workhorse-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
BEAD=$1

fm_workhorse_valid_bead_id "$BEAD" || {
  echo "fm-workhorse-ring: '$BEAD' is not a valid bead id" >&2
  exit 2
}

HOME_DIR=${FM_WORKHORSE_HOME:-${FM_HOME:-}}
[ -n "$HOME_DIR" ] || {
  echo "fm-workhorse-ring: set FM_WORKHORSE_HOME or FM_HOME to the firstmate home that records the workhorse mate; fm-send will not guess one" >&2
  exit 2
}
MATE=${FM_WORKHORSE_MATE:-workhorse-mate}

fm_workhorse_store_check || exit 1
fm_workhorse_bead_json "$BEAD" >/dev/null || exit 1

LINE="workhorse bead $BEAD filed: run bin/fm-workhorse-claim.sh list, claim it, and build it"
out=$(FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-send.sh" "$MATE" "$LINE" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  {
    echo "fm-workhorse-ring: doorbell for $BEAD to $MATE is UNCONFIRMED (fm-send exit $rc); the mate was not confirmed notified"
    [ -z "$out" ] || printf '%s\n' "$out"
    echo "fm-workhorse-ring: re-run bin/fm-workhorse-ring.sh $BEAD once the mate is reachable"
  } >&2
  exit 3
fi
echo "fm-workhorse-ring: rang $MATE for $BEAD (delivery recorded in its inbox)"
