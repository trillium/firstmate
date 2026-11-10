#!/usr/bin/env bash
# fm-check-record.sh - run a verification command and record its verdict for the done gate.
# Usage: fm-check-record.sh <task-id> -- <command> [args...]
#
# A project's `make check` and `make test` targets wrap their real work in this
# script so that every run leaves .pr-evidence/<task-id>/check.json at the
# repository root: {"head","command","exit","finished_at","source"}.
# bin/fm-done-gate-warn.sh reads that file and warns when a done line names a
# head with no recorded check, or a check that exited non-zero.
#
# head is `git rev-parse HEAD` of the directory the command ran in, read after
# the command finished. exit is the command's own status, and this script exits
# with it. finished_at is the Unix time in seconds. source is `live` unless
# FM_CHECK_SOURCE=sample says the run used sample data rather than the real
# system; the done gate does not accept a sample run as proof of a live claim.
# A run that cannot be recorded (not a git work tree, no jq) still returns the
# command's status and says why on stderr.
set -u
id=${1:-}
if [ -z "$id" ] || [ "${2:-}" != -- ] || [ $# -lt 3 ]; then
  echo "usage: fm-check-record.sh <task-id> -- <command> [args...]" >&2
  exit 2
fi
shift 2
case "$id" in
  *[!A-Za-z0-9._-]* | .*)
    echo "fm-check-record: invalid task id: $id" >&2
    exit 2
    ;;
esac
source_kind=${FM_CHECK_SOURCE:-live}
case "$source_kind" in
  live | sample) ;;
  *)
    echo "fm-check-record: FM_CHECK_SOURCE must be live or sample" >&2
    exit 2
    ;;
esac

"$@"
rc=$?

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "fm-check-record: not in a git work tree; verdict not recorded" >&2
  exit "$rc"
}
head=$(git rev-parse HEAD 2>/dev/null) || head=
if [ -z "$head" ] || ! command -v jq >/dev/null 2>&1; then
  echo "fm-check-record: no HEAD or no jq; verdict not recorded" >&2
  exit "$rc"
fi
dir="$root/.pr-evidence/$id"
record=$(jq -n \
  --arg head "$head" --arg command "$*" --argjson exit "$rc" \
  --argjson finished_at "$(date +%s)" --arg source "$source_kind" \
  '{head: $head, command: $command, exit: $exit, finished_at: $finished_at, source: $source}') &&
  mkdir -p "$dir" && printf '%s\n' "$record" >"$dir/check.json" ||
  echo "fm-check-record: could not write $dir/check.json" >&2
exit "$rc"
