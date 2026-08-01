#!/usr/bin/env bash
# fm-ledger.sh - surface beads whose linked work looks landed but were never
# closed, so they can be reviewed and closed instead of leaking open forever.
#
# A crewmate claims its linked bead on receipt (dispatch=claimed / lifecycle=claimed,
# see bin/fm-brief-hooks.d/beads.sh) and fm-teardown.sh now closes it automatically
# once that task's landed work is torn down (see fm-teardown.sh's header). This
# command is the safety net for everything that falls outside that automatic close -
# a --force teardown, a task that never reached teardown, or a bead claimed outside
# firstmate's own dispatch. A bead is "likely_dropped" when it is claimed, still
# open, and has gone quiet longer than --stale-days: whoever claimed it is very
# unlikely to still be working it.
#
# fm-teardown.sh deletes a task's local meta as its very last step, so this command
# cannot rely on local firstmate state to find a leaked bead - it derives
# likely_dropped purely from the beads store itself (labels, status, timestamps).
#
# Usage:
#   fm-ledger.sh [--json] [--stale-days <n>]     list likely_dropped beads (default: 2 days)
#   fm-ledger.sh --close <id> [<id>...]          close specific bead ids
#   fm-ledger.sh --close-all [--stale-days <n>] [--yes]
#                                                 close every currently-listed likely_dropped
#                                                 bead; without --yes, only lists what would close
#
# Env:
#   FM_BEADS_BIN   beads CLI to invoke (default: task)
set -u

BIN="${FM_BEADS_BIN:-task}"
STALE_DAYS=2
MODE=list
YES=0
CLOSE_IDS=()

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which would silently
  # truncate this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) MODE=json; shift ;;
    --stale-days)
      [ $# -ge 2 ] || { echo "fm-ledger: --stale-days requires a value" >&2; exit 2; }
      STALE_DAYS=$2; shift 2 ;;
    --stale-days=*) STALE_DAYS=${1#--stale-days=}; shift ;;
    --close)
      MODE=close; shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
        CLOSE_IDS+=("$1"); shift
      done
      ;;
    --close-all) MODE=close-all; shift ;;
    --yes) YES=1; shift ;;
    *) echo "fm-ledger: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$STALE_DAYS" in
  ''|*[!0-9]*) echo "fm-ledger: --stale-days must be a non-negative integer, got: $STALE_DAYS" >&2; exit 2 ;;
esac

command -v "$BIN" >/dev/null 2>&1 || { echo "fm-ledger: $BIN CLI not found" >&2; exit 1; }

likely_dropped_query() {
  printf 'label=lifecycle:claimed AND status!=closed AND updated<%sd' "$STALE_DAYS"
}

fetch_likely_dropped() {
  "$BIN" query "$(likely_dropped_query)" --json --limit 0 2>/dev/null || echo '[]'
}

close_one() {
  local id=$1
  if "$BIN" close "$id" --reason "closed via fm-ledger: work landed, bead was never closed" >/dev/null 2>&1; then
    echo "closed $id"
  else
    echo "warning: could not close $id" >&2
    return 1
  fi
}

case "$MODE" in
  close)
    [ "${#CLOSE_IDS[@]}" -gt 0 ] || { echo "fm-ledger: --close requires at least one bead id" >&2; exit 2; }
    rc=0
    for id in "${CLOSE_IDS[@]}"; do
      close_one "$id" || rc=1
    done
    exit "$rc"
    ;;
  close-all)
    command -v jq >/dev/null 2>&1 || { echo "fm-ledger: jq not found" >&2; exit 1; }
    beads=$(fetch_likely_dropped)
    ids=$(printf '%s' "$beads" | jq -r '.[].id')
    if [ -z "$ids" ]; then
      echo "no likely-dropped beads to close"
      exit 0
    fi
    if [ "$YES" != 1 ]; then
      echo "would close:"
      printf '%s\n' "$ids"
      echo "re-run with --yes to close these beads"
      exit 0
    fi
    rc=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      close_one "$id" || rc=1
    done <<EOF
$ids
EOF
    exit "$rc"
    ;;
  json)
    command -v jq >/dev/null 2>&1 || { echo "fm-ledger: jq not found" >&2; exit 1; }
    beads=$(fetch_likely_dropped)
    printf '%s' "$beads" | jq '[.[] | {id, title, status, updated_at, likely_dropped: true}]'
    ;;
  list)
    command -v jq >/dev/null 2>&1 || { echo "fm-ledger: jq not found" >&2; exit 1; }
    beads=$(fetch_likely_dropped)
    count=$(printf '%s' "$beads" | jq 'length')
    if [ "$count" -eq 0 ]; then
      echo "No likely-dropped beads (claimed, unclosed, idle > ${STALE_DAYS}d)."
      exit 0
    fi
    echo "Likely-dropped beads (claimed, unclosed, idle > ${STALE_DAYS}d):"
    echo
    printf '%s' "$beads" | jq -r '.[] | "  \(.id)  \(.updated_at)  \(.title)"'
    echo
    echo "close with: fm-ledger.sh --close <id> [<id>...], or fm-ledger.sh --close-all --yes"
    ;;
esac
