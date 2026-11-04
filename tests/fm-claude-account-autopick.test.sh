#!/usr/bin/env bash
# Behavior tests for fm_worker_account_autopick: with config/claude-accounts
# declared and no --account, the entry with the most headroom is chosen, an
# entry below the low threshold is never chosen, and an unreadable entry stays
# eligible behind every measured one.
#
# A fake quota-axi answers from <root>/quota.json, as in
# tests/fm-claude-account-quota.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-account-autopick)

new_case() {
  CASE="$TMP_ROOT/$1"
  CONFIG="$CASE/config"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$CONFIG" "$FAKEBIN" "$CASE/user-home"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -f "$CLAUDE_CONFIG_DIR/quota.json" ] || exit 1
cat "$CLAUDE_CONFIG_DIR/quota.json"
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# account <dir> <percent> [<second-scope-percent>]
account() {
  mkdir -p "$1"
  jq -n --argjson pct "$2" --arg second "${3:-}" '{
    schemaVersion: 5,
    providers: [{provider: "claude", quotaSemantics: {status: "known", effectiveAvailability: ([
      {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
       runway: {status: "through_reset"}, selection: {spendPriority: 0.5}}
    ] + (if $second == "" then [] else [
      {scope: "model:opus", status: "known", effectivePercentRemaining: ($second | tonumber),
       runway: {status: "through_reset"}, selection: {spendPriority: 0.5}}
    ] end))}}]
  }' > "$1/quota.json"
}

declare_accounts() { printf '%s\n' "$@" > "$CONFIG/claude-accounts"; }

# pick [<model>]: runs the selection the way fm-spawn does.
pick() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_CLAUDE_ACCOUNT_LOW_THRESHOLD="${THRESHOLD:-}" \
    bash -c '. "$1/bin/fm-worker-account-lib.sh"; fm_worker_account_autopick "$2" "${3:-}"' _ "$ROOT" "$CONFIG" "${1:-}" 2>&1
}

test_picks_the_account_with_more_headroom() {
  local out rc
  new_case more
  account "$CASE/a" 40
  account "$CASE/b" 85
  declare_accounts "$CASE/a" "$CASE/b"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "two healthy accounts should pick one: $out"
  assert_contains "$out" "$CASE/b"$'\t'"auto-selected $CASE/b (85% headroom >= 20% threshold" "the roomier account should win"
  pass "the account with more headroom is chosen"
}

test_a_low_account_is_never_chosen_and_the_scarcest_scope_counts() {
  local out rc
  new_case low
  account "$CASE/a" 90 10
  account "$CASE/b" 30
  declare_accounts "$CASE/a" "$CASE/b"
  out=$(pick opus); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" "auto-selected $CASE/b (30%" "an account whose model scope is low must lose"
  assert_contains "$out" "skipped low: $CASE/a=10%" "the skipped account should be named"
  pass "an account below the threshold is skipped and its scarcest scope decides"
}

test_every_account_low_refuses() {
  local out rc
  new_case alllow
  account "$CASE/a" 5
  account "$CASE/b" 19
  declare_accounts "$CASE/a" "$CASE/b"
  out=$(pick); rc=$?
  expect_code 1 "$rc" "all-low accounts must refuse: $out"
  assert_contains "$out" "below the 20% low-headroom threshold" "the refusal should name the threshold"
  assert_contains "$out" "name an account with --account" "the refusal should say how to proceed"
  out=$(THRESHOLD=3 pick); rc=$?
  expect_code 0 "$rc" "a lower configured threshold should admit the account: $out"
  assert_contains "$out" "auto-selected $CASE/b (19%" "the threshold override should apply"
  printf '10\n' > "$CONFIG/claude-account-low-threshold"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "the threshold file should apply: $out"
  printf 'lots\n' > "$CONFIG/claude-account-low-threshold"
  out=$(pick); rc=$?
  expect_code 1 "$rc" "a malformed threshold must refuse"
  assert_contains "$out" "low-headroom threshold must be a percentage" "the refusal should explain the value"
  pass "all-low accounts refuse; the threshold is configurable and validated"
}

test_unmeasured_account_stays_eligible_behind_measured_ones() {
  local out rc
  new_case unmeasured
  account "$CASE/b" 50
  mkdir -p "$CASE/a"
  declare_accounts "$CASE/a" "$CASE/b"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" "auto-selected $CASE/b (50%" "a measured healthy account beats an unmeasured one"
  account "$CASE/b" 5
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an unmeasured account should rescue an all-low pool: $out"
  assert_contains "$out" "auto-selected $CASE/a (no usable quota reading" "the unmeasured account should be chosen with disclosed uncertainty"
  pass "an unmeasured account stays eligible, behind every measured healthy one"
}

test_picks_the_account_with_more_headroom
test_a_low_account_is_never_chosen_and_the_scarcest_scope_counts
test_every_account_low_refuses
test_unmeasured_account_stays_eligible_behind_measured_ones

echo "# all fm-claude-account-autopick tests passed"
