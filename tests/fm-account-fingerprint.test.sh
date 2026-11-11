#!/usr/bin/env bash
# Behavior tests for bin/fm-account-fingerprint.sh - inspect and report
# credential fingerprint, auth method, and account usage bucket for a worker
# task or current environment, with live-worker grouping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-account-fingerprint)
TOOL="$ROOT/bin/fm-account-fingerprint.sh"
TOKEN_SECRET_1="sk-ant-oat01-secret-token-number-one-never-leak"
TOKEN_SECRET_2="sk-ant-oat01-secret-token-number-two-different"

new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$CASE/tokens" "$CASE/user-home"
}

make_token_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-$TOKEN_SECRET_1}" > "$1"
  chmod "${3:-600}" "$1"
}

write_meta() { # <id> <key=val>...
  local id=$1 meta="$HOME_DIR/state/$1.meta"
  shift
  mkdir -p "$HOME_DIR/state"
  : > "$meta"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$meta"
  done
}

test_setup_token_worker() {
  new_case setup-token
  local tok_file="$CASE/tokens/alpha.token"
  make_token_file "$tok_file" "$TOKEN_SECRET_1"
  printf 'account: alpha-user@example.com\nkind: Claude Code setup token\n' > "$CASE/tokens/alpha.meta"

  write_meta "task-tok1" \
    "harness=claude" \
    "account=token:alpha.token" \
    "account_request=token:$tok_file"

  local out rc
  out=$(FM_HOME="$HOME_DIR" "$TOOL" task-tok1); rc=$?
  expect_code 0 "$rc" "single task lookup should succeed"
  assert_contains "$out" "target: task-tok1" "reports target"
  assert_contains "$out" "harness: claude" "reports harness"
  assert_contains "$out" "auth_method: setup token" "reports auth method"
  assert_contains "$out" "account: alpha-user@example.com" "extracts account email from companion .meta"
  assert_not_contains "$out" "$TOKEN_SECRET_1" "never prints or leaks secret token"

  local fp
  fp=$(printf '%s\n' "$out" | awk '/^fingerprint:/ {print $2}')
  [ "${#fp}" -eq 12 ] || fail "fingerprint must be 12 characters: $fp"
  [[ "$fp" =~ ^[0-9a-f]{12}$ ]] || fail "fingerprint must be hexadecimal: $fp"
  pass "setup token worker is correctly fingerprinted and reported"
}

test_fingerprint_stability_and_distinctness() {
  new_case stability
  local tok_file1="$CASE/tokens/one.token"
  local tok_file2="$CASE/tokens/two.token"
  make_token_file "$tok_file1" "$TOKEN_SECRET_1"
  make_token_file "$tok_file2" "$TOKEN_SECRET_2"

  write_meta "task-one-a" "harness=claude" "account_request=token:$tok_file1"
  write_meta "task-one-b" "harness=claude" "account_request=token:$tok_file1"
  write_meta "task-two"   "harness=claude" "account_request=token:$tok_file2"

  local out_1a out_1b out_2 fp_1a fp_1b fp_2
  out_1a=$(FM_HOME="$HOME_DIR" "$TOOL" task-one-a)
  out_1b=$(FM_HOME="$HOME_DIR" "$TOOL" task-one-b)
  out_2=$(FM_HOME="$HOME_DIR" "$TOOL" task-two)

  fp_1a=$(printf '%s\n' "$out_1a" | awk '/^fingerprint:/ {print $2}')
  fp_1b=$(printf '%s\n' "$out_1b" | awk '/^fingerprint:/ {print $2}')
  fp_2=$(printf '%s\n' "$out_2" | awk '/^fingerprint:/ {print $2}')

  [ "$fp_1a" = "$fp_1b" ] || fail "same token must produce identical fingerprint ($fp_1a vs $fp_1b)"
  [ "$fp_1a" != "$fp_2" ] || fail "different tokens must produce distinct fingerprints ($fp_1a vs $fp_2)"
  assert_not_contains "$out_1a$out_1b$out_2" "$TOKEN_SECRET_1" "token 1 secret must not leak"
  assert_not_contains "$out_1a$out_1b$out_2" "$TOKEN_SECRET_2" "token 2 secret must not leak"
  pass "fingerprint is stable across tasks sharing a credential and distinct for different credentials"
}

test_unreadable_token_reports_unknown() {
  new_case unreadable
  local loose_file="$CASE/tokens/loose.token"
  make_token_file "$loose_file" "$TOKEN_SECRET_1" 644  # group-readable mode

  write_meta "task-loose" "harness=claude" "account_request=token:$loose_file"
  write_meta "task-missing" "harness=claude" "account_request=token:$CASE/tokens/nonexistent.token"

  local out_loose out_missing
  out_loose=$(FM_HOME="$HOME_DIR" "$TOOL" task-loose)
  out_missing=$(FM_HOME="$HOME_DIR" "$TOOL" task-missing)

  assert_contains "$out_loose" "fingerprint: unknown" "loose permissions report unknown fingerprint"
  assert_contains "$out_missing" "fingerprint: unknown" "missing token reports unknown fingerprint"
  pass "unreadable token files report unknown fingerprint without erroring"
}

test_ordinary_claude_worker() {
  new_case ordinary
  write_meta "task-ord-present" "harness=claude" "account=ordinary"
  write_meta "task-ord-absent"  "harness=claude" "account=ordinary"

  local cfg_dir="$CASE/claude-config"
  mkdir -p "$cfg_dir"
  printf '{"sessionKey":"sess-oauth-test-12345"}\n' > "$cfg_dir/.credentials.json"

  local out_pres out_abs
  out_pres=$(FM_HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$cfg_dir" "$TOOL" task-ord-present)
  out_abs=$(FM_HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CASE/empty-dir" "$TOOL" task-ord-absent)

  assert_contains "$out_pres" "auth_method: subscription login" "reports subscription login"
  assert_contains "$out_pres" "account: ordinary" "reports ordinary account"
  local fp_pres
  fp_pres=$(printf '%s\n' "$out_pres" | awk '/^fingerprint:/ {print $2}')
  [ "${#fp_pres}" -eq 12 ] || fail "present credentials.json must produce 12-char fingerprint"

  assert_contains "$out_abs" "fingerprint: unknown" "absent credentials.json produces unknown fingerprint"
  pass "ordinary Claude account with present vs absent credentials is distinguished"
}

test_pi_worker() {
  new_case pi
  local pi_dir="$CASE/pi-agent"
  mkdir -p "$pi_dir"
  cat > "$pi_dir/auth.json" <<'EOF'
{
  "anthropic": {
    "type": "api_key",
    "key": "sk-ant-api03-pi-secret-key-123"
  },
  "openai": {
    "type": "oauth",
    "email": "pi-user@example.com",
    "access": "tok-openai-access-999"
  }
}
EOF

  write_meta "task-pi-key" \
    "harness=pi" \
    "account=$pi_dir" \
    "account_provider=anthropic"

  write_meta "task-pi-oauth" \
    "harness=pi" \
    "account=$pi_dir" \
    "account_provider=openai"

  local out_key out_oauth
  out_key=$(FM_HOME="$HOME_DIR" "$TOOL" task-pi-key)
  out_oauth=$(FM_HOME="$HOME_DIR" "$TOOL" task-pi-oauth)

  assert_contains "$out_key" "auth_method: API key" "Pi with api_key type reports API key"
  assert_contains "$out_key" "account: anthropic" "Pi reports provider name"
  assert_not_contains "$out_key" "sk-ant-api03" "API key secret never leaks"

  assert_contains "$out_oauth" "auth_method: subscription login" "Pi with oauth type reports subscription login"
  assert_contains "$out_oauth" "account: pi-user@example.com" "Pi reports email label when available"
  assert_not_contains "$out_oauth" "tok-openai" "OAuth access secret never leaks"

  local fp_key fp_oauth
  fp_key=$(printf '%s\n' "$out_key" | awk '/^fingerprint:/ {print $2}')
  fp_oauth=$(printf '%s\n' "$out_oauth" | awk '/^fingerprint:/ {print $2}')
  [ "${#fp_key}" -eq 12 ] || fail "Pi key fingerprint must be 12 chars: $fp_key"
  [ "${#fp_oauth}" -eq 12 ] || fail "Pi oauth fingerprint must be 12 chars: $fp_oauth"
  [ "$fp_key" != "$fp_oauth" ] || fail "different providers must have distinct fingerprints"
  pass "Pi harness with API key and OAuth credentials is handled correctly"
}

test_codex_and_grok() {
  new_case other-harnesses
  local user_home="$CASE/user-home"
  mkdir -p "$user_home/.codex" "$user_home/.grok"

  cat > "$user_home/.codex/auth.json" <<'EOF'
{
  "auth_mode": "chatgpt",
  "tokens": {
    "access_token": "secret-codex-access-token-456"
  }
}
EOF

  cat > "$user_home/.grok/auth.json" <<'EOF'
{
  "https://auth.x.ai::1234": {
    "access_token": "secret-grok-access-token-789"
  }
}
EOF

  write_meta "task-codex" "harness=codex"
  write_meta "task-grok"  "harness=grok"

  local out_codex out_grok
  out_codex=$(FM_HOME="$HOME_DIR" HOME="$user_home" "$TOOL" task-codex)
  out_grok=$(FM_HOME="$HOME_DIR" HOME="$user_home" "$TOOL" task-grok)

  assert_contains "$out_codex" "harness: codex"
  assert_contains "$out_codex" "auth_method: subscription login"
  assert_not_contains "$out_codex" "secret-codex"

  assert_contains "$out_grok" "harness: grok"
  assert_contains "$out_grok" "auth_method: subscription login"
  assert_not_contains "$out_grok" "secret-grok"

  local fp_c fp_g
  fp_c=$(printf '%s\n' "$out_codex" | awk '/^fingerprint:/ {print $2}')
  fp_g=$(printf '%s\n' "$out_grok" | awk '/^fingerprint:/ {print $2}')
  [ "${#fp_c}" -eq 12 ] || fail "Codex fingerprint must be 12 chars"
  [ "${#fp_g}" -eq 12 ] || fail "Grok fingerprint must be 12 chars"
  pass "Codex and Grok harnesses with stored auth.json are correctly fingerprinted"
}

test_current_environment() {
  new_case current-env
  local out_oauth out_api out_json
  out_oauth=$(FM_HOME="$HOME_DIR" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN_SECRET_1" "$TOOL" --current)
  assert_contains "$out_oauth" "target: current"
  assert_contains "$out_oauth" "harness: claude"
  assert_contains "$out_oauth" "auth_method: setup token"
  assert_contains "$out_oauth" "account: CLAUDE_CODE_OAUTH_TOKEN"
  assert_not_contains "$out_oauth" "$TOKEN_SECRET_1"

  out_api=$(FM_HOME="$HOME_DIR" env -u CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY="sk-ant-test-api-key" "$TOOL" --current)
  assert_contains "$out_api" "target: current"
  assert_contains "$out_api" "harness: claude"
  assert_contains "$out_api" "auth_method: API key"
  assert_contains "$out_api" "account: ANTHROPIC_API_KEY"

  out_json=$(FM_HOME="$HOME_DIR" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN_SECRET_1" "$TOOL" --current --json)
  [ "$(printf '%s\n' "$out_json" | jq -r .target)" = "current" ] || fail "JSON output target must be current"
  [ "$(printf '%s\n' "$out_json" | jq -r .auth_method)" = "setup token" ] || fail "JSON auth_method must be setup token"
  pass "current environment inspection works for env credentials"
}

test_group_live_workers() {
  new_case group-workers
  local tok_shared="$CASE/tokens/shared.token"
  local tok_solo="$CASE/tokens/solo.token"
  make_token_file "$tok_shared" "$TOKEN_SECRET_1"
  make_token_file "$tok_solo" "$TOKEN_SECRET_2"
  printf 'account: team@example.com\n' > "$CASE/tokens/shared.meta"

  write_meta "worker-1" "harness=claude" "account_request=token:$tok_shared"
  write_meta "worker-2" "harness=claude" "account_request=token:$tok_shared"
  write_meta "worker-3" "harness=claude" "account_request=token:$tok_solo"
  write_meta "worker-4" "harness=claude" "account=ordinary"

  local out
  out=$(FM_HOME="$HOME_DIR" "$TOOL" --group)
  assert_contains "$out" "account: team@example.com" "grouped output carries team account"
  assert_contains "$out" "- worker-1" "worker-1 is listed"
  assert_contains "$out" "- worker-2" "worker-2 is listed"
  assert_contains "$out" "- worker-3" "worker-3 is listed"
  assert_contains "$out" "- worker-4" "worker-4 is listed"

  # In JSON mode, verify group counts and members
  local json_out
  json_out=$(FM_HOME="$HOME_DIR" "$TOOL" --group --json)
  [ "$(printf '%s\n' "$json_out" | jq '.workers | length')" -eq 4 ] || fail "JSON must report 4 workers"

  # Find the group containing worker-1 and verify worker-2 is in the same group
  local shared_count
  shared_count=$(printf '%s\n' "$json_out" | jq '[.groups[] | select(.workers | contains(["worker-1", "worker-2"]))] | length')
  [ "$shared_count" -eq 1 ] || fail "worker-1 and worker-2 must share a single group in JSON output"

  pass "live workers are correctly listed and grouped by fingerprint"
}

test_error_handling() {
  new_case errors
  local out rc

  out=$(FM_HOME="$HOME_DIR" "$TOOL" non-existent-task 2>&1); rc=$?
  expect_code 1 "$rc" "non-existent task must exit 1"
  assert_contains "$out" "task not found in state: non-existent-task"

  out=$(FM_HOME="$HOME_DIR" "$TOOL" --bad-flag 2>&1); rc=$?
  expect_code 2 "$rc" "unknown option must exit 2"
  assert_contains "$out" "unknown option: --bad-flag"

  out=$(FM_HOME="$HOME_DIR" "$TOOL" --help); rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "Usage:"
  pass "error handling and help flags behave correctly"
}

fm_test_run \
  test_setup_token_worker \
  test_fingerprint_stability_and_distinctness \
  test_unreadable_token_reports_unknown \
  test_ordinary_claude_worker \
  test_pi_worker \
  test_codex_and_grok \
  test_current_environment \
  test_group_live_workers \
  test_error_handling
