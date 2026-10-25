#!/usr/bin/env bash
# Captain-authorized work that is blocked, unstarted, or stalled, and how it is surfaced.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-stalled-work)
NOW=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' 2027-01-15T12:00:00Z +%s 2>/dev/null || date -u -d 2027-01-15T12:00:00Z +%s)

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf '# Backlog\n\n## In flight\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  chmod +x "$home/fakebin/"*
  ln -s "$(command -v jq)" "$home/fakebin/jq"
  printf '%s\n' "$home"
}

# fake_task <home> <beads-json>: a task CLI that prints the fixture for `list`.
fake_task() {
  printf '%s\n' "$2" > "$1/beads.json"
  printf '#!/bin/sh\ncase "$*" in\n  "list --status blocked --json") cat "%s/beads.json" ;;\n  *) exit 2 ;;\nesac\n' "$1" > "$1/fakebin/task"
  chmod +x "$1/fakebin/task"
}

fake_quota() { # <home> <runway-for-second-route>
  printf '#!/bin/sh\nprintf "quota[2]{route,runway}:\\n  a,exhausted_now\\n  b,%s\\n"\n' "$2" > "$1/fakebin/quota-axi"
  chmod +x "$1/fakebin/quota-axi"
}

# Only the home's fakebin plus system tools are visible, so a real task or
# quota-axi on the operator PATH never leaks into a case.
sweep() { # <home> args...
  local home=$1
  shift
  PATH="$home/fakebin:/usr/bin:/bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STALLED_NOW="$NOW" "$ROOT/bin/fm-stalled-work.sh" "$@"
}

seed_backlog() { # <home>
  local home=$1
  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] stall-one - Stalled worker item (repo: sample) (kind: ship) (since 2027-01-01)
- [ ] busy-one - Busy worker item (repo: sample) (kind: ship) (since 2027-01-01)

## Queued
- [ ] old-one - Queued long ago (repo: sample) (kind: ship) (since 2027-01-10)
- [ ] new-one - Queued just now (repo: sample) (kind: ship) (since 2027-01-15)
- [ ] cap-one - Captain decision (repo: sample) (kind: captain) (since 2027-01-01)
- [ ] held-one - Held for captain (repo: sample) (kind: ship) (since 2027-01-01) (hold: pick scope) (hold-kind: captain)
MD
  printf 'working [at=%s]: reading\n' $((NOW - 72 * 3600)) > "$home/state/stall-one.status"
  printf 'working [at=%s]: reading\n' $((NOW - 3600)) > "$home/state/busy-one.status"
}

BEAD_BLOCKED='[{"id":"task-blk","title":"Plain blocked bead","status":"blocked","created_at":"2027-01-05T00:00:00Z","notes":"Waiting on the vendor to ship the API.","description":""}]'
BEAD_QUOTA='[{"id":"task-quota","title":"Quota bead","status":"blocked","created_at":"2027-01-05T00:00:00Z","notes":"BLOCKED: no quota on the configured route.","description":""}]'

test_classes() {
  local home out
  home=$(new_home classes)
  seed_backlog "$home"
  fake_task "$home" "$BEAD_BLOCKED"
  out=$(sweep "$home" --json) || fail 'sweep failed on the class fixture'
  printf '%s' "$out" | jq -e '
    ([.not_done[] | select(.id == "task-blk" and .state == "blocked")] | length) == 1
    and ([.not_done[] | select(.id == "old-one" and .state == "unstarted")] | length) == 1
    and ([.not_done[] | select(.id == "stall-one" and .state == "stalled")] | length) == 1' >/dev/null \
    || fail "blocked, unstarted past grace, and stalled rows were not all reported: $out"
  printf '%s' "$out" | jq -e '[.not_done[].id] | (index("new-one") == null) and (index("cap-one") == null)
    and (index("held-one") == null) and (index("busy-one") == null)' >/dev/null \
    || fail "an item within grace, a captain item, or a live worker was reported: $out"
  printf '%s' "$out" | jq -e '.unavailable == []' >/dev/null || fail 'a readable fixture reported an unavailable source'
  pass 'blocked, unstarted past grace, and stalled are reported; grace, captain, and live items are skipped'
}

test_plain_and_quiet() {
  local home out
  home=$(new_home plain)
  seed_backlog "$home"
  fake_task "$home" '[]'
  out=$(sweep "$home" --plain) || fail 'plain sweep failed'
  printf '%s\n' "$out" | grep -q '^Not done: Queued long ago (old-one) - unstarted 5d: ' \
    || fail "plain list lacks the Not done line: $out"
  home=$(new_home empty)
  fake_task "$home" '[]'
  out=$(sweep "$home" --quiet --plain) || fail 'quiet sweep failed on an empty home'
  [ -z "$out" ] || fail "quiet printed output with nothing waiting and every source read: $out"
  pass 'plain list is readable and quiet stays silent only when nothing waits'
}

test_quota_resume() {
  local home out
  home=$(new_home quota)
  fake_task "$home" "$BEAD_QUOTA"
  out=$(sweep "$home" --json) || fail 'quota sweep failed'
  printf '%s' "$out" | jq -e '.not_done[0].needs == "resumes: when a configured route has runway"' >/dev/null \
    || fail "quota blocker did not get the resume need: $out"
  # No quota-axi: nothing is emitted.
  out=$(sweep "$home" --resume --plain)
  printf '%s\n' "$out" | grep -q 'quota-axi is unavailable' || fail "missing quota-axi was not disclosed: $out"
  fake_quota "$home" exhausted_now
  out=$(sweep "$home" --resume --plain)
  printf '%s\n' "$out" | grep -q 'no configured route has runway' || fail "exhausted routes still emitted lines: $out"
  fake_quota "$home" 12h
  out=$(sweep "$home" --resume --plain)
  printf '%s\n' "$out" | grep -q 'no backlog item owns this work' || fail "a bead with no owner was not told to file one: $out"
  # A queued backlog row blocked on quota gets the exact dispatch lines, emitted not run.
  home=$(new_home quota-row)
  fake_task "$home" '[]'
  fake_quota "$home" 12h
  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight

## Queued
- [ ] row-q - Row waiting on quota (repo: sample) (kind: ship) (since 2027-01-10) blocked-by: done-dep - no quota on the configured route

## Done
- [x] done-dep - Earlier work (repo: sample) (kind: ship) (merged 2027-01-02)
MD
  out=$(sweep "$home" --resume --plain)
  if printf '%s\n' "$out" | grep -q 'Not done: Row waiting on quota'; then
    printf '%s\n' "$out" | grep -q '^  bin/fm-dispatch-resolve.sh data/row-q/brief.md --project sample$' \
      || fail "the dispatch-resolve line was not emitted: $out"
    printf '%s\n' "$out" | grep -q '^  bin/fm-spawn.sh row-q projects/sample --mode ' \
      || fail "the spawn line was not emitted: $out"
  else
    fail "the quota-blocked backlog row was not reported: $out"
  fi
  [ ! -e "$home/data/row-q" ] || fail 'resume created task files instead of only emitting lines'
  pass 'quota blockers resume only when quota-axi shows runway, and lines are emitted not run'
}

test_notify() {
  local home out
  home=$(new_home notify)
  seed_backlog "$home"
  fake_task "$home" '[]'
  out=$(sweep "$home" --notify) || fail 'first notify failed'
  printf '%s\n' "$out" | grep -q 'Not done: Queued long ago' || fail "first notify did not print the list: $out"
  [ -s "$home/state/stalled-work.last" ] || fail 'notify did not record the rows it printed'
  out=$(sweep "$home" --notify) || fail 'second notify failed'
  [ -z "$out" ] || fail "unchanged rows printed again: $out"
  fake_task "$home" "$BEAD_BLOCKED"
  out=$(sweep "$home" --notify) || fail 'third notify failed'
  printf '%s\n' "$out" | grep -q 'Plain blocked bead' || fail "a new row did not print: $out"
  fake_task "$home" '[]'
  out=$(sweep "$home" --notify) || fail 'fourth notify failed'
  printf '%s\n' "$out" | grep -q 'task-blk' || fail "a cleared row was not named: $out"
  pass 'notify prints only when the rows changed and names cleared items'
}

test_store_absent() {
  local home out
  home=$(new_home nostore)
  seed_backlog "$home"
  out=$(sweep "$home" --json) || fail 'sweep failed without a task CLI'
  printf '%s' "$out" | jq -e '[.unavailable[].source] | index("task store") != null' >/dev/null \
    || fail "an absent task CLI was not disclosed: $out"
  out=$(sweep "$home" --quiet --plain) || fail 'quiet sweep failed without a task CLI'
  printf '%s\n' "$out" | grep -q '^Not checked: task store' || fail "quiet hid an unread store: $out"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/task"
  chmod +x "$home/fakebin/task"
  out=$(sweep "$home" --json) || fail 'sweep failed with a failing task CLI'
  printf '%s' "$out" | jq -e '[.unavailable[].source] | index("task store") != null' >/dev/null \
    || fail "a failing task CLI was reported as nothing blocked: $out"
  pass 'an absent or failing task store is disclosed, never read as nothing blocked'
}

test_delivery_surfaces() {
  local home out
  home=$(new_home surfaces)
  seed_backlog "$home"
  fake_task "$home" "$BEAD_BLOCKED"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_STALLED_NOW="$NOW" \
    FM_BEARINGS_NOW=2027-01-15T12:00:00Z "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail 'bearings failed'
  printf '%s' "$out" | jq -e '(.not_done | map(.id) | index("task-blk")) != null' >/dev/null \
    || fail "bearings did not project not_done: $(printf '%s' "$out" | jq -c '.not_done')"
  pass 'bearings projects not_done rows'
}

test_classes
test_plain_and_quiet
test_quota_resume
test_notify
test_store_absent
test_delivery_surfaces
