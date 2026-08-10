#!/usr/bin/env bash
# fm-groom.test.sh - hermetic behavior tests for bin/fm-groom.sh.
#
# fm-groom is an autonomous LAUNCHER; its whole reason to exist safely is a set of
# rails that must never regress. This suite pins the rails that matter WITHOUT any
# network or the real ideas/review/inference/spawn tools, using fm-groom's own test
# override env vars (FM_GROOM_IDEAS_BIN / FM_GROOM_REVIEW_BIN / FM_GROOM_SPAWN /
# FM_GROOM_INFERENCE), so it runs on CI's tool-less ubuntu image.
#
# Rails asserted:
#   1. DRY-RUN (default, unset FM_GROOM_ENABLED) dispatches/files/marks NOTHING.
#   2. FM_GROOM_MAX_PER_RUN bounds how many ideas one run acts on.
#   3. A classifier that returns garbage FAILS SAFE to escalate (never auto-dispatch).
#   4. Idempotency: an idea already carrying a groom:* label is SKIPPED.
#   5. ARMED safe idea -> dispatch happens via fm-spawn AND the idea is marked.
#   6. ARMED unsafe idea -> a review item is filed AND the idea is marked, no spawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GROOM="$ROOT/bin/fm-groom.sh"

TMP=$(fm_test_tmproot fm-groom)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

# --- mock CLIs --------------------------------------------------------------
# The `ideas` mock is a tiny record-and-replay store backed by files in $TMP.
#   ideas ready --json           -> emits the fixture id list
#   ideas show <id> --json       -> emits {id,title,description} for a fixture
#   ideas label list <id>        -> prints any label lines recorded for <id>
#   ideas set-state <id> k=v ...  -> records a "k:v" label line for <id> (idempotency marker)
#   ideas note <id> ...           -> no-op success
MOCK_STORE="$TMP/mockstore"
mkdir -p "$MOCK_STORE"

cat > "$TMP/ideas" <<MOCK
#!/usr/bin/env bash
set -u
store="$MOCK_STORE"
cmd=\${1:-}
case "\$cmd" in
  ready)
    cat "\$store/ready.json"
    ;;
  show)
    id=\$2
    cat "\$store/show-\$id.json" 2>/dev/null || printf '[]'
    ;;
  label)
    sub=\${2:-}
    if [ "\$sub" = list ]; then
      id=\$3
      cat "\$store/labels-\$id" 2>/dev/null || true
    fi
    ;;
  set-state)
    id=\$2
    kv=\$3            # dimension=value
    dim=\${kv%%=*}
    val=\${kv#*=}
    printf '%s:%s\n' "\$dim" "\$val" >> "\$store/labels-\$id"
    ;;
  note)
    : ;;
  *)
    : ;;
esac
exit 0
MOCK
chmod +x "$TMP/ideas"

# review mock: `review q <title> ...` prints a fake id and records the call.
cat > "$TMP/review" <<MOCK
#!/usr/bin/env bash
set -u
store="$MOCK_STORE"
if [ "\${1:-}" = q ]; then
  cat >/dev/null 2>&1 || true   # drain --body-file - stdin
  echo "filed \$*" >> "\$store/review.log"
  printf 'rev-fake-1\n'
fi
exit 0
MOCK
chmod +x "$TMP/review"

# spawn mock: records each dispatch and succeeds.
cat > "$TMP/spawn" <<MOCK
#!/usr/bin/env bash
set -u
store="$MOCK_STORE"
echo "spawn \$*" >> "\$store/spawn.log"
exit 0
MOCK
chmod +x "$TMP/spawn"

# inference mock: argv is "--level <lvl> <system> <user>". The SYSTEM prompt tells
# us which call this is: the formulator's system contains "task description", the
# classifier's contains 'one word on the first line: "safe" or "escalate"'. We key
# the verdict off a marker word placed in the fixture idea title/desc:
#   contains UNSAFEWORD -> classifier returns "escalate"
#   contains GARBAGEWORD -> classifier returns junk (tests fail-safe)
#   otherwise            -> classifier returns "safe"
cat > "$TMP/inference" <<'MOCK'
#!/usr/bin/env bash
set -u
# args: --level <lvl> <system> <user>
system=$3
user=$4
if printf '%s' "$system" | grep -q 'safe.*escalate'; then
  # classifier call
  if printf '%s' "$user" | grep -q GARBAGEWORD; then
    printf 'purple monkey dishwasher\n(no verdict here)\n'
  elif printf '%s' "$user" | grep -q UNSAFEWORD; then
    printf 'escalate\nThis touches production.\n'
  else
    printf 'safe\nLocal reversible work.\n'
  fi
else
  # formulator call
  printf 'FORMULATED BRIEF for: %s\n' "$user" | head -1
fi
exit 0
MOCK
chmod +x "$TMP/inference"

# --- fixtures ---------------------------------------------------------------
# Three ready ideas: one safe, one unsafe (UNSAFEWORD), one garbage (GARBAGEWORD).
cat > "$MOCK_STORE/ready.json" <<'JSON'
[
  {"id":"idea-safe","title":"add a local search helper"},
  {"id":"idea-danger","title":"UNSAFEWORD deploy to prod"},
  {"id":"idea-junk","title":"GARBAGEWORD unclassifiable"}
]
JSON
printf '[{"id":"idea-safe","title":"add a local search helper","description":"read local files and rank them"}]\n' > "$MOCK_STORE/show-idea-safe.json"
printf '[{"id":"idea-danger","title":"UNSAFEWORD deploy to prod","description":"merge and deploy"}]\n' > "$MOCK_STORE/show-idea-danger.json"
printf '[{"id":"idea-junk","title":"GARBAGEWORD unclassifiable","description":"who knows"}]\n' > "$MOCK_STORE/show-idea-junk.json"

run_groom() {  # extra args...
  FM_HOME="$HOME_DIR" \
  FM_GROOM_IDEAS_BIN="$TMP/ideas" \
  FM_GROOM_REVIEW_BIN="$TMP/review" \
  FM_GROOM_SPAWN="$TMP/spawn" \
  FM_GROOM_INFERENCE="$TMP/inference" \
    bash "$GROOM" "$@"
}

reset_mock_state() {
  rm -f "$MOCK_STORE"/labels-* "$MOCK_STORE"/review.log "$MOCK_STORE"/spawn.log
  rm -f "$HOME_DIR"/state/groom-*.meta 2>/dev/null || true
  rm -rf "$HOME_DIR"/data/groom-* 2>/dev/null || true
}

# --- 1. DRY-RUN mutates nothing --------------------------------------------
reset_mock_state
out=$(run_groom 2>&1) || fail "dry-run exited non-zero"$'\n'"$out"
assert_contains "$out" "DRY-RUN" "dry-run banner present"
assert_contains "$out" "WOULD DISPATCH" "dry-run shows would-dispatch for safe idea"
assert_contains "$out" "WOULD FILE" "dry-run shows would-file for unsafe idea"
[ ! -e "$MOCK_STORE/spawn.log" ] || fail "dry-run must not dispatch (spawn.log exists)"
[ ! -e "$MOCK_STORE/review.log" ] || fail "dry-run must not file a review (review.log exists)"
[ -z "$(ls "$MOCK_STORE"/labels-* 2>/dev/null || true)" ] || fail "dry-run must not mark any idea"
pass "dry-run dispatches/files/marks nothing"

# --- 2. FM_GROOM_MAX_PER_RUN bounds the run --------------------------------
reset_mock_state
out=$(run_groom --limit 1 2>&1) || fail "limited dry-run exited non-zero"
# Exactly one IDEA block acted; the report notes the per-run limit stop.
n_ideas=$(printf '%s\n' "$out" | grep -c '^IDEA ' || true)
[ "$n_ideas" -eq 1 ] || fail "expected exactly 1 acted idea with --limit 1, got $n_ideas"$'\n'"$out"
assert_contains "$out" "per-run limit" "limit note surfaced"
pass "max-per-run bounds the run to N ideas"

# --- 3. garbage classifier fails safe to escalate --------------------------
reset_mock_state
out=$(run_groom --idea idea-junk 2>&1) || fail "junk-idea dry-run exited non-zero"
assert_contains "$out" "VERDICT  escalate" "unparseable classifier output escalates (fail-safe)"
assert_contains "$out" "WOULD FILE" "fail-safe routes to review, never dispatch"
case "$out" in *"WOULD DISPATCH"*) fail "fail-safe idea must not be dispatched" ;; esac
pass "garbage classifier output fails safe to escalate"

# --- 4. idempotency: already-groomed idea is skipped -----------------------
reset_mock_state
printf 'groom:dispatched\n' > "$MOCK_STORE/labels-idea-safe"   # pre-mark it
out=$(run_groom --idea idea-safe 2>&1) || fail "idempotency dry-run exited non-zero"
# Acted count is zero: the only idea was skipped.
assert_contains "$out" "acted=0" "already-groomed idea is skipped (acted=0)"
case "$out" in *"WOULD DISPATCH"*) fail "already-groomed idea must not be re-acted" ;; esac
pass "already-groomed idea is skipped (idempotent)"

# --- 5. ARMED safe idea dispatches AND marks -------------------------------
reset_mock_state
out=$(FM_GROOM_ENABLED=1 run_groom --idea idea-safe 2>&1) || fail "armed safe run exited non-zero"$'\n'"$out"
assert_contains "$out" "DISPATCHED as groom-ideasafe" "armed safe idea is dispatched"
[ -e "$MOCK_STORE/spawn.log" ] || fail "armed safe idea must call fm-spawn"
grep -q 'scout' "$MOCK_STORE/spawn.log" || fail "dispatch must be a scout"
grep -q 'groom:dispatched' "$MOCK_STORE/labels-idea-safe" || fail "armed dispatch must mark the idea groom:dispatched"
[ -f "$HOME_DIR/data/groom-ideasafe/brief.md" ] || fail "armed dispatch must write the formulated brief file"
pass "armed safe idea dispatches via fm-spawn and marks the idea"

# --- 6. ARMED unsafe idea files a review AND marks, no spawn ---------------
reset_mock_state
out=$(FM_GROOM_ENABLED=1 run_groom --idea idea-danger 2>&1) || fail "armed unsafe run exited non-zero"$'\n'"$out"
assert_contains "$out" "FILED review item" "armed unsafe idea files a review item"
[ -e "$MOCK_STORE/review.log" ] || fail "armed unsafe idea must file a review item"
[ ! -e "$MOCK_STORE/spawn.log" ] || fail "armed unsafe idea must NOT dispatch"
grep -q 'groom:escalated' "$MOCK_STORE/labels-idea-danger" || fail "armed escalate must mark the idea groom:escalated"
pass "armed unsafe idea files a review item and marks the idea, no dispatch"

pass "fm-groom: all rails hold"
