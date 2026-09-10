#!/usr/bin/env bash
# tests/fm-backend-herdr-pane-labels.test.sh - visible Herdr pane naming
# convention ("<harness> <agent> <label>": owner crown labels, worker
# harness-plus-agent-plus-task labels, and captain-set preservation).
# Fake-herdr-CLI unit tests against bin/backends/herdr.sh, following
# tests/fm-backend-herdr.test.sh's fakebin/command-log convention with real
# jq.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-pane-labels)

make_herdr_fakebin() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
n=$next
echo "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

pane_get_response() {
  local pane=$1 label_json=$2 tab=${3:-w1:t1}
  printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1"%s}}}\n' "$pane" "$tab" "$label_json"
}

test_owner_labels_carry_crown() {
  local got
  got=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_owner_pane_label pi Firstmate' "$ROOT")
  [ "$got" = "Pi Firstmate 👑" ] || fail "owner Firstmate label mismatch (got: '$got')"
  got=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_owner_pane_label pi TalonMate' "$ROOT")
  [ "$got" = "Pi TalonMate 👑" ] || fail "owner TalonMate label mismatch (got: '$got')"
  pass "pane naming: owner panes use the active harness plus role and crown"
}

test_worker_labels_carry_agent_task_and_no_crown() {
  local got
  got=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_worker_pane_label pi Firstmate task-d6376' "$ROOT")
  [ "$got" = "Pi Firstmate · task-d6376" ] || fail "worker label mismatch (got: '$got')"
  case "$got" in
    *"👑"*) fail "worker pane label must never use a crown (got: '$got')" ;;
  esac
  got=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_worker_pane_label pi TalonMate task-0c6bs' "$ROOT")
  [ "$got" = "Pi TalonMate · task-0c6bs" ] || fail "secondmate worker label mismatch (got: '$got')"
  got=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_harness_display pi-signed' "$ROOT")
  [ "$got" = "Pi" ] || fail "pi-signed must share Pi display (got: '$got')"
  pass "pane naming: worker panes carry harness plus owning agent plus task id with no crown"
}

test_owner_role_for_home() {
  local home got
  home="$TMP_ROOT/primary-home"; mkdir -p "$home"
  got=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_owner_role_for_home' "$ROOT")
  [ "$got" = "Firstmate" ] || fail "primary home role mismatch (got: '$got')"
  home="$TMP_ROOT/talon-home"; mkdir -p "$home"
  printf 'talonmate\n' > "$home/.fm-secondmate-home"
  got=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_owner_role_for_home' "$ROOT")
  [ "$got" = "TalonMate" ] || fail "secondmate home role mismatch (got: '$got')"
  home="$TMP_ROOT/other-home"; mkdir -p "$home"
  printf 'beadme\n' > "$home/.fm-secondmate-home"
  got=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_owner_role_for_home' "$ROOT")
  [ "$got" = "Beadme" ] || fail "generic secondmate home role mismatch (got: '$got')"
  pass "pane naming: owner role resolves per home through the secondmate marker"
}

test_ensure_applies_label_to_unlabeled_pane() {
  local dir log resp fb out status
  dir="$TMP_ROOT/apply"; log="$dir/log"; resp="$dir/responses"
  mkdir -p "$resp"; : > "$log"
  pane_get_response "w1:p1" "" > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_ensure_pane_label default w1:p1 "Pi Firstmate · task-d6376"' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "ensure on an unlabeled pane should succeed" "$out"
  assert_contains "$(cat "$log")" "pane"$'\x1f'"rename"$'\x1f'"w1:p1"$'\x1f'"Pi Firstmate · task-d6376" "ensure did not rename the unlabeled pane to the worker label"
  assert_not_contains "$(cat "$log")" "focus" "ensure must never move focus while labeling"
  pass "pane naming: an unlabeled managed pane receives the automatic label without touching focus"
}

test_ensure_upgrades_legacy_fm_pane_label() {
  local dir log resp fb out status
  dir="$TMP_ROOT/legacy"; log="$dir/log"; resp="$dir/responses"
  mkdir -p "$resp"; : > "$log"
  pane_get_response "w1:p1" ',"label":"fm-task-d6376"' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_ensure_pane_label default w1:p1 "Pi Firstmate · task-d6376"' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "ensure on a legacy fm- pane label should succeed" "$out"
  assert_contains "$(cat "$log")" "pane"$'\x1f'"rename"$'\x1f'"w1:p1"$'\x1f'"Pi Firstmate · task-d6376" "ensure did not upgrade the legacy pane label to the visible convention"
  pass "pane naming: a legacy identity-mirroring pane label upgrades to the visible convention"
}

test_ensure_preserves_near_miss_label() {
  local dir log resp fb out status calls
  dir="$TMP_ROOT/nearmiss"; log="$dir/log"; resp="$dir/responses"
  mkdir -p "$resp"; : > "$log"
  pane_get_response "w1:p1" ',"label":"Pi Firstmate"' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_ensure_pane_label default w1:p1 "Pi Firstmate 👑"' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "ensure on a near-miss label should succeed without renaming" "$out"
  assert_not_contains "$(cat "$log")" "rename" "ensure overwrote a near-miss label a captain may have typed by hand"
  calls=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$calls" = 1 ] || fail "ensure on a near-miss label should make no rename call (got $calls calls)"
  pass "pane naming: a harness-shaped label without crown or task is preserved as captain-set"
}

test_ensure_preserves_captain_set_label() {
  local dir log resp fb out status calls
  dir="$TMP_ROOT/preserve"; log="$dir/log"; resp="$dir/responses"
  mkdir -p "$resp"; : > "$log"
  pane_get_response "w1:p1" ',"label":"My custom label"' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_ensure_pane_label default w1:p1 "Pi Firstmate · task-d6376"' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "ensure on a captain-set label should succeed without renaming" "$out"
  assert_not_contains "$(cat "$log")" "rename" "ensure overwrote a captain-set pane label"
  calls=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$calls" = 1 ] || fail "ensure on a captain-set label should make no rename call (got $calls calls)"
  pass "pane naming: an existing captain-set label is preserved without overwriting"
}

test_task_identity_survives_visible_pane_label() {
  local dir log resp fb out status
  dir="$TMP_ROOT/identity"; log="$dir/log"; resp="$dir/responses"
  mkdir -p "$resp"; : > "$log"
  pane_get_response "w1:p1" ',"label":"Pi Firstmate · task-d6376"' "w1:t9" > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t9","workspace_id":"w1","label":"fm-task-d6376"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_verifies_task default w1:p1 task-d6376' "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "task identity must verify through the tab when the pane carries the visible label" "$out"
  pass "pane naming: existing task identity still verifies after the visible rename"
}

test_task_identity_rejects_foreign_pane() {
  local dir log resp fb out status
  dir="$TMP_ROOT/foreign"; log="$dir/log"; resp="$dir/responses"
  mkdir -p "$resp"; : > "$log"
  pane_get_response "w1:p1" ',"label":"My custom label"' "w1:t9" > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t9","workspace_id":"w1","label":"fm-other-task"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_verifies_task default w1:p1 task-d6376' "$ROOT" 2>&1)
  status=$?
  expect_code 1 "$status" "task identity must reject a pane whose tab carries another task" "$out"
  pass "pane naming: the tab fallback does not over-accept a foreign task tab"
}

test_owner_labels_carry_crown
test_worker_labels_carry_agent_task_and_no_crown
test_owner_role_for_home
test_ensure_applies_label_to_unlabeled_pane
test_ensure_upgrades_legacy_fm_pane_label
test_ensure_preserves_near_miss_label
test_ensure_preserves_captain_set_label
test_task_identity_survives_visible_pane_label
test_task_identity_rejects_foreign_pane
