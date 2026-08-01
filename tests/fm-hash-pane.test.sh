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
REAL_WC=$(command -v wc) || fail "wc not found on the test host"
REAL_SBIN_MD5=/sbin/md5
[ -x "$REAL_SBIN_MD5" ] || REAL_SBIN_MD5=$(command -v md5 || true)
REAL_OPENSSL=$(command -v openssl || true)
REAL_SHASUM=$(command -v shasum || true)

# make_fakebin <dir> [tool=path ...]: symlink each named tool from its
# resolved absolute path into <dir>, plus cut/tr/wc always (hash_pane's
# fallback tiers pipe through them). Echoes <dir>.
make_fakebin() {
  local dir=$1 spec tool src
  shift
  mkdir -p "$dir"
  ln -sf "$REAL_CUT" "$dir/cut"
  ln -sf "$REAL_TR" "$dir/tr"
  ln -sf "$REAL_WC" "$dir/wc"
  for spec in "$@"; do
    tool=${spec%%=*}
    src=${spec#*=}
    [ -n "$src" ] || fail "make_fakebin: no resolved path for $tool on this host"
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
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
  local home fakebin out status
  home="$TMP_ROOT/sbin-md5"
  mkdir -p "$home"
  source_watch "$home"
  [ -n "$REAL_SBIN_MD5" ] || fail "no BSD-compatible md5 -q binary found on this host"
  fakebin=$(make_fakebin "$home/fakebin")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$REAL_SBIN_MD5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit via the sbin md5 tier"
  [ -n "$out" ] || fail "hash_pane produced empty output via the sbin md5 tier"
  [ "$out" = "$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$REAL_SBIN_MD5" hash_pane <<<"pane text a")" ] \
    || fail "hash_pane is not stable for identical input via the sbin md5 tier"
  [ "$out" != "$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$REAL_SBIN_MD5" hash_pane <<<"pane text b")" ] \
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

test_hash_pane_never_hard_errors_with_no_hash_tool_at_all() (
  local home fakebin out status
  home="$TMP_ROOT/no-hash-tool"
  mkdir -p "$home"
  source_watch "$home"
  fakebin=$(make_fakebin "$home/fakebin")
  status=0
  out=$(PATH=$fakebin FM_MD5_SBIN_OVERRIDE="$home/no-such-md5" hash_pane <<<"pane text a") || status=$?
  expect_code 0 "$status" "hash_pane exit with no md5/md5sum/openssl/shasum/cksum on PATH"
  [ -n "$out" ] || fail "hash_pane produced empty output with no hash tool at all on PATH"
  pass "hash_pane never hard-errors even with no hashing tool at all on PATH"
)

test_hash_pane_stable_and_distinct_via_sbin_md5
test_hash_pane_falls_back_to_openssl_without_md5_or_md5sum
test_hash_pane_falls_back_past_openssl_to_shasum
test_hash_pane_never_hard_errors_with_no_hash_tool_at_all
