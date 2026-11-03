#!/usr/bin/env bash
# fm-done-gate-warn.sh - warn when a scout appends `done` without the
# captain-hold completion gate. Usage: fm-done-gate-warn.sh <state>/<task>.status
#
# Called by the worker status command right after the append. Reads the last
# status line; for a kind=scout task whose meta lacks the decisions_reviewed=1
# record that `fm-captain-hold.sh complete` writes, prints a warning to stderr.
# Never refuses and always exits 0: the append has already happened.
status=${1:-}
[ -n "$status" ] && [ -f "$status" ] || exit 0
case "$(tail -n 1 "$status")" in done*) ;; *) exit 0 ;; esac
meta=${status%.status}.meta
[ -f "$meta" ] || exit 0
get() { sed -n "s/^$1=//p" "$meta" | tail -n 1; }
[ "$(get kind)" = scout ] || exit 0
[ "$(get decisions_reviewed)" = 1 ] && exit 0
id=$(basename "${status%.status}")
echo "warning: $id reported done but no captain-hold completion record exists; run bin/fm-captain-hold.sh complete $id (--none | <task-id>...) before treating it as finished" >&2
exit 0
