#!/usr/bin/env bash
# fm-workhorse-close.sh - close a workhorse bead only against the evidence it names.
#
# Usage: fm-workhorse-close.sh <bead-id> [--pr <url>] [--report <path>]
#          [--command-output <text|@file>] [--note <text>]
#
# The bead's `## Evidence required` section (written by
# bin/fm-workhorse-file.sh, read through bin/fm-workhorse-lib.sh) names which
# proof closes it: a PR link, a report path, command output, or several. The
# bead is closed ONLY when every named kind is supplied and well formed:
#   --pr             a full https:// URL with no spaces, copied from the forge
#   --report         a path to an existing, non-empty regular file
#   --command-output at least one real line of output (>= 8 characters), or
#                    @<path> naming an existing non-empty file
# A kind the bead does not name is still recorded when supplied but is never a
# substitute for one it does. The bead must be in_progress (claimed) and must
# carry the `workhorse` label in the pinned task store; anything else is
# refused. On success the evidence is written to the bead as one comment and
# the bead is closed with a reason that names it; the filing mate to answer
# is printed as `answer-to: <id>`. Nothing is written when any check fails.
# A comment that lands but a close that fails exits 1 and says so, so the
# close can be re-run (the repeat adds a second, identical comment at worst).
# Exit 2 is a refused close and 1 a store failure.
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

refuse() {
  printf 'fm-workhorse-close: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
BEAD=$1
shift

PR='' REPORT='' CMD_OUT='' NOTE=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || refuse "$1 needs a value"
  case "$1" in
    --pr) PR=$2 ;;
    --report) REPORT=$2 ;;
    --command-output) CMD_OUT=$2 ;;
    --note) NOTE=$2 ;;
    *) refuse "unknown argument: $1" ;;
  esac
  shift 2
done

fm_workhorse_valid_bead_id "$BEAD" || refuse "'$BEAD' is not a valid bead id"
fm_workhorse_store_check || exit 1
REC=$(fm_workhorse_bead_json "$BEAD") || exit 2
STATUS=$(printf '%s' "$REC" | jq -r '.status')
[ "$STATUS" = in_progress ] || refuse "bead $BEAD is $STATUS; only a claimed (in_progress) workhorse bead can be closed"
DESC=$(printf '%s' "$REC" | jq -r '.description // ""')
KINDS=$(fm_workhorse_evidence_kinds "$DESC")
[ -n "$KINDS" ] || refuse "bead $BEAD names no evidence kind (no PR link, report path, or command output); it is not a full brief and must not be closed by this script"

# Validate every supplied kind, then require every named kind.
if [ -n "$PR" ]; then
  printf '%s' "$PR" | grep -Eq '^https://[^[:space:]]+$' || refuse "--pr must be a full https:// URL as the forge printed it (got '$PR')"
fi
if [ -n "$REPORT" ]; then
  [ -f "$REPORT" ] && [ -s "$REPORT" ] || refuse "--report $REPORT is not an existing, non-empty file"
fi
case "$CMD_OUT" in
  @?*)
    [ -f "${CMD_OUT#@}" ] && [ -s "${CMD_OUT#@}" ] || refuse "--command-output ${CMD_OUT#@} is not an existing, non-empty file"
    CMD_TEXT=$(cat "${CMD_OUT#@}")
    ;;
  *) CMD_TEXT=$CMD_OUT ;;
esac
if [ -n "$CMD_OUT" ]; then
  [ "$(printf '%s' "$CMD_TEXT" | tr -d '[:space:]' | wc -c | tr -d ' ')" -ge 8 ] \
    || refuse "--command-output holds no real output; paste the command and its result"
fi

missing=
while IFS= read -r kind; do
  case "$kind" in
    pr) [ -n "$PR" ] || missing="$missing --pr <url>" ;;
    report) [ -n "$REPORT" ] || missing="$missing --report <path>" ;;
    command) [ -n "$CMD_OUT" ] || missing="$missing --command-output <text|@file>" ;;
  esac
done <<<"$KINDS"
[ -z "$missing" ] || refuse "bead $BEAD names evidence that was not supplied:$missing; nothing was written or closed"

COMMENT="Evidence for closing $BEAD:"
SUMMARY=
if [ -n "$PR" ]; then COMMENT+=$'\n'"- PR link: $PR"; SUMMARY="$SUMMARY PR $PR;"; fi
if [ -n "$REPORT" ]; then COMMENT+=$'\n'"- Report path: $REPORT"; SUMMARY="$SUMMARY report $REPORT;"; fi
if [ -n "$CMD_OUT" ]; then
  COMMENT+=$'\n'"- Command output:"$'\n'"$CMD_TEXT"
  SUMMARY="$SUMMARY command output recorded in a comment;"
fi
if [ -n "$NOTE" ]; then COMMENT+=$'\n'"- Note: $NOTE"; fi

fm_workhorse_task comments add "$BEAD" "$COMMENT" >/dev/null || {
  echo "fm-workhorse-close: recording the evidence comment on $BEAD failed; the bead was not closed" >&2
  exit 1
}
fm_workhorse_task close "$BEAD" --reason "Evidence supplied:${SUMMARY%;}" >/dev/null || {
  echo "fm-workhorse-close: the evidence is recorded on $BEAD but closing it failed; re-run this command" >&2
  exit 1
}
printf 'closed %s with evidence\n' "$BEAD"
printf 'answer-to: %s\n' "$(fm_workhorse_section "$DESC" "Answer-to")"
