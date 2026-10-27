#!/usr/bin/env bash
# tests/fm-lock-badge.test.sh - the herdr pane badge shown by bin/fm-lock.sh
# (bin/fm-lock-badge.sh): lock held and lock refused get different styling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-badge)

# A herdr stand-in that records its argv, one invocation per line.
make_world() {  # <name>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/state" "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/herdr.log"
SH
  chmod +x "$dir/fakebin/herdr"
  printf '%s' "$dir"
}

run_badge() {  # <dir> <mode> [pane]
  env -u HERDR_PANE_ID PATH="$1/fakebin:$PATH" HERDR_BIN_PATH="$1/fakebin/herdr" \
    ${3:+HERDR_PANE_ID=$3} "$ROOT/bin/fm-lock-badge.sh" "$2"
}

test_held_and_refused_style_differently() {
  local dir held refused
  dir=$(make_world held-refused)
  run_badge "$dir" held %7
  held=$(cat "$dir/herdr.log")
  : > "$dir/herdr.log"
  run_badge "$dir" refused %7
  refused=$(cat "$dir/herdr.log")
  case "$held" in *"--token lock_held="*"--clear-token lock_ro"*"firstmate (lock)"*" %7") ;; *) fail "held badge wrong: $held" ;; esac
  case "$refused" in *"--token lock_ro="*"--clear-token lock_held"*"firstmate (read-only)"*" %7") ;; *) fail "refused badge wrong: $refused" ;; esac
  [ "$held" != "$refused" ] || fail "held and refused badges are identical"
  pass "held and refused set different tokens and labels"
}

test_clear_drops_both() {
  local dir out
  dir=$(make_world clear)
  run_badge "$dir" clear %7
  out=$(cat "$dir/herdr.log")
  case "$out" in *"--clear-token lock_held"*"--clear-token lock_ro"*"--clear-display-agent"*) ;; *) fail "clear wrong: $out" ;; esac
  pass "clear drops both badges"
}

test_noop_outside_herdr() {
  local dir
  dir=$(make_world nopane)
  run_badge "$dir" held || fail "badge failed outside herdr"
  [ ! -e "$dir/herdr.log" ] || fail "herdr called without HERDR_PANE_ID"
  pass "no herdr call outside a herdr pane"
}

# fm-lock.sh end to end: a free lock badges held, a live foreign holder badges refused.
test_fm_lock_reports_outcome() {
  local dir holder rc
  dir=$(make_world lock-e2e)
  # Harness-named stand-ins: the lock only trusts harness-named ancestry.
  ln -s /bin/bash "$dir/fakebin/claude"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$dir/fakebin:$PATH" HERDR_PANE_ID=%1 \
    HERDR_BIN_PATH="$dir/fakebin/herdr" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$dir/fakebin/claude" -c "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  grep -q -- '--token lock_held=' "$dir/herdr.log" 2>/dev/null || { echo "log: $(cat "$dir/herdr.log" 2>/dev/null)"; fail "fm-lock.sh did not badge a free lock as held"; }
  # A live harness-named process that is not an ancestor of the next acquirer
  # holds the lock, so a second session is refused and badges read-only.
  "$dir/fakebin/claude" -c 'sleep 30; :' >/dev/null 2>&1 &
  holder=$!
  sleep 1
  printf '%s\n' "$holder" > "$dir/state/.lock"
  rm -f "$dir/state/.lock-session"
  : > "$dir/herdr.log"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$dir/fakebin:$PATH" HERDR_PANE_ID=%1 \
    HERDR_BIN_PATH="$dir/fakebin/herdr" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$dir/fakebin/claude" -c "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  rc=$?
  kill "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "second session was not refused"
  grep -q -- '--token lock_ro=' "$dir/herdr.log" || { echo "log: $(cat "$dir/herdr.log")"; fail "refused session not badged read-only"; }
  grep -q -- '--token lock_held=' "$dir/herdr.log" && fail "refused session also badged held"
  pass "fm-lock.sh badges held when free and read-only when refused"
}

test_held_and_refused_style_differently
test_clear_drops_both
test_noop_outside_herdr
test_fm_lock_reports_outcome
