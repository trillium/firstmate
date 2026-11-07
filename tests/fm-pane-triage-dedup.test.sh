#!/usr/bin/env bash
# tests/fm-pane-triage-dedup.test.sh - bin/fm-pane-triage.py --file-beads files
# one task per pane+state: an open row for the same pane and state gets a
# comment instead of a duplicate create. The `herdr` and `task` commands are
# stubs on PATH; the stub `task` logs each call and answers `list` from a canned
# file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pane-triage-dedup)

setup_world() {  # <name> <open-rows-json|FAIL>
  local w=$TMP_ROOT/$1 fb
  mkdir -p "$w/home"
  fb=$(fm_fakebin "$w")
  printf '%s\n' "$2" >"$w/list.json"
  cat >"$fb/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$2" = list ]; then
  echo '{"result":{"panes":[{"pane_id":"w1:p1","agent":"claude","agent_status":"idle","cwd":"/x"}]}}'
else
  echo "Please log in to continue"
fi
STUB
  cat >"$fb/task" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$w/calls.log"
case "\$1" in
  list) [ "\$(cat "$w/list.json")" = FAIL ] && exit 1; cat "$w/list.json" ;;
  create) echo "Created task-new1" ;;
esac
STUB
  chmod +x "$fb/herdr" "$fb/task"
  : >"$w/calls.log"
  printf '%s\n' "$w"
}

run_triage() {  # <world>
  PATH="$1/fakebin:$PATH" FM_HOME="$1/home" python3 -I "$ROOT/bin/fm-pane-triage.py" --file-beads --no-laya >/dev/null
}

test_no_open_row_creates() {
  local w; w=$(setup_world none '[]')
  run_triage "$w"
  assert_grep 'create ' "$w/calls.log" 'expected a create call'
  pass "no open row -> create"
}

test_same_pane_and_state_comments() {
  local w; w=$(setup_world same '[{"id":"task-old1","status":"open","title":"Pane w1:p1 blocked (blocked_auth): needs login/credential: x"}]')
  run_triage "$w"
  assert_grep 'comment task-old1 ' "$w/calls.log" 'expected a comment on the open row'
  assert_no_grep 'create ' "$w/calls.log" 'unexpected create'
  pass "open row same pane+state -> comment, no create"
}

test_different_state_creates() {
  local w; w=$(setup_world diff '[{"id":"task-old2","status":"open","title":"Pane w1:p1 blocked (blocked_usage): usage/rate cap"}]')
  run_triage "$w"
  assert_grep 'create ' "$w/calls.log" 'expected a create call'
  assert_no_grep 'comment task-old2' "$w/calls.log" 'unexpected comment'
  pass "open row same pane, different state -> create"
}

test_lookup_failure_creates() {
  local w; w=$(setup_world fail 'FAIL')
  run_triage "$w"
  assert_grep 'create ' "$w/calls.log" 'expected a create call'
  pass "lookup failure -> create"
}

fm_test_run test_no_open_row_creates test_same_pane_and_state_comments \
  test_different_state_creates test_lookup_failure_creates
