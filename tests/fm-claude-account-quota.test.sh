#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account-quota.sh: each account declared in
# config/claude-accounts (ordinary, directory root, or token:<file>) is
# measured in isolation and its quota facts and uncertainty are printed, never
# a token value or an account choice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-account-quota)
TOOL="$ROOT/bin/fm-claude-account-quota.sh"
TOKEN_SECRET="sk-ant-oat01-never-print-or-log-7712"

# new_case <name> -> sets CASE HOME_DIR FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$FAKEBIN" "$CASE/user-home"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\${ANTHROPIC_API_KEY-unset}" "\$*" >> '$CASE/reads'
printf '%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" >> '$CASE/tokens'
if [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if [ -f '$CASE/token-echo-secret' ]; then
    jq -n --arg err "bad auth for \$CLAUDE_CODE_OAUTH_TOKEN" '{
      schemaVersion: 5,
      providers: [{
        provider: "claude",
        state: {status: "auth_error", error: \$err},
        quotaSemantics: {status: "unknown", effectiveAvailability: []}
      }]
    }'
    exit 1
  fi
  [ -f '$CASE/token-quota.json' ] || exit 1
  cat '$CASE/token-quota.json'
  exit 0
fi
root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
[ -f "\$root/quota.json" ] || exit 1
cat "\$root/quota.json"
[ ! -f "\$root/exit-1" ] || exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# account <dir> <all_models-percent> <all_models-spendPriority> [runway] [model-scope-spendPriority] [usableRunwaySeconds]
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

token_account() {
  local file=$1 secret=${2:-$TOKEN_SECRET} mode=${3:-600} pct=${4:-64} sp=${5:-0.35}
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$secret" > "$file"
  chmod "$mode" "$file"
  jq -n --argjson pct "$pct" --argjson sp "$sp" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: {status: "through_reset"},
           selection: {spendPriority: $sp}}
        ]
      }
    }]
  }' > "$CASE/token-quota.json"
}

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
    ANTHROPIC_API_KEY=ambient-api-key QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" "$TOOL" "$@" 2>&1
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
  assert_grep "$CASE/a|unset|unset|--provider claude --profile-only --json" "$CASE/reads" "account a should be read in isolation under its own root"
  assert_grep "$CASE/b|unset|unset|--provider claude --profile-only --json" "$CASE/reads" "account b should be read in isolation under its own root"
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
  printf '%s\n' "$CASE/spent" "$CASE/dry" "$CASE/unread" "$CASE/missing-dir" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/spent  root=$CASE/spent  scope=all_models  status=known  remaining=0%  spendPriority=0.9  runway=through_reset" "a 0% account prints its facts"
  assert_contains "$out" "row: $CASE/dry  root=$CASE/dry  scope=all_models  status=known  remaining=40%  spendPriority=0.8  runway=exhausted_now" "an exhausted account prints its runway"
  assert_contains "$out" "row: $CASE/unread  root=$CASE/unread  uncertainty: quota-axi could not read this account" "an unreadable account is disclosed uncertainty"
  assert_contains "$out" "row: $CASE/missing-dir  root=$CASE/missing-dir  uncertainty: account directory is not readable: $CASE/missing-dir" "a missing directory is disclosed uncertainty"
  assert_no_choice "$out"
  pass "exhausted, 0%, missing, and unreadable accounts print facts and uncertainty without a verdict"
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
    "a missing finite runway prints -"
  pass "projected exhaustion prints usableRunwaySeconds and confidence"
}

test_a_rate_limited_account_names_the_vendor_reason() {
  local out
  new_case ratelimit
  rate_limited_account "$CASE/rl"
  printf '%s\n' "$CASE/rl" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: $CASE/rl  root=$CASE/rl  uncertainty: quota unknown (rate_limited: Claude quota endpoint rate limited)" \
    "a rate-limited account retains the vendor reason"
  pass "a rate-limited account reports the vendor's own state and error"
}

test_ordinary_and_setup_token_are_measured_in_isolation_and_cached() {
  local out json cache_files
  new_case token
  account "$CASE/user-home/.claude" 42 0.15
  token_account "$CASE/token-files/max100.token" "$TOKEN_SECRET" 600 64 0.35
  printf 'ordinary\ntoken:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: ordinary  root=$CASE/user-home/.claude  scope=all_models  status=known  remaining=42%  spendPriority=0.15" "ordinary login should be measured"
  assert_contains "$out" "row: token:max100.token  root=token:$CASE/token-files/max100.token  scope=all_models  status=known  remaining=64%  spendPriority=0.35" "setup-token account should be measured"
  assert_grep "--provider claude --allow-claude-inference --json" "$CASE/reads" "setup-token should use the inference probe"
  assert_not_contains "$(grep 'allow-claude-inference' "$CASE/reads")" "$CASE/user-home/.claude" "setup-token probe must use an isolated empty CLAUDE_CONFIG_DIR, never ~/.claude"
  assert_grep "$TOKEN_SECRET" "$CASE/tokens" "setup-token read should receive the token in environment"
  assert_not_contains "$out$(cat "$CASE/reads")" "$TOKEN_SECRET" "the token must never reach output or arguments"
  run_tool > /dev/null
  [ "$(grep -c 'allow-claude-inference' "$CASE/reads" | tr -d ' ')" = "1" ] || fail "second reading inside cache window must not probe token again"
  cache_files=$(find "$HOME_DIR/state" -name '.claude-account-quota-*.json' -print)
  [ -n "$cache_files" ] || fail "token reading should write a cache file under state/"
  assert_not_contains "$(find "$HOME_DIR/state" -name '.claude-account-quota-*.json' -exec cat {} +)" "$TOKEN_SECRET" "cache file must never contain the token"
  # Updating the token file's mtime invalidates the cache immediately.
  sleep 1
  touch "$CASE/token-files/max100.token"
  json=$(run_tool --json)
  [ "$(grep -c 'allow-claude-inference' "$CASE/reads" | tr -d ' ')" = "2" ] || fail "updated token file mtime should invalidate stale cache"
  assert_equals "2" "$(jq -r '.accounts | length' <<<"$json")" "--json returns both declared accounts"
  assert_not_contains "$json" "$TOKEN_SECRET" "--json output must never contain the token"
  # Even if quota-axi echoed the token in an error message, scrub_token_from_file redacts it.
  : > "$CASE/token-echo-secret"
  out=$(env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 "$TOOL" 2>&1)
  assert_not_contains "$out" "$TOKEN_SECRET" "even an error echoing the token must be redacted before output"
  assert_contains "$out" "[REDACTED]" "the echoed token is replaced with [REDACTED]"
  pass "ordinary and token:<file> accounts are measured in isolation, cached safely, and never leak the token"
}

test_a_refused_token_file_is_uncertainty_and_never_read() {
  local out
  new_case badtoken
  token_account "$CASE/token-files/open.token" "sk-ant-oat01-openvalue" 644
  token_account "$CASE/token-files/multi.token" "sk-ant-oat01-multi" 600
  printf 'second line\n' >> "$CASE/token-files/multi.token"
  printf 'token:%s\ntoken:%s\n' "$CASE/token-files/open.token" "$CASE/token-files/multi.token" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool)
  assert_contains "$out" "row: token:open.token  root=token:$CASE/token-files/open.token  uncertainty: setup-token file unusable:" "a group-readable token file is reported unmeasured"
  assert_contains "$out" "row: token:multi.token  root=token:$CASE/token-files/multi.token  uncertainty: setup-token file unusable:" "a multiline token file is reported unmeasured"
  assert_absent "$CASE/reads" "a refused token file must not invoke quota-axi"
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
  assert_grep "unset|unset|unset|--provider claude --json" "$CASE/reads" "ordinary should be read with the config root unset"
  assert_grep "$CASE/kc|unset|unset|--provider claude --json" "$CASE/reads" "a custom root should be read under its own root"
  assert_not_contains "$(cat "$CASE/reads")" "--profile-only" "a Keychain root must not use the file-only read"
  assert_not_contains "$(cat "$CASE/tokens")" "ambient-token" "an ambient token must not answer for a Keychain root"
  pass "Keychain-kept roots are measured without the file-only flag and without an ambient token"
}

test_missing_quota_axi_and_malformed_lists() {
  local out rc nobin
  new_case refuse
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "an absent list must refuse"
  assert_contains "$out" "declares no config/claude-accounts" "the refusal should name the missing list"
  printf 'relative\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a malformed list must refuse"
  assert_contains "$out" "config/claude-accounts must hold one account per line" "the refusal should name the format"
  printf 'ordinary\nordinary\n' > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool); rc=$?
  expect_code 2 "$rc" "a duplicate list entry must refuse"
  assert_contains "$out" "declares the same account twice" "the refusal should name duplicate entries"
  assert_absent "$CASE/reads" "a refused list must not read any quota"

  printf 'ordinary\n' > "$HOME_DIR/config/claude-accounts"
  nobin="$CASE/nobin"
  mkdir -p "$nobin"
  for cmd in awk basename bash cat chmod cksum cp dirname env head jq mktemp mv perl rm sleep tr uname; do
    command -v "$cmd" >/dev/null 2>&1 && ln -s "$(command -v "$cmd")" "$nobin/$cmd"
  done
  out=$(env -i HOME="$CASE/user-home" PATH="$nobin" FM_HOME="$HOME_DIR" "$TOOL" --json 2>&1); rc=$?
  expect_code 0 "$rc" "missing quota-axi exits 0 with in-band error: $out"
  assert_equals "quota-axi not installed" "$(jq -r '.accounts[0].error' <<<"$out")" "--json reports missing quota-axi on each declared account"
  pass "absent or malformed lists refuse before any read, and missing quota-axi reports in-band uncertainty"
}

test_two_accounts_print_their_own_rows
test_the_model_scope_is_printed
test_exhausted_and_unreadable_accounts_print_facts
test_projected_runway_prints_its_seconds
test_a_rate_limited_account_names_the_vendor_reason
test_ordinary_and_setup_token_are_measured_in_isolation_and_cached
test_a_refused_token_file_is_uncertainty_and_never_read
test_a_keychain_root_is_read_without_the_file_only_flag
test_missing_quota_axi_and_malformed_lists

echo "# all fm-claude-account-quota tests passed"
