#!/usr/bin/env bash
# fm-install-fetch-lib.test.sh - the pinned-tool installers' shared download
# step serves a digest-matching cache entry without the network, ignores a
# cache entry that does not match its pin, stores only verified downloads, and
# keeps retrying long enough to ride out a short upstream outage.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-install-fetch-lib.sh
. "$ROOT/bin/fm-install-fetch-lib.sh"

TMP=$(fm_test_tmproot fm-install-fetch-lib)
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
[ "$count" -gt "${CURL_FAIL_UNTIL:-0}" ] || exit 22
printf '%s' "${CURL_BODY:-payload}" > "$out"
SH
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/sleep"
export PATH="$FAKEBIN:$PATH" CURL_COUNT="$TMP/count" SLEEP_LOG="$TMP/sleeps"

printf payload > "$TMP/good"
SHA=$(fm_install_sha256 "$TMP/good")

fetch() {
  printf 0 > "$CURL_COUNT"
  : > "$SLEEP_LOG"
  : > "$TMP/out"
  FM_INSTALL_CACHE_DIR=$CACHE fm_install_fetch t "https://x/y" "$TMP/out" "$SHA" 2>"$TMP/err"
}

CACHE="$TMP/cache1"
fetch
[ "$(cat "$CURL_COUNT")" -eq 1 ] || fail "cache miss did not download once"
[ "$(cat "$CACHE/$SHA")" = payload ] || fail "verified download was not stored in the cache"
pass "a verified download is stored under its pin digest"

fetch
[ "$(cat "$CURL_COUNT")" -eq 0 ] || fail "cache hit still used the network"
[ "$(cat "$TMP/out")" = payload ] || fail "cache hit did not deliver the file"
pass "a digest-matching cache entry skips the network"

printf tampered > "$CACHE/$SHA"
fetch
[ "$(cat "$CURL_COUNT")" -eq 1 ] || fail "tampered cache entry was not re-downloaded"
[ "$(cat "$TMP/out")" = payload ] || fail "tampered cache entry was served"
[ "$(cat "$CACHE/$SHA")" = payload ] || fail "tampered cache entry was not replaced by the verified download"
pass "a cache entry that does not match its pin is ignored and replaced"

CACHE="$TMP/cache2"
CURL_BODY=wrong fetch
[ ! -e "$CACHE/$SHA" ] || fail "a download that failed its pin was cached"
pass "a download that fails its pin is never cached"

CACHE="$TMP/cache3"
CURL_FAIL_UNTIL=5 fetch
[ "$(cat "$CURL_COUNT")" -eq 6 ] || fail "fetch did not recover on the sixth attempt"
total=0
while read -r s; do total=$((total + s)); done < "$SLEEP_LOG"
[ "$total" -ge 120 ] || fail "backoff of ${total}s is too short to ride out a 504 window"
pass "retries span at least two minutes"

CACHE="$TMP/cache4"
code=0
CURL_FAIL_UNTIL=99 fetch || code=$?
[ "$code" -ne 0 ] || fail "fetch succeeded although every attempt failed"
pass "persistent failure is reported after the last attempt"
