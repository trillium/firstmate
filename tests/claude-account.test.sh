#!/usr/bin/env bash
# Behavior tests for bin/claude-account.sh: the per-account Claude Code
# isolation launcher (docs/configuration.md "Multi-account Claude Code").
#
# Standalone script, so these tests mock the filesystem with a fake HOME, a fake
# `claude` binary, and a fake `curl` on PATH rather than requiring a real Claude
# Code install or a live teamclaude proxy. Covers the proxy auth preflight, the
# idempotent shared-config symlink step, and the onboarding/trust-dialog
# .claude.json pre-write.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/claude-account.sh"
TMP_ROOT=$(fm_test_tmproot claude-account)

# make_case <name>: builds an isolated fake HOME with shared ~/.claude config
# and one seeded account (account 1), plus a fake `claude` binary on PATH that
# just echoes its CLAUDE_CONFIG_DIR and args. Echoes "<home>|<fakebin>|<log>".
make_case() {
  local name=$1 case_dir home fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  log="$case_dir/claude-invocations.log"
  mkdir -p "$home/.claude/skills" "$home/.claude/hooks" "$home/.claude/commands"
  printf '{}\n' > "$home/.claude/settings.json"
  mkdir -p "$home/.claude-homes/account1/.claude"
  fakebin=$(fm_fakebin "$case_dir")
  # Mock `curl`: the launcher's only use of it is the teamclaude proxy preflight,
  # so a reachable proxy is simulated with exit 0. Cases that need an unreachable
  # proxy overwrite this mock. Mocking it keeps every case hermetic - a real
  # proxy running (or not) on this machine must not change the verdict.
  cat > "$fakebin/curl" <<'CURLEOF'
#!/usr/bin/env bash
exit 0
CURLEOF
  chmod +x "$fakebin/curl"
  cat > "$fakebin/claude" <<EOF
#!/usr/bin/env bash
printf 'CLAUDE_CONFIG_DIR=%s args=%s\n' "\$CLAUDE_CONFIG_DIR" "\$*" >> '$log'
printf 'BASE_URL=%s\n' "\$ANTHROPIC_BASE_URL" >> '$log'
printf 'OAUTH=%s\n' "\$CLAUDE_CODE_OAUTH_TOKEN" >> '$log'
EOF
  chmod +x "$fakebin/claude"
  : > "$log"
  printf '%s\n' "$home|$fakebin|$log"
}

read_case_record() {
  IFS='|' read -r CASE_HOME CASE_FAKEBIN CASE_LOG <<EOF
$1
EOF
}

run_launcher() {
  local home=$1 fakebin=$2
  shift 2
  HOME="$home" PATH="$fakebin:$PATH" "$LAUNCHER" "$@" 2>&1
}

test_unreachable_proxy_fails_loudly() {
  local rec home fakebin log out status
  rec=$(make_case proxy-unreachable)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG
  # Simulate an unreachable teamclaude proxy: the preflight curl fails.
  cat > "$fakebin/curl" <<'CURLEOF'
#!/usr/bin/env bash
exit 7
CURLEOF
  chmod +x "$fakebin/curl"

  out=$(run_launcher "$home" "$fakebin" 1 /status)
  status=$?
  expect_code 1 "$status" "an unreachable proxy should refuse rather than launch claude"
  assert_contains "$out" "teamclaude proxy not reachable" \
    "refusal did not name the unreachable proxy"
  assert_contains "$out" "http://127.0.0.1:3456" \
    "refusal did not name the proxy address"
  assert_contains "$out" "launchctl start com.teamclaude.proxy" \
    "refusal did not show how to start the proxy"
  [ ! -s "$log" ] || fail "claude should never be invoked when the proxy is unreachable"
  pass "an unreachable teamclaude proxy refuses with a start command, no claude invocation"
}

test_auth_routes_through_proxy() {
  local rec home fakebin log out status
  rec=$(make_case proxy-routing)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG

  out=$(run_launcher "$home" "$fakebin" 1 /status)
  status=$?
  expect_code 0 "$status" "a reachable proxy should launch claude"
  assert_grep "BASE_URL=http://127.0.0.1:3456" "$log" \
    "claude was not pointed at the teamclaude proxy via ANTHROPIC_BASE_URL"
  assert_no_grep "OAUTH=sk-" "$log" \
    "the launcher must not inject a per-account token; the proxy owns credentials"
  pass "auth is routed through the teamclaude proxy with no per-account token injected"
}

test_symlinks_shared_config_idempotently() {
  local rec home fakebin log out status target
  rec=$(make_case symlink-idempotent)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG

  out=$(run_launcher "$home" "$fakebin" 1 /status)
  status=$?
  expect_code 0 "$status" "seeded account 1 should launch claude"
  assert_grep "CLAUDE_CONFIG_DIR=$home/.claude-homes/account1/.claude args=/status" "$log" \
    "claude was not invoked with the account's CLAUDE_CONFIG_DIR"

  for item in skills hooks commands; do
    [ -L "$home/.claude-homes/account1/.claude/$item" ] || fail "$item should be symlinked into the account home"
    target=$(readlink "$home/.claude-homes/account1/.claude/$item")
    [ "$target" = "$home/.claude/$item" ] || fail "$item symlink should point at the shared ~/.claude/$item"
  done
  [ ! -e "$home/.claude-homes/account1/.claude/mcp-configs" ] || fail "mcp-configs should not appear when the shared source is absent"

  # Second launch must be idempotent: same symlinks, no error, no duplication.
  : > "$log"
  out=$(run_launcher "$home" "$fakebin" 1 /status)
  status=$?
  expect_code 0 "$status" "a second launch on the same account should still succeed"
  for item in skills hooks commands; do
    [ -L "$home/.claude-homes/account1/.claude/$item" ] || fail "$item symlink should survive a second launch"
  done
  pass "shared config is symlinked idempotently and survives a repeat launch"
}

test_does_not_symlink_credentials_or_claude_json() {
  local rec home fakebin log
  rec=$(make_case never-symlink-secrets)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG
  # Give the shared dir files that would collide by name if the loop were ever
  # widened to include them - the launcher must never touch these two names.
  printf '{"shared":"leak"}\n' > "$home/.claude/.credentials.json"
  printf '{"shared":"leak"}\n' > "$home/.claude/.claude.json"

  run_launcher "$home" "$fakebin" 1 /status >/dev/null
  [ ! -L "$home/.claude-homes/account1/.claude/.credentials.json" ] || fail ".credentials.json must never be a symlink"
  # .claude.json is pre-seeded inside CLAUDE_CONFIG_DIR (where current CC reads
  # it); it must be a real per-account file, never a symlink into shared config.
  [ ! -L "$home/.claude-homes/account1/.claude/.claude.json" ] || fail ".claude.json must never be a symlink"
  assert_no_grep "acct1-secret" "$home/.claude-homes/account1/.claude/.claude.json" \
    ".claude.json should not have been overwritten by any shared file"
  pass "credentials and onboarding state are never symlinked from shared config"
}

test_prewrites_onboarding_and_trust_dialog() {
  local rec home fakebin log trust_dir
  rec=$(make_case trust-dialog)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG
  trust_dir="$TMP_ROOT/some/worktree"
  mkdir -p "$trust_dir"

  CLAUDE_TRUST_DIR="$trust_dir" HOME="$home" PATH="$fakebin:$PATH" "$LAUNCHER" 1 /status >/dev/null
  status=$?
  expect_code 0 "$status" "trust-dialog pre-write launch should succeed"

  # Current Claude Code reads its global config from $CLAUDE_CONFIG_DIR/.claude.json
  # when CLAUDE_CONFIG_DIR is set - NOT from a .claude.json in the parent dir. The
  # pre-seed must land at the path CC reads or onboarding is not skipped.
  local seed="$home/.claude-homes/account1/.claude/.claude.json"
  assert_present "$seed" ".claude.json pre-seed should exist inside CLAUDE_CONFIG_DIR (where current CC reads it)"
  assert_absent "$home/.claude-homes/account1/.claude.json" \
    "the pre-seed must NOT be written to the parent of CLAUDE_CONFIG_DIR (current CC ignores it there)"
  [ ! -L "$seed" ] || fail ".claude.json pre-seed must be a real file, not a symlink"
  assert_grep '"hasCompletedOnboarding": true' "$seed" \
    "onboarding gate hasCompletedOnboarding was not pre-accepted"
  assert_grep '"numStartups"' "$seed" \
    "numStartups was not pre-seeded"
  assert_grep "\"$trust_dir\"" "$seed" \
    "trust dialog was not pre-accepted for CLAUDE_TRUST_DIR"
  assert_grep '"hasTrustDialogAccepted": true' "$seed" \
    "trust dialog flag was not set to true"

  # Idempotent: a second launch for the same trust dir must not error or duplicate.
  CLAUDE_TRUST_DIR="$trust_dir" HOME="$home" PATH="$fakebin:$PATH" "$LAUNCHER" 1 /status >/dev/null
  status=$?
  expect_code 0 "$status" "a repeat launch for an already-trusted directory should still succeed"
  pass "onboarding and the trust dialog are pre-accepted inside CLAUDE_CONFIG_DIR for CLAUDE_TRUST_DIR, idempotently"
}

test_settings_json_symlink_is_never_replaced() {
  local rec home fakebin log
  rec=$(make_case settings-symlink-preserved)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG
  # Shared settings.json intentionally lacks skipDangerousModePermissionPrompt.

  run_launcher "$home" "$fakebin" 1 /status >/dev/null

  [ -L "$home/.claude-homes/account1/.claude/settings.json" ] || \
    fail "a symlinked shared settings.json must not be converted into a private real file"
  local target
  target=$(readlink "$home/.claude-homes/account1/.claude/settings.json")
  [ "$target" = "$home/.claude/settings.json" ] || fail "settings.json symlink should still point at the shared file"
  pass "a symlinked settings.json is left alone rather than silently privatized"
}

test_settings_json_flag_set_when_real_per_account_file() {
  local rec home fakebin log
  rec=$(make_case settings-real-file)
  read_case_record "$rec"
  home=$CASE_HOME fakebin=$CASE_FAKEBIN log=$CASE_LOG
  # Pre-seed a real (non-symlinked) per-account settings.json before the first
  # launch, so the launcher's symlink step leaves it alone and the flag-write
  # step patches this real file in place.
  printf '{"someOtherKey": true}\n' > "$home/.claude-homes/account1/.claude/settings.json"

  run_launcher "$home" "$fakebin" 1 /status >/dev/null

  [ ! -L "$home/.claude-homes/account1/.claude/settings.json" ] || fail "a pre-existing real settings.json should stay real"
  assert_grep '"skipDangerousModePermissionPrompt": true' "$home/.claude-homes/account1/.claude/settings.json" \
    "skipDangerousModePermissionPrompt was not pre-written into the real per-account settings.json"
  assert_grep '"someOtherKey": true' "$home/.claude-homes/account1/.claude/settings.json" \
    "patching settings.json should not drop existing keys"
  pass "a real per-account settings.json gets skipDangerousModePermissionPrompt pre-written"
}

test_unreachable_proxy_fails_loudly
test_auth_routes_through_proxy
test_symlinks_shared_config_idempotently
test_does_not_symlink_credentials_or_claude_json
test_prewrites_onboarding_and_trust_dialog
test_settings_json_symlink_is_never_replaced
test_settings_json_flag_set_when_real_per_account_file

echo "# all claude-account tests passed"
