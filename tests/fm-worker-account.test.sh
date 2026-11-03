#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account; bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in, otherwise the selected root's stored login
# decides - and record the account environment and arguments a launched worker
# receives. tests/fm-worker-account-live-e2e.test.sh proves those answers
# against the real runners.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  # Like the real claude, an environment token is read offline and selected as
  # the oauth_token method; the REJECTED sentinel stands for a signed-out result.
  if [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    printf 'token-check args=%s\n' "\$*" >> '$dir/claude-token-checks'
    if [ "\$CLAUDE_CODE_OAUTH_TOKEN" = sk-ant-oat01-REJECTED ]; then
      printf '{"loggedIn":false,"authMethod":"none"}\n'
      exit 1
    fi
    printf '{"loggedIn":true,"authMethod":"oauth_token"}\n'
    exit 0
  fi
  [ -z "\${ANTHROPIC_API_KEY:-}" ] || exit 0
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'CLAUDE_CODE_USE_BEDROCK=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/claude-worker'
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  chmod +x "$fakebin/claude" "$fakebin/pi"
  cp "$fakebin/pi" "$fakebin/pi-signed"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another account for every runner.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent
  new_case absent claude
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an unpinned Claude spawn should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/claude-checks" "an unpinned spawn must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "an unpinned launch must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an unpinned launch must leave the pane's environment credentials alone"

  new_case absent-pi pi
  out=$(spawn_ship acct-absent-pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves Claude and Pi launches exactly as they were"
}

test_claude_pin_selects_the_root_and_sheds_ambient_credentials() {
  local out rc id=acct-claude
  new_case claude-pin claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a signed-in root should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the pinned root only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/work/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the pinned root's store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the pin"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the pin"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the pin"
  pass "a Claude pin selects its root and sheds the credentials that would outrank it"
}

test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login() {
  local out rc id=acct-claude-out
  new_case claude-signed-out claude
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a Claude pin to a signed-out root must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins Claude workers to $CASE/work, which is not signed in"
  assert_absent "$CASE/work/.claude.json" "a refused spawn must not register trust in the pinned root"
  pass "a Claude pin refuses a signed-out root even when the invoking process has a usable login and API key"
}

test_claude_ordinary_pin_unsets_the_config_root() {
  local out rc id=acct-ordinary
  new_case ordinary claude
  printf 'ordinary' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "an ordinary pin with no default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an ordinary pin with a default login should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "ordinary trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "the ordinary account must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the ordinary pin"
  pass "an ordinary Claude pin selects the default login and drops an ambient root"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed claude
  mkdir -p "$CASE/work"
  for body in 'relative/root' "$CASE/work"$'\r' '' 'ordinary'$'\n''environment' "$CASE/missing-root"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account"
  done
  rm "$HOME_DIR/config/claude-account"
  mkdir "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account"
  printf 'ordinary\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a Pi pin without a providers line must refuse"
  assert_refused_before_launch "$id-pi" "$out" "config/pi-account must hold"
  assert_absent "$CASE/claude-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, extra-line, missing-root, and non-file pins refuse before launch"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope codex
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-codex"); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a Claude pin"
  out=$(spawn_ship "$id-pi" --harness pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves codex and Pi launches unchanged"
}

test_raw_claude_command_receives_the_pin() {
  local out rc id=acct-raw
  new_case raw-claude claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a signed-in pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "a raw Claude spawn should report the pin"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "a raw Claude worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a raw Claude worker must not keep an ambient API key"
  pass "a raw Claude launch command receives the home's pin"
}

test_raw_claude_account_override_refuses_under_a_pin() {
  local out rc id=acct-raw-override var
  new_case raw-override claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pin"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or change or remove config/claude-account" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"
  pass "a pinned home refuses a raw Claude command that overrides the account"
}

test_raw_claude_account_override_is_kept_without_a_pin() {
  local out rc id=acct-raw-unpinned
  new_case raw-unpinned claude
  mkdir -p "$CASE/other"
  out=$(spawn_ship "$id" --harness "CLAUDE_CONFIG_DIR=$CASE/other ANTHROPIC_API_KEY=override-key claude --print raw"); rc=$?
  expect_code 0 "$rc" "an unpinned home should accept a raw Claude account override: $out"
  assert_not_contains "$out" "account=" "an unpinned raw spawn must not report an account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/other" "$CASE/claude-worker" "an unpinned raw override should keep its own root"
  assert_grep "ANTHROPIC_API_KEY=override-key" "$CASE/claude-worker" "an unpinned raw override should keep its own key"
  pass "an unpinned home keeps a raw Claude account override"
}

test_local_secondmate_reads_the_launching_home_pin() {
  local out rc id=acct-sm sm
  new_case secondmate claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$CASE/sm-own"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$CASE/sm-own" > "$sm/config/claude-account"
  fm_register_secondmate "$HOME_DIR/data/secondmates.md" "$id" "$sm"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn under the launching home's pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the secondmate spawn should report the launching home's pin"
  [ "$(cat "$sm/config/claude-account")" = "$CASE/sm-own" ] \
    || fail "the launching home's pin must not be inherited over the secondmate home's own file"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "the secondmate agent should run under the launching home's pinned root"
  pass "a local secondmate reads the launching home's pin and its own home's file is never inherited over"
}

spawn_account_secondmate() {
  local id=$1 sm="$CASE/$1-home"
  shift
  mkdir -p "$sm/bin" "$sm/data" "$sm/config"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  grep -q -- "^- $id - " "$HOME_DIR/data/secondmates.md" 2>/dev/null ||
    fm_register_secondmate "$HOME_DIR/data/secondmates.md" "$id" "$sm"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate "$@"
}

test_secondmate_account_override() {
  local out rc id=acct-sm-override harness file variable worker
  for harness in claude pi pi-signed; do
    new_case "secondmate-override-$harness" "$harness"
    case "$harness" in
    claude) file=claude-account; variable=CLAUDE_CONFIG_DIR; worker=claude ;;
    *) file=pi-account; variable=PI_CODING_AGENT_DIR; worker=pi ;;
    esac
    signed_in_claude_root "$CASE/primary"
    signed_in_claude_root "$CASE/mate"
    printf 'openai-codex\n' > "$CASE/primary/signed-in"
    printf 'openai-codex\n' > "$CASE/mate/signed-in"
    printf '%s\n' "$CASE/primary" > "$HOME_DIR/config/$file"
    mkdir -p "$HOME_DIR/config/secondmate-accounts/$id" "$HOME_DIR/config/secondmate-accounts/acct-ship"
    printf '%s\n' "$CASE/mate" > "$HOME_DIR/config/secondmate-accounts/$id/$file"
    if [ "$harness" != claude ]; then
      printf 'openai-codex\n' >> "$HOME_DIR/config/$file"
      printf 'openai-codex\n' >> "$HOME_DIR/config/secondmate-accounts/$id/$file"
    fi
    cp "$HOME_DIR/config/secondmate-accounts/$id/$file" "$HOME_DIR/config/secondmate-accounts/acct-ship/$file"
    out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
    expect_code 0 "$rc" "a $harness secondmate with its own account should launch: $out"
    assert_contains "$out" "account=$CASE/mate" "the per-mate pin must override the primary's pin"
    run_pane
    assert_grep "$variable=$CASE/mate" "$CASE/$worker-worker" "the mate must receive its own account"
    if [ "$harness" != claude ]; then
      assert_grep '--provider openai-codex' "$CASE/$worker-worker" "the mate must receive its pinned provider"
    fi
    out=$(spawn_account_secondmate acct-other --model openai-codex/gpt-5.5); rc=$?
    expect_code 0 "$rc" "an unconfigured secondmate should keep the primary's pin: $out"
    run_pane
    assert_grep "$variable=$CASE/primary" "$CASE/$worker-worker" "another mate must not receive the override"
    out=$(spawn_ship acct-ship --model openai-codex/gpt-5.5); rc=$?
    expect_code 0 "$rc" "an ordinary worker must keep the primary's pin: $out"
    run_pane
    assert_grep "$variable=$CASE/primary" "$CASE/$worker-worker" "per-mate configuration must not pin ordinary workers"
  done
  pass "Claude, Pi, and pi-signed secondmates use their own pins without changing other launches"
}

test_secondmate_account_refusals() {
  local out rc id=acct-sm-refuse file harness body pin
  for harness in claude pi; do
    new_case "secondmate-refuse-$harness" "$harness"
    file=claude-account
    [ "$harness" = claude ] || file=pi-account
    signed_in_claude_root "$CASE/primary"
    printf 'openai-codex\n' > "$CASE/primary/signed-in"
    printf '%s\n' "$CASE/primary" > "$HOME_DIR/config/$file"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$HOME_DIR/config/$file"
    mkdir -p "$HOME_DIR/config/secondmate-accounts/$id" "$CASE/signed-out"
    pin="$HOME_DIR/config/secondmate-accounts/$id/$file"
    for body in '' relative "$CASE/missing" "$CASE/signed-out"; do
      printf '%s\n' "$body" > "$pin"
      [ "$harness" = claude ] || printf 'openai-codex\n' >> "$pin"
      out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
      expect_code 1 "$rc" "an unusable per-mate $harness pin must refuse: $out"
      assert_refused_before_launch "$id" "$out" "$pin"
    done
    rm "$pin"
    ln -s "$CASE/no-file" "$pin"
    out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
    expect_code 1 "$rc" "a broken per-mate pin link must not fall back"
    assert_refused_before_launch "$id" "$out" "$pin"
    rm "$pin"
    mkdir "$pin"
    out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
    expect_code 1 "$rc" "a non-file per-mate pin must not fall back"
    assert_refused_before_launch "$id" "$out" "$pin"
  done
  pass "unusable per-mate pins name the setting and refuse rather than use the primary's usable account"
}

test_remote_secondmate_account_override_refuses_locally() {
  local out rc id=acct-remote
  new_case remote-account claude
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  printf 'ordinary\n' > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  printf -- '- %s - Remote fixture (host: account-test.invalid; root: /srv/firstmate; home: /srv/mate; scope: tests; projects: none; added 2026-10-17)\n' \
    "$id" > "$HOME_DIR/data/secondmates.md"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate); rc=$?
  expect_code 1 "$rc" "a primary-side remote account override must refuse"
  assert_refused_before_launch "$id" "$out" "$HOME_DIR/config/secondmate-accounts/$id/claude-account cannot pin remote secondmate"
  assert_absent "$CASE/claude-checks" "a remote refusal must not inspect a local login"
  pass "a remote route refuses a primary-side account override instead of silently ignoring it"
}

TOKEN_SENTINEL=sk-ant-oat01-FAKETOKENSENTINEL0123456789

# make_token_file <path> [body] [mode]: a setup-token file for the fake claude.
make_token_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-$TOKEN_SENTINEL}" > "$1"
  chmod "${3:-600}" "$1"
}

# assert_no_token_anywhere <id> <out>: the token value must not reach the spawn
# output, the task record, the status files, or the staged launch text.
assert_no_token_anywhere() {
  local id=$1 out=$2 f
  assert_not_contains "$out" "$TOKEN_SENTINEL" "the spawn output must never carry the token"
  assert_not_contains "$(cat "$CASE/launch.log")" "$TOKEN_SENTINEL" "the launch text must never carry the token"
  for f in "$HOME_DIR/state/$id.meta" "$HOME_DIR/state/$id.status"; do
    [ ! -e "$f" ] || assert_no_grep "$TOKEN_SENTINEL" "$f" "$f must never carry the token"
  done
  for f in /tmp/fm-"$id"+*; do
    [ ! -d "$f" ] || ! grep -rqF "$TOKEN_SENTINEL" "$f" || fail "a staged launch file carried the token"
  done
}

test_token_pin_launches_with_the_token_for_that_worker_only() {
  local out rc id=acct-token
  new_case token-pin claude
  make_token_file "$CASE/tokens/max100.token"
  printf 'token:%s\n' "$CASE/tokens/max100.token" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a setup token should succeed: $out"
  assert_contains "$out" "account=token:max100.token" "the spawn should report only the token file's basename"
  assert_not_contains "$out" "$CASE/tokens" "the spawn should not report the token file's directory"
  assert_grep "account=token:max100.token" "$HOME_DIR/state/$id.meta" "the task record should carry the token pin's basename"
  assert_no_token_anywhere "$id" "$out"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the token sign-in check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  [ "$(cat "$CASE/claude-token-checks")" = "token-check args=auth status" ] \
    || fail "the token check should run claude auth status with the token in its environment only: $(cat "$CASE/claude-token-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "token-pinned trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  assert_contains "$(cat "$CASE/launch.log")" "fm-claude-token-exec.sh" "the launch should run through the token exec helper"
  assert_contains "$(cat "$CASE/launch.log")" "$CASE/tokens/max100.token" "the launch should name the token file, not its content"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_SENTINEL" "$CASE/claude-worker" "the worker should receive the pinned token"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "a token pin must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the token"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the token"
  ! grep '^ARGS=' "$CASE/claude-worker" | grep -qF "$TOKEN_SENTINEL" || fail "the token must not be a worker argument"
  pass "a token pin launches the worker with the token for that worker only, and the token reaches no output or record"
}

test_token_pin_refusals_never_print_the_token() {
  local out rc id=acct-token-bad n=0 body
  new_case token-refusals claude
  printf 'token:%s\n' "$CASE/tokens/t.token" > "$HOME_DIR/config/claude-account"
  # unreadable-by-others rule: a group/world-readable file holding a real token
  make_token_file "$CASE/tokens/t.token" "$TOKEN_SENTINEL" 644
  out=$(spawn_ship "$id-mode"); rc=$?
  expect_code 1 "$rc" "a group- or world-readable token file must refuse"
  assert_refused_before_launch "$id-mode" "$out" "is readable by group or other"
  assert_not_contains "$out" "$TOKEN_SENTINEL" "a refusal must never print the token"
  rm -f "$CASE/tokens/t.token"
  out=$(spawn_ship "$id-missing"); rc=$?
  expect_code 1 "$rc" "a missing token file must refuse"
  assert_refused_before_launch "$id-missing" "$out" "the token file $CASE/tokens/t.token does not exist"
  : > "$CASE/tokens/t.token"; chmod 600 "$CASE/tokens/t.token"
  out=$(spawn_ship "$id-empty"); rc=$?
  expect_code 1 "$rc" "an empty token file must refuse"
  assert_refused_before_launch "$id-empty" "$out" "is empty"
  for body in "$TOKEN_SENTINEL two" "$TOKEN_SENTINEL"$'\n'"$TOKEN_SENTINEL"; do
    n=$((n + 1))
    printf '%s\n' "$body" > "$CASE/tokens/t.token"
    out=$(spawn_ship "$id-multi-$n"); rc=$?
    expect_code 1 "$rc" "a token file holding more than one token must refuse"
    assert_refused_before_launch "$id-multi-$n" "$out" "must hold one token with no spaces or line breaks"
    assert_not_contains "$out" "$TOKEN_SENTINEL" "a refusal must never print the token"
  done
  rm -f "$CASE/tokens/t.token"
  mkdir "$CASE/tokens/t.token"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the token file must refuse"
  assert_refused_before_launch "$id-dir" "$out" "is not a regular file"
  rmdir "$CASE/tokens/t.token"
  make_token_file "$CASE/tokens/t.token" sk-ant-oat01-REJECTED
  out=$(spawn_ship "$id-rejected"); rc=$?
  expect_code 1 "$rc" "a token claude does not report as signed in must refuse"
  assert_refused_before_launch "$id-rejected" "$out" "does not report it as the signed-in credential"
  for body in 'token:relative/t.token' 'token:' 'token: /abs/t.token'; do
    printf '%s\n' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-form"); rc=$?
    expect_code 1 "$rc" "malformed token pin '$body' must refuse"
    assert_refused_before_launch "$id-form" "$out" "token:<absolute path of a setup-token file>"
  done
  pass "a token pin refuses a loose, missing, empty, multi-token, non-file, rejected, or malformed file without printing the token"
}

test_raw_claude_command_receives_the_token_pin() {
  local out rc id=acct-token-raw
  new_case token-raw claude
  make_token_file "$CASE/tokens/max100.token"
  printf 'token:%s\n' "$CASE/tokens/max100.token" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "FOO=1 claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a token pin should succeed: $out"
  assert_contains "$out" "account=token:max100.token" "a raw Claude spawn should report the token pin"
  assert_no_token_anywhere "$id" "$out"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_SENTINEL" "$CASE/claude-worker" "a raw Claude worker should receive the pinned token"
  assert_grep "ARGS=--print raw" "$CASE/claude-worker" "the raw command's own arguments must survive"
  out=$(spawn_ship "$id-override" --harness "CLAUDE_CODE_OAUTH_TOKEN=other claude --print raw"); rc=$?
  expect_code 1 "$rc" "a raw command setting its own token must refuse under a pin"
  assert_refused_before_launch "$id-override" "$out" "the raw launch command sets CLAUDE_CODE_OAUTH_TOKEN"
  pass "a raw Claude launch command receives the token pin and cannot override it"
}

test_token_pin_in_a_secondmate_account_file() {
  local out rc id=acct-token-sm
  new_case token-secondmate claude
  signed_in_claude_root "$CASE/primary"
  make_token_file "$CASE/tokens/mate.token"
  printf '%s\n' "$CASE/primary" > "$HOME_DIR/config/claude-account"
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  printf 'token:%s\n' "$CASE/tokens/mate.token" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  out=$(spawn_account_secondmate "$id"); rc=$?
  expect_code 0 "$rc" "a secondmate with its own token pin should launch: $out"
  assert_contains "$out" "account=token:mate.token" "the per-mate token pin must override the primary's root"
  assert_not_contains "$out" "$TOKEN_SENTINEL" "the secondmate spawn must never print the token"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_SENTINEL" "$CASE/claude-worker" "the mate must receive its pinned token"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "the mate must not receive the primary's root"
  out=$(spawn_account_secondmate acct-token-other); rc=$?
  expect_code 0 "$rc" "another mate must keep the primary's pin: $out"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/primary" "$CASE/claude-worker" "another mate must not receive the token override"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "another mate must not receive the token"
  pass "a per-secondmate token pin applies to that mate alone"
}

test_relaunch_check_and_exec_helper() {
  local out rc
  new_case helper claude
  make_token_file "$CASE/tokens/h.token"
  # The relaunch pre-stop check is the same select call, with no raw command.
  out=$( (
    # shellcheck source=bin/fm-worker-account-lib.sh
    . "$REPO_ROOT/bin/fm-worker-account-lib.sh"
    printf 'token:%s\n' "$CASE/tokens/h.token" > "$HOME_DIR/config/claude-account"
    PATH="$FAKEBIN:$PATH" fm_worker_account_select claude "$HOME_DIR/config" "" claude "" ""
  ) 2>&1); rc=$?
  expect_code 0 "$rc" "the relaunch sign-in check under a token pin should pass: $out"
  assert_contains "$out" "token:h.token" "the selection should name the token pin by basename"
  assert_not_contains "$out" "$TOKEN_SENTINEL" "the selection must never carry the token"
  # The exec helper alone: exports for the command, refuses without echoing.
  # shellcheck disable=SC2016  # The command runs in the exec helper's shell.
  out=$("$REPO_ROOT/bin/fm-claude-token-exec.sh" \
    "$CASE/tokens/h.token" sh -c 'printf "%s" "$CLAUDE_CODE_OAUTH_TOKEN"'); rc=$?
  expect_code 0 "$rc" "the exec helper should run the command"
  [ "$out" = "$TOKEN_SENTINEL" ] || fail "the exec helper should export the token to the command"
  chmod 644 "$CASE/tokens/h.token"
  out=$("$REPO_ROOT/bin/fm-claude-token-exec.sh" \
    "$CASE/tokens/h.token" sh -c 'echo ran' 2>&1); rc=$?
  expect_code 1 "$rc" "the exec helper must refuse a loose token file"
  assert_not_contains "$out" "$TOKEN_SENTINEL" "the exec helper must never print the token"
  assert_not_contains "$out" "ran" "the exec helper must not run the command after a refusal"
  pass "the relaunch check and the exec helper handle a token pin without exposing the token"
}

test_per_launch_account_ordinary_overrides_a_token_pin() {
  local out rc id=acct-ovr-ordinary
  new_case ovr-ordinary claude
  make_token_file "$CASE/tokens/max100.token"
  printf 'token:%s\n' "$CASE/tokens/max100.token" > "$HOME_DIR/config/claude-account"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id" --account ordinary); rc=$?
  expect_code 0 "$rc" "an ordinary override over a token pin should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the overriding ordinary account"
  assert_not_contains "$out" "token:" "the home token pin must not be reported for the overridden launch"
  assert_grep "account=ordinary" "$HOME_DIR/state/$id.meta" "the record should carry the ordinary account"
  assert_grep "account_request=ordinary" "$HOME_DIR/state/$id.meta" "the record should carry the per-launch value"
  assert_absent "$CASE/claude-token-checks" "the ordinary override must not run the token sign-in check"
  assert_not_contains "$(cat "$CASE/launch.log")" "fm-claude-token-exec.sh" "the ordinary launch must not use the token helper"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ordinary launch must shed an ambient token"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "an ordinary launch must drop an ambient config root"
  # Without the flag the home-wide token pin is still the default.
  out=$(spawn_ship acct-ovr-default); rc=$?
  expect_code 0 "$rc" "the home-wide pin should still be the default: $out"
  assert_contains "$out" "account=token:max100.token" "no --account keeps the home-wide token pin"
  assert_no_grep "account_request" "$HOME_DIR/state/acct-ovr-default.meta" "a home-pin launch records no per-launch value"
  pass "a per-launch ordinary account overrides a token pin and leaves the file as the default"
}

test_per_launch_account_token_overrides_an_ordinary_pin() {
  local out rc id=acct-ovr-token
  new_case ovr-token claude
  make_token_file "$CASE/tokens/max100.token"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  out=$(spawn_ship "$id" --account "token:$CASE/tokens/max100.token"); rc=$?
  expect_code 0 "$rc" "a token override over an ordinary pin should succeed: $out"
  assert_contains "$out" "account=token:max100.token" "the spawn should report the token account by basename"
  assert_grep "account_request=token:$CASE/tokens/max100.token" "$HOME_DIR/state/$id.meta" "the record should carry the per-launch value"
  assert_no_token_anywhere "$id" "$out"
  assert_contains "$(cat "$CASE/launch.log")" "fm-claude-token-exec.sh" "the launch should use the token helper"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_SENTINEL" "$CASE/claude-worker" "the worker should receive the token"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the token"
  pass "a per-launch token account overrides an ordinary pin"
}

test_per_launch_account_works_with_no_home_pin_and_refuses_bad_values() {
  local out rc id=acct-ovr-nopin
  new_case ovr-nopin claude
  make_token_file "$CASE/tokens/max100.token"
  out=$(spawn_ship "$id" --account "token:$CASE/tokens/max100.token"); rc=$?
  expect_code 0 "$rc" "--account with no home pin should select that account: $out"
  assert_contains "$out" "account=token:max100.token" "the spawn should report the chosen account"
  out=$(spawn_ship acct-ovr-rel --account relative/path); rc=$?
  expect_code 1 "$rc" "a relative --account must refuse"
  assert_refused_before_launch acct-ovr-rel "$out" "--account must be 'ordinary'"
  chmod 644 "$CASE/tokens/max100.token"
  out=$(spawn_ship acct-ovr-loose --account "token:$CASE/tokens/max100.token"); rc=$?
  expect_code 1 "$rc" "a loose token file must refuse under --account"
  assert_refused_before_launch acct-ovr-loose "$out" "--account pins Claude workers to a setup token"
  assert_not_contains "$out" "$TOKEN_SENTINEL" "a refusal must never print the token"
  rm -f "$HOME_DIR/user-home/.claude/.credentials.json" "$CASE/ambient-claude/.credentials.json"
  out=$(spawn_ship acct-ovr-out --account ordinary); rc=$?
  expect_code 1 "$rc" "a signed-out ordinary account must refuse under --account"
  assert_refused_before_launch acct-ovr-out "$out" "--account pins Claude workers to the ordinary account, which is not signed in"
  pass "--account works without a home pin and refuses malformed, loose, and signed-out values before launch"
}

test_per_launch_account_refuses_non_claude_runners() {
  local out rc id=acct-ovr-pi
  new_case ovr-pi pi
  out=$(spawn_ship "$id" --harness pi --account ordinary); rc=$?
  expect_code 1 "$rc" "--account on a Pi launch must refuse"
  assert_refused_before_launch "$id" "$out" "--account selects a Claude account"
  pass "--account refuses a non-Claude runner"
}

test_relaunch_reuses_the_recorded_per_launch_account() {
  local out rc
  new_case ovr-relaunch claude
  make_token_file "$CASE/tokens/h.token"
  printf 'token:%s\n' "$CASE/tokens/h.token" > "$HOME_DIR/config/claude-account"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  # fm-control computes the pre-stop check from the recorded request; this is
  # the same select call it makes, fed the value fm-spawn recorded.
  out=$( (
    # shellcheck source=bin/fm-worker-account-lib.sh
    . "$REPO_ROOT/bin/fm-worker-account-lib.sh"
    # shellcheck disable=SC2030
    export HOME="$HOME_DIR/user-home"
    PATH="$FAKEBIN:$PATH" fm_worker_account_select claude "$HOME_DIR/config" "" claude "" "" ordinary
  ) 2>&1); rc=$?
  expect_code 0 "$rc" "the relaunch check with a recorded ordinary request should pass: $out"
  assert_contains "$out" "ordinary" "the recorded request should win over the home token pin"
  assert_not_contains "$out" "token:" "the home token pin must not apply to the recorded request"
  pass "the relaunch check honors a recorded per-launch account over the home pin"
}

test_remote_secondmate_refuses_account() {
  local out rc id=acct-remote-flag
  new_case remote-account-flag claude
  signed_in_claude_root "$CASE/first"
  declare_accounts "$CASE/first"
  printf -- '- %s - Remote fixture (host: account-test.invalid; root: /srv/firstmate; home: /srv/mate; scope: tests; projects: none; added 2026-10-17)\n' \
    "$id" > "$HOME_DIR/data/secondmates.md"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "--account on a remote secondmate must refuse"
  assert_refused_before_launch "$id" "$out" "--account applies to ships and scouts"
  assert_absent "$CASE/claude-checks" "a refused remote launch must not inspect a local login"
  pass "a remote secondmate refuses --account instead of launching on the remote home's account"
}

# declare_accounts <entry>...: the home's config/claude-accounts list.
declare_accounts() {
  printf '%s\n' "$@" > "$HOME_DIR/config/claude-accounts"
}

test_no_account_list_keeps_today_and_takes_a_per_launch_account() {
  local out rc id=acct-list-off
  new_case list-off claude
  signed_in_claude_root "$CASE/work"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn in a home without a list should succeed: $out"
  assert_not_contains "$out" "account=" "a home without a list must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "a home without a list must not record an account"
  assert_absent "$CASE/claude-checks" "a home without a list must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "a home without a list must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "a home without a list must leave the pane's environment credentials alone"
  out=$(spawn_ship "$id-flag" --account "$CASE/work"); rc=$?
  expect_code 0 "$rc" "--account without a list is a per-launch account: $out"
  assert_contains "$out" "account=$CASE/work" "a per-launch account without a list must be reported"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id-pin"); rc=$?
  expect_code 0 "$rc" "the single pin must keep working without a list: $out"
  assert_contains "$out" "account=$CASE/work" "the single pin must still report its account"
  pass "without config/claude-accounts the launch, the single pin, and the record are unchanged, and --account is a per-launch account"
}

test_account_list_launches_the_named_entry() {
  local out rc id=acct-list
  new_case list claude
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/second"
  declare_accounts "$CASE/first" "$CASE/second"
  out=$(spawn_ship "$id" --account "$CASE/second"); rc=$?
  expect_code 0 "$rc" "a spawn naming a declared, signed-in account should succeed: $out"
  assert_contains "$out" "account=$CASE/second" "the spawn line should name the chosen account"
  assert_grep "account=$CASE/second" "$HOME_DIR/state/$id.meta" "the task record should carry the chosen account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/second" ] \
    || fail "the sign-in check should ask about the chosen account only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/second/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the chosen account's store"
  assert_absent "$CASE/first/.claude.json" "the other declared account must not be touched"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/second" "$CASE/claude-worker" "the worker should run under the chosen account"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the chosen account"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the chosen account"
  pass "a declared account named with --account is checked, launched, and recorded like a pin"
}

test_account_list_refusals() {
  local out rc id=acct-list-bad n=0 body
  new_case list-refusals claude
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/second"
  mkdir -p "$CASE/signed-out"
  declare_accounts "$CASE/first" "$CASE/second" "$CASE/signed-out" ordinary
  out=$(spawn_ship "$id-other" --account "$CASE/elsewhere"); rc=$?
  expect_code 1 "$rc" "an undeclared account must refuse"
  assert_refused_before_launch "$id-other" "$out" "account '$CASE/elsewhere' is not declared in config/claude-accounts"
  signed_in_claude_root "$CASE/elsewhere"$'\n'"$CASE/first"
  out=$(spawn_ship "$id-newline" --account "$CASE/elsewhere"$'\n'"$CASE/first"); rc=$?
  expect_code 1 "$rc" "an account holding a newline must refuse even when one of its lines is declared"
  assert_refused_before_launch "$id-newline" "$out" "--account must name one config/claude-accounts entry exactly, with no control characters"
  [ ! -e "$CASE/claude-checks" ] || assert_no_grep "$CASE/elsewhere" "$CASE/claude-checks" "a newline account must be refused before its sign-in check"
  out=$(spawn_ship "$id-out" --account "$CASE/signed-out"); rc=$?
  expect_code 1 "$rc" "a signed-out declared account must refuse even with an ambient login and key"
  assert_refused_before_launch "$id-out" "$out" "config/claude-accounts pins Claude workers to $CASE/signed-out, which is not signed in"
  out=$(spawn_ship "$id-ordinary" --account ordinary); rc=$?
  expect_code 1 "$rc" "a signed-out ordinary entry must refuse"
  assert_refused_before_launch "$id-ordinary" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  out=$(spawn_ship "$id-codex" --harness codex --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "--account on another runner must refuse"
  assert_refused_before_launch "$id-codex" "$out" "applies to Claude workers only, not codex"
  out=$(spawn_ship "$id-raw" --account "$CASE/first" --harness "CLAUDE_CONFIG_DIR=$CASE/second claude --print raw"); rc=$?
  expect_code 1 "$rc" "a raw command overriding the chosen account must refuse"
  assert_refused_before_launch "$id-raw" "$out" "the raw launch command sets CLAUDE_CONFIG_DIR"
  printf 'relative/pin\n' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-bad-pin" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "a malformed fallback pin beside a list must refuse"
  assert_refused_before_launch "$id-bad-pin" "$out" "config/claude-account must hold"
  rm "$HOME_DIR/config/claude-account"
  for body in "$CASE/first"$'\n\n'"$CASE/second" "relative/root" "$CASE/first"$'\r' '' "$CASE/first"$'\n'"$CASE/first" "$CASE/first"$'\n'"$CASE/missing"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-accounts"
    out=$(spawn_ship "$id-$n" --account "$CASE/first"); rc=$?
    if [ "$n" = 6 ]; then
      expect_code 0 "$rc" "a missing entry that is not chosen must not block another: $out"
      out=$(spawn_ship "$id-$n-missing" --account "$CASE/missing"); rc=$?
      expect_code 1 "$rc" "a missing chosen entry must refuse"
      assert_refused_before_launch "$id-$n-missing" "$out" "config/claude-accounts must name readable, searchable existing directories"
      continue
    fi
    expect_code 1 "$rc" "malformed list #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-accounts"
  done
  rm "$HOME_DIR/config/claude-accounts"
  mkdir "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-dir" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "a directory in place of the list must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-accounts must be a readable regular file"
  assert_no_grep "$CASE/second" "$CASE/claude-checks" "an account no launch chose must never be sign-in checked"
  assert_absent "$CASE/claude-worker" "no refused launch may start Claude"
  pass "a list refuses a missing, undeclared, signed-out, wrong-runner, raw-override, malformed-fallback, or malformed choice"
}

test_account_list_secondmate_needs_its_own_pin() {
  local out rc id=acct-list-sm
  new_case list-secondmate claude
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/mate"
  declare_accounts "$CASE/first"
  out=$(spawn_account_secondmate "$id"); rc=$?
  expect_code 1 "$rc" "a secondmate without its own pin must refuse under a list: $out"
  assert_refused_before_launch "$id" "$out" "secondmate $id needs its own pin in config/secondmate-accounts/$id/claude-account"
  out=$(spawn_account_secondmate "$id" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "--account on a secondmate must refuse"
  assert_refused_before_launch "$id" "$out" "--account applies to ships and scouts"
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  printf '%s\n' "$CASE/mate" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  out=$(spawn_account_secondmate "$id"); rc=$?
  expect_code 0 "$rc" "a secondmate with its own pin should launch under a list: $out"
  assert_contains "$out" "account=$CASE/mate" "the secondmate should launch on its own pin"
  pass "a list never chooses a secondmate's account: it needs its own pin and refuses --account"
}

# install_autoswitch_quota_fake: installs a fake quota-axi in $FAKEBIN that
# serves $CASE/token-quota.json when CLAUDE_CODE_OAUTH_TOKEN is set and
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/quota.json otherwise.
install_autoswitch_quota_fake() {
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
if [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  [ ! -f '$CASE/token-quota-fail' ] || exit 1
  [ -f '$CASE/token-quota.json' ] || exit 1
  cat '$CASE/token-quota.json'
  exit 0
fi
root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
[ ! -f "\$root/quota-fail" ] || exit 1
[ -f "\$root/quota.json" ] || exit 1
cat "\$root/quota.json"
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# write_claude_quota_snapshot <dest> <all_models_pct> [<spendPriority>] [<runway>] [<model_name> <model_pct>]
write_claude_quota_snapshot() {
  local dest=$1 pct=$2 sp=${3:-0.5} runway=${4:-through_reset} mname=${5:-} mpct=${6:-}
  mkdir -p "$(dirname "$dest")"
  jq -n --argjson pct "$pct" --argjson sp "$sp" --arg runway "$runway" --arg mname "$mname" --arg mpct "$mpct" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      quotaSemantics: {
        status: "known",
        effectiveAvailability: ([
          {scope: "all_models", status: "known", effectivePercentRemaining: $pct,
           runway: {status: $runway}, selection: {spendPriority: $sp}}
        ] + (if $mname == "" then [] else [
          {scope: ("model:" + $mname), status: ("known"), effectivePercentRemaining: ($mpct | tonumber),
           runway: {status: "through_reset"}, selection: {spendPriority: $sp}}
        ] end))
      }
    }]
  }' > "$dest"
}

write_claude_quota_unmeasured() {
  local dest=$1 status=${2:-rate_limited} err=${3:-Claude quota endpoint rate limited}
  mkdir -p "$(dirname "$dest")"
  jq -n --arg st "$status" --arg err "$err" '{
    schemaVersion: 5,
    providers: [{
      provider: "claude",
      state: {status: $st, error: $err},
      quotaSemantics: {status: "unknown", effectiveAvailability: []}
    }]
  }' > "$dest"
}

test_autoswitch_both_healthy_picks_higher_headroom_and_records_meta() {
  local out rc
  new_case auto-healthy claude
  install_autoswitch_quota_fake
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  make_token_file "$CASE/token-files/max100.token"
  printf 'ordinary\ntoken:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"

  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 45 0.4
  write_claude_quota_snapshot "$CASE/token-quota.json" 80 0.7
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-auto-tok); rc=$?
  expect_code 0 "$rc" "both healthy with higher token headroom should launch: $out"
  assert_contains "$out" "account=token:max100.token" "higher-headroom setup-token account is chosen"
  assert_not_contains "$out" "every declared Claude account" "both healthy must not warn"
  assert_no_token_anywhere acct-auto-tok "$out"
  assert_grep "account=token:max100.token" "$HOME_DIR/state/acct-auto-tok.meta" "meta records chosen account basename"
  assert_grep "account_request=token:$CASE/token-files/max100.token" "$HOME_DIR/state/acct-auto-tok.meta" "meta records account_request for relaunch stability"
  assert_grep "account_reason=auto: token:max100.token 80% usable headroom (ordinary 45%; threshold 20%)" "$HOME_DIR/state/acct-auto-tok.meta" "meta records headroom selection reason"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_SENTINEL" "$CASE/claude-worker" "worker runs on the chosen setup-token account"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "setup-token worker drops CLAUDE_CONFIG_DIR"

  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 78 0.6
  write_claude_quota_snapshot "$CASE/token-quota.json" 52 0.3
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-auto-ord); rc=$?
  expect_code 0 "$rc" "both healthy with higher ordinary headroom should launch: $out"
  assert_contains "$out" "account=ordinary" "higher-headroom ordinary account is chosen"
  assert_grep "account=ordinary" "$HOME_DIR/state/acct-auto-ord.meta" "meta records ordinary account"
  assert_grep "account_request=ordinary" "$HOME_DIR/state/acct-auto-ord.meta" "meta records ordinary account_request"
  assert_grep "account_reason=auto: ordinary 78% usable headroom (token:max100.token 52%; threshold 20%)" "$HOME_DIR/state/acct-auto-ord.meta" "meta records ordinary headroom selection reason"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "ordinary worker sheds ambient token"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "ordinary worker drops ambient root"

  # Model-specific scope bounds usable headroom when --model is supplied.
  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 90 0.8 through_reset opus 35
  write_claude_quota_snapshot "$CASE/token-quota.json" 60 0.5
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-auto-model --model opus); rc=$?
  expect_code 0 "$rc" "model-bounded headroom selection should launch: $out"
  assert_contains "$out" "account=token:max100.token" "usable headroom takes the minimum across applicable scopes"
  assert_grep "account_reason=auto: token:max100.token 60% usable headroom (ordinary 35%; threshold 20%)" "$HOME_DIR/state/acct-auto-model.meta" "model scope headroom is reflected in account_reason"
  pass "both healthy: selects the declared Claude account with higher usable headroom and records account + reason"
}

test_autoswitch_skips_low_account_and_honors_configurable_threshold() {
  local out rc
  new_case auto-one-low claude
  install_autoswitch_quota_fake
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  make_token_file "$CASE/token-files/max100.token"
  printf 'ordinary\ntoken:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"

  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 12 0.1
  write_claude_quota_snapshot "$CASE/token-quota.json" 65 0.5
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-skip-ord); rc=$?
  expect_code 0 "$rc" "one low and one healthy should launch on healthy: $out"
  assert_contains "$out" "account=token:max100.token" "low ordinary account is skipped"
  assert_not_contains "$out" "every declared Claude account" "one healthy account remaining must not emit all-low warning"
  assert_grep "account_reason=auto: token:max100.token 65% usable headroom (skipped low ordinary 12%; threshold 20%)" "$HOME_DIR/state/acct-skip-ord.meta" "meta records skipped low ordinary account"

  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 25 0.2
  write_claude_quota_snapshot "$CASE/token-quota.json" 0 -1.5 exhausted_now
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-skip-tok); rc=$?
  expect_code 0 "$rc" "exhausted token and healthy ordinary should launch on ordinary: $out"
  assert_contains "$out" "account=ordinary" "exhausted setup-token account is skipped"
  assert_grep "account_reason=auto: ordinary 25% usable headroom (skipped low token:max100.token exhausted_now at all_models; threshold 20%)" "$HOME_DIR/state/acct-skip-tok.meta" "meta records skipped exhausted setup-token account"

  printf '50\n' > "$HOME_DIR/config/claude-account-low-threshold"
  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 40 0.4
  write_claude_quota_snapshot "$CASE/token-quota.json" 55 0.5
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-skip-cfg50); rc=$?
  expect_code 0 "$rc" "custom 50% threshold should skip 40% account: $out"
  assert_contains "$out" "account=token:max100.token" "40% account is skipped under 50% threshold"
  assert_grep "account_reason=auto: token:max100.token 55% usable headroom (skipped low ordinary 40%; threshold 50%)" "$HOME_DIR/state/acct-skip-cfg50.meta" "meta records custom threshold"
  pass "one low: skips an account below the low-headroom threshold (default 20% or configured) and chooses the healthy account"
}

test_autoswitch_both_low_warns_and_keeps_pinned_account() {
  local out rc
  new_case auto-both-low claude
  install_autoswitch_quota_fake
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  make_token_file "$CASE/token-files/max100.token"
  printf 'ordinary\ntoken:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"
  printf 'token:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-account"

  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 12 -0.8
  write_claude_quota_snapshot "$CASE/token-quota.json" 8 -1.1
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-low-pinned); rc=$?
  expect_code 0 "$rc" "both low should warn and fall back to pinned account: $out"
  assert_contains "$out" "warning: every declared Claude account is below the 20% headroom threshold (ordinary 12%, token:max100.token 8%); keeping pinned account token:max100.token" "clear stderr warning names all low accounts and pinned fallback"
  assert_contains "$out" "account=token:max100.token" "pinned account is chosen even though ordinary had 12% vs 8%"
  assert_no_token_anywhere acct-low-pinned "$out"
  assert_grep "account_reason=fallback-pinned: all declared accounts below 20% (ordinary 12%, token:max100.token 8%); using pinned token:max100.token" "$HOME_DIR/state/acct-low-pinned.meta" "meta records fallback-pinned reason"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_SENTINEL" "$CASE/claude-worker" "worker runs on the fallback pinned setup-token account"

  rm -f "$HOME_DIR/config/claude-account"
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-low-unpinned); rc=$?
  expect_code 0 "$rc" "both low with no pin should warn and use first declared account: $out"
  assert_contains "$out" "warning: every declared Claude account is below the 20% headroom threshold (ordinary 12%, token:max100.token 8%); keeping default declared account ordinary" "warning names first declared fallback when config/claude-account is absent"
  assert_contains "$out" "account=ordinary" "first declared account is used when unpinned"
  assert_grep "account_reason=fallback-default: all declared accounts below 20% (ordinary 12%, token:max100.token 8%); using ordinary" "$HOME_DIR/state/acct-low-unpinned.meta" "meta records fallback-default reason"
  pass "both low: emits a clear warning and keeps today's pinned-account fallback"
}

test_autoswitch_unmeasured_account_stays_eligible_with_disclosed_uncertainty() {
  local out rc
  new_case auto-uncertain claude
  install_autoswitch_quota_fake
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  make_token_file "$CASE/token-files/max100.token"
  printf 'ordinary\ntoken:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"
  printf 'token:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-account"

  # ordinary is low (10%), while setup-token measurement is rate-limited / unavailable ->
  # setup-token stays eligible with disclosed uncertainty (no all-low warning).
  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 10 -0.9
  write_claude_quota_unmeasured "$CASE/token-quota.json" rate_limited "Claude quota endpoint rate limited"
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-uncertain-tok); rc=$?
  expect_code 0 "$rc" "unmeasured token account should stay eligible when ordinary is low: $out"
  assert_contains "$out" "account=token:max100.token" "unmeasured setup-token account is chosen over low ordinary"
  assert_not_contains "$out" "every declared Claude account" "disclosed uncertainty is not treated as low"
  assert_no_token_anywhere acct-uncertain-tok "$out"
  assert_grep "account_reason=auto: token:max100.token eligible with disclosed uncertainty (quota unknown: Claude quota endpoint rate limited; skipped low ordinary 10%)" "$HOME_DIR/state/acct-uncertain-tok.meta" "meta discloses uncertainty and skipped low account"

  # When ordinary is measured healthy (45%) and token is unmeasured, measured healthy wins while disclosing uncertainty.
  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 45 0.3
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-healthy-over-uncertain); rc=$?
  expect_code 0 "$rc" "measured healthy should beat unmeasured: $out"
  assert_contains "$out" "account=ordinary" "measured healthy account wins over unmeasured"
  assert_grep "account_reason=auto: ordinary 45% usable headroom (token:max100.token unmeasured (quota unknown: Claude quota endpoint rate limited); threshold 20%)" "$HOME_DIR/state/acct-healthy-over-uncertain.meta" "meta discloses the unmeasured sibling"

  # When both accounts are unmeasured (probe fails), pinned account stays eligible with disclosed uncertainty.
  : > "$HOME_DIR/user-home/.claude/quota-fail"
  : > "$CASE/token-quota-fail"
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-both-uncertain); rc=$?
  expect_code 0 "$rc" "both unmeasured should stay eligible without warning: $out"
  assert_contains "$out" "account=token:max100.token" "pinned unmeasured account is selected"
  assert_not_contains "$out" "every declared Claude account" "unmeasured accounts must not trigger low warning"
  assert_grep "eligible with disclosed uncertainty" "$HOME_DIR/state/acct-both-uncertain.meta" "meta records disclosed uncertainty"
  pass "measurement unavailable keeps the candidate account eligible with disclosed uncertainty"
}

test_autoswitch_overrides_and_refusals() {
  local out rc
  new_case auto-ovr claude
  install_autoswitch_quota_fake
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  make_token_file "$CASE/token-files/max100.token"
  printf 'ordinary\ntoken:%s\n' "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"
  write_claude_quota_snapshot "$HOME_DIR/user-home/.claude/quota.json" 10 -0.9
  write_claude_quota_snapshot "$CASE/token-quota.json" 85 0.8

  # Explicit --account overrides automatic switching.
  out=$(FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS=0 spawn_ship acct-explicit-ovr --account ordinary); rc=$?
  expect_code 0 "$rc" "explicit --account must override config/claude-accounts: $out"
  assert_contains "$out" "account=ordinary" "explicit --account wins over higher-headroom sibling"
  assert_no_grep "account_reason=" "$HOME_DIR/state/acct-explicit-ovr.meta" "explicit --account records no auto account_reason"

  # Malformed threshold refuses before launch.
  printf '150\n' > "$HOME_DIR/config/claude-account-low-threshold"
  out=$(spawn_ship acct-bad-thresh); rc=$?
  expect_code 1 "$rc" "out-of-range threshold must refuse"
  assert_refused_before_launch acct-bad-thresh "$out" "config/claude-account-low-threshold must hold an integer from 0 through 100"
  rm -f "$HOME_DIR/config/claude-account-low-threshold"

  # Duplicate or malformed config/claude-accounts refuses before launch without printing any token.
  printf 'token:%s\ntoken:%s\n' "$CASE/token-files/max100.token" "$CASE/token-files/max100.token" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship acct-dup-list); rc=$?
  expect_code 1 "$rc" "duplicate config/claude-accounts entry must refuse"
  assert_refused_before_launch acct-dup-list "$out" "config/claude-accounts declares the same account twice"
  assert_not_contains "$out" "$TOKEN_SENTINEL" "refusal never prints token"
  pass "explicit --account overrides automatic selection, and malformed pool or threshold files refuse before launch"
}

test_token_rotation_round_robins_and_pin_wins() {
  local out rc i
  new_case rotation claude
  make_token_file "$CASE/tokens/a.token"
  make_token_file "$CASE/tokens/b.token"
  printf '# accounts\ntoken:%s\ntoken:%s\n' "$CASE/tokens/a.token" "$CASE/tokens/b.token" > "$HOME_DIR/config/claude-token-accounts"
  out=$(spawn_ship rot-1 2>&1); rc=$?
  expect_code 0 "$rc" "first rotated spawn: $out"
  assert_grep "account=token:a.token" "$HOME_DIR/state/rot-1.meta" "first spawn takes the first listed account"
  out=$(spawn_ship rot-2 2>&1); rc=$?
  expect_code 0 "$rc" "second rotated spawn: $out"
  assert_grep "account=token:b.token" "$HOME_DIR/state/rot-2.meta" "second spawn takes the next account"
  out=$(spawn_ship rot-3 2>&1); rc=$?
  assert_grep "account=token:a.token" "$HOME_DIR/state/rot-3.meta" "rotation wraps"
  assert_no_token_anywhere rot-3 "$out"
  out=$(spawn_ship rot-4 --account "token:$CASE/tokens/b.token" 2>&1)
  assert_grep "account=token:b.token" "$HOME_DIR/state/rot-4.meta" "--account wins over rotation"
  printf 'token:%s\n' "$CASE/tokens/a.token" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship rot-5 2>&1)
  assert_grep "account=token:a.token" "$HOME_DIR/state/rot-5.meta" "the pin wins over rotation"
  [ "$(cat "$HOME_DIR/state/claude-account-cursor")" = 0 ] || fail "pinned/explicit spawns must not advance the cursor"
  pass "token rotation round-robins across config/claude-token-accounts; --account and the pin win"
}

test_rotation_next_helper() {
  local cfg="$TMP_ROOT/rotnext"
  mkdir -p "$cfg"
  # shellcheck source=bin/fm-worker-account-lib.sh
  . "$REPO_ROOT/bin/fm-worker-account-lib.sh"
  printf 'token:/x/a\ntoken:/x/b\ntoken:/x/c\n' > "$cfg/claude-token-accounts"
  [ "$(fm_worker_account_rotation_next "$cfg" token:/x/a)" = token:/x/b ] || fail "a -> b"
  [ "$(fm_worker_account_rotation_next "$cfg" token:/x/c)" = token:/x/a ] || fail "c wraps to a"
  [ "$(fm_worker_account_rotation_next "$cfg" "")" = token:/x/a ] || fail "unknown -> first"
  printf 'token:/x/a\n' > "$cfg/claude-token-accounts"
  fm_worker_account_rotation_next "$cfg" token:/x/a >/dev/null 2>&1 && fail "single account cannot rotate"
  printf 'token:rel\n' > "$cfg/claude-token-accounts"
  fm_worker_account_rotation_list "$cfg" >/dev/null 2>&1 && fail "invalid entry must refuse"
  pass "rotation-next wraps, refuses a single account and invalid entries"
}

test_secondmate_account_override
test_secondmate_account_refusals
test_per_launch_account_ordinary_overrides_a_token_pin
test_per_launch_account_token_overrides_an_ordinary_pin
test_per_launch_account_works_with_no_home_pin_and_refuses_bad_values
test_per_launch_account_refuses_non_claude_runners
test_relaunch_reuses_the_recorded_per_launch_account
test_remote_secondmate_account_override_refuses_locally
test_remote_secondmate_refuses_account
test_absent_pin_keeps_the_launch_unchanged
test_claude_pin_selects_the_root_and_sheds_ambient_credentials
test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login
test_claude_ordinary_pin_unsets_the_config_root
test_malformed_pins_refuse_before_launch
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_raw_claude_command_receives_the_pin
test_raw_claude_account_override_refuses_under_a_pin
test_raw_claude_account_override_is_kept_without_a_pin
test_local_secondmate_reads_the_launching_home_pin
test_token_pin_launches_with_the_token_for_that_worker_only
test_token_pin_refusals_never_print_the_token
test_raw_claude_command_receives_the_token_pin
test_token_pin_in_a_secondmate_account_file
test_relaunch_check_and_exec_helper
test_no_account_list_keeps_today_and_takes_a_per_launch_account
test_account_list_launches_the_named_entry
test_account_list_refusals
test_account_list_secondmate_needs_its_own_pin
test_autoswitch_both_healthy_picks_higher_headroom_and_records_meta
test_autoswitch_skips_low_account_and_honors_configurable_threshold
test_autoswitch_both_low_warns_and_keeps_pinned_account
test_autoswitch_unmeasured_account_stays_eligible_with_disclosed_uncertainty
test_autoswitch_overrides_and_refusals
test_token_rotation_round_robins_and_pin_wins
test_rotation_next_helper

echo "# all fm-worker-account tests passed"
