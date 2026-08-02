#!/usr/bin/env bash
# tests/fm-remote-launch.test.sh - behavior tests for the EXPERIMENTAL,
# explicitly transitional remote-bridge launcher (bin/fm-remote-launch.sh).
# Mirrors tests/fm-backend-herdr.test.sh's canned-response fakebin/command-log
# convention. There is no existing websocket-mocking convention in this repo
# (bin/fm-remote-launch.sh is the first script that talks to one), so
# make_fake_python3 below extends that same numbered-response convention to a
# fake `python3` that logs every non-"-c" invocation and returns a scripted
# stdout/exit for it, mirroring make_herdr_fakebin's "-c" special case after
# the precedent set by that fakebin's own `status --json` special case (a
# dependency probe that must succeed without consuming a scripted response
# slot). `curl` is faked the same way for the bridge's REST calls. This file
# does not exercise a real bridge or a real websocket - that is a known,
# documented limitation (see bin/fm-remote-launch.sh's header), the same
# posture tests/fm-backend-herdr-smoke.test.sh takes toward the real herdr
# binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by fm-remote-launch.sh)"; exit 0; }

# GNU base64 decodes with -d, BSD/macOS base64 with -D; detect once.
if printf 'Zm0=' | base64 -d >/dev/null 2>&1; then
  B64_DECODE_FLAG=-d
else
  B64_DECODE_FLAG=-D
fi
b64_decode() { base64 "$B64_DECODE_FLAG"; }

TMP_ROOT=$(fm_test_tmproot fm-remote-launch-tests)

# make_fake_curl: logs every invocation, then answers it from
# $FAKE_CURL_RESPONSES/<n>.{body,code} consumed in call order (default body
# empty, default code 200). Understands exactly the curl flag shapes
# bin/fm-remote-launch.sh actually uses: `-o /dev/null -w '%{http_code}'`
# (reachability), a plain GET (snapshot), and `-w '\n%{http_code}' -X POST -H
# ... -d ...` (bridge command).
make_fake_curl() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FAKE_CURL_LOG:?}"
RESP="${FAKE_CURL_RESPONSES:?}"
{
  printf 'CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

ofile="" wfmt=""
args=("$@")
i=0
n=${#args[@]}
while [ "$i" -lt "$n" ]; do
  a=${args[$i]}
  case "$a" in
    -o) i=$((i + 1)); ofile=${args[$i]:-} ;;
    -w) i=$((i + 1)); wfmt=${args[$i]:-} ;;
    -X|-H|-d|--max-time) i=$((i + 1)) ;;
  esac
  i=$((i + 1))
done

COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
body=""
[ -f "$RESP/$next.body" ] && body=$(cat "$RESP/$next.body")
code=200
[ -f "$RESP/$next.code" ] && code=$(cat "$RESP/$next.code")

[ "$ofile" = "/dev/null" ] || printf '%s' "$body"
if [ -n "$wfmt" ]; then
  sub=${wfmt//%\{http_code\}/$code}
  printf '%b' "$sub"
fi
exit 0
SH
  chmod +x "$fb/curl"
  printf '%s\n' "$fb"
}

# make_fake_python3: special-cases `-c ...` (the dependency import check) to
# always succeed without consuming a scripted slot, mirroring
# make_herdr_fakebin's `status --json` precedent. Every other invocation
# (running probe.py/send.py) is logged and answered from
# $FAKE_PYTHON_RESPONSES/<n>.{out,exit} in call order (default: empty stdout,
# exit 0 - matches probe.py/send.py's own silent-success shape).
make_fake_python3() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/python3" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  exit 0
fi
LOG="${FAKE_PYTHON_LOG:?}"
RESP="${FAKE_PYTHON_RESPONSES:?}"
{
  printf 'CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
if [ -f "$RESP/$next.exit" ]; then
  exit "$(cat "$RESP/$next.exit")"
fi
exit 0
SH
  chmod +x "$fb/python3"
  printf '%s\n' "$fb"
}

# Logged python3 argv is unit-separated (\x1f) as `CALL<US><script-path><US>
# <ws-url><US>...`, so index 0 is always the literal CALL marker and index 1
# is always the fake's own script path (probe.py or send.py) - not
# meaningful to a test. What comes after differs: probe.py is invoked as
# `python3 probe.py <ws_url> <b64-command> <timeout>` (the b64 command is
# index 3), send.py as `python3 send.py <ws_url> <delay> <b64-frame>...`
# (b64 frames start at index 4). These decode that real remote-shell/
# agent-input behavior, not internal source.
#
# Split with bash's own IFS, not awk -F'\x1f': the BSD/macOS "one true awk"
# does not interpret \x1f as a hex escape in -F, so it silently collapses
# every field into one - a real portability pitfall, not a hypothetical one.

# get_call_line <log> <n>: prints the n-th line beginning with CALL.
get_call_line() {
  local log=$1 n=$2 c=0 line
  while IFS= read -r line; do
    case "$line" in
      CALL*)
        c=$((c + 1))
        if [ "$c" -eq "$n" ]; then
          printf '%s\n' "$line"
          return 0
        fi
        ;;
    esac
  done < "$log"
  return 1
}

# decode_probe_call <log> <n>: the n-th logged python3 call's decoded (base64)
# probe command.
decode_probe_call() {
  local log=$1 n=$2 line parts
  line=$(get_call_line "$log" "$n") || return 1
  IFS=$'\x1f' read -ra parts <<<"$line"
  printf '%s' "${parts[3]:-}" | b64_decode 2>/dev/null
}

# decode_send_call <log> <n>: the n-th logged python3 call's decoded (base64)
# input frames, concatenated in order.
decode_send_call() {
  local log=$1 n=$2 line parts i out=""
  line=$(get_call_line "$log" "$n") || return 1
  IFS=$'\x1f' read -ra parts <<<"$line"
  for ((i = 4; i < ${#parts[@]}; i++)); do
    out+=$(printf '%s' "${parts[$i]}" | b64_decode 2>/dev/null)
  done
  printf '%s' "$out"
}

# make_fake_gh: logs every invocation together with its cwd (so a test can
# assert *which* local repo `gh` ran against), then answers with
# $FAKE_GH_RESPONSE (default "0", i.e. no merged PRs found).
make_fake_gh() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FAKE_GH_LOG:?}"
{
  printf 'CALL\x1fcwd=%s' "$PWD"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
printf '%s\n' "${FAKE_GH_RESPONSE:-0}"
exit 0
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

# setup_env <case-name>: fresh STATE/PROJECTS dirs plus fake curl/python3 on
# PATH, wired to per-case response/log dirs. Sets SPAWN_ENV as an array of
# "KEY=val" assignments a test can splice into an `env` call.
setup_case() {
  local name=$1
  CASE="$TMP_ROOT/$name"
  mkdir -p "$CASE/state" "$CASE/projects" "$CASE/curl-resp" "$CASE/py-resp"
  CURL_FB=$(make_fake_curl "$CASE/curl-fb")
  PY_FB=$(make_fake_python3 "$CASE/py-fb")
  FAKE_CURL_LOG="$CASE/curl.log"
  FAKE_PYTHON_LOG="$CASE/python.log"
  : > "$FAKE_CURL_LOG"
  : > "$FAKE_PYTHON_LOG"
  export FAKE_CURL_LOG FAKE_PYTHON_LOG
  export FAKE_CURL_RESPONSES="$CASE/curl-resp"
  export FAKE_PYTHON_RESPONSES="$CASE/py-resp"
  RUN_PATH="$PY_FB:$CURL_FB:$PATH"
}

run_launcher() {
  PATH="$RUN_PATH" \
    FM_STATE_OVERRIDE="$CASE/state" \
    FM_PROJECTS_OVERRIDE="$CASE/projects" \
    FM_REMOTE_BRIDGE_URL="http://fake-bridge:8787" \
    "$ROOT/bin/fm-remote-launch.sh" "$@"
}

# --- test 1: project absent -> clone ---------------------------------------

test_spawn_clones_absent_project() {
  local out rc
  setup_case spawn-clone
  fm_git_identity
  fm_git_init_commit "$CASE/projects/proj"
  fm_git_add_origin "$CASE/projects/proj" "$CASE/origin-bare.git"

  printf '200\n' > "$CASE/curl-resp/1.code"  # reachable snapshot
  printf '{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1"}\n' \
    > "$CASE/curl-resp/2.body"               # workspace.create
  printf '1\n' > "$CASE/py-resp/2.exit"      # project-present probe -> absent
  printf '/home/mini/code/.fm-worktrees/task-1\n' > "$CASE/py-resp/4.out"  # worktree add

  out=$(run_launcher mini1 proj task-1 "do the thing" 2>&1); rc=$?
  expect_code 0 "$rc" "spawn (clone path) exit"
  assert_contains "$out" "done: launched task task-1" "spawn (clone path) reports done"
  assert_present "$CASE/state/task-1.meta" "spawn (clone path) writes state/task-1.meta"
  assert_grep "backend=remote-bridge" "$CASE/state/task-1.meta" "meta records backend=remote-bridge"
  assert_grep "remote_project_path=/home/mini/code/.fm-worktrees/task-1" "$CASE/state/task-1.meta" \
    "meta records the worktree path returned by the mini"

  local cloned
  cloned=$(decode_probe_call "$FAKE_PYTHON_LOG" 3)
  assert_contains "$cloned" "git clone" "absent project triggers a git clone on the mini"
  assert_contains "$cloned" "origin-bare.git" "clone uses the project's own registered origin"
  pass "fm-remote-launch clones an absent project onto the mini before spinning up"
}

# --- test 2: dirty project -> refuse ----------------------------------------

test_spawn_refuses_dirty_project() {
  local out rc
  setup_case spawn-dirty
  fm_git_identity
  fm_git_init_commit "$CASE/projects/proj"
  fm_git_add_origin "$CASE/projects/proj" "$CASE/origin-bare.git"

  printf '200\n' > "$CASE/curl-resp/1.code"
  printf '{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1"}\n' \
    > "$CASE/curl-resp/2.body"
  printf '0\n' > "$CASE/py-resp/2.exit"       # project present
  printf '2\t0\t0\n' > "$CASE/py-resp/3.out"  # 2 dirty files

  out=$(run_launcher mini1 proj task-2 "do the thing" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must refuse a dirty project on the mini"
  assert_contains "$out" "dirty or has local commits" "refusal names the dirty/diverged reason"
  assert_absent "$CASE/state/task-2.meta" "no meta is recorded when the spawn is refused"
  assert_contains "$(cat "$FAKE_CURL_LOG")" "workspace.close" \
    "the just-created workspace is closed on a dirty-project refusal"
  pass "fm-remote-launch refuses a dirty/diverged project instead of touching it"
}

# --- test 3: no gh/git auth on the mini -> refuse ---------------------------

test_spawn_refuses_no_gh_auth() {
  local out rc
  setup_case spawn-noauth
  fm_git_identity
  fm_git_init_commit "$CASE/projects/proj"
  fm_git_add_origin "$CASE/projects/proj" "$CASE/origin-bare.git"

  printf '200\n' > "$CASE/curl-resp/1.code"
  printf '{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1"}\n' \
    > "$CASE/curl-resp/2.body"
  printf '1\n' > "$CASE/py-resp/1.exit"  # gh auth status probe fails

  out=$(run_launcher mini1 proj task-3 "do the thing" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must refuse when the mini lacks working git/gh auth"
  assert_contains "$out" "authentication" "refusal names the missing-auth reason"
  assert_absent "$CASE/state/task-3.meta" "no meta is recorded when auth is missing"
  assert_contains "$(cat "$FAKE_CURL_LOG")" "workspace.close" \
    "the just-created workspace is closed on a no-auth refusal"

  # Never-inject invariant: no login/credential-provisioning command is ever
  # sent, only the read-only status probe.
  local sent
  sent=$(decode_probe_call "$FAKE_PYTHON_LOG" 1)
  assert_not_contains "$sent" "auth login" "the auth check never runs gh auth login"
  assert_contains "$sent" "gh auth status" "the auth check is the read-only gh auth status"
  pass "fm-remote-launch refuses when the mini lacks git/gh auth, without provisioning credentials"
}

# --- test 4: full spin-up recipe (project already present and clean) -------

test_spawn_full_recipe_records_meta() {
  local out rc
  setup_case spawn-recipe
  fm_git_identity
  fm_git_init_commit "$CASE/projects/proj"
  fm_git_add_origin "$CASE/projects/proj" "$CASE/origin-bare.git"

  printf '200\n' > "$CASE/curl-resp/1.code"
  printf '{"workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","terminal_id":"term-9"}\n' \
    > "$CASE/curl-resp/2.body"
  printf '0\n' > "$CASE/py-resp/2.exit"        # project present
  printf '0\t0\t0\n' > "$CASE/py-resp/3.out"   # clean, no ahead/behind
  printf '/home/mini/code/.fm-worktrees/task-4\n' > "$CASE/py-resp/4.out"  # worktree add

  out=$(run_launcher mini1 proj task-4 "implement the feature" 2>&1); rc=$?
  expect_code 0 "$rc" "spawn (full recipe) exit"
  assert_contains "$out" "done: launched task task-4" "spawn (full recipe) reports done"

  assert_present "$CASE/state/task-4.meta" "spawn writes state/task-4.meta"
  assert_grep "endpoint_task_id=task-4" "$CASE/state/task-4.meta" "meta records the task id"
  assert_grep "backend=remote-bridge" "$CASE/state/task-4.meta" "meta records backend=remote-bridge"
  assert_grep "kind=ship" "$CASE/state/task-4.meta" "meta records kind=ship"
  assert_grep "project=proj" "$CASE/state/task-4.meta" "meta records the project name"
  assert_grep "remote_mini=mini1" "$CASE/state/task-4.meta" "meta records the target mini"
  assert_grep "remote_workspace_id=w9" "$CASE/state/task-4.meta" "meta records the workspace id"
  assert_grep "remote_tab_id=w9:t1" "$CASE/state/task-4.meta" "meta records the tab id"
  assert_grep "remote_pane_id=w9:p1" "$CASE/state/task-4.meta" "meta records the pane id"
  assert_grep "remote_terminal_id=term-9" "$CASE/state/task-4.meta" "meta records the terminal id"
  assert_grep "label=fm-task-4" "$CASE/state/task-4.meta" "meta records the fm-<id> label"

  local started
  started=$(decode_send_call "$FAKE_PYTHON_LOG" 5)
  assert_contains "$started" "task-4" "the agent start frame cds into the recorded worktree"
  assert_contains "$started" "claude" "the agent start frame launches claude"

  assert_contains "$(cat "$FAKE_CURL_LOG")" "workspace.rename" \
    "the workspace is renamed to carry the task id (reconcile needs the label)"
  pass "fm-remote-launch runs the full spin-up recipe and records complete task state"
}

# --- test 5: spin-down only when landed -------------------------------------

seed_reclaim_meta() {
  local id=$1
  fm_write_meta "$CASE/state/$id.meta" \
    "endpoint_task_id=$id" \
    "backend=remote-bridge" \
    "kind=ship" \
    "project=proj" \
    "remote_mini=mini1" \
    "remote_workspace_id=w9" \
    "remote_tab_id=w9:t1" \
    "remote_pane_id=w9:p1" \
    "remote_terminal_id=term-9" \
    "remote_project_path=/home/mini/code/.fm-worktrees/$id" \
    "label=fm-$id"
}

test_reclaim_refuses_when_unlanded() {
  local out rc
  setup_case reclaim-unlanded
  seed_reclaim_meta task-5

  printf '200\n' > "$CASE/curl-resp/1.code"      # reachability
  printf '3\tNA\n' > "$CASE/py-resp/1.out"       # dirty AND no upstream

  out=$(run_launcher reclaim task-5 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "reclaim must refuse when work is not confirmed landed"
  assert_contains "$out" "not confirmed landed" "refusal explains the reason"
  assert_not_contains "$(cat "$FAKE_CURL_LOG")" "workspace.close" \
    "an unlanded workspace is never closed"
  assert_present "$CASE/state/task-5.meta" "meta is left in place when reclaim is refused"
  pass "fm-remote-launch refuses to reclaim a workspace whose work is not landed"
}

test_reclaim_closes_when_landed() {
  local out rc
  setup_case reclaim-landed
  seed_reclaim_meta task-6

  printf '200\n' > "$CASE/curl-resp/1.code"   # reachability
  printf '0\t0\n' > "$CASE/py-resp/1.out"     # clean, ahead=0
  printf '200\n' > "$CASE/curl-resp/2.code"   # workspace.close

  out=$(run_launcher reclaim task-6 2>&1); rc=$?
  expect_code 0 "$rc" "reclaim (landed) exit"
  assert_contains "$out" "done: reclaimed task task-6" "reclaim reports done"
  assert_contains "$(cat "$FAKE_CURL_LOG")" "workspace.close" \
    "a confirmed-landed workspace is closed"
  assert_absent "$CASE/state/task-6.meta" "the live meta file is retired after reclaim"
  assert_present "$CASE/state/task-6.meta.reclaimed" "the meta file survives, renamed, after reclaim"
  pass "fm-remote-launch reclaims a workspace once its work is confirmed landed"
}

# --- test 7: squash-merge fallback scopes `gh` to the target project's repo,
# not firstmate's own ambient cwd ---------------------------------------

test_reclaim_pr_merged_fallback_scopes_to_project_repo() {
  local out rc call
  setup_case reclaim-pr-merged
  fm_git_identity
  fm_git_init_commit "$CASE/projects/proj"
  fm_git_add_origin "$CASE/projects/proj" "$CASE/origin-bare.git"
  seed_reclaim_meta task-7

  local GH_FB
  GH_FB=$(make_fake_gh "$CASE/gh-fb")
  RUN_PATH="$GH_FB:$RUN_PATH"
  FAKE_GH_LOG="$CASE/gh.log"
  : > "$FAKE_GH_LOG"
  export FAKE_GH_LOG
  export FAKE_GH_RESPONSE=1

  printf '200\n' > "$CASE/curl-resp/1.code"   # reachability
  printf '0\t3\n' > "$CASE/py-resp/1.out"     # clean, 3 local commits ahead of upstream
  printf '200\n' > "$CASE/curl-resp/2.code"   # workspace.close

  out=$(run_launcher reclaim task-7 2>&1); rc=$?
  expect_code 0 "$rc" "reclaim (squash-merge fallback) exit"
  assert_contains "$out" "done: reclaimed task task-7" \
    "reclaim reports done via the merged-PR fallback"

  local expected_cwd
  expected_cwd=$(cd "$CASE/projects/proj" && pwd)
  call=$(get_call_line "$FAKE_GH_LOG" 1)
  assert_contains "$call" "cwd=$expected_cwd" \
    "gh pr list runs from the target project's own local clone, not firstmate's own cwd"
  pass "fm-remote-launch's squash-merge fallback queries the target project's own repo"
}

test_spawn_clones_absent_project
test_spawn_refuses_dirty_project
test_spawn_refuses_no_gh_auth
test_spawn_full_recipe_records_meta
test_reclaim_refuses_when_unlanded
test_reclaim_closes_when_landed
test_reclaim_pr_merged_fallback_scopes_to_project_repo
