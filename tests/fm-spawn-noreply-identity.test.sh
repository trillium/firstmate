#!/usr/bin/env bash
# Regression: spawned crew panes export the captain's noreply GitHub email as
# the git author and committer identity, and spawn writes no user.email to any
# git config - a treehouse worktree shares its repository config with the
# project's primary clone, so a config write would change every checkout.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-noreply-identity)
NOREPLY="5898009+trillium@users.noreply.github.com"

test_spawn_sets_noreply_email_leaves_global_untouched() {
  local case_dir home proj wt fakebin id out status
  id=noreply-id-z1
  case_dir="$TMP_ROOT/case-one"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" pi-signed)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fm_test_spawn_brief "$home" "$id"
  printf '[user]\n\temail = captain-sentinel@example.invalid\n' > "$case_dir/global.gitconfig"

  : > "$case_dir/pane.log"
  out=$(GIT_CONFIG_GLOBAL="$case_dir/global.gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
    FM_FAKE_PANE_LOG="$case_dir/pane.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" --mode direct-PR --yolo off --model sonnet "$id" "$proj" --harness pi)
  status=$?
  expect_code 0 "$status" "pi spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report pi harness"

  assert_grep "export GIT_AUTHOR_EMAIL=$NOREPLY GIT_COMMITTER_EMAIL=$NOREPLY" "$case_dir/pane.log" \
    "the worker pane did not receive the noreply identity export"
  if git -C "$wt" config --get user.email >/dev/null 2>&1; then
    fail "spawn wrote user.email into the shared repository config: $(git -C "$wt" config --get user.email)"
  fi
  if git -C "$proj" config --get --local user.email >/dev/null 2>&1; then
    fail "the project clone's repository config gained a user.email"
  fi
  assert_grep "captain-sentinel@example.invalid" "$case_dir/global.gitconfig" "global config was modified"
  pass "spawn exports the noreply identity to the worker and writes no git config"
}

test_spawn_sets_noreply_email_leaves_global_untouched

echo "# all fm-spawn-noreply-identity tests passed"
