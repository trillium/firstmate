#!/usr/bin/env bash
# tests/fm-cloud.test.sh - bin/fm-cloud.sh driven through its CLI with a stub
# claude and a real local git remote; the stub never reaches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export GIT_AUTHOR_NAME=fm-test GIT_AUTHOR_EMAIL=fm-test@example.invalid GIT_COMMITTER_NAME=fm-test GIT_COMMITTER_EMAIL=fm-test@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-cloud)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"

REMOTE="$TMP_ROOT/remote.git"
REPO="$TMP_ROOT/repo"
git init -q --bare "$REMOTE"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin HEAD:refs/heads/main
git -C "$REPO" push -q origin HEAD:refs/heads/claude/old-run

export FM_CLAUDE_JSON="$TMP_ROOT/claude.json"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$(cd "$REPO" && pwd -P)" > "$FM_CLAUDE_JSON"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "9.9.9 (Claude Code)"; exit 0 ;;
  --help) printf '  --cloud [d]\n  --environment <id>\n  --teleport [s]\n'; exit 0 ;;
esac
printf '%s\n' "$*" > "$FM_STUB_ARGS"
[ -t 1 ] || { echo "--cloud requires an interactive terminal (piped stdout would silently ignore --cloud)" >&2; exit 1; }
[ -z "${FM_STUB_FAIL:-}" ] || { echo "boom" >&2; exit 3; }
printf '\033[1mCreated cloud session\033[0m\n'
echo "Branch main is 2 commits ahead of origin/main, so the cloud session starts without them"
echo "View: https://claude.ai/code/session_abc123XYZ"
echo "Resume with: claude --teleport session_abc123XYZ"
SH
chmod +x "$FAKEBIN/claude"
export FM_STUB_ARGS="$TMP_ROOT/args"

# A gate remote listed first must never be chosen; origin is the fallback.
GREPO="$TMP_ROOT/gaterepo"
git init -q "$GREPO"; git -C "$GREPO" commit -q --allow-empty -m init
git init -q --bare "$TMP_ROOT/gate.git"
git -C "$GREPO" remote add no-mistakes "$TMP_ROOT/gate.git"
git -C "$GREPO" remote add origin "$REMOTE"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true}}}\n' "$(cd "$REPO" && pwd -P)" "$(cd "$GREPO" && pwd -P)" > "$FM_CLAUDE_JSON"

cloud() { PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$STATE_DIR" bash "$ROOT/bin/fm-cloud.sh" "$@"; }

out=$(cloud launch --repo "$REPO" --environment ccpool_env1 "do the thing tskey-SUPERSECRET" 2>&1) || fail "launch failed: $out"
assert_contains "$out" "session: session_abc123XYZ" "launch prints the parsed session id"
assert_contains "$out" "warning: Branch main is 2 commits ahead" "claude's branch-ahead warning is surfaced"
assert_contains "$out" "url: https://claude.ai/code/session_abc123XYZ" "launch prints the url"
assert_contains "$(cat "$FM_STUB_ARGS")" "--cloud do the thing" "claude gets --cloud and the prompt"
assert_contains "$(cat "$FM_STUB_ARGS")" "--environment ccpool_env1" "claude gets --environment"
rec=$(ls "$STATE_DIR"/cloud-runs/*.run)
assert_grep "session=session_abc123XYZ" "$rec" "record holds the session"
assert_grep "environment=ccpool_env1" "$rec" "record holds the environment id"
assert_no_grep "SUPERSECRET" "$rec" "record never stores the prompt text"
assert_not_contains "$out" "SUPERSECRET" "launch never echoes the prompt"
pass "launch records a run without the prompt"

id=$(basename "$rec" .run)
out=$(cloud status "$id") || fail "status failed"
assert_contains "$out" "branch: none yet" "pre-existing claude/* branches are not reported"
git -C "$REPO" push -q origin HEAD:refs/heads/claude/new-run
out=$(cloud status "$id") || fail "status failed"
assert_contains "$out" "branch: claude/new-run" "a new result branch is reported"
assert_not_contains "$out" "claude/old-run" "the baseline branch stays quiet"
pass "status polls the remote for new claude/* branches"

assert_contains "$(cloud list)" "$id" "list shows the run"
pass "list shows recorded runs"

printf 'file prompt\n' > "$TMP_ROOT/p.txt"
cloud launch --repo "$REPO" --file "$TMP_ROOT/p.txt" >/dev/null || fail "launch --file failed"
assert_contains "$(cat "$FM_STUB_ARGS")" "--cloud file prompt" "--file supplies the prompt"
pass "launch --file"

out=$(cloud launch --repo "$GREPO" "gate remote case" 2>&1) || fail "launch (gate remote) failed: $out"
assert_contains "$out" "claude/* branch on origin" "no upstream: origin is polled, not the gate remote"
git -C "$GREPO" remote add fork "$REMOTE"
git -C "$GREPO" config branch."$(git -C "$GREPO" rev-parse --abbrev-ref HEAD)".remote fork
out=$(cloud launch --repo "$GREPO" "upstream case" 2>&1) || fail "launch (upstream) failed: $out"
assert_contains "$out" "claude/* branch on fork" "the branch's upstream remote is polled"
git -C "$GREPO" config branch."$(git -C "$GREPO" rev-parse --abbrev-ref HEAD)".remote no-mistakes
out=$(cloud launch --repo "$GREPO" "gate upstream case" 2>&1) || fail "launch (gate upstream) failed: $out"
assert_contains "$out" "claude/* branch on origin" "a gate-remote upstream is skipped"
pass "result remote selection"

failed_before=$(find "$STATE_DIR/cloud-runs" -name '*.run' | wc -l | tr -d ' ')
FM_STUB_FAIL=1 cloud launch --repo "$REPO" "x" >/dev/null 2>&1; rc=$?
assert_equals 1 "$rc" "a failing claude fails the launch"
assert_equals "$failed_before" "$(find "$STATE_DIR/cloud-runs" -name '*.run' | wc -l | tr -d ' ')" "a failed launch records nothing"
cloud launch >/dev/null 2>&1; rc=$?
assert_equals 2 "$rc" "launch without a prompt is a usage error"
cloud bogus >/dev/null 2>&1; rc=$?
assert_equals 2 "$rc" "unknown subcommand is a usage error"
pass "launch failure and usage errors"

out=$(cloud doctor) || fail "doctor failed"
assert_contains "$out" "flag --cloud: supported" "doctor checks --cloud"
assert_contains "$out" "runbooks-e8k" "doctor points at the runbook"
pass "doctor"

out=$(cloud cleanup "$id") || fail "cleanup failed"
assert_absent "$rec" "cleanup retires the record"
assert_contains "$out" "TS_AUTHKEY" "cleanup prints the manual web steps"
assert_contains "$out" "runbooks-e8k" "cleanup points at the runbook"
cloud cleanup "$id" >/dev/null 2>&1; rc=$?
assert_equals 1 "$rc" "cleanup of a missing run fails"
cloud cleanup "../x" >/dev/null 2>&1; rc=$?
assert_equals 2 "$rc" "cleanup rejects a path-like id"
pass "cleanup"

# Untrusted --repo is refused before claude runs; the config is never written.
UREPO="$TMP_ROOT/untrusted"
git init -q "$UREPO"; git -C "$UREPO" commit -q --allow-empty -m init
git -C "$UREPO" remote add origin "$REMOTE"
rm -f "$FM_STUB_ARGS"
before_cj=$(cat "$FM_CLAUDE_JSON")
out=$(cloud launch --repo "$UREPO" "x" 2>&1); rc=$?
assert_equals 1 "$rc" "untrusted repo is refused"
assert_contains "$out" "has not trusted" "refusal says the dir is untrusted"
assert_contains "$out" "$(cd "$UREPO" && pwd -P)" "refusal names the dir"
assert_absent "$FM_STUB_ARGS" "claude never ran for an untrusted repo"
assert_equals "$before_cj" "$(cat "$FM_CLAUDE_JSON")" "trust file is not modified"
pass "untrusted repo refused"

# A hung claude (trust-dialog style wait) is stopped by the launch timeout.
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
[ -t 1 ] || exit 1
sleep 300
SH
out=$(FM_CLOUD_LAUNCH_TIMEOUT=2 cloud launch --repo "$REPO" "x" 2>&1); rc=$?
assert_equals 1 "$rc" "a hung launch exits nonzero"
assert_contains "$out" "no result within 2s" "timeout diagnostic"
pass "launch timeout"

# Credit expiry honours the real expiry moment.
mkdir -p "$TMP_ROOT/home/config"
CREDIT="$TMP_ROOT/home/config/cloud-credit"
credit_out() { printf 'amount=10\nexpires=%s\n' "$1" > "$CREDIT"; TZ="${2:-UTC}" FM_HOME="$TMP_ROOT/home" bash "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-cloud.sh" credit 2>&1; }
now=$(date +%s)

in5h=$(date -u -d "@$((now + 5 * 3600 + 600))" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$((now + 5 * 3600 + 600))" +%Y-%m-%dT%H:%M:%S)
out=$(credit_out "${in5h}Z")
assert_contains "$out" "5 hour(s) remaining" "explicit Z time reports hours"

# The same instant written with an offset is the same moment.
off_local=$(date -u -d "@$((now + 5 * 3600 + 600  + 8 * 3600))" +%Y-%m-%dT%H:%M 2>/dev/null || date -u -r "$((now + 5 * 3600 + 600  + 8 * 3600))" +%Y-%m-%dT%H:%M)
out=$(credit_out "${off_local}+08:00")
assert_contains "$out" "5 hour(s) remaining" "explicit +08:00 offset is honoured"
off_west=$(date -u -d "@$((now + 5 * 3600 + 600 - 8 * 3600))" +%Y-%m-%dT%H:%M 2>/dev/null || date -u -r "$((now + 5 * 3600 + 600 - 8 * 3600))" +%Y-%m-%dT%H:%M)
out=$(credit_out "${off_west}-08:00")
assert_contains "$out" "5 hour(s) remaining" "explicit -08:00 offset is honoured"

in20m=$(date -u -d "@$((now + 20 * 60))" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$((now + 20 * 60))" +%Y-%m-%dT%H:%M:%S)
out=$(credit_out "${in20m}Z")
assert_contains "$out" "minute(s) remaining" "under an hour reports minutes"

in3d=$(date -u -d "@$((now + 3 * 86400 - 600))" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$((now + 3 * 86400 - 600))" +%Y-%m-%dT%H:%M:%S)
out=$(credit_out "${in3d}Z")
assert_contains "$out" "3 day(s) remaining" "over a day reports days"

# Date-only means the end of that day in local time: today's local date is still live
# in a zone far behind UTC, where UTC end-of-day reading would have been wrong.
for tz in Etc/GMT+8 Etc/GMT-10; do
  today=$(TZ=$tz date +%Y-%m-%d)
  out=$(credit_out "$today" "$tz")
  assert_contains "$out" "remaining" "date-only today is unexpired in $tz"
  case "$out" in *"day(s)"*) fail "date-only today under a day in $tz: $out" ;; esac
done
yesterday=$(TZ=Etc/GMT+8 date -d 'yesterday' +%Y-%m-%d 2>/dev/null || TZ=Etc/GMT+8 date -v-1d +%Y-%m-%d)
out=$(credit_out "$yesterday" Etc/GMT+8)
assert_contains "$out" "expired $yesterday" "past date-only is expired"

out=$(credit_out "2020-01-01T00:00Z")
assert_contains "$out" "expired 2020-01-01T00:00Z" "past explicit time is expired"
out=$(credit_out "soon")
assert_contains "$out" "not a YYYY-MM-DD" "malformed value reported"
pass "credit expiry"
