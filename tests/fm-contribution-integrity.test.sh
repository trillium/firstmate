#!/usr/bin/env bash
# Behavioral tests for the contribution push-integrity check run by the poll.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contribution-integrity)
NOW=2026-09-16T08:00:00Z
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
URL=https://github.com/up/r/pull/8

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/delivery" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/root/bin" "$home/forge"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf -- '- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n' "$URL" >> "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  cat > "$home/fakebin/robots" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FORGE/robots.log"
printf 'agent-fake\n'
SH
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(jq -r .head.sha "$FORGE/core.json")" '{headRefOid:$head,reviewDecision:""}' ;;
  'api repos/up/r/pulls/8') cat "$FORGE/core.json" ;;
  'api repos/up/r/pulls/8/files?'*) jq -s '[.]' "$FORGE/files.json" ;;
  'api repos/fork/r/compare/'*) cat "$FORGE/compare.json" ;;
  'api repos/up/r/issues/8/comments?'*|'api repos/up/r/pulls/8/reviews?'*|'api repos/up/r/pulls/8/comments?'*) printf '[[]]\n' ;;
  'api repos/up/r/commits/'*'/check-runs?'*) printf '[{"check_runs":[]}]\n' ;;
  'api repos/up/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/up/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/"* "$home/root/bin/"*
  : > "$home/forge/files.json"
  printf '{"ahead_by":0}\n' > "$home/forge/compare.json"
  push "$home" "$H1" 3 true
  printf '%s\n' "$home"
}

push() { # home head commits mergeable [fork]
  local home=$1 head=$2 commits=$3 mergeable=$4 fork=${5:-no}
  jq -n --arg head "$head" --argjson commits "$commits" --argjson mergeable "$mergeable" --arg fork "$fork" '
    {state:"open",user:{login:"author"},draft:false,merged_at:null,commits:$commits,mergeable:$mergeable,
     head:{sha:$head,ref:"feature",repo:(if $fork == "yes" then {full_name:"fork/r",default_branch:"main"} else {full_name:"up/r",default_branch:"main"} end)},
     base:{repo:{full_name:"up/r"}}}' > "$home/forge/core.json"
}

poll() { # home
  local home=$1
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$ROOT/bin/fm-contributions.sh" poll
}

incident_count() { [ -f "$1/forge/robots.log" ] && wc -l < "$1/forge/robots.log" | tr -d ' ' || printf 0; }

baseline() { # home : establish a good head
  poll "$1" >/dev/null || fail 'baseline poll failed'
  [ "$(incident_count "$1")" = 0 ] || fail 'baseline raised an incident'
}

test_clean_push_is_silent() {
  local home out
  home=$(new_home clean)
  baseline "$home"
  push "$home" "$H2" 5 true
  out=$(poll "$home") || fail 'poll failed'
  [ -z "$out" ] && [ "$(incident_count "$home")" = 0 ] || fail "clean push flagged: $out"
  pass 'a clean push raises no wake and no incident'
}

test_conflicting_head() {
  local home out
  home=$(new_home conflicting)
  baseline "$home"
  push "$home" "$H2" 4 false
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "check: contributions integrity $URL rules=conflicting bad=$H2 last-good=$H1" \
    || fail "conflicting wake missing: $out"
  [ "$(incident_count "$home")" = 1 ] || fail 'expected one robots item'
  pass 'conflicting head wakes and files one robots item'
}

test_commit_growth() {
  local home out
  home=$(new_home growth)
  baseline "$home"
  push "$home" "$H2" 103 true
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "rules=commit-growth bad=$H2 last-good=$H1" || fail "growth wake missing: $out"
  pass 'a push adding about 100 commits is flagged'
}

test_wrong_base() {
  local home out
  home=$(new_home wrongbase)
  baseline "$home"
  push "$home" "$H2" 100 true yes
  printf '{"ahead_by":3}\n' > "$home/forge/compare.json"
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "wrong-base" || fail "wrong-base wake missing: $out"
  push "$home" "$H3" 4 true yes
  printf '{"ahead_by":4}\n' > "$home/forge/compare.json"
  out=$(poll "$home") || fail 'poll failed'
  ! printf '%s\n' "$out" | grep -Fq wrong-base || fail "own-commits fork push wrongly flagged: $out"
  pass 'fork-main commits in a fork PR are flagged; a PR of only its own commits is not'
}

test_workflow_files() {
  local home out
  home=$(new_home workflows)
  baseline "$home"
  push "$home" "$H2" 4 true
  printf '{"filename":".github/workflows/ci.yml"}\n' > "$home/forge/files.json"
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "rules=workflows bad=$H2" || fail "workflow wake missing: $out"
  pass 'workflow files appearing in the diff are flagged'
}

test_dedupe_and_good_head_kept() {
  local home out
  home=$(new_home dedupe)
  baseline "$home"
  push "$home" "$H2" 4 false
  poll "$home" >/dev/null || fail 'poll failed'
  out=$(poll "$home") || fail 'repeat poll failed'
  [ -z "$out" ] && [ "$(incident_count "$home")" = 1 ] || fail "same bad head re-raised: $out"
  push "$home" "$H3" 5 false
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "bad=$H3 last-good=$H1" || fail "a flagged head became known-good: $out"
  [ "$(incident_count "$home")" = 2 ] || fail 'new bad head should file its own item'
  pass 'one incident per PR and head, and a flagged head never becomes known-good'
}

accept() { # home head [url]
  local home=$1
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$ROOT/bin/fm-contributions.sh" integrity accept "${3:-$URL}" "$2"
}

test_accept_stops_workflow_refiring() {
  local home out
  home=$(new_home accept)
  baseline "$home"
  push "$home" "$H2" 4 true
  printf '{"filename":".github/workflows/ci.yml"}\n' > "$home/forge/files.json"
  poll "$home" > /dev/null || fail 'poll failed'
  [ "$(incident_count "$home")" = 1 ] || fail 'workflow head should file one item'
  accept "$home" "$H2" > /dev/null || fail 'accept of the flagged head failed'
  push "$home" "$H3" 5 true
  out=$(poll "$home") || fail 'poll failed'
  [ -z "$out" ] && [ "$(incident_count "$home")" = 1 ] || fail "later push re-alerted after accept: $out"
  pass 'an accepted workflow head stops later pushes re-filing the workflows rule'
}

test_accept_refuses_other_head() {
  local home
  home=$(new_home acceptrefuse)
  baseline "$home"
  push "$home" "$H2" 4 true
  printf '{"filename":".github/workflows/ci.yml"}\n' > "$home/forge/files.json"
  poll "$home" > /dev/null || fail 'poll failed'
  accept "$home" "$H3" 2> /dev/null && fail 'accept of a head other than the recorded one succeeded'
  accept "$home" "$H2" "https://github.com/up/r/pull/99" 2> /dev/null && fail 'accept of an unobserved PR succeeded'
  accept "$home" notasha 2> /dev/null && fail 'accept of a malformed head succeeded'
  push "$home" "$H3" 5 true
  poll "$home" | grep -Fq "rules=workflows bad=$H3" || fail 'refused accept still silenced the workflows rule'
  pass 'accept refuses a head that is not the recorded last head'
}

test_accept_keeps_other_rules() {
  local home out
  home=$(new_home acceptrules)
  baseline "$home"
  push "$home" "$H2" 4 true
  printf '{"filename":".github/workflows/ci.yml"}\n' > "$home/forge/files.json"
  poll "$home" > /dev/null || fail 'poll failed'
  accept "$home" "$H2" > /dev/null || fail 'accept failed'
  push "$home" "$H3" 5 false
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "rules=conflicting bad=$H3 last-good=$H2" || fail "conflicting did not fire after accept: $out"
  push "$home" "$H1" 120 true
  out=$(poll "$home") || fail 'poll failed'
  printf '%s\n' "$out" | grep -Fq "rules=commit-growth" || fail "commit-growth did not fire after accept: $out"
  pass 'other rules still fire after an accept'
}

test_slow_forge_and_filing_stay_inside_the_poll_budget() {
  local home out start elapsed
  home=$(new_home slow)
  baseline "$home"
  push "$home" "$H2" 103 true
  mv "$home/fakebin/gh" "$home/fakebin/gh-fast"
  printf '#!/bin/sh\nsleep 1\nexec "%s" "$@"\n' "$home/fakebin/gh-fast" > "$home/fakebin/gh"
  printf '#!/bin/sh\nexec sleep 30\n' > "$home/fakebin/robots"
  chmod +x "$home/fakebin/gh" "$home/fakebin/robots"
  start=$(date +%s)
  out=$(FM_CONTRIBUTIONS_BUDGET=7 FM_CHECK_TIMEOUT=10 poll "$home") || fail 'slow poll failed'
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 9 ] || fail "slow poll took ${elapsed}s with a 7s budget"
  [ "$(incident_count "$home")" = 0 ] || fail 'a filing the budget cut short was recorded as filed'
  jq -e --arg head "$H1" '.last_head == $head' "$home/state/contribution-integrity/"*.json >/dev/null \
    || fail 'the unfinished head was recorded instead of retried'
  jq -e '.records[0].checked_at != null and .records[0].observation.head != null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the observation finished before the budget ran out was not recorded'
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$FORGE/robots.log"\nprintf "agent-fake\\n"\n' > "$home/fakebin/robots"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$home/fakebin/gh-fast" > "$home/fakebin/gh"
  out=$(poll "$home") || fail 'retry poll failed'
  [ "$(incident_count "$home")" = 1 ] || fail "the deferred incident was not filed by the next poll: $out"
  pass 'slow forge reads and a slow filing stay inside the poll budget and the next poll finishes the check'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  failures=0
  for test_name in test_clean_push_is_silent test_conflicting_head test_commit_growth test_wrong_base test_workflow_files test_dedupe_and_good_head_kept test_accept_stops_workflow_refiring test_accept_refuses_other_head test_accept_keeps_other_rules test_slow_forge_and_filing_stay_inside_the_poll_budget; do
    ( "$test_name" ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || exit 1
fi
