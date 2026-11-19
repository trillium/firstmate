#!/usr/bin/env bash
# tests/fm-workhorse-file.test.sh - fm-workhorse-file.sh filing and refusals.
#
# Covers: the bead lands in the pinned task store (never the decoy .beads in
# the caller's cwd), always through `task` with BEADS_DIR pinned and the cwd
# moved off the caller's tree; the full-brief body, label, and filing-mate
# record; the ring after filing and the exit when it is unconfirmed; and every
# refusal path, each of which must file nothing.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/workhorse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/workhorse-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-workhorse-file)
wh_world "$TMP_ROOT/w"

# expect_refused <label> <expected-message-fragment> <overrides...>
expect_refused() {
  local label=$1 fragment=$2 out rc=0
  shift 2
  out=$(wh_file_valid "$@" 2>&1) || rc=$?
  expect_code 2 "$rc" "$label" "$out"
  assert_contains "$out" "$fragment" "$label should name its cause"
  assert_equals "0" "$(wh_store_count "$WH_STORE")" "$label must file nothing"
  assert_equals "0" "$(wh_store_count "$WH_DECOY/.beads")" "$label must file nothing in the decoy store"
}

test_refuses_empty_vague_and_placeholder_sections() {
  expect_refused "an empty intent" "Captain's intent is empty" --intent "   "
  expect_refused "an empty spec" "Firstmate spec is empty" --spec ""
  expect_refused "an empty out-of-scope" "Out of scope is empty" --out-of-scope ""
  expect_refused "an empty definition of done" "Definition of done is empty" --dod ""
  expect_refused "a vague out-of-scope" "vague stand-in" --out-of-scope "none"
  expect_refused "a vague definition of done" "vague stand-in" --dod "TBD."
  expect_refused "a one-liner spec" "too short" --spec "do the thing"
  expect_refused "a leftover scaffold placeholder" "placeholder" --spec "Build {FIRSTMATE_SPEC} exactly as written"
  expect_refused "a fill-in placeholder" "placeholder" --intent "Make <fill in the real ask> work for everyone"
  expect_refused "a TODO marker" "placeholder" --dod "Tests pass and the TODO is resolved fully"
  expect_refused "a Captain-labelled intent" "Captain label" --intent "Captain: make the capacitor configurable please"
  expect_refused "a spec that splits the brief" "'## '" --spec $'Add the key.\n## Sneaky heading\nmore words'
  expect_refused "a title-copy section" "repeats the title" \
    --title "Add flux capacitor option to the loader" --intent "Add flux capacitor option to the loader"
  expect_refused "a short title" "too short" --title "Fix it"
  pass "empty, vague, one-line, placeholder, labelled, and heading-splitting sections are refused with nothing filed"
}

test_refuses_missing_or_bad_evidence_mode_yolo_project_and_mate() {
  local out rc=0
  expect_refused "an evidence kind that is not allowed" "must be pr, report, or command" --evidence "screenshot:a picture of the result"
  expect_refused "evidence with no kind" "must look like" --evidence "just a description of proof"
  expect_refused "vague evidence text" "vague stand-in" --evidence "pr:tbd"
  expect_refused "a bad mode" "--mode must be" --mode yolo-mode
  expect_refused "a bad yolo" "--yolo must be on or off" --yolo maybe
  expect_refused "an invalid project" "not a valid project" --project "bad project"
  expect_refused "an invalid filing mate" "not a valid mate id" --answer-to "bad mate"
  out=$(wh_file --title "Missing evidence entirely for this bead" --intent "Make the capacitor configurable now." \
    --spec "Add the config key and read it." --out-of-scope "Anything touching billing paths." \
    --dod "Tests cover the key fully." --mode local-only --yolo off --project demo-project --answer-to porter 2>&1) || rc=$?
  expect_code 2 "$rc" "no evidence at all" "$out"
  assert_contains "$out" "--evidence is required" "missing evidence is named"
  rc=0
  out=$(wh_file --title "Missing mode and yolo for this bead" --intent "Make the capacitor configurable now." \
    --spec "Add the config key and read it." --out-of-scope "Anything touching billing paths." \
    --dod "Tests cover the key fully." --evidence "pr:the merged PR link" --project demo-project --answer-to porter 2>&1) || rc=$?
  expect_code 2 "$rc" "no mode" "$out"
  assert_contains "$out" "--mode is required" "a missing mode is named, never defaulted"
  rc=0
  out=$(wh_file --title "Missing filing mate for this bead" --intent "Make the capacitor configurable now." \
    --spec "Add the config key and read it." --out-of-scope "Anything touching billing paths." \
    --dod "Tests cover the key fully." --evidence "pr:the merged PR link" --mode local-only --yolo off --project demo-project 2>&1) || rc=$?
  expect_code 2 "$rc" "no filing mate" "$out"
  assert_contains "$out" "--answer-to is required" "a missing filing mate is named"
  assert_equals "0" "$(wh_store_count "$WH_STORE")" "no refusal filed anything"
  pass "missing or invalid evidence, mode, yolo, project, and filing mate are refused with nothing filed"
}

test_refuses_when_the_pinned_store_is_missing() {
  local out rc=0
  out=$(FM_WORKHORSE_BEADS_DIR="$TMP_ROOT/nowhere/.beads" wh_file_valid 2>&1) || rc=$?
  expect_code 1 "$rc" "an absent pinned store" "$out"
  assert_contains "$out" "does not exist" "the absent store is named"
  assert_contains "$out" "refusing to fall back" "it never falls back to another store"
  assert_equals "0" "$(wh_store_count "$WH_DECOY/.beads")" "the decoy store stays empty"
  pass "an absent pinned store is refused rather than replaced by the cwd's store"
}

test_files_a_full_brief_in_the_pinned_store() {
  local out desc heading
  out=$(wh_file_valid 2>"$TMP_ROOT/err") || fail "a valid request should file: $(cat "$TMP_ROOT/err")"
  assert_equals "task-b1" "$out" "the bead id is the only stdout line"
  assert_equals "1" "$(wh_store_count "$WH_STORE")" "the bead lands in the pinned store"
  assert_equals "0" "$(wh_store_count "$WH_DECOY/.beads")" "nothing lands in the .beads of the caller's cwd"
  desc=$(jq -r '.[0].description' "$WH_STORE/store.json")
  for heading in "## Captain's intent" "## Firstmate spec" "## Out of scope" "## Definition of done" \
    "## Evidence required" "## Delivery mode + yolo posture" "## Answer-to"; do
    assert_contains "$desc" "$heading" "the body carries $heading"
  done
  assert_contains "$desc" "- PR link: the merged pull request link" "evidence names the PR kind"
  assert_contains "$desc" "- Command output: the test run output proving it passes" "evidence names the command kind"
  assert_contains "$desc" "mode: local-only" "the mode is recorded"
  assert_contains "$desc" "yolo: off" "the yolo posture is recorded"
  assert_contains "$desc" "project: demo-project" "the project is recorded"
  assert_equals "workhorse" "$(jq -r '.[0].labels[0]' "$WH_STORE/store.json")" "the workhorse label is set"
  assert_equals "porter" "$(jq -r '.[0].metadata.filed_by' "$WH_STORE/store.json")" "the filing mate is recorded"
  pass "a valid request files one full-brief bead with label and filing mate in the pinned store"
}

test_store_is_pinned_from_a_cwd_with_a_different_beads() {
  local create_call
  create_call=$(grep '|create ' "$WH_LOG" | head -n1)
  assert_contains "$create_call" "|$WH_STORE|" "the create call carried the pinned BEADS_DIR"
  assert_equals "$(dirname "$WH_STORE")" "${create_call%%|*}" "the call ran from the store's own parent, not the caller's cwd"
  assert_not_contains "$(cut -d'|' -f1,2 "$WH_LOG" | sort -u)" "$WH_DECOY" "no call ever resolved the decoy store or cwd"
  pass "filing from a cwd holding another .beads reaches only the pinned task store"
}

test_rings_the_workhorse_after_filing() {
  local sent
  sent=$(cat "$WH_SEND_LOG")
  assert_equals "1" "$(printf '%s\n' "$sent" | grep -c .)" "one doorbell was sent"
  assert_contains "$sent" "FM_HOME=$WH_HOME|workhorse-mate " "the send names the mate with FM_HOME explicit"
  assert_contains "$sent" "task-b1" "the doorbell names the bead"
  pass "filing rings the workhorse through fm-send with an explicit home"
}

test_unconfirmed_ring_exits_4_but_keeps_the_bead() {
  local out rc=0
  : >"$WH_SEND_LOG"
  out=$(WH_SEND_RC=1 wh_file_valid --title "A second bead for the unconfirmed doorbell" 2>"$TMP_ROOT/err") || rc=$?
  expect_code 4 "$rc" "an unconfirmed doorbell" "$(cat "$TMP_ROOT/err")"
  assert_equals "task-b2" "$out" "the id is still printed"
  assert_contains "$(cat "$TMP_ROOT/err")" "bin/fm-workhorse-ring.sh task-b2" "stderr names the exact re-ring"
  assert_equals "2" "$(wh_store_count "$WH_STORE")" "the bead stays filed"
  pass "a lost doorbell exits 4 after printing the filed bead id"
}

test_dry_run_files_and_rings_nothing() {
  local out
  : >"$WH_SEND_LOG"
  out=$(wh_file_valid --dry-run) || fail "dry-run should succeed"
  assert_contains "$out" "## Captain's intent" "dry-run prints the body"
  assert_equals "2" "$(wh_store_count "$WH_STORE")" "dry-run files nothing"
  assert_equals "" "$(cat "$WH_SEND_LOG")" "dry-run rings nothing"
  pass "dry-run prints the body and touches neither the store nor the mate"
}

test_reads_section_text_from_a_file() {
  local out
  printf 'Add a config key that the loader reads at startup, from a file.\n' >"$TMP_ROOT/spec.txt"
  out=$(wh_file_valid --spec "@$TMP_ROOT/spec.txt" --dry-run) || fail "@file text should be accepted"
  assert_contains "$out" "from a file." "the file text reaches the body"
  out=$(wh_file_valid --spec "@$TMP_ROOT/missing.txt" --dry-run 2>&1) && fail "a missing @file must be refused"
  assert_contains "$out" "does not exist" "a missing @file is named"
  pass "@file section text is read, and a missing file is refused"
}

fm_test_run \
  test_refuses_empty_vague_and_placeholder_sections \
  test_refuses_missing_or_bad_evidence_mode_yolo_project_and_mate \
  test_refuses_when_the_pinned_store_is_missing \
  test_files_a_full_brief_in_the_pinned_store \
  test_store_is_pinned_from_a_cwd_with_a_different_beads \
  test_rings_the_workhorse_after_filing \
  test_unconfirmed_ring_exits_4_but_keeps_the_bead \
  test_dry_run_files_and_rings_nothing \
  test_reads_section_text_from_a_file
