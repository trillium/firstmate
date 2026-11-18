#!/usr/bin/env bash
# tests/workhorse-helpers.sh - fixtures shared by the fm-workhorse-*.test.sh suites.
#
# Source after tests/lib.sh. It builds a throwaway world: a pinned task store
# directory, a decoy store in a different cwd, a fake `task` CLI that keeps its
# beads in $BEADS_DIR/store.json (so the store a call really reached is
# observable) and logs every call's cwd and BEADS_DIR, and an isolated copy of
# the workhorse scripts whose sibling fm-send.sh is a recording fake.
#
# wh_world <root> sets: WH_STORE (pinned .beads dir), WH_DECOY (decoy cwd that
# holds its own .beads), WH_FAKEBIN, WH_BIN (isolated script copy), WH_LOG
# (task call log), WH_SEND_LOG (fake fm-send call log), WH_HOME (a fake mate
# home). The fake fm-send exits WH_SEND_RC (default 0).

wh_world() {  # <root>
  local root=$1
  WH_STORE="$root/store/.beads"
  WH_DECOY="$root/decoy"
  WH_FAKEBIN="$root/fakebin"
  WH_BIN="$root/bin"
  WH_LOG="$root/task-calls.log"
  WH_SEND_LOG="$root/send-calls.log"
  WH_HOME="$root/mate-home"
  mkdir -p "$WH_STORE" "$WH_DECOY/.beads" "$WH_FAKEBIN" "$WH_BIN" "$WH_HOME/data" "$WH_HOME/state" "$WH_HOME/config"
  printf '[]\n' >"$WH_STORE/store.json"
  printf '[]\n' >"$WH_DECOY/.beads/store.json"
  : >"$WH_LOG"
  : >"$WH_SEND_LOG"

  cat >"$WH_FAKEBIN/task" <<'SH'
#!/usr/bin/env bash
# Fake `task`: beads live in $BEADS_DIR/store.json.
set -eu
store="${BEADS_DIR:?BEADS_DIR unset}/store.json"
[ -f "$store" ] || printf '[]\n' >"$store"
printf '%s|%s|%s\n' "$PWD" "$BEADS_DIR" "$(printf '%s' "$*" | tr '\n' ' ')" >>"$FAKE_TASK_LOG"
cmd=$1
shift
save() { printf '%s\n' "$1" >"$store"; }
case "$cmd" in
  create)
    title=$1; shift
    desc='' labels='' meta='{}'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --description) desc=$2; shift 2 ;;
        --labels) labels=$2; shift 2 ;;
        --metadata) meta=$2; shift 2 ;;
        --silent) shift ;;
        *) shift ;;
      esac
    done
    n=$(jq 'length' "$store")
    id="task-b$((n + 1))"
    save "$(jq --arg id "$id" --arg t "$title" --arg d "$desc" --arg l "$labels" --argjson m "$meta" --argjson n "$n" \
      '. + [{id:$id,title:$t,description:$d,status:"open",assignee:"",labels:($l|split(",")),metadata:$m,created_at:("2026-01-01T00:00:0\($n)Z"),comments:[]}]' "$store")"
    printf '%s\n' "$id"
    ;;
  show)
    id=$1
    jq -e --arg id "$id" '[.[] | select(.id == $id)] | if length == 0 then empty else . end' "$store" || exit 1
    ;;
  list)
    label='' status='' noassign=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --label) label=$2; shift 2 ;;
        --status) status=$2; shift 2 ;;
        --no-assignee) noassign=1; shift ;;
        -n) shift 2 ;;
        *) shift ;;
      esac
    done
    jq --arg l "$label" --arg s "$status" --argjson na "$noassign" '
      [.[] | select(($l == "" or (.labels | index($l)) != null)
        and ($s == "" or .status == $s)
        and ($na == 0 or .assignee == ""))]' "$store"
    ;;
  update)
    # FAKE_UPDATE_RC forces the next update to fail with that code (13 is the
    # real CLI's stale-guard exit, i.e. another claimer won).
    [ -z "${FAKE_UPDATE_RC:-}" ] || exit "$FAKE_UPDATE_RC"
    id=$1; shift
    ifa='__unset__' ifs='__unset__' assignee='__unset__' status='__unset__'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --if-assignee) ifa=$2; shift 2 ;;
        --if-status) ifs=$2; shift 2 ;;
        --assignee) assignee=$2; shift 2 ;;
        --status) status=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    cur=$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$store")
    [ -n "$cur" ] || exit 1
    if [ "$ifa" != __unset__ ] && [ "$(printf '%s' "$cur" | jq -r '.assignee')" != "$ifa" ]; then exit 13; fi
    if [ "$ifs" != __unset__ ] && [ "$(printf '%s' "$cur" | jq -r '.status')" != "$ifs" ]; then exit 13; fi
    save "$(jq --arg id "$id" --arg a "$assignee" --arg s "$status" '
      map(if .id == $id then
        (if $a != "__unset__" then .assignee = $a else . end)
        | (if $s != "__unset__" then .status = $s else . end)
      else . end)' "$store")"
    ;;
  comments)
    [ "$1" = add ] || exit 1
    save "$(jq --arg id "$2" --arg c "$3" 'map(if .id == $id then .comments += [$c] else . end)' "$store")"
    ;;
  close)
    [ -z "${FAKE_CLOSE_RC:-}" ] || exit "$FAKE_CLOSE_RC"
    id=$1; shift
    reason=''
    [ "${1:-}" = --reason ] && reason=$2
    save "$(jq --arg id "$id" --arg r "$reason" 'map(if .id == $id then .status = "closed" | .close_reason = $r else . end)' "$store")"
    ;;
  *) echo "fake task: unsupported command $cmd" >&2; exit 1 ;;
esac
SH
  chmod +x "$WH_FAKEBIN/task"

  # shellcheck disable=SC2153  # ROOT is exported by tests/lib.sh, which every suite sources first.
  cp "$ROOT"/bin/fm-workhorse-*.sh "$WH_BIN/"
  cat >"$WH_BIN/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf 'FM_HOME=%s|%s\n' "${FM_HOME-<unset>}" "$*" >>"$WH_SEND_LOG"
exit "${WH_SEND_RC:-0}"
SH
  chmod +x "$WH_BIN/fm-send.sh"
  export FAKE_TASK_LOG="$WH_LOG" WH_SEND_LOG
  export FM_WORKHORSE_BEADS_DIR="$WH_STORE"
  PATH="$WH_FAKEBIN:$PATH"
  export PATH
}

# wh_file <args...> - run the isolated fm-workhorse-file.sh from the decoy cwd.
wh_file() {
  (cd "$WH_DECOY" && FM_HOME="$WH_HOME" "$WH_BIN/fm-workhorse-file.sh" "$@")
}

# wh_file_valid [overrides...] - the full valid request; a later flag overrides
# an earlier one, so a case breaks exactly one field by repeating it.
wh_file_valid() {
  wh_file_no_evidence \
    --evidence "pr:the merged pull request link" \
    --evidence "command:the test run output proving it passes" \
    "$@"
}

# wh_file_no_evidence [more flags...] - the valid request without any evidence,
# for a case that names its own evidence kinds.
wh_file_no_evidence() {
  wh_file \
    --title "Add flux capacitor option to the loader" \
    --intent "Make the flux capacitor configurable for each project." \
    --spec "Add a config key that the loader reads at startup." \
    --out-of-scope "Anything touching the billing code paths." \
    --dod "Tests cover the new key and its refusal path." \
    --mode local-only --yolo off --project demo-project --answer-to porter \
    "$@"
}

# wh_store_count <beads-dir>
wh_store_count() {
  jq 'length' "$1/store.json"
}

# wh_seed <title> <labels-csv> [description] - add a bead straight to the pinned
# store through the fake CLI and print its id.
wh_seed() {
  BEADS_DIR="$WH_STORE" task create "$1" --description "${3:-}" --labels "$2" --silent
}
