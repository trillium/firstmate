#!/usr/bin/env bash
# Regression: spawned crew worktrees carry the captain's noreply GitHub email
# locally while global git config is untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-noreply-identity)
NOREPLY="5898009+trillium@users.noreply.github.com"

make_fakebin() {
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
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed
  printf '%s\n' "$fakebin"
}

test_spawn_sets_noreply_email_leaves_global_untouched() {
  local case_dir home proj wt fakebin id out status local_email
  id=noreply-id-z1
  case_dir="$TMP_ROOT/case-one"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "pi" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '[user]\n\temail = captain-sentinel@example.invalid\n' > "$case_dir/global.gitconfig"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GIT_CONFIG_GLOBAL="$case_dir/global.gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
    PATH="$fakebin:$PATH" \
    "$SPAWN" --mode direct-PR --yolo off --model sonnet "$id" "$proj" --harness pi 2>&1)
  status=$?
  expect_code 0 "$status" "pi spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report pi harness"

  local_email=$(git -C "$wt" config user.email)
  [ "$local_email" = "$NOREPLY" ] || fail "worktree user.email is '$local_email', want '$NOREPLY'"
  assert_grep "captain-sentinel@example.invalid" "$case_dir/global.gitconfig" "global config was modified"
  pass "spawned worktree carries the noreply email while global config is untouched"
}

test_spawn_sets_noreply_email_leaves_global_untouched

echo "# all fm-spawn-noreply-identity tests passed"
