#!/usr/bin/env bash
# tests/fm-beads-resilience-lib.test.sh - unit tests for the beads read-side
# mirror and durable write queue (bin/fm-beads-resilience-lib.sh), the
# beads-authority-migration Stage 5 resilience layer (report.md section 5).
# Exercises the library's own functions directly rather than through a caller,
# since fm-session-start.test.sh, fm-fleet-snapshot-view.test.sh, and
# fm-bootstrap.test.sh already cover the caller-facing mirror-fallback and
# MISSING:/DEGRADED: escalation behavior end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-beads-resilience-lib-tests)

FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state"
export FM_HOME
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_ROOT STATE 2>/dev/null || true

# fm_beads_close_already_applied reads status through fm_beads_status, which
# lives in fm-tasks-axi-lib.sh (the one owner of the `task show --json` array
# unwrap). The runtime callers (bin/fm-bootstrap.sh, bin/fm-session-start.sh)
# source both libs together, so this test does too.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-beads-resilience-lib.sh
. "$ROOT/bin/fm-beads-resilience-lib.sh"

# --- read-side mirror ---------------------------------------------------

fm_beads_mirror_read missing-view >/dev/null 2>&1 &&
  fail "reading a mirror that was never written should fail"
pass "fm_beads_mirror_read fails closed when no mirror has ever been written for a view"

fm_beads_mirror_write ready $'ready-task-1\nready-task-2' \
  || fail "fm_beads_mirror_write should succeed on a fresh state dir"
[ -f "$FM_HOME/state/.beads-mirror-ready.json" ] \
  || fail "fm_beads_mirror_write did not create state/.beads-mirror-<view>.json"
GOT=$(fm_beads_mirror_read ready) || fail "fm_beads_mirror_read failed right after a successful write"
[ "$GOT" = $'ready-task-1\nready-task-2' ] \
  || fail "fm_beads_mirror_read did not round-trip the exact raw output written: got '$GOT'"
pass "fm_beads_mirror_write/fm_beads_mirror_read round-trip the exact raw output of a successful read"

fm_beads_mirror_fresh ready 900 || fail "a just-written mirror must be fresh under a 900s threshold"
pass "fm_beads_mirror_fresh accepts a just-written mirror under an ordinary threshold"

sleep 1
fm_beads_mirror_fresh ready 0 && fail "a mirror older than a 0s threshold must not be reported fresh"
pass "fm_beads_mirror_fresh rejects a mirror once it exceeds the given max age"

ISO=$(fm_beads_mirror_timestamp_iso ready) || fail "fm_beads_mirror_timestamp_iso failed on an existing mirror"
case "$ISO" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
  *) fail "fm_beads_mirror_timestamp_iso did not return a UTC ISO-8601 timestamp: $ISO" ;;
esac
pass "fm_beads_mirror_timestamp_iso reports the mirror's write time as a UTC ISO-8601 timestamp"

FM_HOME_UNWRITTEN="$TMP_ROOT/home-empty"
mkdir -p "$FM_HOME_UNWRITTEN/state"
FM_HOME="$FM_HOME_UNWRITTEN" FM_STATE_OVERRIDE="$FM_HOME_UNWRITTEN/state" bash -c '
  set -u
  # shellcheck source=bin/fm-beads-resilience-lib.sh
  . "$1/bin/fm-beads-resilience-lib.sh"
  fm_beads_mirror_freshest_iso 900 >/dev/null 2>&1 && exit 1
  exit 0
' _ "$ROOT" \
  || fail "an empty state dir with no mirrors must report no freshest timestamp"
pass "fm_beads_mirror_freshest_iso correctly reports absence when no mirror exists"

sleep 1
fm_beads_mirror_write fleet 'fleet-record-1'
FRESHEST=$(fm_beads_mirror_freshest_iso 900) || fail "fm_beads_mirror_freshest_iso failed with two fresh mirrors"
[ "$FRESHEST" = "$(fm_beads_mirror_timestamp_iso fleet)" ] \
  || fail "fm_beads_mirror_freshest_iso should pick the more recently written of two fresh views, got $FRESHEST"
pass "fm_beads_mirror_freshest_iso picks the freshest of multiple known mirror views"

# --- write-side durable queue --------------------------------------------

[ "$(fm_beads_write_queue_count)" = 0 ] || fail "a fresh state dir must start with an empty write queue"

fm_beads_write_enqueue bd-1 "close bd-1" close bd-1 --reason "done" \
  || fail "fm_beads_write_enqueue failed on a well-formed call"
[ "$(fm_beads_write_queue_count)" = 1 ] || fail "enqueuing one write should bring the queue count to 1"
QUEUE_LINE=$(cat "$FM_HOME/state/.beads-write-queue")
printf '%s' "$QUEUE_LINE" | jq -e '
  .task_id == "bd-1" and .description == "close bd-1" and (.argv == ["close","bd-1","--reason","done"])
' >/dev/null || fail "queued write record has the wrong shape: $QUEUE_LINE"
pass "fm_beads_write_enqueue appends a durable JSON record with task_id, description, and the exact task argv"

fm_beads_write_enqueue bd-2 "assign bd-2" assign bd-2 crewmate-x \
  || fail "a second enqueue call failed"
[ "$(fm_beads_write_queue_count)" = 2 ] || fail "a second enqueue should bring the queue count to 2"
pass "fm_beads_write_enqueue appends without disturbing an already-queued write"

# fake `task` CLI directing behavior per FM_FAKE_TASK_MODE:
#   down     - every call fails (store unreachable)
#   partial  - the store is reachable but the bd-1 close still fails (e.g. a
#              genuine conflict: `show bd-1 --json` reports it still open),
#              bd-2's assign succeeds
#   up       - every call succeeds
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/task" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_FAKE_TASK_MODE:?}
log=${FM_FAKE_TASK_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
[ "$mode" = down ] && exit 7
case "$*" in
  'list --limit 1') exit 0 ;;
  'close bd-1 --reason done')
    [ "$mode" = up ] && exit 0
    exit 1
    ;;
  'show bd-1 --json') printf '%s\n' '[{"id":"bd-1","status":"open"}]'; exit 0 ;;
  'assign bd-2 crewmate-x') exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/task"

OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_TASK_MODE=down fm_beads_write_queue_reconcile 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "reconcile must fail while the store is unreachable"
printf '%s\n' "$OUT" | grep -Fq "store still unreachable" \
  || fail "reconcile did not report the store as still unreachable: $OUT"
[ "$(fm_beads_write_queue_count)" = 2 ] || fail "an unreachable store must leave the queue untouched"
pass "fm_beads_write_queue_reconcile reports an unreachable store and leaves the queue untouched"

LOG="$TMP_ROOT/task-partial.log"
OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_TASK_MODE=partial FM_FAKE_TASK_LOG="$LOG" fm_beads_write_queue_reconcile 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "reconcile must report failure while any queued write still fails to replay"
printf '%s\n' "$OUT" | grep -Fq "reconciled queued write for bd-2" \
  || fail "reconcile did not report bd-2's successful replay: $OUT"
printf '%s\n' "$OUT" | grep -Fq "replay failed for bd-1" \
  || fail "reconcile did not report bd-1's failed replay: $OUT"
[ "$(fm_beads_write_queue_count)" = 1 ] \
  || fail "a partial reconcile must drop the succeeded write and keep only the failed one queued"
QUEUE_LINE=$(cat "$FM_HOME/state/.beads-write-queue")
printf '%s' "$QUEUE_LINE" | jq -e '.task_id == "bd-1"' >/dev/null \
  || fail "the write left in the queue after a partial reconcile should be bd-1's failed close: $QUEUE_LINE"
pass "fm_beads_write_queue_reconcile replays each queued write independently, dropping successes and re-queuing failures"

OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_TASK_MODE=up fm_beads_write_queue_reconcile 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "reconcile must succeed once the store fully recovers: $OUT"
printf '%s\n' "$OUT" | grep -Fq "reconciled queued write for bd-1" \
  || fail "reconcile did not report bd-1's replay once the store recovered: $OUT"
[ "$(fm_beads_write_queue_count)" = 0 ] || fail "a fully successful reconcile must drain the write queue to empty"
pass "fm_beads_write_queue_reconcile drains the queue completely once the store recovers"

fm_beads_write_queue_reconcile
RC=$?
[ "$RC" -eq 0 ] || fail "reconcile on an already-empty queue must be a no-op success"
pass "fm_beads_write_queue_reconcile is a no-op success on an already-empty queue"

# --- idempotent close reconciliation --------------------------------------
# A queued close whose replay still fails must not be re-queued forever when
# the live store shows the bead is already gone (or already closed) - only a
# genuine conflict (bead still open) is a real replay failure.

FM_BEADS_WRITE_QUEUE="$TMP_ROOT/close-idempotent-queue"
FM_BEADS_WRITE_QUEUE_LOCK="$TMP_ROOT/close-idempotent-queue.lock"

FAKEBIN_CLOSE="$TMP_ROOT/fakebin-close-idempotent"
mkdir -p "$FAKEBIN_CLOSE"
cat > "$FAKEBIN_CLOSE/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'close bd-closed --reason done') exit 1 ;;
  'show bd-closed --json') printf '%s\n' '[{"id":"bd-closed","status":"closed"}]'; exit 0 ;;
  'close bd-gone --reason done') exit 1 ;;
  'show bd-gone --json') exit 1 ;;
  'close bd-open --reason done') exit 1 ;;
  'show bd-open --json') printf '%s\n' '[{"id":"bd-open","status":"open"}]'; exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN_CLOSE/task"

fm_beads_write_enqueue bd-closed "close bd-closed" close bd-closed --reason "done" \
  || fail "enqueue for the already-closed-bead scenario failed"
OUT=$(PATH="$FAKEBIN_CLOSE:$BASE_PATH" fm_beads_write_queue_reconcile 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "reconcile must succeed when the only queued close is already applied: $OUT"
printf '%s\n' "$OUT" | grep -Fq "reconciled queued write for bd-closed" \
  || fail "reconcile did not report bd-closed as reconciled: $OUT"
printf '%s\n' "$OUT" | grep -Fq "bead already closed" \
  || fail "reconcile did not label bd-closed's reconciliation as an already-closed bead: $OUT"
[ "$(fm_beads_write_queue_count)" = 0 ] \
  || fail "a queued close whose bead is already closed on the live store must not remain queued"
pass "fm_beads_write_queue_reconcile reconciles a queued close when the live store reports the bead already closed"

fm_beads_write_enqueue bd-gone "close bd-gone" close bd-gone --reason "done" \
  || fail "enqueue for the bead-absent scenario failed"
OUT=$(PATH="$FAKEBIN_CLOSE:$BASE_PATH" fm_beads_write_queue_reconcile 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "reconcile must succeed when the only queued close targets a now-absent bead: $OUT"
printf '%s\n' "$OUT" | grep -Fq "bead already closed" \
  || fail "reconcile did not label bd-gone's reconciliation: $OUT"
[ "$(fm_beads_write_queue_count)" = 0 ] \
  || fail "a queued close targeting an absent bead must not remain queued"
pass "fm_beads_write_queue_reconcile reconciles a queued close when the bead itself is absent from the live store"

fm_beads_write_enqueue bd-open "close bd-open" close bd-open --reason "done" \
  || fail "enqueue for the genuine-conflict scenario failed"
OUT=$(PATH="$FAKEBIN_CLOSE:$BASE_PATH" fm_beads_write_queue_reconcile 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "reconcile must report failure when the queued close's bead is still open: $OUT"
printf '%s\n' "$OUT" | grep -Fq "replay failed for bd-open" \
  || fail "reconcile did not report bd-open's genuine replay failure: $OUT"
[ "$(fm_beads_write_queue_count)" = 1 ] \
  || fail "a queued close whose bead is still open must remain queued as a genuine conflict"
pass "fm_beads_write_queue_reconcile re-queues a queued close whose bead is still open on the live store, a genuine conflict"

echo "# fm-beads-resilience-lib.test.sh: all assertions passed"
