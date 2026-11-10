#!/usr/bin/env bash
# tests/fm-remote-secondmate-relaunch.test.sh - regression coverage for
# bin/fm-remote-secondmate-relaunch.sh: the parent-side tool an operator runs
# to move a remote secondmate onto a new harness, model, or effort.
#
# Reproduces the observed defect: running
# bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness>
# <model> <effort> relaunches the agent on its host, but that host-local verb
# can only rewrite its own endpoint record. The parent's own state/<id>.meta
# kept naming the runtime the mate used to run. The wrapper drives the same
# host-local relaunch and then republishes this home's own record from the
# identity the host confirmed.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it, rather than exercising a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-relaunch)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/ios.meta" \
    "window=remote:ios" \
    "endpoint_task_id=ios" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=pi" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=openai-codex/gpt-5.6-sol" \
    "effort=medium" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..5]);
' "$argv_b64")
IFS=$'\t' read -r cmd action id harness model effort <<EOF
$command_fields
EOF
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
if [ "$action" = tab-rename ]; then
  # the label is the 4th argv element (id is the 3rd); log it byte-for-byte
  printf 'tab-rename id=%s label=[%s]\n' "$id" "$harness" >> "$FM_FAKE_RENAME_LOG"
  exit 0
fi
if [ "$action" = tab-pin ]; then
  printf 'tab-pin id=%s\n' "$id" >> "$FM_FAKE_RENAME_LOG"
  exit 0
fi
[ "$action" = relaunch ] || exit 94
case "$FM_FAKE_RELAUNCH_MODE" in
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
esac
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
# The account pin the host's launch resolved: FM_FAKE_ACCOUNT is the value
# (empty for an unpinned mate), and report-none models a host too old to
# report an account key at all.
if [ "${FM_FAKE_ACCOUNT_MODE:-}" != report-none ]; then
  printf 'account=%s\n' "${FM_FAKE_ACCOUNT:-}"
  [ -z "${FM_FAKE_ACCOUNT_PROVIDER:-}" ] || printf 'account_provider=%s\n' "$FM_FAKE_ACCOUNT_PROVIDER"
fi
SH
chmod +x "$FAKEBIN/fake-ssh"

run_relaunch() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" FM_FAKE_RENAME_LOG="$TMP/rename.log" \
    FM_FAKE_ACCOUNT="${FM_FAKE_ACCOUNT:-}" FM_FAKE_ACCOUNT_PROVIDER="${FM_FAKE_ACCOUNT_PROVIDER:-}" \
    FM_FAKE_ACCOUNT_MODE="${FM_FAKE_ACCOUNT_MODE:-}" \
    "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@" 2>&1
}

# --- a successful relaunch republishes the parent's own route record --------
reset_meta
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_contains "$OUT" "relaunched ios harness=claude" \
  "the wrapper should still print the host's own confirmation line"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed model"
assert_grep 'effort=medium' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed effort"
assert_no_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the stale runtime should not still be recorded"
assert_no_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the stale model should not still be recorded"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive the update"
assert_grep 'window=remote:ios' "$HOME_DIR/state/ios.meta" \
  "unrelated identity fields must survive the update"
pass "a successful remote relaunch republishes the parent's harness, model, and effort"

# --- the parent records what the host confirmed, not what it was asked ------
reset_meta
FM_FAKE_RELAUNCH_MODE=confirm-other
OUT=$(run_relaunch ios default default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 0 "$RC" "a relaunch whose host resolves a different identity should succeed"$'\n'"$OUT"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed model"
assert_no_grep 'harness=default' "$HOME_DIR/state/ios.meta" \
  "the parent record must not keep the unresolved request"
pass "a remote relaunch records the identity the host confirmed"

# --- the account the host confirmed is printed and recorded -----------------
reset_meta
OUT=$(FM_FAKE_ACCOUNT=token:work run_relaunch ios claude default default); RC=$?
expect_code 0 "$RC" "a relaunch onto a pinned host should succeed"$'\n'"$OUT"
assert_contains "$OUT" "account=token:work" \
  "the relaunch output should print the account the host confirmed"
assert_grep 'account=token:work' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed account"
OUT=$(FM_FAKE_ACCOUNT=token:other FM_FAKE_ACCOUNT_PROVIDER=openai run_relaunch ios claude default default); RC=$?
expect_code 0 "$RC" "a repin relaunch should succeed"$'\n'"$OUT"
assert_contains "$OUT" "account=token:other" "the repin should show in the relaunch output"
assert_grep 'account=token:other' "$HOME_DIR/state/ios.meta" "the repin was not recorded"
assert_grep 'account_provider=openai' "$HOME_DIR/state/ios.meta" "the confirmed account provider was not recorded"
[ "$(grep -c '^account=' "$HOME_DIR/state/ios.meta")" = 1 ] \
  || fail "a repin must leave exactly one account= line"
assert_no_grep 'account=token:work' "$HOME_DIR/state/ios.meta" "the previous pin should not survive a repin"
OUT=$(run_relaunch ios claude default default); RC=$?
expect_code 0 "$RC" "a relaunch onto an unpinned host should succeed"$'\n'"$OUT"
assert_no_regex '^account' "$HOME_DIR/state/ios.meta" \
  "a host that confirms no pin must clear the recorded account and provider"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive an account update"
pass "a remote relaunch prints and records the account the host confirmed, including a repin and an unpin"

# --- a host that reports no account key leaves the recorded account alone ----
reset_meta
printf 'account=token:recorded\n' >> "$HOME_DIR/state/ios.meta"
OUT=$(FM_FAKE_ACCOUNT_MODE=report-none run_relaunch ios claude default default); RC=$?
expect_code 0 "$RC" "a relaunch onto a host that reports no account should still succeed"$'\n'"$OUT"
assert_contains "$OUT" "did not report an account pin" "the unconfirmed account should be called out"
assert_grep 'account=token:recorded' "$HOME_DIR/state/ios.meta" \
  "an unreported account must not be rewritten as confirmed or cleared"
pass "a host that reports no account leaves the recorded account untouched and says so"

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
pass "a refused remote relaunch leaves the parent's record untouched"

# --- a local (non-remote) secondmate is refused, not silently mishandled ----
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" \
  "worktree=/srv/local1" "project=/srv/local1" "harness=codex" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_relaunch local1 claude - -); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate must not be accepted by the remote relaunch tool"
assert_contains "$OUT" "not a remotely placed secondmate" \
  "the refusal should explain the tool this task needs instead"
pass "a local secondmate is refused by the remote relaunch tool"

# --- a relaunch keeps an already-armed PR poll authenticating ---------------
# fm-pr-check.sh now refuses to arm a poll on a kind=secondmate record, but a
# record armed before that refusal can still carry the block until the
# watcher retires it. fm-pr-check.sh wrote pr= (and, when a forge head was
# readable, pr_head=) as the LAST lines of the record, and
# fm_pr_metadata_identity_parse treats any other key appearing after pr= as
# invalid, so this wrapper must not append its harness=/model=/effort= lines
# after that identity block. The fixture is seeded the way such a record was
# really written: pr= appended last to the meta, then the poll artifacts
# published through the same fm_pr_poll_prepare/fm_pr_poll_publish_prepared
# pair fm-pr-check.sh uses, since the refused entry point cannot arm it.
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/ios.meta" \
  || fail "could not write the pr= identity for the relaunch-ordering test"
fm_pr_poll_prepare "$HOME_DIR/state" ios github \
  https://github.com/example/repo/pull/1 github.com example/repo 1 \
  "$ROOT/bin/fm-pr-poll.sh" \
  || fail "could not prepare the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_publish_prepared \
  || fail "could not publish the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "PR poll fixture did not authenticate before the relaunch"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed with an armed PR poll"$'\n'"$OUT"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "a remote relaunch broke PR poll authentication by writing harness/model/effort after pr="
pass "a remote relaunch keeps an already-armed PR poll authenticating"

# --- a configured tab label is applied to the confirmed remote tab ---------
reset_meta
: > "$TMP/rename.log"
printf '# comment\nios 💎2️⃣ iOS  delivery\n' > "$HOME_DIR/config/tab-labels"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a relaunch with a tab label should succeed"$'\n'"$OUT"
assert_grep 'tab-rename id=ios label=[💎2️⃣ iOS  delivery]' "$TMP/rename.log" \
  "the remote tab was not renamed to the emoji/space label, delivered as one argv element"
assert_grep 'tab-pin id=ios' "$TMP/rename.log" "the labeled remote tab was not pinned first"
[ "$(grep -c '^tab-rename' "$TMP/rename.log")" = 1 ] || fail "exactly one rename should be issued"
pass "a configured tab label is applied to the remote tab over SSH"

# --- no label for the id -> no rename; a refused relaunch -> no rename ------
reset_meta
: > "$TMP/rename.log"
printf 'other-id Some Label\n' > "$HOME_DIR/config/tab-labels"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a relaunch without a label should succeed"$'\n'"$OUT"
[ ! -s "$TMP/rename.log" ] || fail "no rename should be issued for an unlisted id"
rm -f "$HOME_DIR/config/tab-labels"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a relaunch with no tab-labels file should succeed"$'\n'"$OUT"
[ ! -s "$TMP/rename.log" ] || fail "no rename should be issued without a tab-labels file"
printf 'ios Label\n' > "$HOME_DIR/config/tab-labels"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "refused relaunch must fail"
[ ! -s "$TMP/rename.log" ] || fail "a refused relaunch must not rename the tab"
pass "no label (or a refused relaunch) issues no rename"

echo "ALL TESTS PASSED"
