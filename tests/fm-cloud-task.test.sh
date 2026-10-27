#!/usr/bin/env bash
# tests/fm-cloud-task.test.sh - a cloud run as an ordinary firstmate dispatch:
# bin/fm-cloud.sh launch --task, the finish check, landing hand-off, teardown,
# cleanup, credit, and the backend=cloud carve-outs in crew-state and reap.
# claude, gh and gh-axi are stubs and the remote is a local bare repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cloud-task)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
CONFIG="$HOME_DIR/config"
mkdir -p "$STATE" "$DATA" "$CONFIG" "$HOME_DIR/projects"
touch "$STATE/.last-watcher-beat"
printf '%s\n' manual > "$CONFIG/backlog-backend"

REMOTE="$TMP_ROOT/remote.git"
REPO="$TMP_ROOT/repo"
git init -q --bare "$REMOTE"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin HEAD:refs/heads/main
git -C "$REPO" push -q origin HEAD:refs/heads/claude/old-run

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_STUB_ARGS"
[ -t 1 ] || { echo "--cloud requires an interactive terminal" >&2; exit 1; }
echo "View: https://claude.ai/code/session_task123"
SH
# A gh-axi that lists a PR for any head when FM_STUB_PR holds a number.
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
[ -s "${FM_STUB_PR:-/nonexistent}" ] || { echo "prs[0]:"; exit 0; }
printf 'prs[1]{number,title}:\n  %s,"cloud work"\n' "$(cat "$FM_STUB_PR")"
SH
# A gh that answers `pr view --json state` from FM_STUB_PRSTATE.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in *"pr view"*) cat "${FM_STUB_PRSTATE:-/dev/null}"; exit 0 ;; esac
exit 0
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/gh-axi" "$FAKEBIN/gh"
export FM_STUB_ARGS="$TMP_ROOT/args"
export FM_STUB_PR="$TMP_ROOT/stub-pr"
export FM_STUB_PRSTATE="$TMP_ROOT/stub-prstate"

env_run() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" "$@"
}
cloud() { env_run bash "$ROOT/bin/fm-cloud.sh" "$@"; }

write_brief() {  # <task>
  mkdir -p "$DATA/$1"
  cat > "$DATA/$1/brief.md" <<EOF
# Task
## Captain's intent
Do the cloud thing for $1.

# Definition of done
Delivery contract: mode=direct-PR
EOF
}

# --- launch --task ------------------------------------------------------------

out=$(cloud launch --task t-missing --repo "$REPO" 2>&1); rc=$?
assert_equals 1 "$rc" "launch --task without a brief fails"
assert_contains "$out" "no brief" "the missing brief is named"
assert_absent "$STATE/t-missing.meta" "a refused launch records nothing"

write_brief t-one
out=$(cloud launch --task t-one --repo "$REPO" --file "$TMP_ROOT/x" 2>&1); rc=$?
assert_equals 2 "$rc" "--task with --file is a usage error"
out=$(cloud launch --task t-one --repo "$REPO" --mode no-mistakes 2>&1); rc=$?
assert_equals 2 "$rc" "a cloud run only delivers by direct-PR"

out=$(cloud launch --task t-one --repo "$REPO" 2>&1) || fail "launch --task failed: $out"
assert_contains "$out" "task: t-one" "launch --task reports the binding"
assert_contains "$out" "url: https://claude.ai/code/session_task123" "launch prints the session url"
args=$(cat "$FM_STUB_ARGS")
assert_contains "$args" "Do the cloud thing for t-one" "claude gets the brief"
assert_contains "$args" "branch named claude/t-one" "claude gets the cloud trailer"
assert_contains "$args" "no secrets" "the trailer forbids secrets"
meta="$STATE/t-one.meta"
assert_grep "backend=cloud" "$meta" "meta marks the cloud backend"
assert_grep "mode=direct-PR" "$meta" "meta records direct-PR"
assert_grep "branch=claude/t-one" "$meta" "meta records the result branch"
assert_grep "cloud_url=https://claude.ai/code/session_task123" "$meta" "meta records the session url"
assert_equals 1 "$(grep -c '^spawn_gen=' "$meta")" "meta carries exactly one spawn_gen"
assert_no_grep "window=" "$meta" "a cloud meta has no window"
assert_grep "task=t-one" "$(ls "$STATE"/cloud-runs/*.run | head -n 1)" "the run record names its task"
assert_grep "cloud run launched" "$STATE/t-one.status" "the status log notes the launch"
assert_grep "session_task123" "$STATE/t-one.status" "the status log carries the session"
[ -x "$STATE/t-one.check.sh" ] || fail "the finish check is executable"
assert_equals 700 "$(stat -f '%Lp' "$STATE/t-one.check.sh" 2>/dev/null || stat -c '%a' "$STATE/t-one.check.sh")" "the finish check is mode 0700"
assert_present "$STATE/t-one.check-trust" "the finish check is registered"
assert_not_contains "$(cat "$STATE/t-one.check.sh")" "Do the cloud thing" "the check script holds no prompt text"
pass "launch --task records the run, the task, the status and the check"

out=$(cloud launch --task t-one --repo "$REPO" 2>&1); rc=$?
assert_equals 1 "$rc" "a second launch for the same task is refused"
assert_contains "$out" "already has a record" "the duplicate is named"
pass "launch --task refuses a duplicate"

# --- the finish check ---------------------------------------------------------

run_id=$(sed -n 's/^cloud_run=//p' "$meta")
quiet=$(env_run "$STATE/t-one.check.sh") || fail "check script failed"
assert_equals "" "$quiet" "the check is silent while nothing has happened"

git -C "$REPO" push -q origin HEAD:refs/heads/claude/t-one
out=$(env_run "$STATE/t-one.check.sh")
assert_contains "$out" "branch claude/t-one pushed, no PR yet" "a new branch wakes firstmate"
assert_contains "$out" "session_task123" "the wake names the session"
assert_equals "" "$(env_run "$STATE/t-one.check.sh")" "the same branch is reported once"
pass "the check fires once on a new branch"

# A PR is found through the github slug of the run's remote; the local bare
# remote has none, so record a github-shaped remote_url on the run.
sed -i.bak 's#^remote_url=.*#remote_url=https://github.com/acme/widgets.git#' "$STATE/cloud-runs/$run_id.run"
rm -f "$STATE/cloud-runs/$run_id.run.bak"
assert_equals "" "$(env_run "$STATE/t-one.check.sh")" "no PR yet keeps the branch report quiet"
printf '%s\n' 77 > "$FM_STUB_PR"
out=$(env_run "$STATE/t-one.check.sh")
assert_contains "$out" "PR https://github.com/acme/widgets/pull/77 opened from claude/t-one" "a PR wakes firstmate with its url"
assert_contains "$out" "bin/fm-cloud.sh land t-one" "the wake names the landing hand-off"
assert_equals "" "$(env_run "$STATE/t-one.check.sh")" "the same PR is reported once"
rm -f "$FM_STUB_PR"
pass "the check fires once on a PR"

# Timeout: a second task with no branch, back-dated.
write_brief t-two
cloud launch --task t-two --repo "$REPO" >/dev/null 2>&1 || fail "launch t-two failed"
run2=$(sed -n 's/^cloud_run=//p' "$STATE/t-two.meta")
rec2="$STATE/cloud-runs/$run2.run"
# Ignore the t-one branch so t-two sees no result of its own.
git -C "$REPO" ls-remote --heads origin 'refs/heads/claude/*' | awk '{print $1":"$2}' | paste -sd, - > "$TMP_ROOT/heads"
sed -i.bak "s#^heads_before=.*#heads_before=$(cat "$TMP_ROOT/heads")#" "$rec2"; rm -f "$rec2.bak"
assert_equals "" "$(env_run "$STATE/t-two.check.sh")" "a fresh run with no result is silent"
sed -i.bak "s#^launched_at=.*#launched_at=$(( $(date +%s) - 3 * 3600 ))#" "$rec2"; rm -f "$rec2.bak"
assert_equals "" "$(env_run "$STATE/t-two.check.sh")" "silence under the limit stays quiet"
out=$(FM_CLOUD_TIMEOUT_MINUTES=60 env_run "$STATE/t-two.check.sh")
assert_contains "$out" "no branch or PR after" "silence past the limit wakes firstmate"
assert_contains "$out" "possibly stuck" "the wake says possibly stuck"
assert_contains "$out" "https://claude.ai/code/session_task123" "the stuck wake names the session"
assert_equals "" "$(FM_CLOUD_TIMEOUT_MINUTES=60 env_run "$STATE/t-two.check.sh")" "the stuck wake fires once"
printf '%s\n' 30 > "$CONFIG/cloud-timeout"
rm -f "$STATE/cloud-runs/$run2.stuck"
out=$(env_run "$STATE/t-two.check.sh")
assert_contains "$out" "possibly stuck" "config/cloud-timeout sets the limit"
rm -f "$CONFIG/cloud-timeout"
pass "the check fires on timeout, once"

# --- land ---------------------------------------------------------------------

write_brief t-land
cloud launch --task t-land --repo "$REPO" >/dev/null 2>&1 || fail "launch t-land failed"
lmeta="$STATE/t-land.meta"
out=$(cloud land t-land 2>&1); rc=$?
assert_equals 1 "$rc" "land refuses a run with no result branch"
git -C "$REPO" push -q origin HEAD:refs/heads/claude/t-land
out=$(cloud land t-land 2>&1); rc=$?
assert_equals 1 "$rc" "land refuses a run with no PR"
sed -i.bak 's#^remote_url=.*#remote_url=https://github.com/acme/widgets.git#' "$STATE/cloud-runs/$(sed -n 's/^cloud_run=//p' "$lmeta").run"
rm -f "$STATE/cloud-runs/"*.bak
printf '%s\n' 78 > "$FM_STUB_PR"
out=$(cloud land t-land 2>&1) || fail "land failed: $out"
assert_contains "$out" "https://github.com/acme/widgets/pull/78" "land names the PR it armed"
assert_grep "pr=https://github.com/acme/widgets/pull/78" "$lmeta" "land records the PR on the task"
assert_grep "branch=claude/t-land" "$lmeta" "land keeps the result branch on the task"
assert_grep "backend=cloud" "$lmeta" "land keeps the cloud backend on the task"
assert_no_grep "fm-cloud.sh" "$STATE/t-land.check.sh" "the PR poll replaces the cloud check"
rm -f "$FM_STUB_PR"
printf '%s\n' MERGED > "$FM_STUB_PRSTATE"
cloud teardown t-land >/dev/null 2>&1 || fail "teardown after land failed"
assert_absent "$lmeta" "a landed cloud task tears down"
assert_absent "$STATE/t-land.check.sh" "teardown retires the PR poll"
pass "land hands the PR to the merge poll and teardown retires it"

# --- landing and teardown -----------------------------------------------------

out=$(cloud teardown t-one 2>&1); rc=$?
assert_equals 1 "$rc" "teardown refuses a run with no recorded PR"
assert_contains "$out" "REFUSED" "the refusal says so"
assert_present "$meta" "a refused teardown keeps the task record"
assert_present "$STATE/t-one.check.sh" "a refused teardown keeps the check"

printf '%s\n' "https://github.com/acme/widgets/pull/77" > "$TMP_ROOT/prurl"
echo "pr=https://github.com/acme/widgets/pull/77" >> "$meta"
printf '%s\n' OPEN > "$FM_STUB_PRSTATE"
out=$(cloud teardown t-one 2>&1); rc=$?
assert_equals 1 "$rc" "teardown refuses an unmerged PR"
assert_contains "$out" "not merged" "the open PR is named"
assert_present "$STATE/cloud-runs/$run_id.run" "an unmerged teardown keeps the run record"
assert_equals "" "$(env_run "$STATE/t-one.check.sh")" "once a PR is recorded the cloud check yields to the PR poll"

printf '%s\n' MERGED > "$FM_STUB_PRSTATE"
out=$(cloud teardown t-one 2>&1) || fail "teardown of a merged run failed: $out"
assert_contains "$out" "teardown t-one complete" "teardown reports completion"
assert_absent "$meta" "teardown removes the task record"
assert_absent "$STATE/t-one.check.sh" "teardown retires the check"
assert_absent "$STATE/t-one.check-trust" "teardown retires the check trust"
assert_absent "$STATE/cloud-runs/$run_id.run" "teardown retires the run record"
assert_absent "$STATE/cloud-runs/$run_id.seen" "teardown retires the seen marker"
pass "teardown refuses unlanded work and retires everything once merged"

# fm-teardown.sh delegates a backend=cloud task to the same path.
write_brief t-three
cloud launch --task t-three --repo "$REPO" >/dev/null 2>&1 || fail "launch t-three failed"
run3=$(sed -n 's/^cloud_run=//p' "$STATE/t-three.meta")
out=$(env_run bash "$ROOT/bin/fm-teardown.sh" t-three 2>&1); rc=$?
assert_equals 1 "$rc" "fm-teardown refuses an unlanded cloud run"
assert_present "$STATE/t-three.meta" "fm-teardown keeps the record when it refuses"
out=$(env_run bash "$ROOT/bin/fm-teardown.sh" t-three --force 2>&1) || fail "fm-teardown --force failed: $out"
assert_absent "$STATE/t-three.meta" "fm-teardown --force retires the cloud task"
assert_absent "$STATE/t-three.check.sh" "fm-teardown --force retires the check"
assert_absent "$STATE/cloud-runs/$run3.run" "fm-teardown --force retires the run record"
pass "fm-teardown delegates cloud tasks"

# --- cleanup ------------------------------------------------------------------

out=$(cloud cleanup "$run2" 2>&1); rc=$?
assert_equals 1 "$rc" "cleanup refuses a run bound to a live task"
assert_contains "$out" "teardown t-two" "the refusal points at teardown"
rm -f "$STATE/t-two.meta"  # the task record is gone; the run is now an orphan
out=$(cloud cleanup "$run2" 2>&1) || fail "cleanup of an orphan failed: $out"
assert_absent "$STATE/t-two.check.sh" "cleanup retires an orphan run's check"
assert_absent "$STATE/t-two.check-trust" "cleanup retires an orphan run's check trust"
assert_absent "$rec2" "cleanup retires the orphan run record"
pass "cleanup retires the check for an orphan run"

# --- backlog gate -------------------------------------------------------------

if command -v tasks-axi >/dev/null 2>&1; then
  GATE_HOME="$TMP_ROOT/gate-home"
  mkdir -p "$GATE_HOME/state" "$GATE_HOME/data" "$GATE_HOME/config"
  touch "$GATE_HOME/state/.last-watcher-beat"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$GATE_HOME/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$GATE_HOME/data/backlog.md"
  mkdir -p "$GATE_HOME/data/g-one"
  cp "$DATA/t-one/brief.md" "$GATE_HOME/data/g-one/brief.md"
  gate_cloud() {
    PATH="$FAKEBIN:$PATH" FM_HOME="$GATE_HOME" FM_STATE_OVERRIDE="$GATE_HOME/state" \
      FM_DATA_OVERRIDE="$GATE_HOME/data" FM_CONFIG_OVERRIDE="$GATE_HOME/config" \
      bash "$ROOT/bin/fm-cloud.sh" "$@"
  }
  before=$(find "$GATE_HOME/state/cloud-runs" -name '*.run' 2>/dev/null | wc -l | tr -d ' ')
  out=$(gate_cloud launch --task g-one --repo "$REPO" 2>&1); rc=$?
  assert_equals 1 "$rc" "launch --task refuses a task with no backlog item"
  assert_contains "$out" "no backlog item" "the missing item is named"
  assert_equals "$before" "$(find "$GATE_HOME/state/cloud-runs" -name '*.run' 2>/dev/null | wc -l | tr -d ' ')" "nothing was launched without an item"
  assert_absent "$GATE_HOME/state/g-one.meta" "no record is written without an item"
  (cd "$GATE_HOME" && tasks-axi add g-one "cloud item" --kind ship --file data/backlog.md >/dev/null) \
    || fail "could not seed the backlog item"
  out=$(gate_cloud launch --task g-one --repo "$REPO" 2>&1) || fail "launch --task with a backlog item failed: $out"
  assert_grep "g-one" "$GATE_HOME/data/backlog.md" "the item is still in the backlog"
  state_line=$(tasks-axi show g-one --file "$GATE_HOME/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)
  assert_equals "in_flight" "$state_line" "launch --task moves the item to In flight"
  pass "launch --task moves the backlog item to In flight and refuses without one"
else
  printf 'ok - skipped the backlog gate cases (tasks-axi is not installed)\n'
fi

# --- credit -------------------------------------------------------------------

out=$(cloud credit) || fail "credit failed"
assert_contains "$out" "credit: not configured" "credit reports an unconfigured home"
printf 'amount=249\nexpires=%s\n' "$(date -u -v+10d +%Y-%m-%d 2>/dev/null || date -u -d '+10 days' +%Y-%m-%d)" > "$CONFIG/cloud-credit"
out=$(cloud credit) || fail "credit failed"
assert_contains "$out" '$249 expires' "credit reports the amount"
assert_contains "$out" "day(s) remaining" "credit reports the days remaining"
launched=$(wc -l < "$STATE/cloud-runs/.launched" | tr -d ' ')
assert_contains "$out" "runs launched: $launched" "credit counts the runs launched"
assert_contains "$(cloud doctor)" "credit: " "doctor includes the credit line"
printf 'amount=249\nexpires=2020-01-01\n' > "$CONFIG/cloud-credit"
assert_contains "$(cloud credit)" "expired 2020-01-01" "credit reports an expired credit"
printf 'amount=249\nexpires=soon\n' > "$CONFIG/cloud-credit"
assert_contains "$(cloud credit)" "is not a YYYY-MM-DD date" "credit reports a malformed expiry"
rm -f "$CONFIG/cloud-credit"
pass "credit reports days remaining and runs launched"

# --- crew-state and reap carve-outs --------------------------------------------

write_brief t-four
cloud launch --task t-four --repo "$REPO" >/dev/null 2>&1 || fail "launch t-four failed"
out=$(env_run bash "$ROOT/bin/fm-crew-state.sh" t-four 2>&1) || fail "crew-state failed: $out"
assert_contains "$out" "state: working" "crew-state shows a cloud run working"
assert_contains "$out" "https://claude.ai/code/session_task123" "crew-state shows the session url"
pass "crew-state reads a window-less cloud task"

out=$(env_run bash "$ROOT/bin/fm-reap.sh" scan 2>&1) || fail "reap scan failed: $out"
assert_contains "$out" "t-four" "reap lists the cloud task"
assert_not_contains "$out" "DEAD-UNLANDED" "a cloud run with no pane is not dead"
pass "reap does not treat a cloud run as dead"

# --- dod gate ------------------------------------------------------------------

dod_probe() {  # <meta-file> -> exit code of the done-note acceptance gate
  bash -c '
    . "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-dod-lib.sh"
    fm_dod_accept_ship_done ship direct-PR "" "" "done [at=1]: PR https://github.com/acme/widgets/pull/77" "$2" t-four "$3" >/dev/null 2>&1
  ' _ "$ROOT" "$STATE" "$1"
}
dod_probe "$STATE/t-four.meta"; rc=$?
assert_equals 0 "$rc" "the done gate accepts a cloud run, which has no worktree to verify"
grep -vx 'backend=cloud' "$STATE/t-four.meta" > "$TMP_ROOT/plain.meta"
dod_probe "$TMP_ROOT/plain.meta"; rc=$?
assert_equals 1 "$rc" "the done gate still verifies a head for a worktree-backed task"
pass "the done gate skips head verification for cloud runs only"

cloud teardown t-four --force >/dev/null 2>&1 || fail "cleanup of t-four failed"
assert_absent "$STATE/t-four.meta" "the cloud task tears down cleanly"
