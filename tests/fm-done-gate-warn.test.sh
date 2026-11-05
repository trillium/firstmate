#!/usr/bin/env bash
# tests/fm-done-gate-warn.test.sh - done without a completion record warns,
# and a done line names unsettled checks on the branch's open PR.
set -u
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
S="$(dirname "${BASH_SOURCE[0]}")/../bin/fm-done-gate-warn.sh"
printf 'kind=scout\n' >"$D/t.meta"
echo "done [at=1]: x" >"$D/t.status"
out=$("$S" "$D/t.status" 2>&1)
rc=$?
[ $rc = 0 ] && case $out in *"no captain-hold completion record"*) ;; *) echo FAIL no-warn; exit 1 ;; esac
printf 'decisions_reviewed=1\n' >>"$D/t.meta"
out=$("$S" "$D/t.status" 2>&1)
[ -z "$out" ] || { echo "FAIL warned after complete"; exit 1; }

mkdir -p "$D/bin" "$D/wt"
cat >"$D/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${FM_DONE_GATE_STUB:-pr}" in
  timeout-list)
    sleep 30
    exit 0
    ;;
  nopr)
    echo 'no pull requests found' >&2
    exit 1
    ;;
  *)
    printf '  42,fixture\n'
    exit 0
    ;;
esac
SH
cat >"$D/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_DONE_GATE_CALLS:?}"
case "${FM_DONE_GATE_STUB:-pass}" in
  timeout)
    sleep 30
    exit 0
    ;;
  pending)
    printf '%s\n' '[{"name":"lint","bucket":"pending"},{"name":"build","bucket":"fail"},{"name":"unit","bucket":"pass"},{"name":"docs","bucket":"skipping"},{"name":"lint","bucket":"pending"}]'
    exit 8
    ;;
  pass)
    printf '%s\n' '[{"name":"unit","bucket":"pass"},{"name":"docs","bucket":"skipping"}]'
    exit 0
    ;;
  nochecks)
    echo "no checks reported on the 'fm/example' branch" >&2
    exit 1
    ;;
  empty)
    printf '%s\n' '[]'
    exit 1
    ;;
  error)
    echo 'HTTP 502: Bad Gateway' >&2
    exit 1
    ;;
  *)
    echo "unexpected stub mode ${FM_DONE_GATE_STUB:-}" >&2
    exit 91
    ;;
esac
SH
chmod +x "$D/bin/gh-axi" "$D/bin/gh"

ship_meta() {
  printf 'kind=ship\nworktree=%s\nbranch=fm/example\n' "$D/wt" >"$D/ship.meta"
}

run_ship() {
  ship_meta
  : >"$D/calls"
  FM_DONE_GATE_CALLS="$D/calls" PATH="$D/bin:$PATH" "$S" "$D/ship.status" 2>&1
}

echo "done [at=2]: pushed" >"$D/ship.status"
out=$(FM_DONE_GATE_STUB=pending run_ship)
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL pending checks changed the exit status ($rc)"; exit 1; }
case $out in
  "warning: ship reported done with unsettled checks on branch fm/example: pending: lint; failing: build") ;;
  *) echo "FAIL pending summary: $out"; exit 1 ;;
esac
case "$(cat "$D/calls")" in
  "pr checks 42 --json name,bucket") ;;
  *) echo "FAIL forge check invocation: $(cat "$D/calls")"; exit 1 ;;
esac

out=$(FM_DONE_GATE_STUB=pass run_ship)
[ -z "$out" ] || { echo "FAIL warned on passing checks: $out"; exit 1; }

out=$(FM_DONE_GATE_STUB=nochecks run_ship)
case $out in
  "warning: ship reported done but no checks have reported yet on branch fm/example") ;;
  *) echo "FAIL no-checks summary: $out"; exit 1 ;;
esac

out=$(FM_DONE_GATE_STUB=empty run_ship)
case $out in
  "warning: ship reported done but no checks have reported yet on branch fm/example") ;;
  *) echo "FAIL empty-checks summary: $out"; exit 1 ;;
esac

out=$(FM_DONE_GATE_STUB=error run_ship)
[ -z "$out" ] || { echo "FAIL warned on forge error: $out"; exit 1; }

out=$(FM_DONE_GATE_STUB=nopr run_ship)
[ -z "$out" ] || { echo "FAIL warned when no PR: $out"; exit 1; }
[ ! -s "$D/calls" ] || { echo "FAIL checks ran without a PR: $(cat "$D/calls")"; exit 1; }

echo "working [at=3]: still going" >"$D/ship.status"
out=$(FM_DONE_GATE_STUB=pending run_ship)
[ -z "$out" ] || { echo "FAIL warned on a non-done line: $out"; exit 1; }
[ ! -s "$D/calls" ] || { echo "FAIL forge ran for a non-done line"; exit 1; }

echo "done [at=4]: pushed" >"$D/ship.status"
start=$(date +%s)
out=$(FM_DONE_GATE_CHECK_SECS=1 FM_DONE_GATE_STUB=timeout run_ship)
end=$(date +%s)
[ -z "$out" ] || { echo "FAIL warned on a timed-out forge read: $out"; exit 1; }
[ $((end - start)) -lt 8 ] || { echo "FAIL forge read was not bounded ($((end - start))s)"; exit 1; }

echo "done [at=5]: report" >"$D/t.status"
printf 'kind=scout\nworktree=%s\nbranch=fm/example\n' "$D/wt" >"$D/t.meta"
out=$(FM_DONE_GATE_CALLS="$D/calls" FM_DONE_GATE_STUB=pending PATH="$D/bin:$PATH" "$S" "$D/t.status" 2>&1)
case $out in
  *"no captain-hold completion record"*) ;;
  *) echo "FAIL scout warning dropped: $out"; exit 1 ;;
esac
case $out in
  *"unsettled checks on branch fm/example: pending: lint; failing: build"*) ;;
  *) echo "FAIL scout done hid unsettled checks: $out"; exit 1 ;;
esac

echo ok
