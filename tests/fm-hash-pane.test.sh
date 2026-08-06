#!/usr/bin/env bash
# tests/fm-hash-pane.test.sh - bin/fm-watch.sh's hash_pane() tool-resolution
# fallback chain. hash_pane() only feeds poll-to-poll change detection, so any
# tool that yields a stable token is interchangeable; these tests confirm the
# fallback chain never hard-errors when a watcher's PATH is missing md5 and
# md5sum (observed on a secondmate whose runtime PATH omitted both, causing
# repeated watcher FAILED cycles that needed manual restarts).
#
# Each case builds a minimal PATH from symlinks to individually resolved
# binaries rather than trimming directories out of the ambient PATH: on at
# least one dev machine md5, md5sum, and openssl are all symlinked from the
# same homebrew bin directory, so removing "the directory containing md5"
# would silently remove openssl too and defeat the tier being tested.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hash-pane)

# Resolve real tool paths once, before any test narrows PATH.
REAL_CUT=$(command -v cut) || fail "cut not found on the test host"
REAL_TR=$(command -v tr) || fail "tr not found on the test host"
REAL_OD=$(command -v od) || fail "od not found on the test host"
REAL_AWK=$(command -v awk) || fail "awk not found on the test host"
REAL_CAT=$(command -v cat) || fail "cat not found on the test host"
REAL_OPENSSL=$(command -v openssl || true)
REAL_SHASUM=$(command -v shasum || true)
REAL_CKSUM=$(command -v cksum || true)
REAL_MD5SUM=$(command -v md5sum || true)

# make_fakebin <dir> [tool=path ...]: symlink each named tool from its
# resolved absolute path into <dir>, plus cut/tr/od/awk/cat always
# (hash_pane's fallback tiers, including the pure-shell last resort, pipe
# through them; cat also backs make_fake_sbin_md5's stand-in script).
# Echoes <dir>.
make_fakebin() {
  local dir=$1 spec tool src
  shift
  mkdir -p "$dir"
  ln -sf "$REAL_CUT" "$dir/cut"
  ln -sf "$REAL_TR" "$dir/tr"
  ln -sf "$REAL_OD" "$dir/od"
  ln -sf "$REAL_AWK" "$dir/awk"
  ln -sf "$REAL_CAT" "$dir/cat"
  for spec in "$@"; do
    tool=${spec%%=*}
    src=${spec#*=}
    [ -n "$src" ] || fail "make_fakebin: no resolved path for $tool on this host"
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# make_fake_sbin_md5 <path>: write an executable stand-in for `md5 -q` at
# <path> that ignores its arguments and echoes stdin back with a fixed tag
# prefix. hash_pane only needs the sbin-md5 tier to yield a token that is
# stable for identical input and distinct for different input, so this
# avoids depending on the test host actually having /sbin/md5 (absent on
# non-BSD CI runners) or any ambient `md5` binary. Echoes <path>.
make_fake_sbin_md5() {
  local path=$1
  cat > "$path" <<'FAKE_MD5'
#!/bin/sh
printf 'faux-sbin-md5:'
cat
FAKE_MD5
  chmod +x "$path"
  printf '%s\n' "$path"
}

# source_watch <home>: source fm-watch.sh's function definitions into the
# current shell without running its main-entry watcher loop (fm-watch.sh
# returns early when sourced; see its "Main entry" guard).
source_watch() {
  local home=$1
  FM_HOME="$home"
  FM_STATE_OVERRIDE="$home/state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
}

test_hash_pane_stable_and_distinct_via_sbin_md5() (
  local home fakebin fake_sbin_md5 out status
  home="$TMP_ROOT/sbin-md5"
  mkdir -p "$home"
  source_watch "$home"
  fakebin=$(make_fakebin "$home/fakebin")
  fake_sbin_md5=$(make_fake_sbin_md5 "$home/fake-sbin-md5")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$fake_sbin_md5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit via the sbin md5 tier"
  [ -n "$out" ] || fail "hash_pane produced empty output via the sbin md5 tier"
  [ "$out" = "$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$fake_sbin_md5" hash_pane <<<"pane text a")" ] \
    || fail "hash_pane is not stable for identical input via the sbin md5 tier"
  [ "$out" != "$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$fake_sbin_md5" hash_pane <<<"pane text b")" ] \
    || fail "hash_pane produced the same hash for different input via the sbin md5 tier"
  pass "hash_pane returns a stable, input-sensitive hash via the sbin md5 tier"
)

test_hash_pane_falls_back_to_openssl_without_md5_or_md5sum() (
  local home fakebin out expected status
  home="$TMP_ROOT/no-md5-no-md5sum"
  mkdir -p "$home"
  source_watch "$home"
  [ -n "$REAL_OPENSSL" ] || fail "openssl not available to exercise the fallback tier"
  fakebin=$(make_fakebin "$home/fakebin" "openssl=$REAL_OPENSSL")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit with md5/md5sum absent from PATH"
  [ -n "$out" ] || fail "hash_pane produced empty output with md5/md5sum absent from PATH"
  expected=$(printf 'pane text a\n' | "$REAL_OPENSSL" dgst -md5 -r | "$REAL_CUT" -d' ' -f1)
  [ "$out" = "$expected" ] \
    || fail "hash_pane did not use the openssl fallback tier when md5/md5sum are unresolvable (got '$out', wanted '$expected')"
  pass "hash_pane falls back to openssl and exits cleanly when md5 and md5sum are absent from PATH"
)

test_hash_pane_falls_back_past_openssl_to_shasum() (
  local home fakebin out expected status
  home="$TMP_ROOT/no-md5-no-openssl"
  mkdir -p "$home"
  source_watch "$home"
  [ -n "$REAL_SHASUM" ] || fail "shasum not available to exercise the fallback tier"
  fakebin=$(make_fakebin "$home/fakebin" "shasum=$REAL_SHASUM")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit with md5/md5sum/openssl absent from PATH"
  [ -n "$out" ] || fail "hash_pane produced empty output with md5/md5sum/openssl absent from PATH"
  expected=$(printf 'pane text a\n' | "$REAL_SHASUM" | "$REAL_CUT" -d' ' -f1)
  [ "$out" = "$expected" ] \
    || fail "hash_pane did not use the shasum fallback tier past openssl (got '$out', wanted '$expected')"
  pass "hash_pane falls back past openssl to shasum and still exits cleanly"
)

test_hash_pane_falls_back_past_shasum_to_cksum() (
  local home fakebin out expected status
  home="$TMP_ROOT/no-md5-no-openssl-no-shasum"
  mkdir -p "$home"
  source_watch "$home"
  [ -n "$REAL_CKSUM" ] || fail "cksum not available to exercise the fallback tier"
  fakebin=$(make_fakebin "$home/fakebin" "cksum=$REAL_CKSUM")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit with md5/md5sum/openssl/shasum absent from PATH"
  [ -n "$out" ] || fail "hash_pane produced empty output with md5/md5sum/openssl/shasum absent from PATH"
  expected=$(printf '%x\n' "$(printf 'pane text a\n' | "$REAL_CKSUM" | "$REAL_CUT" -d' ' -f1)")
  [ "$out" = "$expected" ] \
    || fail "hash_pane did not use the cksum fallback tier past shasum (got '$out', wanted '$expected')"
  [ "$out" != "$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text b")" ] \
    || fail "hash_pane produced the same hash for different input via the cksum tier"
  pass "hash_pane falls back past shasum to cksum and still exits cleanly"
)

test_hash_pane_never_hard_errors_with_no_hash_tool_at_all() (
  local home fakebin out out_b status
  home="$TMP_ROOT/no-hash-tool"
  mkdir -p "$home"
  source_watch "$home"
  fakebin=$(make_fakebin "$home/fakebin")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit with no md5/md5sum/openssl/shasum/cksum on PATH"
  [ -n "$out" ] || fail "hash_pane produced empty output with no hash tool at all on PATH"
  # "pane text a" and "pane text b" are the same length: this is a regression
  # check for the prior last-resort tier (wc -c), which returned a raw byte
  # count and so produced the identical token for both, masking real changes.
  out_b=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text b")
  [ "$out" != "$out_b" ] \
    || fail "hash_pane's last-resort tier produced the same output for same-length different content (got '$out' for both)"
  pass "hash_pane never hard-errors and stays content-sensitive with no hashing tool at all on PATH"
)

test_hash_pane_behavior_probe_detects_gnu_md5_without_q_flag() (
  local home fakebin fake_gnu_md5 out status
  home="$TMP_ROOT/gnu-md5-no-q-flag"
  mkdir -p "$home"
  source_watch "$home"
  fakebin=$(make_fakebin "$home/fakebin" "md5sum=$REAL_MD5SUM" "openssl=$REAL_OPENSSL")

  # Create a fake GNU md5 that exists but doesn't support -q flag
  fake_gnu_md5="$home/fake-gnu-md5"
  cat > "$fake_gnu_md5" <<'FAKE_GNU_MD5'
#!/bin/sh
# Simulate GNU md5 (no -q flag)
if [ "$*" = "-q" ] || echo "$@" | grep -q "\-q"; then
  echo "md5: invalid option -- 'q'" >&2
  exit 1
fi
# Pass through to md5sum
exec md5sum "$@"
FAKE_GNU_MD5
  chmod +x "$fake_gnu_md5"

  status=0
  # The fix uses behavior probe (printf '' | md5 -q >/dev/null 2>&1)
  # so it should detect that -q fails and fall back to md5sum
  out=$(PATH="$home:$fakebin" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane detects GNU md5 -q failure and falls back gracefully"
  [ -n "$out" ] || fail "hash_pane produced empty output with GNU md5 (no -q support) — defect regression: name probe did not fall back to md5sum"
  [ "$out" = "$(PATH="$home:$fakebin" hash_pane <<<"pane text a")" ] \
    || fail "hash_pane is not stable for identical input with GNU md5 fallback"
  pass "hash_pane behavior probe detects GNU md5 without -q flag and falls back to md5sum (defect fix validation)"
)

test_hash_pane_stable_and_distinct_via_sbin_md5
test_hash_pane_falls_back_to_openssl_without_md5_or_md5sum
test_hash_pane_falls_back_past_openssl_to_shasum
test_hash_pane_falls_back_past_shasum_to_cksum
test_hash_pane_never_hard_errors_with_no_hash_tool_at_all
test_hash_pane_behavior_probe_detects_gnu_md5_without_q_flag
