#!/usr/bin/env bash
# Behavior tests: fleet-snapshot per-task probes stay bounded on wedged endpoints.
#
# A dead-endpoint fleet used to hang fleet_snapshot past 100s because the
# per-task crew-state read and the backend endpoint probes had no deadline.
# These cases stub the herdr CLI with a sleeper and prove the snapshot still
# finishes quickly with timeout-marked rows instead of stalling.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-timeout)

# Pin the parlay record store away from the developer's real ~/.parlay so every
# case in this file is hermetic.
export PARLAY_AGENT_HOME="$TMP_ROOT/.parlay-absent"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/parlay" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = sweep ] || exit 0
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    printf '%%1\n'
    ;;
  capture-pane)
    printf 'work in progress\nesc to interrupt\n'
    ;;
esac
exit 0
SH
  # Wedged herdr CLI: every subcommand sleeps past any sane probe bound.
  # Absolute /bin/sleep: bare `sleep` may resolve to a guard shim in this fleet.
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
/bin/sleep 30
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/parlay" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/herdr-worktree"
  fm_write_meta "$home/state/healthy-tmux.meta" \
    "window=firstmate:fm-healthy-tmux" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: healthy pane\n' > "$home/state/healthy-tmux.status"
  fm_write_meta "$home/state/wedged-herdr.meta" \
    "backend=herdr" \
    "window=default:wDEAD:p2" \
    "worktree=$home/projects/herdr-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: wedged endpoint\n' > "$home/state/wedged-herdr.status"
}

test_wedged_probe_cannot_stall_snapshot() {
  local home fakebin out rc start elapsed
  home=$(make_home wedged)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  start=$SECONDS
  out=$(PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_SNAPSHOT_TASK_CREW_STATE_TIMEOUT=2 \
    FM_SNAPSHOT_TASK_ENDPOINT_TIMEOUT=1 \
    "$SNAPSHOT" --json)
  rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -eq 0 ] || fail "snapshot must succeed despite the wedged probe (rc=$rc): $out"
  [ "$elapsed" -lt 15 ] || fail "wedged probe stalled the snapshot (${elapsed}s with a 30s sleeper)"
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "wedged-herdr")
    | .current_state.source == "timeout"
      and .current_state.state == "unknown"
      and (.current_state.detail | contains("timed out"))
      and .endpoint.exists == null
      and .endpoint.agent_alive == "not_checked"
  ' >/dev/null || fail "wedged row must be timeout-marked, not stalled or failed: $out"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "healthy-tmux")
    | .current_state.source != "timeout"
      and .endpoint.exists == true
  ' >/dev/null || fail "healthy row must be unaffected by the bounds: $out"
  pass "wedged herdr probe yields a timeout-marked row in ${elapsed}s, healthy row unaffected"
}

test_herdr_cli_probe_inherits_bound() {
  local home fakebin start elapsed rc
  home=$(make_home cli-bound)
  fakebin=$(make_fakebin "$home")
  start=$SECONDS
  (
    export PATH="$fakebin:$PATH" FM_HOME="$home" FM_BACKEND_HERDR_CLI_TIMEOUT=1
    # shellcheck source=bin/fm-backend.sh
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source herdr
    fm_backend_herdr_cli default pane get wDEAD:p2 >/dev/null 2>&1
  )
  rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -eq 124 ] || fail "wedged herdr CLI must hit the bound (rc=$rc, want 124)"
  [ "$elapsed" -lt 8 ] || fail "herdr CLI probe ran ${elapsed}s despite a 1s bound"
  pass "herdr CLI probe inherits a 1s bound (rc=124 in ${elapsed}s)"
}

test_wedged_probe_cannot_stall_snapshot
test_herdr_cli_probe_inherits_bound
