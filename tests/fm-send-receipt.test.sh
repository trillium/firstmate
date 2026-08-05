#!/usr/bin/env bash
# fm-send delivery receipt: a zero exit must carry positive proof of delivery.
#
# fm-send runs bin/fm-guard.sh first, so its stderr can already hold a loud
# supervision banner by the time the send itself happens. Without a receipt, a
# caller reading the tail of that output sees only the banner and cannot tell a
# delivered message from one that never arrived - a real miss, where two routing
# sends were reported as delivered and left no trace at all. These tests pin the
# receipt contract on every send path:
#   1. The verified text path prints one `ok:` line LAST, even under a banner.
#   2. A marked secondmate send names its pending correlation id, because
#      delivery is not a reply.
#   3. An unconfirmed submit exits non-zero and prints NO receipt.
#   4. The --key path and the unverified --raw escape hatch print their own
#      receipts, and --raw's says plainly that nothing was verified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-receipt)
fm_git_identity fmtest fmtest@example.invalid

# A fake tmux that lets fm-send's submit path reach a clean "empty" verdict:
# display-message yields a numeric cursor_y and capture-pane returns an empty
# bordered composer, so the first Enter reads as submitted. Set
# FM_FAKE_COMPOSER_DIRTY=1 to return a composer with text still in it, which is
# how the submit path reports an unconfirmed delivery.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_COMPOSER_DIRTY:-}" ]; then
      printf '╭────╮\n│ hi │\n╰────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
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

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# run_send <fakebin> <home> <root> <errfile> -- <fm-send args...>
# <root> is FM_ROOT_OVERRIDE, so a caller can point the tangle guard at a real
# repo and prove the receipt still survives underneath a printed banner.
run_send() {
  local fb=$1 home=$2 root=$3 err=$4; shift 4
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_SEND_SETTLE=0 \
    "$SEND" "$@" >/dev/null 2>"$err"
}

# The last non-empty line of a file.
last_line() {
  grep -v '^[[:space:]]*$' "$1" | tail -1
}

test_receipt_survives_a_guard_banner() {
  local dir fb home repo err rc
  dir="$TMP_ROOT/banner"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home banner); err="$dir/send.err"
  # A primary checkout stranded on a feature branch: the tangle banner fires.
  repo="$dir/primary"
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" checkout -q -B fm/tangled-jj1

  fm_write_meta "$home/state/alpha.meta" \
    "window=firstmate:fm-alpha" "endpoint_task_id=alpha" "harness=echo" "kind=ship"
  run_send "$fb" "$home" "$repo" "$err" "fm-alpha" "keep going"; rc=$?
  expect_code 0 "$rc" "a verified send should succeed"
  assert_contains "$(cat "$err")" "WORKTREE TANGLE" \
    "this case is only meaningful while the guard banner actually prints"
  assert_contains "$(last_line "$err")" "ok: text delivered and submitted to" \
    "the delivery receipt must be the LAST line, not swallowed by the banner above it"
  pass "fm-send: a delivered message reports itself as the last line even under a guard banner"
}

test_secondmate_receipt_names_the_open_expectation() {
  local dir fb home err rc got
  dir="$TMP_ROOT/corr"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home corr); err="$dir/send.err"
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"

  run_send "$fb" "$home" "$home" "$err" "fm-domain" "route this work"; rc=$?
  expect_code 0 "$rc" "a verified secondmate send should succeed"
  got=$(last_line "$err")
  assert_contains "$got" "ok: text delivered and submitted to" "secondmate send printed no receipt"
  assert_contains "$got" "awaiting reply corr=" \
    "the receipt must say delivery is not a reply and name the open expectation"
  pass "fm-send: a marked secondmate receipt names the still-open reply expectation"
}

test_unconfirmed_submit_prints_no_receipt() {
  local dir fb home err rc got
  dir="$TMP_ROOT/unconfirmed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unconfirmed); err="$dir/send.err"
  fm_write_meta "$home/state/alpha.meta" \
    "window=firstmate:fm-alpha" "endpoint_task_id=alpha" "harness=echo" "kind=ship"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    FM_FAKE_COMPOSER_DIRTY=1 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 \
    "$SEND" "fm-alpha" "keep going" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed submit must exit non-zero"
  got=$(cat "$err")
  assert_not_contains "$got" "ok: text delivered" "a message that did not land must never print a delivery receipt"
  assert_contains "$got" "not submitted" "an unconfirmed submit must say so"
  pass "fm-send: an unconfirmed submit exits non-zero with no delivery receipt"
}

test_key_and_raw_receipts() {
  local dir fb home err rc
  dir="$TMP_ROOT/key-raw"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyraw); err="$dir/send.err"
  fm_write_meta "$home/state/alpha.meta" \
    "window=firstmate:fm-alpha" "endpoint_task_id=alpha" "harness=echo" "kind=ship"

  run_send "$fb" "$home" "$home" "$err" "fm-alpha" --key Enter; rc=$?
  expect_code 0 "$rc" "a key send should succeed"
  assert_contains "$(last_line "$err")" "ok: key 'Enter' sent to" "the key path printed no receipt"

  run_send "$fb" "$home" "$home" "$err" "sess:win" --raw "drive the demo"; rc=$?
  expect_code 0 "$rc" "a raw send to a live no-meta target should succeed"
  assert_contains "$(last_line "$err")" "delivery NOT verified" \
    "the raw escape hatch must state that its zero exit proves nothing about delivery"
  pass "fm-send: the key path and the unverified --raw escape hatch each print an honest receipt"
}

test_receipt_survives_a_guard_banner
test_secondmate_receipt_names_the_open_expectation
test_unconfirmed_submit_prints_no_receipt
test_key_and_raw_receipts
