#!/usr/bin/env bash
# Hermetic behavior tests for bin/fm-idea-mine.ts.
#
# No network: the two inference passes are mocked via FM_IDEA_MINE_INFER_CMD,
# and the ideas/review store CLIs are mocked with PATH shims that append every
# invocation to a log and mint deterministic ids. Every case drives the real
# fm-idea-mine.ts against a fixture transcript and asserts filed / skipped /
# dry-run / empty / malformed behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v bun >/dev/null 2>&1 || { echo "skip: bun not found for fm-idea-mine tests"; exit 0; }

SCRIPT="$ROOT/bin/fm-idea-mine.ts"

# --- fixtures ---------------------------------------------------------------

# Write a minimal but realistic .jsonl transcript into $1 with a couple of
# human turns that carry idea signal plus assistant/tool noise to strip.
write_transcript() {
  local file=$1
  cat > "$file" <<'JSONL'
{"type":"user","message":{"role":"user","content":"can you build me a voice-first way to triage my inbox?"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","text":"internal reasoning that must not leak"},{"type":"text","text":"Sure, here is a plan."}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"tool output noise that is not an idea"}]}}
{"type":"user","message":{"role":"user","content":"i keep wishing my espresso machine logged shots automatically"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
JSONL
}

# Build a mock inference command. It reads the SYSTEM prompt (2nd-to-last arg)
# to decide which pass it is, and emits the JSON for that pass. The GEN and EVAL
# payloads are supplied as files so each test controls them.
make_infer_mock() {
  local dir=$1 gen_file=$2 eval_file=$3
  local mock="$dir/infer-mock.sh"
  cat > "$mock" <<SH
#!/usr/bin/env bash
# args: [<base args>...] <system_prompt> <user_prompt>
system="\${@:(-2):1}"
case "\$system" in
  *"surface ideas"*|*"uncaptured"*) cat "$gen_file" ;;
  *"critical second-pass"*|*"critically evaluate"*|*"kept"*) cat "$eval_file" ;;
  *) echo "MOCK: unrecognized system prompt" >&2; exit 3 ;;
esac
SH
  chmod +x "$mock"
  printf '%s\n' "$mock"
}

# Store CLI mock: logs invocation and mints a deterministic id from a counter.
# Usage: install_store_mock <fakebin> <name> <id-prefix> <log>
install_store_mock() {
  local fakebin=$1 name=$2 prefix=$3 log=$4
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
log="$log"
prefix="$prefix"
printf '%s' "$name" >> "\$log"
for a in "\$@"; do printf ' [%s]' "\$a" >> "\$log"; done
printf '\n' >> "\$log"
verb=\${1:-}
if [ "\$verb" = create ]; then
  n=\$(( \$(cat "\$log.counter" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "\$log.counter"
  printf '%s-%03d\n' "\$prefix" "\$n"
  exit 0
fi
if [ "\$verb" = list ]; then
  # emit the seeded existing-ideas JSON if present, else empty array
  if [ -f "\$log.existing.json" ]; then cat "\$log.existing.json"; else echo '[]'; fi
  exit 0
fi
if [ "\$verb" = update ]; then exit 0; fi
exit 0
SH
  chmod +x "$fakebin/$name"
}

# Run fm-idea-mine.ts with a hermetic environment. Sets up transcript dir,
# fakebin PATH, infer mock, state dir. Extra args forwarded to the script.
# Globals set by the caller: GEN_FILE, EVAL_FILE, optional EXISTING_JSON.
run_mine() {
  local tmp=$1; shift
  local transcript_dir="$tmp/transcripts"
  local fakebin state_dir infer log
  mkdir -p "$transcript_dir"
  write_transcript "$transcript_dir/session.jsonl"
  fakebin=$(fm_fakebin "$tmp")
  state_dir="$tmp/state"
  log="$tmp/store.log"
  : > "$log"
  install_store_mock "$fakebin" ideas idea "$log"
  install_store_mock "$fakebin" review review "$log"
  if [ -n "${EXISTING_JSON:-}" ]; then cp "$EXISTING_JSON" "$log.existing.json"; fi
  infer=$(make_infer_mock "$tmp" "$GEN_FILE" "$EVAL_FILE")
  env -i \
    PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    HOME="$tmp/home" \
    FM_IDEA_MINE_TRANSCRIPT_DIR="$transcript_dir" \
    FM_IDEA_MINE_MUSE_FILE="$tmp/no-such-muse.md" \
    FM_IDEA_MINE_INFER_CMD="$infer" \
    FM_IDEA_MINE_IDEAS_CMD=ideas \
    FM_IDEA_MINE_REVIEW_CMD=review \
    FM_IDEA_MINE_STATE_DIR="$state_dir" \
    "$(command -v bun)" "$SCRIPT" "$@" 2>&1
}

# --- payload builders -------------------------------------------------------

gen_two() {
  cat > "$1" <<'JSON'
[
  {"title":"Voice inbox triage","spark":"build me a voice-first way to triage my inbox","rationale":"never captured","source_hint":"triage my inbox"},
  {"title":"Auto espresso shot logging","spark":"machine logged shots automatically","rationale":"recurring wish","source_hint":"espresso machine"}
]
JSON
}

eval_keep_two() {
  cat > "$1" <<'JSON'
{
  "kept":[
    {"title":"Voice inbox triage","spark":"voice-first inbox triage","scores":{"novelty":7,"impact":8,"feasibility":6,"alignment":9},"overall":7.5,"why":"strong voice-first fit","recommended_action":"build"},
    {"title":"Auto espresso shot logging","spark":"auto shot logging","scores":{"novelty":5,"impact":4,"feasibility":7,"alignment":3},"overall":4.8,"why":"fun but off-mission","recommended_action":"discuss"}
  ],
  "dropped":[
    {"title":"Some vague thing","reason":"too vague to act on"}
  ]
}
JSON
}

# --- tests ------------------------------------------------------------------

test_happy_path_generate_evaluate_file() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-happy)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"; unset EXISTING_JSON
  gen_two "$GEN_FILE"; eval_keep_two "$EVAL_FILE"
  local out; out=$(run_mine "$tmp") || fail "happy path exited nonzero: $out"
  local log="$tmp/store.log"
  # Two ideas created + one review created.
  local idea_creates review_creates
  idea_creates=$(grep -c '^ideas \[create\]' "$log" || true)
  review_creates=$(grep -c '^review \[create\]' "$log" || true)
  [ "$idea_creates" = 2 ] || fail "expected 2 idea creates, got $idea_creates"$'\n'"$(cat "$log")"
  [ "$review_creates" = 1 ] || fail "expected 1 review create, got $review_creates"$'\n'"$(cat "$log")"
  assert_contains "$out" "filed 2 new ideas" "summary should report 2 filed"
  assert_contains "$out" "review item:" "summary should name the review id"
  pass "happy path: generate -> evaluate -> files two ideas and one review item"
}

test_dedup_skips_existing_idea() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-dedup)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"
  gen_two "$GEN_FILE"; eval_keep_two "$EVAL_FILE"
  # Seed an existing idea whose title fuzzily matches "Voice inbox triage".
  EXISTING_JSON="$tmp/existing.json"
  cat > "$EXISTING_JSON" <<'JSON'
[{"id":"idea-existing","title":"voice inbox triage assistant"}]
JSON
  local out; out=$(run_mine "$tmp") || fail "dedup run exited nonzero: $out"
  local log="$tmp/store.log"
  local idea_creates
  idea_creates=$(grep -c '^ideas \[create\]' "$log" || true)
  [ "$idea_creates" = 1 ] || fail "expected 1 idea create (one deduped), got $idea_creates"$'\n'"$(cat "$log")"
  assert_contains "$out" "skipped 1 duplicates" "summary should report the skipped duplicate"
  assert_contains "$out" "idea-existing" "duplicate should reference the existing id"
  pass "dedup: an already-present idea is skipped, not re-filed"
}

test_dry_run_files_nothing() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-dry)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"; unset EXISTING_JSON
  gen_two "$GEN_FILE"; eval_keep_two "$EVAL_FILE"
  local out; out=$(run_mine "$tmp" --dry-run) || fail "dry-run exited nonzero: $out"
  local log="$tmp/store.log"
  # No create/update should have been logged at all.
  if grep -qE '\[create\]|\[update\]' "$log"; then
    fail "dry-run must not file anything, but store.log has:"$'\n'"$(cat "$log")"
  fi
  assert_contains "$out" "DRY RUN" "dry-run output should announce itself"
  assert_contains "$out" "would file" "dry-run should preview what it would file"
  pass "dry-run: computes the harvest but files nothing"
}

test_empty_history_no_op() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-empty)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"; unset EXISTING_JSON
  gen_two "$GEN_FILE"; eval_keep_two "$EVAL_FILE"
  # Point at an empty transcript dir (no .jsonl at all).
  local transcript_dir="$tmp/empty"; mkdir -p "$transcript_dir"
  local fakebin; fakebin=$(fm_fakebin "$tmp")
  local log="$tmp/store.log"; : > "$log"
  install_store_mock "$fakebin" ideas idea "$log"
  install_store_mock "$fakebin" review review "$log"
  local infer; infer=$(make_infer_mock "$tmp" "$GEN_FILE" "$EVAL_FILE")
  local out
  out=$(env -i PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    HOME="$tmp/home" \
    FM_IDEA_MINE_TRANSCRIPT_DIR="$transcript_dir" \
    FM_IDEA_MINE_MUSE_FILE="$tmp/no-muse.md" \
    FM_IDEA_MINE_INFER_CMD="$infer" \
    FM_IDEA_MINE_STATE_DIR="$tmp/state" \
    "$(command -v bun)" "$SCRIPT" 2>&1) || fail "empty-history run exited nonzero: $out"
  if grep -qE '\[create\]' "$log"; then
    fail "empty history must not file anything:"$'\n'"$(cat "$log")"
  fi
  assert_contains "$out" "no transcript history" "empty history should report nothing to do"
  pass "empty history: no-op, files nothing"
}

test_malformed_inference_fails_safe() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-malformed)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"; unset EXISTING_JSON
  # Generate pass returns garbage, not JSON.
  printf 'this is not json at all, the model rambled\n' > "$GEN_FILE"
  eval_keep_two "$EVAL_FILE"
  local out rc=0
  out=$(run_mine "$tmp") || rc=$?
  local log="$tmp/store.log"
  [ "$rc" -ne 0 ] || fail "malformed inference should exit nonzero, got 0"$'\n'"$out"
  if grep -qE '\[create\]' "$log"; then
    fail "malformed inference must not file garbage:"$'\n'"$(cat "$log")"
  fi
  assert_contains "$out" "generate pass failed" "should report the generate failure"
  pass "malformed inference JSON fails safe: nonzero exit, nothing filed"
}

test_idempotency_marker_skips_unchanged_tail() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-idem)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"; unset EXISTING_JSON
  gen_two "$GEN_FILE"; eval_keep_two "$EVAL_FILE"
  # First run files.
  local out1; out1=$(run_mine "$tmp") || fail "first idempotency run failed: $out1"
  local log="$tmp/store.log"
  local first_creates; first_creates=$(grep -c '\[create\]' "$log" || true)
  [ "$first_creates" -gt 0 ] || fail "first run should have filed something"
  # Second run over the SAME transcript must no-op on the marker.
  : > "$log"; rm -f "$log.counter"
  local out2; out2=$(run_mine "$tmp") || fail "second idempotency run failed: $out2"
  if grep -qE '\[create\]' "$log"; then
    fail "second run over unchanged tail must not re-file:"$'\n'"$(cat "$log")"
  fi
  assert_contains "$out2" "unchanged" "second run should report the tail unchanged"
  pass "idempotency: unchanged transcript tail is skipped on the marker"
}

test_kept_cap_enforced() {
  local tmp; tmp=$(fm_test_tmproot fm-idea-mine-cap)
  mkdir -p "$tmp"
  GEN_FILE="$tmp/gen.json"; EVAL_FILE="$tmp/eval.json"; unset EXISTING_JSON
  gen_two "$GEN_FILE"
  # Evaluation returns two kept, but cap is 1 -> only the higher-scored files.
  eval_keep_two "$EVAL_FILE"
  local fakebin state_dir infer log transcript_dir
  transcript_dir="$tmp/transcripts"; mkdir -p "$transcript_dir"
  write_transcript "$transcript_dir/session.jsonl"
  fakebin=$(fm_fakebin "$tmp"); state_dir="$tmp/state"; log="$tmp/store.log"; : > "$log"
  install_store_mock "$fakebin" ideas idea "$log"
  install_store_mock "$fakebin" review review "$log"
  infer=$(make_infer_mock "$tmp" "$GEN_FILE" "$EVAL_FILE")
  local out
  out=$(env -i PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    HOME="$tmp/home" \
    FM_IDEA_MINE_TRANSCRIPT_DIR="$transcript_dir" \
    FM_IDEA_MINE_MUSE_FILE="$tmp/no-muse.md" \
    FM_IDEA_MINE_INFER_CMD="$infer" \
    FM_IDEA_MINE_STATE_DIR="$state_dir" \
    FM_IDEA_MINE_MAX_KEPT=1 \
    "$(command -v bun)" "$SCRIPT" 2>&1) || fail "cap run exited nonzero: $out"
  local idea_creates; idea_creates=$(grep -c '^ideas \[create\]' "$log" || true)
  [ "$idea_creates" = 1 ] || fail "kept cap of 1 should file exactly 1 idea, got $idea_creates"$'\n'"$(cat "$log")"
  pass "kept cap: FM_IDEA_MINE_MAX_KEPT bounds the number of filed ideas"
}

test_happy_path_generate_evaluate_file
test_dedup_skips_existing_idea
test_dry_run_files_nothing
test_empty_history_no_op
test_malformed_inference_fails_safe
test_idempotency_marker_skips_unchanged_tail
test_kept_cap_enforced

echo "# all fm-idea-mine tests passed"
