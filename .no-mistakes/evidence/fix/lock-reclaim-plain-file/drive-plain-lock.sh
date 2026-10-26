#!/usr/bin/env bash
# Live driver: real fm-wake-lib.sh wake-queue append against a plain-file lock.
# usage: drive-plain-lock.sh <bin-dir> <label>
export BIN=$1; LABEL=$2
run() { # name, setup, body
  local T; T=$(mktemp -d); mkdir -p "$T/state"; export FM_STATE_OVERRIDE="$T/state"
  echo "=== [$LABEL] $1"; eval "$2"
  ( cd "$T"; eval "$3" ); echo "exit=$?"
  echo "lock path: $(ls -la "$T/state/.wake-queue.lock" 2>&1 | awk '{print $1}')  steal-markers: $(ls -a "$T/state" | grep -c steal)"
  [ -f "$T/state/.wake-queue" ] && echo "queue rows: $(wc -l < "$T/state/.wake-queue")"
  rm -rf "$T"
}
APPEND='timeout 8 bash -c ". \"\$BIN/fm-wake-lib.sh\"; s=\$SECONDS; fm_wake_append heartbeat hb payload && echo appended after \$((SECONDS-s))s"'
run "S1 stale 0-byte plain .wake-queue.lock" ': > "$T/state/.wake-queue.lock"; touch -t 200001010000 "$T/state/.wake-queue.lock"' "$APPEND"
run "S2 fresh plain .wake-queue.lock (must wait out grace, then acquire)" ': > "$T/state/.wake-queue.lock"' "$APPEND"
run "S3 live symlink holder (must not be stolen)" '' '
  FM_STATE_OVERRIDE="$FM_STATE_OVERRIDE" bash -c ". \"$BIN/fm-wake-lib.sh\"; fm_lock_try_acquire \"\$STATE/.wake-queue.lock\" && sleep 6" & h=$!; sleep 0.5
  before=$(readlink "$FM_STATE_OVERRIDE/.wake-queue.lock"); timeout 3 bash -c ". \"$BIN/fm-wake-lib.sh\"; fm_wake_append heartbeat hb p"; echo "waiter rc=$? (124=still waiting, correct)"
  after=$(readlink "$FM_STATE_OVERRIDE/.wake-queue.lock"); [ "$before" = "$after" ] && echo "holder symlink intact: $after"; kill $h; wait $h 2>/dev/null; true'
run "S4 40 concurrent try_acquire on stale plain file" ': > "$T/state/.wake-queue.lock"; touch -t 200001010000 "$T/state/.wake-queue.lock"' '
  for i in $(seq 40); do bash -c ". \"$BIN/fm-wake-lib.sh\"; fm_lock_try_acquire \"\$STATE/.wake-queue.lock\" && { echo win >> wins; sleep 1; }" & done; wait; echo "winners=$(wc -l < wins 2>/dev/null || echo 0)"'
run "S5 adversarial: dead stealer left .steal + stale plain file" ': > "$T/state/.wake-queue.lock"; touch -t 200001010000 "$T/state/.wake-queue.lock"
  FM_STATE_OVERRIDE="$FM_STATE_OVERRIDE" bash -c ". \"$BIN/fm-wake-lib.sh\"; fm_lock_try_acquire \"\$STATE/.wake-queue.lock.steal\"; readlink \"\$STATE/.wake-queue.lock.steal\""; touch -h -t 200001010000 "$T/state/.wake-queue.lock.steal" 2>/dev/null; echo "dead stealer pid in .steal: $(cat "$T/state/.wake-queue.lock.steal/pid")"' '
  timeout 8 bash -c ". \"$BIN/fm-wake-lib.sh\"; fm_lock_try_acquire \"\$STATE/.wake-queue.lock\"; echo \"try rc=\$? FM_LOCK_RECOVERED_PID=[\${FM_LOCK_RECOVERED_PID:-}] steal.steal exists=\$([ -e \"\$STATE/.wake-queue.lock.steal.steal\" -o -L \"\$STATE/.wake-queue.lock.steal.steal\" ] && echo yes || echo no)\""'
