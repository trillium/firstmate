#!/usr/bin/env bash
# tests/fm-check-record.test.sh - a recorded check names the head it ran on,
# keeps the command's exit status, and the done gate warns when the record
# does not back a done line.
set -u
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-check-record.sh"
W="$D/wt"
mkdir -p "$W"
git -C "$W" init -q
git -C "$W" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m one
head=$(git -C "$W" rev-parse HEAD)

( cd "$W" && "$R" demo -- true )
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL passing command returned $rc"; exit 1; }
f="$W/.pr-evidence/demo/check.json"
[ "$(jq -r '.head' "$f")" = "$head" ] || { echo "FAIL head not recorded"; exit 1; }
[ "$(jq -r '.exit' "$f")" = 0 ] || { echo "FAIL exit not recorded"; exit 1; }
[ "$(jq -r '.source' "$f")" = live ] || { echo "FAIL source default"; exit 1; }
[ "$(jq -r '.command' "$f")" = true ] || { echo "FAIL command not recorded"; exit 1; }
case "$(jq -r '.finished_at' "$f")" in '' | *[!0-9]*) echo "FAIL finished_at"; exit 1 ;; esac

( cd "$W" && FM_CHECK_SOURCE=sample "$R" demo -- sh -c 'exit 3' )
rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL failing command status lost ($rc)"; exit 1; }
[ "$(jq -r '.exit' "$f")" = 3 ] || { echo "FAIL failing exit not recorded"; exit 1; }
[ "$(jq -r '.source' "$f")" = sample ] || { echo "FAIL sample source not recorded"; exit 1; }

( cd "$W" && "$R" 'bad id' -- true ) 2>/dev/null
[ $? -eq 2 ] || { echo "FAIL invalid id accepted"; exit 1; }
( cd "$W" && "$R" demo true ) 2>/dev/null
[ $? -eq 2 ] || { echo "FAIL missing -- accepted"; exit 1; }

# Done gate: a Makefile check target puts the done head under the recorded-check rule.
printf 'check:\n\ttrue\n' >"$W/Makefile"
G="$(cd "$(dirname "$R")" && pwd)/fm-done-gate-warn.sh"
printf 'kind=ship\nworktree=%s\n' "$W" >"$D/demo.meta"
gate() { "$G" "$D/demo.status" 2>&1; }
clear_records() { find "$W/.pr-evidence" -mindepth 1 -delete 2>/dev/null; }
short=${head:0:7}

echo "done [at=1]: pushed" >"$D/demo.status"
clear_records
out=$(gate)
case $out in *"no recorded check exists"*) ;; *) echo "FAIL no-record not warned: $out"; exit 1 ;; esac

( cd "$W" && "$R" demo -- true )
out=$(gate)
[ -z "$out" ] || { echo "FAIL warned on a passing record for the head: $out"; exit 1; }

echo "done [at=2]: tests green at $short" >"$D/demo.status"
out=$(gate)
[ -z "$out" ] || { echo "FAIL warned when done names the recorded head: $out"; exit 1; }

( cd "$W" && "$R" demo -- sh -c 'exit 1' )
out=$(gate)
case $out in *"recorded check exited 1"*) ;; *) echo "FAIL failing record not warned: $out"; exit 1 ;; esac

( cd "$W" && FM_CHECK_SOURCE=sample "$R" demo -- true )
out=$(gate)
case $out in *"used sample data, not live"*) ;; *) echo "FAIL sample record not warned: $out"; exit 1 ;; esac

( cd "$W" && "$R" demo -- true )
git -C "$W" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m two
echo "done [at=3]: pushed" >"$D/demo.status"
out=$(gate)
case $out in *"recorded check is for ${short}"*) ;; *) echo "FAIL stale head not warned: $out"; exit 1 ;; esac

echo "done [at=4]: tests green at $short" >"$D/demo.status"
out=$(gate)
[ -z "$out" ] || { echo "FAIL warned for the named recorded head: $out"; exit 1; }

: >"$W/Makefile"
echo "done [at=5]: pushed" >"$D/demo.status"
clear_records
out=$(gate)
[ -z "$out" ] || { echo "FAIL warned without a Makefile check target: $out"; exit 1; }

echo ok
