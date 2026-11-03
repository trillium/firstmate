#!/usr/bin/env bash
# tests/fm-lock-enforce-mutators.test.sh - fm-spawn/teardown/pr-merge/merge-local
# refuse a session excluded by another live state/.lock; workers and the
# supervision branch are allowed; fm-send only warns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-enforce)
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
# A live process whose executable name is a verified harness, owning the lock.
ln -s /bin/bash "$TMP_ROOT/claude"
"$TMP_ROOT/claude" -c 'sleep 120; :' >/dev/null 2>&1 &
OWNER=$!
trap 'kill $OWNER 2>/dev/null' EXIT
echo "$OWNER" > "$HOME_DIR/state/.lock"

run() {  # <script> [env...] -- runs with no args, prints stderr
  local s=$1; shift
  # Run under a second fake harness process so the caller has a verified
  # harness ancestry that differs from the lock owner (CI has no real harness).
  env FM_HOME="$HOME_DIR" "$@" "$TMP_ROOT/claude" -c '"$0"; :' "$ROOT/bin/$s" 2>&1 </dev/null
}

test_refused_for_foreign_lock() {
  local s out
  for s in fm-spawn.sh fm-teardown.sh fm-pr-merge.sh fm-merge-local.sh; do
    out=$(run "$s")
    case "$out" in *"does not hold the firstmate session lock"*) ;; *) fail "$s not refused: $out" ;; esac
  done
  pass "mutators refuse a lock-excluded session"
}

test_allowed_for_worker_and_branch() {
  local s out
  for s in fm-spawn.sh fm-teardown.sh fm-pr-merge.sh fm-merge-local.sh; do
    out=$(run "$s" FM_TASK_ID=t1)
    case "$out" in *"does not hold the firstmate session lock"*) fail "$s refused worker" ;; esac
    out=$(run "$s" FM_SUPERVISION_ACTOR=branch)
    case "$out" in *"does not hold the firstmate session lock"*) fail "$s refused branch" ;; esac
  done
  pass "workers and branch actor are not refused"
}

test_allowed_without_foreign_lock() {
  local out
  rm -f "$HOME_DIR/state/.lock"
  out=$(run fm-teardown.sh)
  case "$out" in *"does not hold the firstmate session lock"*) fail "refused with no lock" ;; esac
  echo "$OWNER" > "$HOME_DIR/state/.lock"
  pass "no foreign lock means no refusal"
}

test_send_warns_only() {
  local out
  out=$(run fm-send.sh)
  case "$out" in *"warning - this session does not hold"*) ;; *) fail "fm-send did not warn: $out" ;; esac
  case "$out" in *"refused - this session"*) fail "fm-send refused" ;; esac
  pass "fm-send warns without refusing"
}

test_refused_for_foreign_lock
test_allowed_for_worker_and_branch
test_allowed_without_foreign_lock
test_send_warns_only
