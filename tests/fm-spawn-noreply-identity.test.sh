#!/usr/bin/env bash
# Regression: spawned crew worktrees carry the captain's noreply GitHub email
# locally while global git config is untouched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-noreply-identity)
NOREPLY="5898009+trillium@users.noreply.github.com"

test_spawn_sets_noreply_email_leaves_global_untouched() {
  local case_dir home proj wt fakebin id out status local_email
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

  out=$(GIT_CONFIG_GLOBAL="$case_dir/global.gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
    fm_test_run_spawn "$home" "$wt" "$fakebin" --mode direct-PR --yolo off --model sonnet "$id" "$proj" --harness pi)
  status=$?
  expect_code 0 "$status" "pi spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report pi harness"

  local_email=$(git -C "$wt" config user.email)
  [ "$local_email" = "$NOREPLY" ] || fail "worktree user.email is '$local_email', want '$NOREPLY'"
  assert_grep "captain-sentinel@example.invalid" "$case_dir/global.gitconfig" "global config was modified"
  pass "spawned worktree carries the noreply email while global config is untouched"
}

test_spawn_sets_noreply_email_leaves_global_untouched

echo "# all fm-spawn-noreply-identity tests passed"
