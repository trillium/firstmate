#!/usr/bin/env bash
# The drain prints the NOT DONE list on a heartbeat wake only.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-not-done)

# A home with one queued item filed long before the grace window, and a task CLI
# that reports no blocked beads so the host's real store never leaks in.
make_home_case() {
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/data" "$dir/config" "$dir/projects"
  printf '# Backlog\n\n## In flight\n\n## Queued\n- [ ] old-one - Queued long ago (repo: sample) (kind: ship) (since 2020-01-01)\n' \
    > "$dir/data/backlog.md"
  printf '#!/bin/sh\nprintf "[]\\n"\n' > "$dir/fakebin/task"
  chmod +x "$dir/fakebin/task"
  printf '%s\n' "$dir"
}

drain() { # <dir>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" "$DRAIN"
}

test_heartbeat_prints_not_done() {
  local dir out
  dir=$(make_home_case heartbeat)
  append_wake "$dir/state" heartbeat heartbeat heartbeat || fail 'heartbeat append failed'
  out=$(drain "$dir") || fail 'heartbeat drain failed'
  printf '%s\n' "$out" | grep -q '^NOT DONE (captain-authorized work waiting' \
    || fail "heartbeat drain lacks the NOT DONE section: $out"
  printf '%s\n' "$out" | grep -q 'Not done: Queued long ago (old-one) - unstarted' \
    || fail "heartbeat drain lacks the Not done line: $out"
  pass 'a heartbeat wake prints the NOT DONE list'
}

test_signal_wake_omits_not_done() {
  local dir out
  dir=$(make_home_case signal)
  printf 'working: reading\n' > "$dir/state/other.status"
  append_wake "$dir/state" signal other "signal: $dir/state/other.status" || fail 'signal append failed'
  out=$(drain "$dir") || fail 'signal drain failed'
  printf '%s\n' "$out" | grep -q 'NOT DONE' && fail "a signal wake carried the NOT DONE section: $out"
  pass 'a signal wake does not print the NOT DONE list'
}

test_heartbeat_prints_not_done
test_signal_wake_omits_not_done
