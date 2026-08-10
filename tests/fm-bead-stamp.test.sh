#!/usr/bin/env bash
# tests/fm-bead-stamp.test.sh - fm-bead-stamp.sh stamps a linked bead as
# dispatched (dispatch=sent, lifecycle=sent, assign) and stays fail-open on
# every ordinary gap (no bead id, no task CLI, no agent name, bead not
# found). This suite adds coverage for the beads-authority-migration Stage 5
# resilience layer (report.md section 5): a store-unreachable dispatch queues
# all three writes for later replay instead of only warning and losing them,
# and an individual write that fails against a reachable store is queued on
# its own rather than every write.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bead-stamp-tests)
STAMP="$ROOT/bin/fm-bead-stamp.sh"

# make_home <name>: an isolated FM_HOME with just a state dir, so each case
# gets its own write queue.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s' "$home"
}

# make_fakebin <name>: an isolated bin dir for this case's fake `task`.
make_fakebin() {
  local bin="$TMP_ROOT/$1-bin"
  mkdir -p "$bin"
  printf '%s' "$bin"
}

queue_count() {
  local home=$1
  [ -f "$home/state/.beads-write-queue" ] || { echo 0; return; }
  wc -l < "$home/state/.beads-write-queue" | tr -d ' '
}

# --- fail-open gaps, unrelated to the resilience layer -------------------

OUT=$("$STAMP" "" agent-x 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "an empty bead id must still exit 0 (fail-open)"
printf '%s\n' "$OUT" | grep -Fq "no bead id given" || fail "an empty bead id did not warn: $OUT"
pass "fm-bead-stamp.sh exits 0 and warns when no bead id is given"

HOME_NO_CLI=$(make_home no-cli)
OUT=$(PATH="/usr/bin:/bin" FM_HOME="$HOME_NO_CLI" "$STAMP" bd-1 agent-x 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a missing task CLI must still exit 0 (fail-open)"
printf '%s\n' "$OUT" | grep -Fq "task CLI not found" || fail "a missing task CLI did not warn: $OUT"
[ "$(queue_count "$HOME_NO_CLI")" = 0 ] || fail "a missing task CLI must not queue anything, there is no CLI to replay against later"
pass "fm-bead-stamp.sh exits 0 and warns when the task CLI is not on PATH, without queuing"

HOME_NO_AGENT=$(make_home no-agent)
FAKEBIN_NO_AGENT=$(make_fakebin no-agent)
cat > "$FAKEBIN_NO_AGENT/task" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN_NO_AGENT/task"
OUT=$(PATH="$FAKEBIN_NO_AGENT:$BASE_PATH" FM_HOME="$HOME_NO_AGENT" "$STAMP" bd-1 "" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "an empty agent name must still exit 0 (fail-open)"
printf '%s\n' "$OUT" | grep -Fq "no agent name given" || fail "an empty agent name did not warn: $OUT"
pass "fm-bead-stamp.sh exits 0 and warns when no agent name is given"

# --- store unreachable: queue all three writes ----------------------------

HOME_DOWN=$(make_home store-down)
FAKEBIN_DOWN=$(make_fakebin store-down)
cat > "$FAKEBIN_DOWN/task" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAKEBIN_DOWN/task"
OUT=$(PATH="$FAKEBIN_DOWN:$BASE_PATH" FM_HOME="$HOME_DOWN" "$STAMP" bd-1 agent-x 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a store-unreachable dispatch must still exit 0 (fail-open)"
printf '%s\n' "$OUT" | grep -Fq "beads store unreachable, queuing dispatch stamp for bd-1" \
  || fail "a store-unreachable dispatch did not warn as expected: $OUT"
[ "$(queue_count "$HOME_DOWN")" = 3 ] \
  || fail "a store-unreachable dispatch must queue all three writes (dispatch=sent, lifecycle=sent, assign), got $(queue_count "$HOME_DOWN")"
QUEUE="$HOME_DOWN/state/.beads-write-queue"
jq -e 'select(.task_id == "bd-1" and .description == "dispatch=sent" and (.argv == ["set-state","bd-1","dispatch=sent","--reason","dispatched: agent=agent-x"]))' "$QUEUE" >/dev/null \
  || fail "the queued dispatch=sent write has the wrong shape: $(cat "$QUEUE")"
jq -e 'select(.task_id == "bd-1" and .description == "lifecycle=sent" and (.argv == ["set-state","bd-1","lifecycle=sent","--reason","dispatched: agent=agent-x"]))' "$QUEUE" >/dev/null \
  || fail "the queued lifecycle=sent write has the wrong shape: $(cat "$QUEUE")"
jq -e 'select(.task_id == "bd-1" and .description == "assign agent-x" and (.argv == ["assign","bd-1","agent-x"]))' "$QUEUE" >/dev/null \
  || fail "the queued assign write has the wrong shape: $(cat "$QUEUE")"
pass "a store-unreachable dispatch queues all three writes durably for later replay, exact argv preserved"

# --- bead not found on a reachable store: no queuing ----------------------

HOME_NOT_FOUND=$(make_home not-found)
FAKEBIN_NOT_FOUND=$(make_fakebin not-found)
cat > "$FAKEBIN_NOT_FOUND/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'show bd-missing') exit 1 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN_NOT_FOUND/task"
OUT=$(PATH="$FAKEBIN_NOT_FOUND:$BASE_PATH" FM_HOME="$HOME_NOT_FOUND" "$STAMP" bd-missing agent-x 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a bead genuinely not found must still exit 0 (fail-open)"
printf '%s\n' "$OUT" | grep -Fq "bead bd-missing not found" || fail "a not-found bead did not warn as expected: $OUT"
[ "$(queue_count "$HOME_NOT_FOUND")" = 0 ] \
  || fail "a bead genuinely not found on a reachable store must not be queued, there is nothing to replay"
pass "a reachable store reporting the bead itself not found warns and does not queue anything"

# --- fully reachable store: no queuing, exact calls made ------------------

HOME_UP=$(make_home store-up)
FAKEBIN_UP=$(make_fakebin store-up)
LOG_UP="$TMP_ROOT/store-up.log"
cat > "$FAKEBIN_UP/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$LOG_UP"
case "\$*" in
  'list --limit 1') exit 0 ;;
  'show bd-1') exit 0 ;;
  'set-state bd-1 dispatch=sent --reason dispatched: agent=agent-x') exit 0 ;;
  'set-state bd-1 lifecycle=sent --reason dispatched: agent=agent-x') exit 0 ;;
  'assign bd-1 agent-x') exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN_UP/task"
OUT=$(PATH="$FAKEBIN_UP:$BASE_PATH" FM_HOME="$HOME_UP" "$STAMP" bd-1 agent-x 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a fully reachable store dispatch must exit 0: $OUT"
[ -z "$OUT" ] || fail "a fully successful dispatch should print no warnings: $OUT"
[ "$(queue_count "$HOME_UP")" = 0 ] || fail "a fully successful dispatch must not queue anything"
assert_grep "set-state bd-1 dispatch=sent --reason dispatched: agent=agent-x" "$LOG_UP" \
  "the live dispatch=sent call was never made against the reachable store"
assert_grep "set-state bd-1 lifecycle=sent --reason dispatched: agent=agent-x" "$LOG_UP" \
  "the live lifecycle=sent call was never made against the reachable store"
assert_grep "assign bd-1 agent-x" "$LOG_UP" \
  "the live assign call was never made against the reachable store"
pass "a fully reachable store makes all three live calls directly and queues nothing"

# --- reachable store, one write rejected: only that write is queued -------

HOME_PARTIAL=$(make_home store-partial)
FAKEBIN_PARTIAL=$(make_fakebin store-partial)
cat > "$FAKEBIN_PARTIAL/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'show bd-1') exit 0 ;;
  'set-state bd-1 dispatch=sent --reason dispatched: agent=agent-x') exit 1 ;;
  'set-state bd-1 lifecycle=sent --reason dispatched: agent=agent-x') exit 0 ;;
  'assign bd-1 agent-x') exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN_PARTIAL/task"
OUT=$(PATH="$FAKEBIN_PARTIAL:$BASE_PATH" FM_HOME="$HOME_PARTIAL" "$STAMP" bd-1 agent-x 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a partially rejected dispatch must still exit 0 (fail-open)"
printf '%s\n' "$OUT" | grep -Fq "could not set dispatch=sent on bead bd-1, queuing for retry" \
  || fail "the rejected dispatch=sent write did not warn as expected: $OUT"
[ "$(queue_count "$HOME_PARTIAL")" = 1 ] \
  || fail "only the one rejected write should be queued, the other two succeeded live; got $(queue_count "$HOME_PARTIAL")"
jq -e 'select(.task_id == "bd-1" and .description == "dispatch=sent")' "$HOME_PARTIAL/state/.beads-write-queue" >/dev/null \
  || fail "the write left queued after a partial rejection should be dispatch=sent: $(cat "$HOME_PARTIAL/state/.beads-write-queue")"
pass "a reachable store that rejects one write queues only that write, the other two are not duplicated"

echo "# fm-bead-stamp.test.sh: all assertions passed"
