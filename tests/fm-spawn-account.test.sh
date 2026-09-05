#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's --account flag (per-account Claude Code
# isolation; docs/configuration.md "Multi-account Claude Code").
#
# Like fm-spawn-dispatch-profile.test.sh, these drive fm-spawn through meta
# writing and launch construction with a fake tmux pane and a real isolated
# git worktree, capturing the literal launch command sent with
# `tmux send-keys -l` so assertions pin the exact command firstmate would run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-account)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" --mode no-mistakes --yolo off --model sonnet "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_account_flag_records_meta_and_uses_account_launcher() {
  local rec id out status launch expected
  id=account-one-z1
  rec=$(make_spawn_case account-one claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --account 1)
  status=$?
  expect_code 0 "$status" "claude spawn with --account 1 should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude harness"
  assert_grep "account=1" "$HOME_DIR/state/$id.meta" "meta missing account=1"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_TRUST_DIR='$WT_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false '${ROOT}/bin/claude-account.sh' 1 --dangerously-skip-permissions --model 'sonnet' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "account launch did not use claude-account.sh with CLAUDE_TRUST_DIR"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "--account 1 records account=1 in meta and launches through claude-account.sh with CLAUDE_TRUST_DIR set"
}

test_account_flag_defaults_to_absent_meta_and_plain_claude() {
  local rec id out status launch expected
  id=account-off-z2
  rec=$(make_spawn_case account-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude)
  status=$?
  expect_code 0 "$status" "claude spawn without --account should succeed"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "meta should not record account= when --account is absent"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model 'sonnet' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-account launch should be unchanged except for the now-required --model flag"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "absent --account leaves meta and the launch command unchanged"
}

test_crew_account_supplies_default_account() {
  local rec id out status launch expected
  id=crew-account-default-z5
  rec=$(make_spawn_case crew-account-default claude "$id")
  read_case_record "$rec"
  printf '3\n' > "$HOME_DIR/config/crew-account"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude)
  status=$?
  expect_code 0 "$status" "a claude spawn with a config/crew-account default should succeed"
  assert_grep "account=3" "$HOME_DIR/state/$id.meta" \
    "config/crew-account default was not recorded as account=3 in meta"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_TRUST_DIR='$WT_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false '${ROOT}/bin/claude-account.sh' 3 --dangerously-skip-permissions --model 'sonnet' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "the crew-account default did not launch through claude-account.sh on account 3"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "config/crew-account supplies the default account when --account is absent"
}

test_explicit_account_overrides_crew_account_default() {
  local rec id out status
  id=crew-account-override-z6
  rec=$(make_spawn_case crew-account-override claude "$id")
  read_case_record "$rec"
  printf '3\n' > "$HOME_DIR/config/crew-account"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --account 1)
  status=$?
  expect_code 0 "$status" "an explicit --account beside a crew-account default should succeed"
  assert_grep "account=1" "$HOME_DIR/state/$id.meta" \
    "explicit --account 1 should win over the config/crew-account default"
  assert_no_grep "account=3" "$HOME_DIR/state/$id.meta" \
    "the crew-account default should not survive an explicit --account"
  pass "an explicit --account overrides the config/crew-account default"
}

test_crew_account_default_ignored_on_non_claude_harness() {
  local rec id out status launch expected
  id=crew-account-codex-z7
  rec=$(make_spawn_case crew-account-codex codex "$id")
  read_case_record "$rec"
  printf '3\n' > "$HOME_DIR/config/crew-account"

  # The default is a claude-only auth-routing convenience. A home that has the
  # file must still be able to spawn every other harness exactly as it did
  # before the file existed - never turned into the --account refusal.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex)
  status=$?
  expect_code 0 "$status" "a codex spawn beside a config/crew-account default should succeed"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" \
    "the crew-account default should not be recorded for a non-claude harness"

  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *claude-account.sh*) fail "a codex launch must not go through claude-account.sh"$'\n'"actual: $launch" ;;
  esac
  pass "the config/crew-account default is ignored on a non-claude harness rather than refusing the spawn"
}

test_crew_account_malformed_value_is_no_default() {
  local rec id out status launch expected
  id=crew-account-malformed-z8
  rec=$(make_spawn_case crew-account-malformed claude "$id")
  read_case_record "$rec"
  # A partially-numeric value must not be accepted on a first-character match:
  # it would reach meta and be concatenated unquoted into the launch command.
  printf '2junk\n' > "$HOME_DIR/config/crew-account"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude)
  status=$?
  expect_code 0 "$status" "a malformed config/crew-account should leave the spawn working"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" \
    "a malformed config/crew-account value must not reach meta"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model 'sonnet' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "a malformed crew-account value must leave the launch command unchanged"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "a malformed config/crew-account value is treated as no default"
}

test_crew_account_multiline_file_uses_first_line_only() {
  local rec id out status launch expected
  id=crew-account-multiline-z9
  rec=$(make_spawn_case crew-account-multiline claude "$id")
  read_case_record "$rec"
  # Whitespace stripping alone would fold these two lines into account 34.
  printf '3\n4\n' > "$HOME_DIR/config/crew-account"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude)
  status=$?
  expect_code 0 "$status" "a multi-line config/crew-account should leave the spawn working"
  assert_grep "account=3" "$HOME_DIR/state/$id.meta" \
    "a multi-line config/crew-account should resolve to its first line"
  assert_no_grep "account=34" "$HOME_DIR/state/$id.meta" \
    "a multi-line config/crew-account must not concatenate into a different account"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_TRUST_DIR='$WT_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false '${ROOT}/bin/claude-account.sh' 3 --dangerously-skip-permissions --model 'sonnet' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "a multi-line crew-account file did not launch on account 3"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "a multi-line config/crew-account uses its first line only"
}

test_crew_account_unreadable_file_is_no_default() {
  local rec id out status launch expected
  if [ "$(id -u)" -eq 0 ]; then
    printf '# skip: unreadable-file case is meaningless as root\n'
    return 0
  fi
  id=crew-account-unreadable-za
  rec=$(make_spawn_case crew-account-unreadable claude "$id")
  read_case_record "$rec"
  printf '3\n' > "$HOME_DIR/config/crew-account"
  chmod 000 "$HOME_DIR/config/crew-account"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude)
  status=$?
  chmod 600 "$HOME_DIR/config/crew-account"
  expect_code 0 "$status" "an unreadable config/crew-account must not abort the spawn"$'\n'"output: $out"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" \
    "an unreadable config/crew-account must not reach meta"

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model 'sonnet' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "an unreadable crew-account file must leave the launch command unchanged"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "an unreadable config/crew-account yields no default instead of aborting the spawn"
}

test_account_flag_requires_claude_harness() {
  local rec id out status
  id=account-wrong-harness-z3
  rec=$(make_spawn_case account-wrong-harness codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --account 1)
  status=$?
  expect_code 1 "$status" "--account with a non-claude harness should refuse"
  assert_contains "$out" "error: --account requires the claude harness" \
    "refusal did not explain the claude-harness requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "harness refusal should happen before meta is written"
  pass "--account refuses a non-claude harness before meta or launch"
}

test_account_flag_rejects_non_positive_integer() {
  local rec id out status
  id=account-bad-value-z4
  rec=$(make_spawn_case account-bad-value claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --account 0)
  status=$?
  expect_code 1 "$status" "--account 0 should refuse"
  assert_contains "$out" "error: --account requires a positive integer" \
    "refusal did not explain the positive-integer requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "bad --account value should refuse before meta is written"
  pass "--account rejects a non-positive-integer value"
}

test_account_flag_records_meta_and_uses_account_launcher
test_account_flag_defaults_to_absent_meta_and_plain_claude
test_crew_account_supplies_default_account
test_explicit_account_overrides_crew_account_default
test_crew_account_default_ignored_on_non_claude_harness
test_crew_account_malformed_value_is_no_default
test_crew_account_multiline_file_uses_first_line_only
test_crew_account_unreadable_file_is_no_default
test_account_flag_requires_claude_harness
test_account_flag_rejects_non_positive_integer

echo "# all fm-spawn-account tests passed"
