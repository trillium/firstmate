#!/usr/bin/env bash
# tests/fm-cloud-channel.test.sh - the cloud worker <-> firstmate channel:
# status lines read from the worker's branch by `fm-cloud.sh check`, steering by
# `fm-cloud.sh continue` and the fm-send route to it, and the credit report.
# claude and gh-axi are stubs and the remote is a local bare repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cloud-channel)
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
WORK="$TMP_ROOT/work"
git init -q --bare "$REMOTE"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin HEAD:refs/heads/main
git clone -q "$REMOTE" "$WORK" 2>/dev/null

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
[ -t 1 ] || { echo "--cloud requires an interactive terminal" >&2; exit 1; }
n=$(( $(find "$(dirname "$FM_STUB_ARGS")" -maxdepth 1 -name 'args.*' | wc -l | tr -d ' ') + 1 ))
printf '%s\n' "$*" > "$FM_STUB_ARGS.$n"
echo "View: https://claude.ai/code/session_chan$n"
SH
printf '#!/usr/bin/env bash\necho "prs[0]:"\n' > "$FAKEBIN/gh-axi"
chmod +x "$FAKEBIN/claude" "$FAKEBIN/gh-axi"
export FM_STUB_ARGS="$TMP_ROOT/args"

env_run() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" "$@"
}
cloud() { env_run bash "$ROOT/bin/fm-cloud.sh" "$@"; }

# Push the worker's status file (or its removal) to claude/ch-one.
push_status() {  # <content>|--remove
  (
    cd "$WORK" || exit 1
    git fetch -q origin 2>/dev/null
    git checkout -q -B claude/ch-one "origin/claude/ch-one" 2>/dev/null || git checkout -q -B claude/ch-one origin/main
    if [ "$1" = --remove ]; then
      git rm -q .fm-cloud/status
    else
      mkdir -p .fm-cloud
      printf '%s\n' "$1" > .fm-cloud/status
      git add -f .fm-cloud/status
    fi
    git -c user.name=t -c user.email=t@example.invalid commit -q -m "status"
    git push -q origin claude/ch-one
  ) || fail "could not push the worker status"
}

mkdir -p "$DATA/ch-one"
cat > "$DATA/ch-one/brief.md" <<'EOF2'
# Task
## Captain's intent
Do the channel thing.
EOF2

# --- the trailer ----------------------------------------------------------------

cloud launch --task ch-one --repo "$REPO" >/dev/null 2>&1 || fail "launch failed"
args=$(cat "$FM_STUB_ARGS.1")
assert_contains "$args" ".fm-cloud/status" "the trailer names the status file"
assert_contains "$args" "needs-decision" "the trailer names the local status grammar"
assert_contains "$args" "git rm .fm-cloud/status" "the trailer has the worker remove the file last"
assert_not_contains "$args" "TOKEN" "the trailer carries no secrets"
pass "the cloud trailer defines the status channel"

# --- check reads the status file --------------------------------------------------

assert_equals "" "$(env_run "$STATE/ch-one.check.sh")" "no branch means no status lines"
L1="working [at=1700000001]: setup done"
L2="needs-decision [at=1700000002] [key=db]: use sqlite or postgres?"
JUNK="chatter: not a status verb
rm -rf / pretend line"
push_status "$L1
$L2
$JUNK"
out=$(env_run "$STATE/ch-one.check.sh")
assert_contains "$out" "cloud run ch-one: $L1" "a milestone line wakes firstmate"
assert_contains "$out" "cloud run ch-one: $L2" "a question wakes firstmate with its exact text"
assert_not_contains "$out" "chatter" "a line with an unknown verb is ignored"
assert_not_contains "$out" "pretend" "a non-status line is ignored"
assert_grep "needs-decision [at=1700000002] [key=db]: use sqlite or postgres?" "$STATE/ch-one.status" "the question is appended to the task status log"
assert_equals 1 "$(grep -c 'key=db' "$STATE/ch-one.status")" "the question is logged once"
second=$(env_run "$STATE/ch-one.check.sh")
assert_not_contains "$second" "setup done" "a line is emitted once"
assert_not_contains "$second" "sqlite" "a question is emitted once"
pass "check emits each new status line once and logs it"

L3="done [at=1700000500]: PR https://github.com/acme/widgets/pull/9"
push_status "$L1
$L2
$JUNK
$L3"
out=$(env_run "$STATE/ch-one.check.sh")
assert_contains "$out" "cloud run ch-one: $L3" "only the new done line is emitted"
assert_not_contains "$out" "setup done" "earlier lines are not repeated"
push_status --remove
out=$(env_run "$STATE/ch-one.check.sh")
assert_not_contains "$out" "done [at" "removing the file in the last commit re-emits nothing"
assert_contains "$(git -C "$WORK" ls-tree -r --name-only HEAD)" "" "the worker branch tip no longer carries the file"
if git -C "$WORK" ls-tree -r --name-only HEAD | grep -q '^.fm-cloud/status$'; then fail "the status file must be gone from the branch tip"; fi
pass "the status file is read from history after its removal"

# --- continue and the fm-send route -----------------------------------------------

before_lines=$(find "$TMP_ROOT" -maxdepth 1 -name 'args.*' | wc -l | tr -d ' ')
old_run=$(sed -n 's/^cloud_run=//p' "$STATE/ch-one.meta")
out=$(cloud continue ch-one "use sqlite" 2>&1) || fail "continue failed: $out"
assert_equals $((before_lines + 1)) "$(find "$TMP_ROOT" -maxdepth 1 -name 'args.*' | wc -l | tr -d ' ')" "continue launched exactly one follow-up run"
last=$(cat "$FM_STUB_ARGS.$((before_lines + 1))")
assert_contains "$last" "use sqlite" "the follow-up carries the steer"
assert_contains "$last" "Do the channel thing" "the follow-up carries the brief"
assert_contains "$last" "claude/ch-one" "the follow-up targets the same branch"
assert_contains "$last" "needs-decision [at=1700000002] [key=db]" "the follow-up carries the prior status lines"
new_run=$(sed -n 's/^cloud_run=//p' "$STATE/ch-one.meta")
[ "$new_run" != "$old_run" ] || fail "the task is not bound to the new run"
assert_grep "continues=$old_run" "$STATE/cloud-runs/$new_run.run" "the new run records what it continues"
assert_grep "task=ch-one" "$STATE/cloud-runs/$new_run.run" "the new run is recorded against the same task"
assert_absent "$STATE/cloud-runs/$old_run.run" "the old run record is retired"
assert_grep "cloud_url=https://claude.ai/code/session_chan" "$STATE/ch-one.meta" "meta points at the new session"
assert_grep "steer delivered" "$STATE/ch-one.status" "the status log notes the steer"
assert_equals 2 "$(wc -l < "$STATE/cloud-runs/.launched" | tr -d ' ')" "the launch ledger counts the follow-up"
out=$(cloud continue ch-one 2>&1); rc=$?
assert_equals 2 "$rc" "continue without text is a usage error"
out=$(cloud continue nope "x" 2>&1); rc=$?
assert_equals 1 "$rc" "continue refuses an unknown task"
pass "continue relaunches on the same branch and rebinds the task"

out=$(env_run bash "$ROOT/bin/fm-send.sh" ch-one "answer: postgres" 2>&1) || fail "fm-send to a cloud task failed: $out"
assert_contains "$(cat "$FM_STUB_ARGS.$((before_lines + 2))")" "answer: postgres" "fm-send routes a cloud task to continue"
out=$(env_run bash "$ROOT/bin/fm-send.sh" ch-one --key Enter 2>&1); rc=$?
assert_equals 1 "$rc" "fm-send --key has no cloud endpoint"
assert_contains "$out" "text only" "the refusal says why"
out=$(env_run bash "$ROOT/bin/fm-send.sh" ch-one --resolve-key db "go with postgres" 2>&1) || fail "fm-send --resolve-key failed: $out"
assert_grep "] [key=db]: answered by a steer" "$STATE/ch-one.status" "--resolve-key closes the decision"
pass "fm-send routes backend=cloud to continue"

# --- credit report ------------------------------------------------------------------

printf 'amount=100\nexpires=2099-01-01\n' > "$CONFIG/cloud-credit"
out=$(cloud credit 2>&1) || fail "credit failed: $out"
assert_contains "$out" "runs per task:" "credit lists runs per task"
assert_contains "$out" "ch-one: 4" "credit counts the task's runs including follow-ups"
assert_contains "$out" "runs per day (UTC):" "credit lists runs per day"
assert_contains "$out" "$(date -u +%F): 4" "credit counts today's runs"
assert_contains "$out" "wall time per run" "credit reports wall time"
assert_contains "$out" "no activity seen" "a run with no activity is said so"
assert_contains "$out" "no CLI" "credit says the balance has no CLI"
assert_contains "$out" "claude.ai" "credit says where the balance is read"
# A run with known activity: launch, then a status line 90 seconds later.
printf 'cloud-fixed-1 1700000000 wall-task\ncloud-fixed-2 1700086400 wall-task\n' >> "$STATE/cloud-runs/.launched"
printf 'cloud-fixed-1 1700000090\n' >> "$STATE/cloud-runs/.activity"
out=$(cloud credit 2>&1)
assert_contains "$out" "cloud-fixed-1 task=wall-task: 1m30s" "wall time is launch to last activity"
assert_contains "$out" "2023-11-14: 1" "a past day is counted"
assert_contains "$out" "2023-11-15: 1" "the next day is counted separately"
pass "credit reports runs per task and day and wall time per run"
