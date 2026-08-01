#!/usr/bin/env bash
# fm-send post-submit transition verification (FM_SEND_VERIFY_TRANSITION).
#
# fm-send's plain success only proves the composer cleared - the Enter landed and
# the text was submitted. It does NOT prove the receiving agent actually started
# a turn: a prior incident had a message staged in a composer that never executed.
# FM_SEND_VERIFY_TRANSITION=1 adds a post-submit assertion that polls the target's
# busy state and confirms the turn transitioned idle->working, failing loudly when
# the pane stays idle. These tests pin that behavior hermetically (stubbed tmux, no
# real agent):
#   1. Off by default: an idle pane after submit still succeeds (opt-in, no regression).
#   2. On + pane goes busy: the turn is confirmed started and fm-send succeeds.
#   3. On + pane stays idle: fm-send fails loudly with "SEND DID NOT LAND ... remains idle".
#   4. On + verification read fails ("unknown"): composer cleared, so fm-send proceeds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-verify-transition)

# A fake tmux that lets fm-send's submit path reach a clean "empty" verdict, then
# answers the post-submit busy scan per FM_FAKE_MODE:
#   working  -> the -40 busy scan shows a matching busy footer (turn started)
#   idle     -> the -40 busy scan shows a quiet prompt (turn never started)
#   readfail -> the verify read probe (capture-pane -S -1) fails (unverifiable)
# The composer capture (-S 0 / -S <cy>) always returns an empty bordered box so
# fm_tmux_composer_state reads "empty" (submit landed) on the first Enter.
make_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${1:-}
# Find the -S value, if any, to distinguish composer/read-probe/busy-scan reads.
sflag=""
prev=""
for a in "$@"; do
  [ "$prev" = "-S" ] && sflag=$a
  prev=$a
done
case "$cmd" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    case "$sflag" in
      -40)
        # post-submit busy scan
        if [ "${FM_FAKE_MODE:-idle}" = working ]; then
          printf 'assistant is thinking\nesc to interrupt\n'
        else
          printf 'idle prompt > \n'
        fi
        exit 0 ;;
      -1)
        # verify read probe: fail only in readfail mode
        [ "${FM_FAKE_MODE:-idle}" = readfail ] && exit 1
        printf 'idle prompt > \n'; exit 0 ;;
      *)
        # composer reads: an empty bordered box -> "empty" verdict
        printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
    esac ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <mode> [env...] -- echoes combined stdout+stderr, sets RC.
run_send() {
  local fb=$1 mode=$2 home; shift 2
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  # FM_SEND_SETTLE=0 keeps the success path fast; FM_SEND_VERIFY_TIMEOUT small so
  # the idle branch resolves in a couple of real 0.2s polls.
  env "$@" PATH="$fb:$PATH" FM_FAKE_MODE="$mode" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    "$SEND" "sess:win" "hello captain" 2>&1
}

test_off_by_default_idle_still_succeeds() {
  local dir fb out rc
  dir="$TMP_ROOT/off"; mkdir -p "$dir"; fb=$(make_stub "$dir")
  out=$(run_send "$fb" idle); rc=$?
  expect_code 0 "$rc" "verification off + idle pane must still succeed (opt-in)"
  pass "fm-send: transition verification is off by default (idle pane still succeeds)"
}

test_on_working_succeeds() {
  local dir fb out rc
  dir="$TMP_ROOT/working"; mkdir -p "$dir"; fb=$(make_stub "$dir")
  out=$(run_send "$fb" working FM_SEND_VERIFY_TRANSITION=1 FM_SEND_VERIFY_TIMEOUT=0.4); rc=$?
  expect_code 0 "$rc" "verification on + pane goes busy must succeed"$'\n'"$out"
  pass "fm-send: verification confirms the turn started when the pane goes busy"
}

test_on_idle_fails_loudly() {
  local dir fb out rc
  dir="$TMP_ROOT/idle"; mkdir -p "$dir"; fb=$(make_stub "$dir")
  out=$(run_send "$fb" idle FM_SEND_VERIFY_TRANSITION=1 FM_SEND_VERIFY_TIMEOUT=0.4); rc=$?
  expect_code 1 "$rc" "verification on + pane stays idle must fail loudly"$'\n'"$out"
  case "$out" in
    *"SEND DID NOT LAND"*"remains idle"*) ;;
    *) fail "idle branch: expected 'SEND DID NOT LAND ... remains idle', got:"$'\n'"$out" ;;
  esac
  pass "fm-send: verification fails loudly when the submitted turn never starts (stays idle)"
}

test_on_unknown_proceeds() {
  local dir fb out rc
  dir="$TMP_ROOT/unknown"; mkdir -p "$dir"; fb=$(make_stub "$dir")
  out=$(run_send "$fb" readfail FM_SEND_VERIFY_TRANSITION=1 FM_SEND_VERIFY_TIMEOUT=0.4); rc=$?
  expect_code 0 "$rc" "verification on + unverifiable read (unknown) must proceed"$'\n'"$out"
  pass "fm-send: verification proceeds when the turn cannot be verified but the composer cleared"
}

test_off_by_default_idle_still_succeeds
test_on_working_succeeds
test_on_idle_fails_loudly
test_on_unknown_proceeds
