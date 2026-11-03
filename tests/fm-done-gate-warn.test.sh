#!/usr/bin/env bash
# tests/fm-done-gate-warn.test.sh - done without a completion record warns.
set -u
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
S="$(dirname "${BASH_SOURCE[0]}")/../bin/fm-done-gate-warn.sh"
printf 'kind=scout\n' > "$D/t.meta"; echo "done [at=1]: x" > "$D/t.status"
out=$("$S" "$D/t.status" 2>&1) ; rc=$?
[ $rc = 0 ] && case $out in *"no captain-hold completion record"*) ;; *) echo FAIL no-warn; exit 1;; esac
printf 'decisions_reviewed=1\n' >> "$D/t.meta"
out=$("$S" "$D/t.status" 2>&1)
[ -z "$out" ] || { echo "FAIL warned after complete"; exit 1; }
echo ok
