#!/usr/bin/env bash
# Behavior tests for bin/fm-pool-reclaim.sh - the treehouse pool reclaimer.
#
# A treehouse pool only shrinks: `treehouse prune` skips any worktree with
# uncommitted changes, and a lease is durable until an explicit return, so every
# endpoint that dies without reaching fm-teardown.sh leaks its slot forever.
# fm-pool-reclaim reclaims the two leak shapes that need no judgment and must
# refuse everything else, because its return is `--force` (which resets) and a
# wrong verdict destroys unlanded work.
#
# Each case runs over real throwaway git repos - the dirt classification reads
# real `git status --porcelain` output, so a fake would only confirm the
# assumption written into the fake - with a fake `treehouse` that serves a canned
# `status --json` pool and records every `return` invocation to a log:
#   (a) spent slot: only a deleted hook dropping is dirty        -> reclaimed
#   (b) real untracked work alongside the dropping               -> skipped
#   (c) real MODIFIED file that is not a dropping                -> skipped
#   (d) stale lease, no processes, past the threshold            -> reclaimed
#       and returned with --if-lease-id so a re-lease is refused
#   (e) fresh lease inside the threshold                         -> skipped
#   (f) lease with no parseable timestamp                        -> skipped
#   (g) any live process in the worktree                         -> untouched
#   (h) dry run is the default: it decides but returns nothing
#   (i) --only-if-exhausted no-ops while a slot is available, and sweeps when
#       every slot is spoken for
#   (j) fail-open: a missing treehouse, a failing status, and unparseable JSON
#       all exit 0 so the spawn pre-flight can never be why a spawn fails
#   (k) empty-field alignment: an unleased dirty worktree's two empty lease
#       fields must not shift the process count or age left (the tab-vs-US
#       separator regression - tab is IFS whitespace and collapses runs)
#   (l) every RFC3339Nano fraction width Go emits ages correctly, including the
#       widths fromisoformat rejects outright before Python 3.11
#   (m) a dirty slot claimed by someone else mid-sweep is re-verified and left
#       alone, since an unleased slot has no lease id to guard the return with
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECLAIM="$ROOT/bin/fm-pool-reclaim.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-reclaim)
fm_git_identity fmtest fmtest@example.invalid

# A fake treehouse serving $TH_POOL_JSON for `status --json`, a plain-text
# rendering for bare `status`, and appending its full argv to $TH_RETURN_LOG for
# `return`. Returns succeed unless FM_FAKE_TH_RETURN_FAIL is set, which lets a
# case drive the refused-return path (a lease re-acquired mid-sweep).
# FM_FAKE_TH_POOL_AFTER names a second pool file served from the SECOND
# `status --json` onward, which is how a case simulates the pool changing under
# the sweep between its decision read and its pre-return re-read.
make_fake_treehouse() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    if [ "${2:-}" = --json ]; then
      if [ -n "${FM_FAKE_TH_POOL_AFTER:-}" ] && [ -e "$TH_POOL_JSON.served" ]; then
        cat "$FM_FAKE_TH_POOL_AFTER"
      else
        : > "$TH_POOL_JSON.served"
        cat "$TH_POOL_JSON"
      fi
    else
      # Bare `status` only needs the status word per line for the
      # available-slot scan in older callers; keep it obviously distinct.
      python3 -c '
import json, os, sys
for wt in json.load(open(os.environ["TH_POOL_JSON"])):
    print("%s\t%s\t%s" % (wt.get("name",""), wt.get("status",""), wt.get("path","")))
'
    fi
    ;;
  return)
    shift
    printf '%s\n' "$*" >> "$TH_RETURN_LOG"
    [ -z "${FM_FAKE_TH_RETURN_FAIL:-}" ] || { echo "lease no longer matches" >&2; exit 1; }
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$fakebin/treehouse"
}

# A real git repo with one commit, so `git status --porcelain` is real output.
make_worktree() {  # <dir>
  local dir=$1
  fm_git_init_commit "$dir"
  printf '%s\n' "$dir"
}

# Commit a hook dropping into the worktree's history, then delete it from the
# working tree. This reproduces the exact live failure: the generated
# .claude/settings.local.json was once committed by an over-broad `git add`, so
# fm-teardown's `rm -f` of it now reads as an uncommitted DELETION rather than
# the removal of an ignored file, which pins the slot dirty forever.
commit_then_delete_dropping() {  # <dir> <relpath>
  local dir=$1 rel=$2
  mkdir -p "$dir/$(dirname "$rel")"
  printf '{"hooks":{}}\n' > "$dir/$rel"
  # -f because a captain's global excludes may already ignore the path - which
  # is exactly how the real commit happened: an over-broad add forced it in.
  git -C "$dir" add -f -- "$rel"
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -qm "dropping"
  rm -f "$dir/$rel"
}

# Render a pool JSON array from "<status>|<path>|<lease_id>|<holder>|<nprocs>|<leased_at>"
# records, so each case declares only the pool shape it is about.
write_pool() {  # <outfile> <record>...
  local out=$1
  shift
  python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
pool = []
for i, spec in enumerate(sys.argv[2:]):
    status, path, lease_id, holder, nprocs, leased_at = spec.split("|")
    pool.append({
        "name": str(i + 1),
        "path": path,
        "status": status,
        "lease_id": lease_id,
        "lease_holder": holder,
        "leased_at": leased_at or None,
        "processes": [{"pid": 1000 + j, "name": "zsh"} for j in range(int(nprocs))],
    })
open(out, "w").write(json.dumps(pool))
PY
}

# An RFC3339 stamp <n> seconds in the past, in the same shape treehouse emits
# (fractional seconds plus a numeric UTC offset), so the parser is exercised on
# the real format rather than a simplified one. The optional second argument sets
# how many fractional digits to emit: Go's RFC3339Nano trims trailing zeros, so
# any width from 0 to 9 reaches the parser in practice, and only 3 and 6 are
# accepted by fromisoformat before Python 3.11.
stamp_ago() {  # <seconds> [fraction digits]
  python3 -c '
import sys, datetime
ago = int(sys.argv[1])
digits = int(sys.argv[2]) if len(sys.argv) > 2 else 6
now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=ago)
text = now.isoformat(timespec="seconds")
# isoformat puts the offset last, so split it back off to insert the fraction.
base, offset = text[:-6], text[-6:]
# microsecond is six digits; the fixed "789" tail extends it to the nine Go can
# emit, so widths past six carry real digits rather than padding zeros.
fraction = (("%06d" % now.microsecond) + "789")[:digits] if digits else ""
print(base + (("." + fraction) if fraction else "") + offset)
' "$1" "${2:-6}"
}

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

CASE_N=0
# Build a case sandbox: fresh fakebin, pool file, and return log, all exported.
new_case() {  # -> exports FAKEBIN TH_POOL_JSON TH_RETURN_LOG CASE_DIR
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_N"
  mkdir -p "$CASE_DIR"
  FAKEBIN=$(fm_fakebin "$CASE_DIR")
  make_fake_treehouse "$FAKEBIN"
  export TH_POOL_JSON="$CASE_DIR/pool.json"
  export TH_RETURN_LOG="$CASE_DIR/returns.log"
  : > "$TH_RETURN_LOG"
  rm -f "$TH_POOL_JSON.served"
  unset FM_FAKE_TH_RETURN_FAIL
  unset FM_FAKE_TH_POOL_AFTER
  # The project directory only has to exist; the fake resolves no pool from it.
  mkdir -p "$CASE_DIR/project"
}

# Sets OUT (combined output) and RC in the CALLER's shell rather than echoing:
# a `$(run_reclaim ...)` capture would fork a subshell and lose the exit code,
# and the exit code is half of what every fail-open case asserts.
run_reclaim() {  # <args...> -> sets OUT, RC
  OUT=$(PATH="$FAKEBIN:$PATH" "$RECLAIM" --project "$CASE_DIR/project" "$@" 2>&1)
  RC=$?
}

# --- (a) spent slot: only a deleted hook dropping is dirty ------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
run_reclaim --yes; out=$OUT
expect_code 0 "$RC" "(a) spent slot exits 0"
assert_contains "$out" "reclaimed $WT" "(a) spent slot is reclaimed"
assert_contains "$out" "only firstmate hook droppings" "(a) reason names the droppings"
assert_grep "$WT" "$TH_RETURN_LOG" "(a) treehouse return was actually called"
assert_grep "--force" "$TH_RETURN_LOG" "(a) return used --force"
pass "(a) dirty-with-only-hook-droppings slot is reclaimed"

# Every dropping firstmate writes must classify the same way, or a slot dirtied
# by one of the less common ones silently pins forever.
for dropping in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
                .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
  new_case
  WT=$(make_worktree "$CASE_DIR/wt")
  commit_then_delete_dropping "$WT" "$dropping"
  write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
  run_reclaim --yes; out=$OUT
  assert_contains "$out" "reclaimed $WT" "(a) $dropping is recognized as a dropping"
done
pass "(a) every hook dropping fm-teardown removes is recognized"

# --- (b) real untracked work alongside a dropping ---------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
printf 'unlanded\n' > "$WT/CHANGELOG.md"
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
run_reclaim --yes; out=$OUT
expect_code 0 "$RC" "(b) exits 0"
assert_contains "$out" "skipped $WT" "(b) worktree with real work is skipped"
assert_contains "$out" "firstmate did not write" "(b) reason names the foreign change"
assert_not_contains "$(cat "$TH_RETURN_LOG")" "$WT" "(b) no return was called"
pass "(b) untracked work alongside a dropping blocks the reclaim"

# --- (c) a modified non-dropping file --------------------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
printf 'edited\n' >> "$WT/README.md"
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
run_reclaim --yes; out=$OUT
assert_contains "$out" "skipped $WT" "(c) modified tracked file is skipped"
assert_not_contains "$(cat "$TH_RETURN_LOG")" "$WT" "(c) no return was called"
pass "(c) a modified non-dropping file blocks the reclaim"

# --- (d) stale lease -------------------------------------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
write_pool "$TH_POOL_JSON" "leased|$WT|abc123|beadme|0|$(stamp_ago 90000)"
run_reclaim --yes; out=$OUT
expect_code 0 "$RC" "(d) exits 0"
assert_contains "$out" "reclaimed $WT" "(d) stale lease is reclaimed"
assert_contains "$out" "beadme" "(d) reason names the lease holder"
# --if-lease-id is the whole race guard: without it a lease re-acquired between
# the status read and the return would be stolen from its live new holder.
assert_grep "--if-lease-id abc123" "$TH_RETURN_LOG" "(d) return was guarded by the lease id"
pass "(d) a process-free lease past the threshold is reclaimed under --if-lease-id"

# A return the fake refuses (the re-leased race) must be reported, not counted
# as a reclaim, and must still exit 0.
new_case
WT=$(make_worktree "$CASE_DIR/wt")
write_pool "$TH_POOL_JSON" "leased|$WT|abc123|beadme|0|$(stamp_ago 90000)"
export FM_FAKE_TH_RETURN_FAIL=1
run_reclaim --yes; out=$OUT
unset FM_FAKE_TH_RETURN_FAIL
expect_code 0 "$RC" "(d) refused return still exits 0"
assert_contains "$out" "could not reclaim $WT" "(d) refused return is reported"
assert_contains "$out" "0 reclaimed" "(d) refused return is not counted as reclaimed"
pass "(d) a refused lease return is reported rather than counted"

# --- (e) fresh lease inside the threshold ----------------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
# 30s old: exactly the window between `treehouse get --lease` and the
# leaseholder's first process, which must never be reclaimed out from under it.
write_pool "$TH_POOL_JSON" "leased|$WT|abc123|beadme|0|$(stamp_ago 30)"
run_reclaim --yes; out=$OUT
assert_contains "$out" "skipped $WT" "(e) fresh lease is skipped"
assert_contains "$out" "not old enough" "(e) reason names the age"
assert_not_contains "$(cat "$TH_RETURN_LOG")" "$WT" "(e) no return was called"
pass "(e) a lease younger than the threshold is left alone"

# The threshold is configurable, and lowering it must make the same lease stale.
new_case
WT=$(make_worktree "$CASE_DIR/wt")
write_pool "$TH_POOL_JSON" "leased|$WT|abc123|beadme|0|$(stamp_ago 300)"
run_reclaim --yes --stale-lease-secs 60; out=$OUT
assert_contains "$out" "reclaimed $WT" "(e) a lowered threshold makes the same lease stale"
pass "(e) --stale-lease-secs moves the staleness boundary"

# --- (f) lease with no parseable timestamp ---------------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
write_pool "$TH_POOL_JSON" "leased|$WT|abc123|beadme|0|not-a-timestamp"
run_reclaim --yes; out=$OUT
assert_contains "$out" "skipped $WT" "(f) unparseable lease timestamp is skipped"
assert_contains "$out" "no usable timestamp" "(f) reason names the missing timestamp"
assert_not_contains "$(cat "$TH_RETURN_LOG")" "$WT" "(f) no return was called"
pass "(f) an unaged lease is declined rather than guessed at"

# --- (g) any live process protects the worktree ----------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
# Dirty with only a dropping AND a stale-looking lease: reclaimable on every
# axis EXCEPT that something is running in it. The process count alone must win.
write_pool "$TH_POOL_JSON" "dirty|$WT|||1|" "leased|$WT-b|abc|h|2|$(stamp_ago 90000)"
run_reclaim --yes; out=$OUT
assert_not_contains "$(cat "$TH_RETURN_LOG")" "$WT" "(g) no return was called on a live worktree"
assert_contains "$out" "2 in use" "(g) live worktrees are counted as in use"
pass "(g) a worktree with any live process is never touched"

# --- (h) dry run is the default --------------------------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
run_reclaim; out=$OUT
expect_code 0 "$RC" "(h) dry run exits 0"
assert_contains "$out" "would reclaim $WT" "(h) dry run reports the decision"
assert_contains "$out" "dry run:" "(h) dry run labels itself"
assert_not_contains "$out" "reclaimed $WT (spent" "(h) dry run does not claim it acted"
[ ! -s "$TH_RETURN_LOG" ] || fail "(h) dry run must not call treehouse return"
pass "(h) without --yes nothing is returned"

# --- (i) --only-if-exhausted ------------------------------------------------

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|" "available|$CASE_DIR/free|||0|"
run_reclaim --yes --only-if-exhausted; out=$OUT
expect_code 0 "$RC" "(i) available-slot short circuit exits 0"
assert_contains "$out" "pool has an available worktree" "(i) the sweep is skipped"
[ ! -s "$TH_RETURN_LOG" ] || fail "(i) an available slot must skip the sweep entirely"
pass "(i) --only-if-exhausted no-ops while a slot is free"

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|" "in-use|$CASE_DIR/busy|||3|"
run_reclaim --yes --only-if-exhausted; out=$OUT
assert_contains "$out" "reclaimed $WT" "(i) an exhausted pool is swept"
assert_grep "$WT" "$TH_RETURN_LOG" "(i) the exhausted-pool sweep returned the slot"
pass "(i) --only-if-exhausted sweeps when no slot is available"

# --- (j) fail-open on every input problem ----------------------------------

new_case
write_pool "$TH_POOL_JSON" "dirty|$CASE_DIR/nope|||0|"
# A PATH with no treehouse at all: the pre-flight must step aside silently.
out=$(PATH="$CASE_DIR/empty:/usr/bin:/bin" "$RECLAIM" --project "$CASE_DIR/project" --yes 2>&1)
expect_code 0 "$?" "(j) missing treehouse exits 0"
assert_contains "$out" "treehouse not found" "(j) missing treehouse is reported"
pass "(j) a missing treehouse fails open"

new_case
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
SH
chmod +x "$FAKEBIN/treehouse"
run_reclaim --yes; out=$OUT
expect_code 0 "$RC" "(j) failing status exits 0"
assert_contains "$out" "treehouse status failed" "(j) a failing status is reported"
pass "(j) a failing treehouse status fails open"

new_case
printf 'not json at all\n' > "$TH_POOL_JSON"
run_reclaim --yes; out=$OUT
expect_code 0 "$RC" "(j) unparseable status exits 0"
assert_contains "$out" "could not parse" "(j) unparseable status is reported"
[ ! -s "$TH_RETURN_LOG" ] || fail "(j) unparseable status must not return anything"
pass "(j) unparseable pool JSON fails open"

# --- (k) empty lease fields must not shift the record ----------------------
#
# The flattened record carries two lease fields that are empty for every
# unleased worktree. Separated by tab, bash's `read` collapses the run (tab is
# IFS whitespace) and the process count lands in the lease-id field and the age
# in the holder - which reads every unleased dirty slot as "still leased" and
# reclaims nothing. This is the exact regression that made the first live run
# skip all six abandoned slots.

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
run_reclaim --yes; out=$OUT
assert_not_contains "$out" "still leased" "(k) an unleased dirty slot is not read as leased"
assert_contains "$out" "reclaimed $WT" "(k) empty lease fields keep their place"
pass "(k) empty lease fields do not shift the process count or age"

# --- (l) fractional-second widths treehouse can actually emit ---------------
#
# treehouse is Go, so leased_at arrives as RFC3339Nano: up to nine fractional
# digits, trailing zeros trimmed, which yields every width from none to nine.
# Before Python 3.11 fromisoformat accepts exactly three or six and raises on the
# rest, so an unnormalized parse turns an ordinary nanosecond stamp into "no
# usable timestamp" and that lease is skipped for as long as it exists - the leak
# this whole script was written to stop, reintroduced through the parser.
#
# Be honest about what this case can prove: Python 3.11 widened fromisoformat to
# accept any fraction width, so on a 3.11+ host these assertions hold whether or
# not the normalization is there. It bites only where the bug bites - a 3.9 or
# 3.10 interpreter - which is exactly where a regression would otherwise land
# silently, since the reclaimer fails closed and simply stops reclaiming leases.

for width in 0 1 3 6 7 9; do
  new_case
  WT=$(make_worktree "$CASE_DIR/wt")
  write_pool "$TH_POOL_JSON" "leased|$WT|abc123|beadme|0|$(stamp_ago 90000 "$width")"
  run_reclaim --yes; out=$OUT
  assert_not_contains "$out" "no usable timestamp" \
    "(l) a ${width}-digit fraction parses"
  assert_contains "$out" "reclaimed $WT" \
    "(l) a stale lease stamped with a ${width}-digit fraction is reclaimed"
done
pass "(l) every RFC3339Nano fraction width treehouse emits is aged, not declined"

# --- (m) the dirty slot is re-verified immediately before the return --------
#
# A dirty unleased slot carries no lease id, so `--if-lease-id` has nothing to
# match and the reclaim would otherwise trust a pool reading taken before the
# sweep walked every worktree and shelled out to git for each. Re-reading right
# before the return shrinks that window to the gap between two commands. Drive it
# by rewriting the pool file between the two reads, which is exactly what a
# concurrent `treehouse get` would look like from here.

new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
# The slot is leased to someone else by the time the sweep re-reads the pool.
export FM_FAKE_TH_POOL_AFTER="$CASE_DIR/pool-after.json"
write_pool "$FM_FAKE_TH_POOL_AFTER" "leased|$WT|zzz999|latecomer|1|$(stamp_ago 5)"
run_reclaim --yes; out=$OUT
unset FM_FAKE_TH_POOL_AFTER
expect_code 0 "$RC" "(m) exits 0"
assert_contains "$out" "stopped being an unclaimed dirty slot" \
  "(m) the slot taken mid-sweep is reported, not reclaimed"
assert_not_contains "$(cat "$TH_RETURN_LOG")" "$WT" \
  "(m) no --force return was issued against the newly claimed slot"
pass "(m) a dirty slot claimed mid-sweep is re-verified and left alone"

# The guard must not cost anything when nothing changed: the same slot with a
# stable pool still reclaims, or the re-read would have broken every reclaim.
new_case
WT=$(make_worktree "$CASE_DIR/wt")
commit_then_delete_dropping "$WT" .claude/settings.local.json
write_pool "$TH_POOL_JSON" "dirty|$WT|||0|"
run_reclaim --yes; out=$OUT
assert_contains "$out" "reclaimed $WT" "(m) an unchanged pool still reclaims after the re-read"
pass "(m) the re-verify passes through when the slot is unchanged"

echo "all fm-pool-reclaim tests passed"
