#!/usr/bin/env bash
# tests/fm-size-limit.test.sh - behavior of bin/fm-size-limit.sh through its
# CLI: under-limit verdicts, over-limit verdicts with the decomposition
# playbook, test-file exemption, missing paths, and exit codes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/fm-size-limit.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-size-limit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

make_lines() { # <path> <count>
  : > "$1"
  i=0
  while [ "$i" -lt "$2" ]; do
    printf 'x\n' >> "$1"
    i=$((i + 1))
  done
}

SMALL="$TMP/small.py"
BIG="$TMP/big.py"
EDGE="$TMP/edge.py"
TESTFILE="$TMP/widget_test.py"
make_lines "$SMALL" 10
make_lines "$BIG" 260
make_lines "$EDGE" 250
make_lines "$TESTFILE" 500

OUT=$("$CHECK" "$SMALL" 2>&1)
CODE=$?
case "$OUT" in
  *'VERDICT: OK'*) pass 'under-limit file reports OK' ;;
  *) fail "under-limit file reports OK (got: $OUT)" ;;
esac
[ "$CODE" -eq 0 ] || fail "under-limit exit is 0 (got $CODE)"

OUT=$("$CHECK" "$BIG" 2>&1)
CODE=$?
case "$OUT" in
  *'VERDICT: OVER-LIMIT'*) pass '260-line file reports OVER-LIMIT' ;;
  *) fail "260-line file reports OVER-LIMIT (got: $OUT)" ;;
esac
case "$OUT" in
  *'DECOMPOSITION PLAYBOOK'*'single-concept'*) pass 'over-limit output carries the playbook' ;;
  *) fail 'over-limit output carries the playbook' ;;
esac
case "$OUT" in
  *'Never relax or bypass'*) pass 'playbook states the never-relax rule' ;;
  *) fail 'playbook states the never-relax rule' ;;
esac
[ "$CODE" -eq 1 ] || fail "over-limit exit is 1 (got $CODE)"

OUT=$("$CHECK" "$EDGE" 2>&1)
case "$OUT" in
  *'VERDICT: OVER-LIMIT'*) pass '250-line boundary file reports OVER-LIMIT' ;;
  *) fail "250-line boundary file reports OVER-LIMIT (got: $OUT)" ;;
esac

OUT=$("$CHECK" "$TESTFILE" 2>&1)
CODE=$?
case "$OUT" in
  *'VERDICT: EXEMPT'*) pass '500-line test file reports EXEMPT' ;;
  *) fail "500-line test file reports EXEMPT (got: $OUT)" ;;
esac
[ "$CODE" -eq 0 ] || fail "exempt exit is 0 (got $CODE)"

OUT=$("$CHECK" "$TMP/nope.py" 2>&1)
CODE=$?
case "$OUT" in
  *'ERROR'*) pass 'missing file reports ERROR' ;;
  *) fail 'missing file reports ERROR' ;;
esac
[ "$CODE" -eq 2 ] || fail "missing-file exit is 2 (got $CODE)"

OUT=$("$CHECK" 2>&1)
CODE=$?
[ "$CODE" -eq 2 ] || fail "bare invocation exit is 2 (got $CODE)"
case "$OUT" in
  *'usage:'*) pass 'bare invocation prints usage' ;;
  *) fail 'bare invocation prints usage' ;;
esac

OUT=$("$CHECK" --json "$BIG" "$SMALL" 2>&1)
CODE=$?
case "$OUT" in
  *'"verdict":"OVER-LIMIT"'*'"verdict":"OK"'*) pass 'json mode reports both verdicts' ;;
  *) fail "json mode reports both verdicts (got: $OUT)" ;;
esac
[ "$CODE" -eq 1 ] || fail "json over-limit exit is 1 (got $CODE)"

OUT=$("$CHECK" --limit 300 "$BIG" 2>&1)
case "$OUT" in
  *'VERDICT: OK'*) pass 'explicit --limit still works for direct shell use' ;;
  *) fail 'explicit --limit still works for direct shell use' ;;
esac

mkdir -p "$TMP/latest"
FALSEFRIEND="$TMP/latest/big.py"
make_lines "$FALSEFRIEND" 260
OUT=$("$CHECK" "$FALSEFRIEND" 2>&1)
case "$OUT" in
  *'VERDICT: OVER-LIMIT'*) pass 'latest/ directory does not falsely exempt' ;;
  *) fail "latest/ directory does not falsely exempt (got: $OUT)" ;;
esac

exit "$FAILED"
