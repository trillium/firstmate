#!/usr/bin/env bash
# fm-send --raw: best-effort escape hatch for a raw/unmanaged pane.
#
# The default text path verifies delivery by reading the target's agent
# composer, so it fails closed on a bare shell pane that has no state/<id>.meta
# and no composer. --raw dispatches the backend's atomic type-then-Enter
# primitive instead: a loud, documented best-effort send with no submit proof.
# These tests pin that the escape hatch sends on a no-meta explicit target,
# refuses the nonsensical --raw --key combination, and surfaces a raw send
# failure loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-raw)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_SEND_FAIL:-}" ]; then
      exit 1
    fi
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_raw_sends_to_unmanaged_pane() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/raw-ok"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home rawok); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  # sess:win has no recorded meta; the default path would fail closed. --raw
  # sends best-effort via the backend's atomic type-then-Enter primitive.
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win --raw "drive the demo" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "raw send to a live no-meta explicit target should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:win literal=0 arg=drive the demo" "raw send should type text and submit atomically to the explicit target"
  pass "fm-send --raw: best-effort send drives a raw/unmanaged pane with no meta"
}

test_raw_with_key_rejected() {
  local dir fb home err rc
  dir="$TMP_ROOT/raw-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home rawkey); err="$dir/send.err"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" sess:win --raw --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--raw --key should be rejected"
  assert_contains "$(cat "$err")" "--raw cannot be combined with --key" "combination diagnostic should be explicit"
  pass "fm-send --raw: refuses the nonsensical --raw --key combination"
}

test_raw_send_failure_is_loud() {
  local dir fb home err log rc
  dir="$TMP_ROOT/raw-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home rawfail); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_SEND_FAIL=1 FM_SEND_SETTLE=0 \
    "$SEND" sess:win --raw "drive the demo" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "raw send should fail loudly when the backend send fails"
  assert_contains "$(cat "$err")" "raw text not sent to sess:win" "raw send failure diagnostic should be loud"
  pass "fm-send --raw: a failed backend send is surfaced as a hard error"
}

test_raw_sends_to_unmanaged_pane
test_raw_with_key_rejected
test_raw_send_failure_is_loud
