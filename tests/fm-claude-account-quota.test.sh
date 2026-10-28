#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account-quota.sh: each account declared in
# config/claude-accounts is measured under its own CLAUDE_CONFIG_DIR and its
# quota facts and uncertainty are printed, never a choice.
#
# A fake quota-axi answers from <root>/quota.json, the way the real read
# answers from that root's own credential, and logs the root and arguments of
# every read plus, apart from the arguments, the setup token it was given. A
# root holds its login as <root>/.credentials.json (read with --profile-only),
# as <root>/.oauth-token (a setup token), or in the Keychain (neither file).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-account-quota)
TOOL="$ROOT/bin/fm-claude-account-quota.sh"

# new_case <name> -> sets CASE HOME_DIR FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$CASE/user-home"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s %s %s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$CASE/reads'
printf '%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" >> '$CASE/tokens'
root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
[ -f "\$root/quota.json" ] || exit 1
cat "\$root/quota.json"
[ ! -f "\$root/exit-1" ] || exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# account <dir> <all_models-percent> <all_models-spendPriority> [runway] [model-scope-spendPriority] [usableRunwaySeconds]
# A Claude root whose profile-only read reports these numbers.
account() {
  local dir=$1 pct=$2 sp=$3 runway=${4:-through_reset} model_sp=${5:-} seconds=${6:-}
  mkdir -p "$dir"
  : > "$dir/.credentials.json"
  jq -n --argjson pct "$pct" --argjson sp "$sp" --arg runway "$runway" --arg model_sp "$model_sp" --arg seconds "$seconds" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      quotaSemantics: {
        status: "known",
        effectiveAvailability: ([
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: ({status: $runway} + (if $seconds == "" then {} else {usableRunwaySeconds: ($seconds | tonumber), projectionConfidence: "established"} end)),
           selection: {spendPriority: $sp}}
        ] + (if $model_sp == "" then [] else [
          {scope: "model:opus", status: "known", effectivePercentRemaining: 50,
           runway: {status: "through_reset"}, selection: {spendPriority: ($model_sp | tonumber)}}
        ] end))
      }
    }]
  }' > "$dir/quota.json"
}

# rate_limited_account <dir>: a root whose read the vendor rate-limits, which
# quota-axi reports with exit 1 and a snapshot naming that state.
rate_limited_account() {
  mkdir -p "$1"
  : > "$1/.credentials.json"
  jq -n '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      state: {status: "rate_limited", error: "Claude quota endpoint rate limited"},
      quotaSemantics: {status: "unknown", effectiveAvailability: []}
    }]
  }' > "$1/quota.json"
  : > "$1/exit-1"
}

run_tool() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" "$TOOL" "$@" 2>&1
}

assert_no_choice() {
  assert_not_contains "$1" "--account" "the tool must not print a chosen account"
  assert_not_contains "$1" "status: " "the tool must not print a verdict status"
  assert_not_contains "$1" "eligible" "the tool must not judge eligibility"
}

test_two_accounts_print_their_own_rows() {
  local out rc
  new_case two
  account "$CASE/a" 70 0.2
  account "$CASE/b" 60 0.5
  printf '%s\n%s\n' "$CASE/a" "$CASE/b" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 0 "$rc" "measuring two declared accounts should succeed: $out"
  assert_contains "$out" "row: $CASE/a  root=$CASE/a  scope=all_models  status=known  remaining=70%  spendPriority=0.2  runway=through_reset" "account a's own row should be shown"
  assert_contains "$out" "row: $CASE/b  root=$CASE/b  scope=all_models  status=known  remaining=60%  spendPriority=0.5  runway=through_reset" "account b's own row should be shown"
  assert_no_choice "$out"
  assert_grep "$CASE/a unset --provider claude --profile-only --json" "$CASE/reads" "account a should be read in isolation under its own root"
  assert_grep "$CASE/b unset --provider claude --profile-only --json" "$CASE/reads" "account b should be read in isolation under its own root"
  pass "each declared account prints its own quota row, read under its own root"
}

test_the_model_scope_is_printed() {
  local out
  new_case model
  account "$CASE/a" 70 0.2 through_reset 0.9
  printf '%s\n' "$CASE/a" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool --model opus)
  assert_contains "$out" "row: $CASE/a  root=$CASE/a  scope=all_models  status=known  remaining=70%  spendPriority=0.2" "the all_models scope applies to the model"
  assert_contains "$out" "row: $CASE/a  root=$CASE/a  scope=model:opus  status=known  remaining=50%  spendPriority=0.9" "the model scope should be printed"
  out=$(run_tool)
  assert_not_contains "$out" "scope=model:opus" "a model scope does not apply without --model"
  assert_no_choice "$out"
  pass "a model-specific scope is printed only for that model"
}

test_exhausted_and_unreadable_accounts_print_facts() {
  local out
  new_case gates
  account "$CASE/spent" 0 0.9
  account "$CASE/dry" 40 0.8 exhausted_now
  mkdir -p "$CASE/unread"
  printf '%s\n' "$CASE/spent" "$CASE/dry" "$CASE/unread" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/spent  root=$CASE/spent  scope=all_models  status=known  remaining=0%  spendPriority=0.9  runway=through_reset" "a 0% account prints its facts"
  assert_contains "$out" "row: $CASE/dry  root=$CASE/dry  scope=all_models  status=known  remaining=40%  spendPriority=0.8  runway=exhausted_now" "an exhausted account prints its runway"
  assert_contains "$out" "row: $CASE/unread  root=$CASE/unread  uncertainty: quota-axi could not read this account" "an unreadable account is disclosed uncertainty"
  assert_no_choice "$out"
  pass "exhausted, 0%, and unreadable accounts print facts and uncertainty without a verdict"
}

test_projected_runway_prints_its_seconds() {
  local out
  new_case runway
  account "$CASE/long" 80 0.4 projected_exhaustion "" 241920
  account "$CASE/short" 30 0.9 projected_exhaustion "" 2700
  account "$CASE/unknown" 50 0.5 projected_exhaustion
  printf '%s\n' "$CASE/long" "$CASE/short" "$CASE/unknown" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/long  root=$CASE/long  scope=all_models  status=known  remaining=80%  spendPriority=0.4  runway=projected_exhaustion  usableRunwaySeconds=241920  confidence=established" \
    "a projected exhaustion should carry its runway seconds"
  assert_contains "$out" "row: $CASE/short  root=$CASE/short  scope=all_models  status=known  remaining=30%  spendPriority=0.9  runway=projected_exhaustion  usableRunwaySeconds=2700  confidence=established" \
    "each account should carry its own runway seconds"
  assert_contains "$out" "row: $CASE/unknown  root=$CASE/unknown  scope=all_models  status=known  remaining=50%  spendPriority=0.5  runway=projected_exhaustion  usableRunwaySeconds=-" \
    "a projection without seconds should show that it is missing"
  assert_not_contains "$out" "runway=through_reset  usableRunwaySeconds" "through_reset carries no runway seconds"
  assert_no_choice "$out"
  pass "a projected exhaustion prints each account's own runway seconds and confidence without a verdict"
}

test_a_rate_limited_account_names_the_vendor_reason() {
  local out
  new_case rate-limited
  rate_limited_account "$CASE/limited"
  printf '%s\n' "$CASE/limited" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/limited  root=$CASE/limited  uncertainty: quota unknown (rate_limited: Claude quota endpoint rate limited)" \
    "a rate-limited read should keep quota-axi's own reason, not report an unreadable account"
  assert_not_contains "$out" "could not read" "a rate-limited snapshot is not an unreadable root"
  assert_no_choice "$out"
  pass "a rate-limited account names the vendor's reason"
}

test_ordinary_is_measured_from_the_default_root() {
  local out
  new_case ordinary
  account "$CASE/user-home/.claude" 50 0.3
  printf 'ordinary\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=50%  spendPriority=0.3" "the ordinary account should be measurable"
  assert_no_choice "$out"
  assert_grep "$CASE/user-home/.claude unset" "$CASE/reads" "ordinary should be read from ~/.claude"
  pass "ordinary is measured from the default ~/.claude root"
}

# token_account <dir> <token> [mode]: an account whose login is a setup token.
token_account() {
  account "$1" 64 0.35
  rm -f "$1/.credentials.json"
  printf '%s\n' "$2" > "$1/.oauth-token"
  chmod "${3:-600}" "$1/.oauth-token"
}

test_a_setup_token_root_is_read_under_its_token_and_cached() {
  local out
  new_case token
  token_account "$CASE/mb" sk-ant-oat01-secretvalue
  printf '%s\n' "$CASE/mb" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/mb  root=$CASE/mb  scope=all_models  status=known  remaining=64%  spendPriority=0.35" "a setup-token account should be measured"
  assert_grep "$CASE/mb unset --provider claude --allow-claude-inference --json" "$CASE/reads" "a token root should be read with the inference probe, pinned to its own root"
  assert_not_contains "$(cat "$CASE/reads")" "--profile-only" "a token root must not use the file-only read"
  assert_grep "sk-ant-oat01-secretvalue" "$CASE/tokens" "the read should run under the root's own token"
  assert_not_contains "$out$(cat "$CASE/reads")" "sk-ant-oat01-secretvalue" "the token must never reach output or arguments"
  run_tool > /dev/null
  expect_code 1 "$(wc -l < "$CASE/reads" | tr -d ' ')" "a second reading inside the cache window should not probe again"
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 "$TOOL" > /dev/null 2>&1
  expect_code 2 "$(wc -l < "$CASE/reads" | tr -d ' ')" "a disabled cache should probe again"
  pass "a setup-token root is measured under its own token with one cached inference probe"
}

test_a_refused_token_file_is_uncertainty_and_never_read() {
  local out
  new_case badtoken
  token_account "$CASE/open" sk-ant-oat01-openvalue 644
  token_account "$CASE/multi" sk-ant-oat01-multi
  printf 'second line\n' >> "$CASE/multi/.oauth-token"
  printf '%s\n' "$CASE/open" "$CASE/multi" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/open  root=$CASE/open  uncertainty: setup-token file unusable:" "a group-readable token file is reported unmeasured"
  assert_contains "$out" "row: $CASE/multi  root=$CASE/multi  uncertainty: setup-token file unusable:" "a multiline token file is reported unmeasured"
  assert_absent "$CASE/reads" "a refused token file must not be read"
  assert_not_contains "$out" "sk-ant-oat01" "a refused token must never be echoed"
  pass "an unusable token file is disclosed uncertainty and never read"
}

test_a_keychain_root_is_read_without_the_file_only_flag() {
  local out
  new_case keychain
  account "$CASE/kc" 55 0.45
  rm -f "$CASE/kc/.credentials.json"
  account "$CASE/user-home/.claude" 40 0.6
  rm -f "$CASE/user-home/.claude/.credentials.json"
  printf 'ordinary\n%s\n' "$CASE/kc" > "$HOME_DIR/config/claude-accounts"
  out=$(env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" CLAUDE_CODE_OAUTH_TOKEN=ambient-token \
    CLAUDE_CONFIG_DIR=/ambient/root QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" "$TOOL" 2>&1)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=40%" "a Keychain-kept ordinary login should be measured"
  assert_contains "$out" "row: $CASE/kc  root=$CASE/kc  scope=all_models  status=known  remaining=55%" "a Keychain-kept custom root should be measured"
  assert_grep "unset unset --provider claude --json" "$CASE/reads" "ordinary should be read with the config root unset"
  assert_grep "$CASE/kc unset --provider claude --json" "$CASE/reads" "a custom root should be read under its own root"
  assert_not_contains "$(cat "$CASE/reads")" "--profile-only" "a Keychain root must not use the file-only read"
  assert_not_contains "$(cat "$CASE/tokens")" "ambient-token" "an ambient token must not answer for a Keychain root"
  pass "Keychain-kept roots are measured without the file-only flag and without an ambient token"
}

test_absent_or_malformed_lists_refuse() {
  local out rc
  new_case refuse
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "an absent list must refuse"
  assert_contains "$out" "declares no config/claude-accounts" "the refusal should name the missing list"
  printf 'relative\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a malformed list must refuse"
  assert_contains "$out" "config/claude-accounts must hold one account per line" "the refusal should name the format"
  assert_absent "$CASE/reads" "a refused list must not read any quota"
  pass "an absent or malformed list refuses before any quota read"
}

test_two_accounts_print_their_own_rows
test_the_model_scope_is_printed
test_exhausted_and_unreadable_accounts_print_facts
test_projected_runway_prints_its_seconds
test_a_rate_limited_account_names_the_vendor_reason
test_ordinary_is_measured_from_the_default_root
test_a_setup_token_root_is_read_under_its_token_and_cached
test_a_refused_token_file_is_uncertainty_and_never_read
test_a_keychain_root_is_read_without_the_file_only_flag
test_absent_or_malformed_lists_refuse

echo "# all fm-claude-account-quota tests passed"
