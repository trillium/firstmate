#!/usr/bin/env bash
# Behavior tests for the rot report: the quiet-failure sweep over a firstmate
# home. Covers the never-cry-wolf contract (a healthy home is silent), one
# finding per severity band, the clean/not-checked distinction, the zero-network
# default and its --include-network opt-in, the JSON and TOON renderings, the
# exit-0-with-findings contract, and the read-only guarantee that makes the
# command safe in a session that could not take the home's lock.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROT="$ROOT/bin/fm-rot-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-rot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# One clock pinned for the whole run so ages stay stable across the several
# invocations in a single test. It has to be real "now": a fixture written
# during the run is the freshness case, and a clock in the future would age it
# past every threshold and make the never-cry-wolf assertions vacuous. Fixtures
# that must read as OLD are backdated to a fixed date safely in the past.
NOW=$(date -u +%s)
OLD_STAMP=202401010000

# A fakebin covering every tool the canonical snapshot and this report may reach
# for. gh RECORDS each call to $NET_LOG so a test can prove the default path
# makes no network call at all, and answers with one untracked fleet PR plus one
# unrelated human PR so the fm/-branch restriction is observable.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # A dead endpoint is any window whose name carries "dead-".
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  # treehouse is stubbed absent-ish so the pool sweep reports "not checked"
  # instead of walking the developer's real worktree pool from a test.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
case "$*" in
  *"pr list"*"--state merged"*)
    printf '[{"headRefName":"fm/landed-squash"}]\n'
    ;;
  *"pr list"*)
    cat <<'JSON'
[{"number":11,"url":"https://github.com/acme/repo/pull/11","title":"Fleet work","isDraft":false,"createdAt":"2027-01-05T00:00:00Z","updatedAt":"2027-01-05T00:00:00Z","headRefName":"fm/untracked-task","headRefOid":"aaaaaaaaaaaa1111","reviewDecision":"","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"mergeable":"MERGEABLE"},
 {"number":12,"url":"https://github.com/acme/repo/pull/12","title":"Someone else","isDraft":false,"createdAt":"2027-01-05T00:00:00Z","updatedAt":"2027-01-05T00:00:00Z","headRefName":"feature/human-branch","headRefOid":"bbbbbbbbbbbb2222","reviewDecision":"","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"mergeable":"MERGEABLE"}]
JSON
    ;;
  *"run list"*) printf '[]\n' ;;
  *) printf '[]\n' ;;
esac
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
exit 0
SH
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/treehouse" "$fb/gh" "$fb/gh-axi" "$fb/curl"
  printf '%s\n' "$fb"
}

# A healthy home: one live worker, a registered project with a matching clone,
# no stray markers, and a committed working tree.
make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/alpha"
  fm_git_init_commit "$home/projects/alpha"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - Ship the thing (repo: alpha) (kind: ship) (since 2027-01-01)

## Queued

## Done
EOF
  printf -- '- alpha - delivery: no-mistakes\n' > "$home/data/projects.md"
  fm_write_meta "$home/state/live-task.meta" \
    "window=firstmate:fm-live-task" \
    "endpoint_task_id=live-task" \
    "worktree=$home/projects/alpha" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: building the thing\n' > "$home/state/live-task.status"
  # Mirror the real home's gitignore so runtime records never dirty the
  # checkout, then commit, so a clean home really is clean.
  printf 'state/\ndata/\nconfig/\nprojects/\nnet.log\n' > "$home/.gitignore"
  printf '# fixture home\n' > "$home/AGENTS.md"
  git -C "$home" init -q
  git -C "$home" add -A
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
  printf '%s\n' "$home"
}

# Run the report against <home>. FM_ROOT_OVERRIDE keeps the pool sweep and every
# home-relative path inside the fixture, and FM_BEADS_BIN names a CLI that does
# not exist so the bead ledger reports "not checked" instead of reaching the
# developer's real store.
run() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2; shift 2
  PATH="$fb:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_ROT_NOW="$NOW" \
  FM_BEADS_BIN=fm-no-such-bead-cli \
  NET_LOG="$home/net.log" \
    "$ROT" "$@"
}

# A stable fingerprint of every path under <dir>, plus each file's size and
# content hash, so a test can prove a run changed nothing at all.
fingerprint() {  # <dir>
  find "$1" \( -name net.log -o -name '*.out' \) -prune -o -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
    if [ -f "$p" ]; then
      printf '%s %s\n' "$p" "$(cksum < "$p")"
    else
      printf '%s dir\n' "$p"
    fi
  done
}

# --- a healthy home says nothing ---------------------------------------------

HOME_OK=$(make_home healthy)
FB=$(make_fakebin "$TMP_ROOT")
out=$(run "$HOME_OK" "$FB" 2>&1); rc=$?
expect_code 0 "$rc" 'a healthy home exits 0'
assert_contains "$out" 'nothing rotting' 'a healthy home reports nothing rotting'
for marker in '[home-uncommitted]' '[orphan-worktree]' '[staleness-unfiled]' \
              '[dead-endpoint]' '[secondmate-home-missing]' '[project-registry-drift]' \
              '[unarmed-check]' '[quarantined-check]' '[stale-open-decisions]'; do
  assert_not_contains "$out" "$marker" "a healthy home does not emit $marker"
done
pass 'a healthy home is silent'

# An idle-but-present worker, an empty queue and a clean clone are all healthy,
# and the report must still distinguish "checked and clean" from "not checked".
assert_contains "$out" 'not checked' 'the report names what it did not check'
assert_contains "$out" 'Every check not listed above ran and found nothing.' \
  'a finding-free check is distinguishable from a skipped one'
assert_contains "$out" 'network check, rerun with --include-network' \
  'the network checks are disclosed as skipped, not as clean'
pass 'clean and not-checked are distinguishable'

# --- the default path touches no remote --------------------------------------

if [ -s "$HOME_OK/net.log" ]; then
  fail "the default path made a network call:"$'\n'"$(cat "$HOME_OK/net.log")"
fi
pass 'the default path makes no network call'

# --- read-only, and therefore safe without the home lock ---------------------

# Hold the home's session lock with a pid this process does not descend from, so
# the run happens in exactly the state that forbids every mutation.
printf '999999\n' > "$HOME_OK/state/.lock"
BEFORE=$(fingerprint "$HOME_OK")
out=$(run "$HOME_OK" "$FB" 2>&1); rc=$?
AFTER=$(fingerprint "$HOME_OK")
expect_code 0 "$rc" 'the report runs with the home lock held elsewhere'
assert_contains "$out" 'nothing rotting' 'the locked-out run still produces its report'
if [ "$BEFORE" != "$AFTER" ]; then
  fail "the report changed the home:"$'\n'"$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
fi
rm -f "$HOME_OK/state/.lock"
pass 'the report mutates nothing, so it is safe without the home lock'

# --- S1: work that may be silently lost --------------------------------------

HOME_S1=$(make_home s1)
printf 'half-finished production code\n' > "$HOME_S1/uncommitted.txt"
touch -t "$OLD_STAMP" "$HOME_S1/uncommitted.txt"
cat > "$HOME_S1/state/reclaimed-task.staleness-unfiled" <<EOF
worktree: /tmp/pool/7/alpha
branch: fm/reclaimed-task
project: alpha
EOF
touch -t "$OLD_STAMP" "$HOME_S1/state/reclaimed-task.staleness-unfiled"
out=$(run "$HOME_S1" "$FB" 2>&1); rc=$?
expect_code 0 "$rc" 'a run that finds rot still exits 0'
assert_contains "$out" 'S1  work may be silently lost' 'the S1 band is rendered'
assert_contains "$out" '[home-uncommitted]' 'uncommitted work in the fleet home is reported'
assert_contains "$out" 'uncommitted path(s) in the fleet home checkout' \
  'the home finding says how much is uncommitted'
assert_contains "$out" '[staleness-unfiled]' 'an unfiled triage marker is reported'
assert_contains "$out" '/tmp/pool/7/alpha' 'the unfiled marker names the preserved worktree'
assert_contains "$out" 'fm/reclaimed-task' 'the unfiled marker names the branch'
assert_contains "$out" 'next: ' 'every finding carries a next command'
pass 'S1 findings are reported with their worktree, branch and next step'

# --- S3: records that point at nothing ---------------------------------------

HOME_S3=$(make_home s3)
# The dead record still leases an isolated copy that holds work. That lease is
# what exhausts the worktree pool, so the finding has to name the copy and say
# whether anything is in it.
S3_HELD=$TMP_ROOT/s3-pool/held
mkdir -p "$S3_HELD"
fm_git_init_commit "$S3_HELD"
printf 'work nobody will commit now\n' > "$S3_HELD/left-behind.txt"
fm_write_meta "$HOME_S3/state/gone-task.meta" \
  "window=firstmate:fm-dead-gone-task" \
  "endpoint_task_id=dead-gone-task" \
  "worktree=$S3_HELD" \
  "project=alpha" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes"
printf 'working: last thing it ever said\n' > "$HOME_S3/state/gone-task.status"
touch -t "$OLD_STAMP" "$HOME_S3/state/gone-task.status"
printf -- '- alpha - delivery: no-mistakes\n- ghost - delivery: direct-PR\n' \
  > "$HOME_S3/data/projects.md"
printf -- '- lost - fixture domain (home: %s/nowhere; scope: fixture; projects: alpha; added 2027-01-01)\n' \
  "$TMP_ROOT" > "$HOME_S3/data/secondmates.md"
out=$(run "$HOME_S3" "$FB" 2>&1); rc=$?
expect_code 0 "$rc" 'the S3 run exits 0'
assert_contains "$out" 'S3  records point at nothing' 'the S3 band is rendered'
assert_contains "$out" '[dead-endpoint] gone-task' 'a task whose worker is gone is reported'
assert_contains "$out" "still holds $S3_HELD with 1 uncommitted path(s)" \
  'the dead record names the isolated copy it still leases and what is in it'
assert_contains "$out" '[project-registry-drift] ghost' \
  'a registered project with no clone is reported'
assert_contains "$out" '[secondmate-home-missing] lost' \
  'a second mate whose home is not there is reported'
assert_not_contains "$out" '[dead-endpoint] live-task' \
  'a live worker is never reported as a dead endpoint'
pass 'S3 findings cover dead endpoints, registry drift and missing second mate homes'

# A second mate on another machine is disclosed as unchecked rather than guessed at.
printf -- '- remote-mate - other machine (home: /srv/fm; host: mini1; scope: fixture; projects: alpha; added 2027-01-01)\n' \
  >> "$HOME_S3/data/secondmates.md"
out=$(run "$HOME_S3" "$FB" 2>&1)
assert_contains "$out" 'second mates on another machine were not checked from here: remote-mate' \
  'a remote second mate is disclosed as unchecked, not reported as broken'
assert_not_contains "$out" '[secondmate-home-missing] remote-mate' \
  'a remote second mate is never called missing from the local path'
pass 'a remote second mate is reported as not checked'

# --- S1: one copy claimed by two records -------------------------------------

# Two records naming the same isolated copy is the live-data-loss shape: a
# cleanup or relaunch of the dead one operates on the live one's tree.
HOME_DUP=$(make_home dup)
fm_write_meta "$HOME_DUP/state/stale-claim.meta" \
  "window=firstmate:fm-dead-stale-claim" \
  "endpoint_task_id=dead-stale-claim" \
  "worktree=$HOME_DUP/projects/alpha" \
  "project=alpha" \
  "harness=claude" \
  "kind=scout" \
  "mode=no-mistakes"
out=$(run "$HOME_DUP" "$FB" 2>&1); rc=$?
expect_code 0 "$rc" 'the duplicate-claim run exits 0'
assert_contains "$out" "[duplicate-worktree] $HOME_DUP/projects/alpha" \
  'a copy claimed by two records is reported'
assert_contains "$out" 'live-task' 'the duplicate finding names one claimant'
assert_contains "$out" 'stale-claim' 'the duplicate finding names the other claimant'
assert_contains "$out" 'still worked in by live-task' \
  'the duplicate finding says which claimant still has a worker'
pass 'one isolated copy claimed by two task records is reported as a hazard'

# One record per copy is the ordinary case and must stay silent.
rm -f "$HOME_DUP/state/stale-claim.meta"
out=$(run "$HOME_DUP" "$FB" 2>&1)
assert_not_contains "$out" '[duplicate-worktree]' \
  'a copy with a single claimant is never reported'
pass 'a singly-claimed copy is left alone'

# --- S4: decisions that have gone quiet --------------------------------------

# The worker is gone, so nobody is going to answer the decision it parked on.
# A decision held by a LIVE worker is that worker's business, and the canonical
# snapshot already withholds it from the open-decision hint for exactly that
# reason - so this fixture uses a task whose endpoint is gone.
HOME_S4=$(make_home s4)
# The worktree lives outside the home: a directory inside it would be real
# uncommitted work and would (correctly) trip the S1 check.
S4_POOL=$TMP_ROOT/s4-pool/quiet
mkdir -p "$S4_POOL"
fm_git_init_commit "$S4_POOL"
fm_write_meta "$HOME_S4/state/quiet-task.meta" \
  "window=firstmate:fm-dead-quiet-task" \
  "endpoint_task_id=dead-quiet-task" \
  "worktree=$S4_POOL" \
  "project=alpha" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes"
printf 'needs-decision [key=schema]: which shape do we keep\n' \
  > "$HOME_S4/state/quiet-task.status"
touch -t "$OLD_STAMP" "$HOME_S4/state/quiet-task.status"
out=$(run "$HOME_S4" "$FB" 2>&1); rc=$?
expect_code 0 "$rc" 'the S4 run exits 0'
assert_contains "$out" 'S4  gone quiet' 'the S4 band is rendered'
assert_contains "$out" '[stale-open-decisions] quiet-task' 'a long-open decision is reported'
assert_contains "$out" 'schema' 'the decision finding names the decision key'
pass 'S4 reports a decision that has been open while the task said nothing'

# A decision opened moments ago is healthy and must not be reported.
printf 'needs-decision [key=fresh]: just asked\n' > "$HOME_S4/state/quiet-task.status"
out=$(run "$HOME_S4" "$FB" 2>&1)
assert_not_contains "$out" '[stale-open-decisions]' \
  'a freshly opened decision is not reported as gone quiet'
pass 'a fresh decision is left alone'

# --- S2: the network opt-in --------------------------------------------------

HOME_S2=$(make_home s2)
git -C "$HOME_S2/projects/alpha" remote add origin https://github.com/acme/repo.git
out=$(run "$HOME_S2" "$FB" --include-network 2>&1); rc=$?
expect_code 0 "$rc" 'the network run exits 0'
assert_contains "$out" 'S2  delivery is stalled' 'the S2 band is rendered'
assert_contains "$out" '[pr-untracked] https://github.com/acme/repo/pull/11' \
  'an open fleet PR that no task records is reported'
assert_contains "$out" 'fm/untracked-task' 'the untracked PR finding names its branch'
assert_not_contains "$out" 'pull/12' \
  'a PR from a branch the fleet did not create is never reported'
assert_grep 'gh pr list' "$HOME_S2/net.log" 'the network run does call the forge'
# These fixture pull requests are deliberately dated after the pinned clock, which
# is exactly what happens live when a pull request is opened while the report is
# still running. That must read as brand new, not as an unreadable age.
assert_not_contains "$out" 'age unknown' \
  'a pull request newer than the pinned clock reports an age rather than giving up on one'
pass 'S2 reports untracked fleet PRs and ignores everyone else PRs'

# A PR the fleet already records is tracked, not rot.
fm_write_meta "$HOME_S2/state/live-task.meta" \
  "window=firstmate:fm-live-task" \
  "endpoint_task_id=live-task" \
  "worktree=$HOME_S2/projects/alpha" \
  "project=alpha" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "pr=https://github.com/acme/repo/pull/11"
out=$(run "$HOME_S2" "$FB" --include-network 2>&1)
assert_not_contains "$out" '[pr-untracked]' 'a recorded PR is not reported as untracked'
pass 'a PR a task already records is left alone'

# --- S2: work that was committed and never delivered -------------------------

# Most fleet branches are landed, so the interesting assertion is not that a
# stranded branch is found - it is that a squash-merged one, which is neither an
# ancestor of the default branch nor patch-identical to it, is NOT.
HOME_BR=$(make_home br)
ALPHA=$HOME_BR/projects/alpha
git -C "$ALPHA" remote add origin https://github.com/acme/repo.git
git -C "$ALPHA" update-ref refs/remotes/origin/main HEAD
git -C "$ALPHA" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
base=$(git -C "$ALPHA" rev-parse HEAD)
grow_branch() {  # <branch> <commits>
  local b=$1 n=$2 i flat=${1//\//-}
  git -C "$ALPHA" checkout -q -B "$b" "$base"
  for i in $(seq 1 "$n"); do
    printf '%s %s\n' "$b" "$i" > "$ALPHA/$flat-$i.txt"
    git -C "$ALPHA" add -A
    git -C "$ALPHA" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm "$b $i"
  done
  [ "$(git -C "$ALPHA" rev-list --count "$base..$b")" = "$n" ] \
    || fail "fixture: $b did not grow to $n commits"
}
grow_branch fm/stranded 12
grow_branch fm/landed-squash 12
# Leave the checkout back on the base so neither branch is anybody working copy.
git -C "$ALPHA" checkout -q --detach "$base"

out=$(run "$HOME_BR" "$FB" --include-network 2>&1); rc=$?
expect_code 0 "$rc" 'the stranded-branch run exits 0'
assert_contains "$out" '[stranded-branch] fm/stranded' \
  'a branch of undelivered commits with no pull request is reported'
assert_contains "$out" '12 commit(s) across 12 file(s) not on main' \
  'the stranded finding says how much work is on it'
assert_not_contains "$out" '[stranded-branch] fm/landed-squash' \
  'a squash-merged branch is never reported as stranded'
pass 'S2 reports undelivered branches and never a squash-merged one'

# A branch somebody has checked out is a working copy, not abandoned work.
git -C "$ALPHA" checkout -q fm/stranded
out=$(run "$HOME_BR" "$FB" --include-network 2>&1)
assert_not_contains "$out" '[stranded-branch] fm/stranded' \
  'a branch that is currently checked out is never reported as stranded'
pass 'a checked-out branch is left alone'

# --- machine-readable renderings ---------------------------------------------

json=$(run "$HOME_S1" "$FB" --json 2>&1); rc=$?
expect_code 0 "$rc" 'the JSON rendering exits 0'
printf '%s' "$json" | jq -e '.schema == "fm-rot-report.v1"' >/dev/null \
  || fail "the JSON rendering is not the declared schema:"$'\n'"$json"
printf '%s' "$json" | jq -e '.finding_count > 0 and (.findings | length) == .finding_count' >/dev/null \
  || fail "the JSON finding count does not match its findings:"$'\n'"$json"
printf '%s' "$json" | jq -e '.network_included == false' >/dev/null \
  || fail 'the JSON rendering does not record that the network was skipped'
printf '%s' "$json" | jq -e '
  [.findings[] | select(.check == "home-uncommitted")] | length == 1' >/dev/null \
  || fail "the JSON rendering lost the home-uncommitted finding:"$'\n'"$json"
printf '%s' "$json" | jq -e '
  .findings | all(has("check") and has("band") and has("subject") and has("detail") and has("next"))' >/dev/null \
  || fail 'a JSON finding is missing a required field'
printf '%s' "$json" | jq -e '(.not_checked | length) > 0 and (.checks | length) > 0' >/dev/null \
  || fail 'the JSON rendering drops the check inventory or the not-checked list'
pass 'the JSON rendering carries findings, omissions and the check inventory'

toon=$(run "$HOME_S1" "$FB" --toon 2>&1); rc=$?
expect_code 0 "$rc" 'the TOON rendering exits 0'
assert_contains "$toon" 'schema: fm-rot-report.v1' 'the TOON rendering declares its schema'
assert_contains "$toon" 'home-uncommitted' 'the TOON rendering carries the finding'
pass 'the TOON rendering matches the JSON model'

# --- the tool own failures are the only non-zero exits ------------------------

out=$(run "$HOME_OK" "$FB" --no-such-flag 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail 'an unknown flag exited 0'
pass 'a misuse of the tool exits non-zero'
