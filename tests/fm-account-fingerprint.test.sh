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
  assert_contains "$out" "--fleet" "help documents --fleet"
  pass "error handling and help flags behave correctly"
}

test_claude_identity_derived() {
  new_case claude-identity
  local claude_dir="$CASE/claude-config"
  mkdir -p "$claude_dir"
  cat > "$claude_dir/.claude.json" <<'EOF'
{
  "oauthAccount": {
    "emailAddress": "pilot-user@example.com",
    "organizationUuid": "org-uuid-12345"
  }
}
EOF

  write_meta "task-claude-id" "harness=claude" "account=ordinary"

  local out json_out rc
  out=$(FM_HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$claude_dir" "$TOOL" task-claude-id); rc=$?
  expect_code 0 "$rc" "identity-derived lookup should succeed"
  assert_contains "$out" "target: task-claude-id" "reports target"
  assert_contains "$out" "harness: claude" "reports harness"
  assert_contains "$out" "auth_method: subscription login" "reports subscription login"
  assert_contains "$out" "account: pilot-user@example.com" "extracts email from .claude.json"
  assert_contains "$out" "(identity-derived)" "clearly marks fingerprint as identity-derived"

  json_out=$(FM_HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$claude_dir" "$TOOL" task-claude-id --json)
  [ "$(printf '%s\n' "$json_out" | jq -r .account)" = "pilot-user@example.com" ] || fail "JSON account must match email"
  [ "$(printf '%s\n' "$json_out" | jq -r .derivation)" = "identity-derived" ] || fail "JSON derivation must be identity-derived"
  local fp
  fp=$(printf '%s\n' "$json_out" | jq -r .fingerprint)
  [ "${#fp}" -eq 12 ] || fail "JSON fingerprint must be 12 chars: $fp"
  pass "Claude subscription login derives identity from non-secret config and marks identity-derived"
}

test_grok_and_agy_identity_derived() {
  new_case grok-agy-identity
  local user_home="$CASE/user-home"
  mkdir -p "$user_home/.grok" "$user_home/.gemini"

  cat > "$user_home/.grok/auth.json" <<'EOF'
{
  "https://auth.x.ai::mock": {
    "email": "space-cadet@example.com",
    "user_id": "usr_998877"
  }
}
EOF

  cat > "$user_home/.gemini/google_accounts.json" <<'EOF'
{
  "active": "cosmonaut@example.com"
}
EOF

  write_meta "task-grok-id" "harness=grok"
  write_meta "task-agy-id"  "harness=agy"

  local out_grok out_agy
  out_grok=$(FM_HOME="$HOME_DIR" HOME="$user_home" "$TOOL" task-grok-id)
  out_agy=$(FM_HOME="$HOME_DIR" HOME="$user_home" "$TOOL" task-agy-id)

  assert_contains "$out_grok" "account: space-cadet@example.com" "Grok uses email from auth.json"
  assert_contains "$out_grok" "(identity-derived)" "Grok marks identity-derived"

  assert_contains "$out_agy" "account: cosmonaut@example.com" "Agy uses email from google_accounts.json"
  assert_contains "$out_agy" "(identity-derived)" "Agy marks identity-derived"
  pass "Grok and Agy derive identity from known non-secret sources when tokens are absent"
}

test_fleet_inspection() {
  new_case fleet
  local prim_home="$HOME_DIR"
  local local_sm_home="$CASE/secondmate-local"
  local remote_sm_home="$CASE/secondmate-remote"
  local fake_ssh="$CASE/fake-ssh"

  mkdir -p "$prim_home/data" "$prim_home/state" "$prim_home/config"
  mkdir -p "$local_sm_home/state" "$local_sm_home/config"
  mkdir -p "$remote_sm_home/state" "$remote_sm_home/config"

  # Tokens
  local tok_alpha="$CASE/tokens/alpha.token"
  local tok_beta="$CASE/tokens/beta.token"
  make_token_file "$tok_alpha" "$TOKEN_SECRET_1"
  make_token_file "$tok_beta" "$TOKEN_SECRET_2"
  printf 'account: shared-team@example.com\n' > "$CASE/tokens/alpha.meta"
  printf 'account: solo-remote@example.com\n' > "$CASE/tokens/beta.meta"

  # 1. Primary home tasks
  # task-prim-1 uses shared token alpha
  cat > "$prim_home/state/task-prim-1.meta" <<EOF
harness=claude
account_request=token:$tok_alpha
EOF

  # 2. Local secondmate tasks
  # task-local-1 ALSO uses shared token alpha (shares fingerprint with primary!)
  cat > "$local_sm_home/state/task-local-1.meta" <<EOF
harness=claude
account_request=token:$tok_alpha
EOF

  # 3. Remote secondmate tasks
  # task-rem-1 uses token beta
  # task-rem-2 is a Claude worker with non-secret config
  cat > "$remote_sm_home/state/task-rem-1.meta" <<EOF
harness=claude
account_request=token:$tok_beta
EOF

  local rem_claude_cfg="$CASE/remote-claude-cfg"
  mkdir -p "$rem_claude_cfg"
  cat > "$rem_claude_cfg/.claude.json" <<'EOF'
{
  "oauthAccount": {
    "emailAddress": "remote-dev@example.com"
  }
}
EOF
  cat > "$remote_sm_home/state/task-rem-2.meta" <<EOF
harness=claude
account=ordinary
EOF

  # Build fake-ssh
  cat > "$fake_ssh" <<EOF
#!/usr/bin/env bash
host=""
remote_cmd=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --) shift; host="\$1"; shift; remote_cmd="\$*"; break ;;
    -o) shift 2 ;;
    -*) shift ;;
    *) host="\$1"; shift; remote_cmd="\$*"; break ;;
  esac
done

if [ "\$host" = "wedged-host" ]; then
  echo "ssh: connect to host wedged-host port 22: Connection timed out" >&2
  exit 255
fi

# For remote home simulation:
if [ "\$host" = "remote-node" ]; then
  # Execute the shipped script from stdin under simulated remote home
  CLAUDE_CONFIG_DIR="$rem_claude_cfg" eval "\$remote_cmd"
  exit \$?
fi

echo "unknown host: \$host" >&2
exit 1
EOF
  chmod 700 "$fake_ssh"

  # Build data/secondmates.md
  cat > "$prim_home/data/secondmates.md" <<EOF
- sm-local - Local secondmate (home: $local_sm_home; scope: local work; projects: ; added 2026-11-10)
- sm-remote - Remote secondmate (host: remote-node; root: /opt/firstmate; home: $remote_sm_home; scope: remote work; projects: ; added 2026-11-10)
- sm-wedged - Unreachable remote secondmate (host: wedged-host; root: /opt/firstmate; home: /opt/firstmate-dead; scope: wedged work; projects: ; added 2026-11-10)
EOF

  local out_fleet json_fleet
  out_fleet=$(
    FM_SSH_BIN="$fake_ssh" FM_SNAPSHOT_HOST="testhost" FM_HOME="$prim_home" \
    "$TOOL" --fleet
  )

  # Secrets must NEVER leak in fleet output
  assert_not_contains "$out_fleet" "$TOKEN_SECRET_1" "never leaks token secret 1 in fleet text output"
  assert_not_contains "$out_fleet" "$TOKEN_SECRET_2" "never leaks token secret 2 in fleet text output"

  # Verify agent lines contain host, home, task, harness, auth
  assert_contains "$out_fleet" "host: testhost, home: primary, task: task-prim-1, harness: claude, auth: setup token" \
    "primary agent line reports host, home, task, harness, auth"
  assert_contains "$out_fleet" "host: testhost, home: sm-local, task: task-local-1, harness: claude, auth: setup token" \
    "local secondmate agent line reports host, home, task, harness, auth"
  assert_contains "$out_fleet" "host: remote-node, home: sm-remote, task: task-rem-1, harness: claude, auth: setup token" \
    "remote secondmate agent line reports host, home, task, harness, auth"
  assert_contains "$out_fleet" "host: remote-node, home: sm-remote, task: task-rem-2, harness: claude, auth: subscription login" \
    "remote subscription agent line reports host, home, task, harness, auth"

  # Verify unreachable host reporting
  assert_contains "$out_fleet" "unreachable homes:" "reports unreachable section"
  assert_contains "$out_fleet" "host: wedged-host, home: sm-wedged" "lists wedged host"
  assert_contains "$out_fleet" "Connection timed out" "unreachable home includes timeout diagnostic"

  # JSON mode verification
  json_fleet=$(
    FM_SSH_BIN="$fake_ssh" FM_SNAPSHOT_HOST="testhost" FM_HOME="$prim_home" \
    "$TOOL" --fleet --json
  )

  assert_not_contains "$json_fleet" "$TOKEN_SECRET_1" "never leaks token secret 1 in fleet JSON output"
  assert_not_contains "$json_fleet" "$TOKEN_SECRET_2" "never leaks token secret 2 in fleet JSON output"

  local worker_count
  worker_count=$(printf '%s\n' "$json_fleet" | jq '.workers | length')
  [ "$worker_count" -eq 4 ] || fail "JSON must report 4 workers across all homes, got: $worker_count"

  # Verify unreachable list in JSON
  local unreach_count
  unreach_count=$(printf '%s\n' "$json_fleet" | jq '.unreachable | length')
  [ "$unreach_count" -eq 1 ] || fail "JSON must report 1 unreachable home, got: $unreach_count"
  local unreach_host
  unreach_host=$(printf '%s\n' "$json_fleet" | jq -r '.unreachable[0].host')
  [ "$unreach_host" = "wedged-host" ] || fail "unreachable host must be wedged-host, got: $unreach_host"

  # Verify shared group: task-prim-1 and task-local-1 must be in the same group!
  local shared_group_workers
  shared_group_workers=$(printf '%s\n' "$json_fleet" | jq -r '[.groups[] | select(.account == "shared-team@example.com") | .workers[] | .target] | sort | join(",")')
  [ "$shared_group_workers" = "task-local-1,task-prim-1" ] || fail "primary and local tasks sharing token must group together, got: $shared_group_workers"

  pass "fleet inspection enumerates homes, groups cross-home workers, reports unreachable hosts, and contains secrets"
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
  test_error_handling \
  test_claude_identity_derived \
  test_grok_and_agy_identity_derived \
  test_fleet_inspection
