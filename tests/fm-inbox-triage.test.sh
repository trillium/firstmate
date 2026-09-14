#!/usr/bin/env bash
# tests/fm-inbox-triage.test.sh - the inbox-to-project triage CLI routes every
# bead to exactly one project on agent decision, runs all registered detectors
# as evidence only, and appends an immutable JSONL trace per decision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRIAGE="$ROOT/bin/fm-inbox-triage.sh"
DETECTORS="$ROOT/bin/fm-inbox-triage-detectors"
TMP_ROOT=$(fm_test_tmproot fm-inbox-triage-tests)

REG="$TMP_ROOT/registry.json"
cat > "$REG" <<'JSON'
{"projects": [{"slug": "herdr", "name": "Herdr"}, {"slug": "parlay", "name": "Parlay", "aliases": ["parlay-oss"]}]}
JSON

POS="$TMP_ROOT/pos.json"
cat > "$POS" <<'JSON'
{"id": "inbox-pos", "title": "Fix Herdr pane naming", "description": "see projects/herdr for context, parlay-oss also mentioned", "labels": ["project:herdr"], "assignee": "pi-inbox", "status": "in_progress"}
JSON

NEG="$TMP_ROOT/neg.json"
cat > "$NEG" <<'JSON'
{"id": "inbox-neg", "title": "Buy milk", "description": "nothing to do with any project", "labels": [], "assignee": "pi-inbox", "status": "open"}
JSON

CAT="$TMP_ROOT/cat.json"
cat > "$CAT" <<'JSON'
{"id": "inbox-cat", "title": "Health note", "description": "personal", "labels": ["cat-health"], "assignee": "pi-inbox", "status": "open"}
JSON

score_for() {
  printf '%s' "$1" | jq -r --arg d "$2" '.evidence[] | select(.detector == $d) | .score'
}

project_for() {
  printf '%s' "$1" | jq -r --arg d "$2" '.evidence[] | select(.detector == $d) | (.project // "null")'
}

# --- detector registry -----------------------------------------------------

LIST_OUT=$("$TRIAGE" detectors)
printf '%s\n' "$LIST_OUT" | grep -q "project-name-mention" || fail "detectors did not list project-name-mention: $LIST_OUT"
printf '%s\n' "$LIST_OUT" | grep -q "label-match" || fail "detectors did not list label-match: $LIST_OUT"
printf '%s\n' "$LIST_OUT" | grep -q "path-slug-affinity" || fail "detectors did not list path-slug-affinity: $LIST_OUT"
pass "detectors lists all three shipped detectors"

# --- evidence: positive ----------------------------------------------------

EV_POS=$("$TRIAGE" evidence inbox-pos --input "$POS" --registry "$REG" --json)
[ "$(score_for "$EV_POS" label-match)" = 95 ] || fail "label-match missed project:herdr: $EV_POS"
[ "$(project_for "$EV_POS" label-match)" = herdr ] || fail "label-match named the wrong project: $EV_POS"
[ "$(score_for "$EV_POS" project-name-mention)" = 90 ] || fail "project-name-mention missed the Herdr slug: $EV_POS"
[ "$(project_for "$EV_POS" project-name-mention)" = herdr ] || fail "project-name-mention named the wrong project: $EV_POS"
[ "$(score_for "$EV_POS" path-slug-affinity)" = 80 ] || fail "path-slug-affinity missed projects/herdr: $EV_POS"
[ "$(project_for "$EV_POS" path-slug-affinity)" = herdr ] || fail "path-slug-affinity named the wrong project: $EV_POS"
pass "evidence on a positive bead scores all three detectors at herdr"

# --- evidence: negative ----------------------------------------------------

EV_NEG=$("$TRIAGE" evidence inbox-neg --input "$NEG" --registry "$REG" --json)
for d in label-match project-name-mention path-slug-affinity; do
  [ "$(score_for "$EV_NEG" "$d")" = 0 ] || fail "$d scored a bead with no signal: $EV_NEG"
  [ "$(project_for "$EV_NEG" "$d")" = null ] || fail "$d named a project with no signal: $EV_NEG"
done
pass "evidence on an unrelated bead is all score-0 with null projects"

# --- label-match: topic labels are evidence, not projects ------------------

EV_CAT=$("$TRIAGE" evidence inbox-cat --input "$CAT" --registry "$REG" --json)
[ "$(score_for "$EV_CAT" label-match)" = 40 ] || fail "label-match missed the cat-health topic hint: $EV_CAT"
[ "$(project_for "$EV_CAT" label-match)" = null ] || fail "label-match turned a topic label into a project: $EV_CAT"
pass "label-match treats cat- labels as topic evidence with a null project"

# --- detector I/O contract, each detector directly -------------------------

for d in project-name-mention label-match path-slug-affinity; do
  OUT=$(jq -n -c '{id: "t", title: "Herdr work", description: "projects/herdr", labels: ["project:herdr"]}' | "$DETECTORS/$d.sh" --registry "$REG")
  printf '%s' "$OUT" | jq -e '.detector and (.score | type == "number") and (.evidence | type == "string") and has("project")' >/dev/null \
    || fail "$d broke the detector I/O contract: $OUT"
done
pass "every detector honors the stdin-JSON / single-object-out contract"

OUT=$(jq -n -c '{id: "t", title: "zzz", description: "zzz", labels: []}' | "$DETECTORS/project-name-mention.sh")
[ "$(printf '%s' "$OUT" | jq -r '.score')" = 0 ] || fail "project-name-mention without a registry must score 0, not fail: $OUT"
OUT=$(jq -n -c '{id: "t", title: "zzz", description: "see projects/brandnew", labels: []}' | "$DETECTORS/path-slug-affinity.sh")
[ "$(printf '%s' "$OUT" | jq -r '.project')" = brandnew ] || fail "path-slug-affinity without a registry missed the projects/ candidate: $OUT"
pass "detectors stay fail-open without a registry"

# --- decide: exactly one project, reason, immutable trace -------------------

LOG="$TMP_ROOT/trace.jsonl"
OUT=$("$TRIAGE" decide inbox-pos --project herdr --reason 'closest fit' --input "$POS" --registry "$REG" --trace-log "$LOG" --feedback label-match:decisive --actor tester)
printf '%s' "$OUT" | grep -Fq "triaged inbox-pos -> herdr" || fail "decide did not confirm the routing: $OUT"
[ -f "$LOG" ] || fail "decide did not write the trace log"
jq -e 'select(.inbox_id == "inbox-pos" and .decision.project == "herdr" and .decision.reason == "closest fit" and .feedback["label-match"] == "decisive" and (.evidence | length) == 3 and .input.assignee == "pi-inbox")' "$LOG" >/dev/null \
  || fail "trace line missed inputs, evidence, decision, feedback, or assignment: $(cat "$LOG")"
pass "decide routes to exactly one project and appends a complete trace line"

"$TRIAGE" decide inbox-neg --project parlay --reason 'second look' --input "$NEG" --registry "$REG" --trace-log "$LOG" >/dev/null
[ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || fail "the second decide did not append, history must be append-only"
jq -e 'select(.inbox_id == "inbox-neg")' "$LOG" >/dev/null || fail "the first trace line was overwritten by the second decide"
pass "the trace log is append-only across decisions"

"$TRIAGE" decide inbox-neg --reason 'no project' --input "$NEG" --registry "$REG" --trace-log "$LOG" >/dev/null 2>&1 \
  && fail "decide without --project must fail"
"$TRIAGE" decide inbox-neg --project a --project b --reason 'two' --input "$NEG" --registry "$REG" --trace-log "$LOG" >/dev/null 2>&1 \
  && fail "decide with two --project flags must fail"
"$TRIAGE" decide inbox-neg --project a --input "$NEG" --registry "$REG" --trace-log "$LOG" >/dev/null 2>&1 \
  && fail "decide without --reason must fail"
"$TRIAGE" decide inbox-neg --project a --reason 'x' --feedback label-match:bogus --input "$NEG" --registry "$REG" --trace-log "$LOG" >/dev/null 2>&1 \
  && fail "decide with an invalid feedback value must fail"
[ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || fail "a rejected decide mutated the trace log"
pass "decide enforces exactly-one-project, reason, and feedback values without touching the log"

# --- decide --create-project stays local to the registry file ---------------

LOCAL_REG="$TMP_ROOT/local-registry.json"
printf '{"projects": []}' > "$LOCAL_REG"
"$TRIAGE" decide inbox-neg --project brandnew --reason 'nothing fits, creating' --create-project --input "$NEG" --registry "$LOCAL_REG" --trace-log "$LOG" >/dev/null
jq -e '.projects | map(.slug) | index("brandnew")' "$LOCAL_REG" >/dev/null \
  || fail "create-project did not add the slug to the local registry: $(cat "$LOCAL_REG")"
jq -e 'select(.inbox_id == "inbox-neg" and .decision.created == true)' "$LOG" >/dev/null \
  || fail "create-project did not record created=true in the trace"
pass "create-project adds the slug to the local registry file only and marks the trace"

# --- decide attaches the routing to the bead, atomically ----------------------

FAKE_STATE="$TMP_ROOT/fake-inbox-state"
mkdir -p "$FAKE_STATE"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake-inbox")
cat > "$FAKEBIN/inbox" <<'SH'
#!/usr/bin/env bash
# stub inbox CLI: show/update only, backed by $FM_FAKE_INBOX_STATE/labels_<id>.
set -u
state="${FM_FAKE_INBOX_STATE:-/tmp/fm-fake-inbox-missing}"
cmd=${1:-}
[ -n "$cmd" ] || { echo "stub inbox: no command" >&2; exit 2; }
shift
id=""; add=""; remove=""
while [ $# -gt 0 ]; do
  case "$1" in
    --add-label) add=${2:-}; shift 2 ;;
    --remove-label) remove=${2:-}; shift 2 ;;
    --*) shift ;;
    *) if [ -z "$id" ]; then id=$1; fi; shift ;;
  esac
done
[ -n "$id" ] || { echo "stub inbox: no id" >&2; exit 2; }
file="$state/labels_$id"
case "$cmd" in
  show)
    labels_json="[]"
    if [ "${FM_FAKE_INBOX_HIDE_LABELS:-0}" = 1 ]; then
      labels_json="[]"
    elif [ -f "$file" ]; then
      labels_json=$(jq -R . "$file" | jq -s -c '.') || labels_json="[]"
    fi
    jq -c -n --arg id "$id" --argjson labels "$labels_json" \
      '[{id: $id, title: "stub bead", description: "stub", labels: $labels, assignee: "", status: "open"}]'
    ;;
  update)
    if [ -n "$add" ]; then
      if [ "${FM_FAKE_INBOX_FAIL_WRITE:-0}" = 1 ]; then
        echo "stub inbox: simulated write failure" >&2
        exit 1
      fi
      touch "$file"
      grep -Fxq "$add" "$file" 2>/dev/null || printf '%s\n' "$add" >> "$file"
    fi
    if [ -n "$remove" ] && [ -f "$file" ]; then
      grep -Fxv "$remove" "$file" > "$file.tmp" || true
      mv "$file.tmp" "$file"
    fi
    ;;
  *) echo "stub inbox: unknown command $cmd" >&2; exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/inbox"

ATTACH_LOG="$TMP_ROOT/attach-trace.jsonl"
OUT=$(FM_INBOX_BIN="$FAKEBIN/inbox" FM_FAKE_INBOX_STATE="$FAKE_STATE" "$TRIAGE" decide inbox-stub1 --project parlay --reason 'stub attach' --registry "$REG" --trace-log "$ATTACH_LOG" --actor tester)
printf '%s' "$OUT" | grep -Fq "triaged inbox-stub1 -> parlay" || fail "decide did not confirm the stub routing: $OUT"
grep -Fxq "project:parlay" "$FAKE_STATE/labels_inbox-stub1" || fail "decide did not attach project:parlay to the bead"
[ "$(wc -l < "$ATTACH_LOG" | tr -d ' ')" = 1 ] || fail "decide did not append exactly one trace line"
jq -e 'select(.inbox_id == "inbox-stub1" and .decision.project == "parlay")' "$ATTACH_LOG" >/dev/null \
  || fail "attach trace line missed the decision: $(cat "$ATTACH_LOG")"
pass "decide attaches the project label to the bead and verifies before tracing"

FAIL_LOG="$TMP_ROOT/attach-fail.jsonl"
FM_INBOX_BIN="$FAKEBIN/inbox" FM_FAKE_INBOX_STATE="$FAKE_STATE" FM_FAKE_INBOX_FAIL_WRITE=1 \
  "$TRIAGE" decide inbox-stub2 --project parlay --reason 'stub failure' --registry "$REG" --trace-log "$FAIL_LOG" >/dev/null 2>&1 \
  && fail "decide with a failing bead write must fail"
[ ! -f "$FAIL_LOG" ] || [ "$(wc -l < "$FAIL_LOG" | tr -d ' ')" = 0 ] || fail "a failed attach left an orphan trace claim: $(cat "$FAIL_LOG")"
assert_absent "$FAKE_STATE/labels_inbox-stub2" "a failed attach left label state behind"
pass "a failed bead write leaves no orphan trace claim"

HIDE_LOG="$TMP_ROOT/attach-hide.jsonl"
FM_INBOX_BIN="$FAKEBIN/inbox" FM_FAKE_INBOX_STATE="$FAKE_STATE" FM_FAKE_INBOX_HIDE_LABELS=1 \
  "$TRIAGE" decide inbox-stub3 --project parlay --reason 'stub hidden' --registry "$REG" --trace-log "$HIDE_LOG" >/dev/null 2>&1 \
  && fail "decide with an unverifiable attach must fail"
[ ! -f "$HIDE_LOG" ] || [ "$(wc -l < "$HIDE_LOG" | tr -d ' ')" = 0 ] || fail "a failed verify left an orphan trace claim: $(cat "$HIDE_LOG")"
grep -Fxq "project:parlay" "$FAKE_STATE/labels_inbox-stub3" 2>/dev/null \
  && fail "a failed verify left the bead label behind without a trace"
pass "a verify mismatch surfaces an error instead of silent success"

FM_INBOX_BIN="$FAKEBIN/inbox" FM_FAKE_INBOX_STATE="$FAKE_STATE" \
  "$TRIAGE" decide inbox-stub4 --project parlay --reason 'stub bad log' --registry "$REG" --trace-log "$TMP_ROOT/no-such-dir/trace.jsonl" >/dev/null 2>&1 \
  && fail "decide with an unwritable trace log must fail"
grep -Fxq "project:parlay" "$FAKE_STATE/labels_inbox-stub4" 2>/dev/null \
  && fail "a failed trace append left the bead label behind without a trace"
pass "a failed trace append rolls the bead label back"

echo "# fm-inbox-triage.test.sh: all assertions passed"
