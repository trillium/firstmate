#!/usr/bin/env bash
# bin/fm-remote-launch.sh - EXPERIMENTAL, EXPLICITLY TRANSITIONAL remote-bridge
# launcher. Launches (and reclaims) a crewmate agent on a named "mini"
# (mini1/mini2/mini3/...) over the herdr-web bridge, proxied through a local
# bridge at FM_REMOTE_BRIDGE_URL (default http://localhost:8787) as
# /api/remote/<mini>/...
#
# Design source: data/multisystem-launch-contract-scout/report.md, grounded in
# ~/code/herdr-web/bridge/src/web_bridge.rs and the proven one-off launch in
# data/mini3-parlay-dev-launch/report.md. Two captain decisions from that
# report are built to directly:
#   - Ownership = C (transitional): this is a small, self-contained,
#     explicitly disposable script - NOT a bin/backends/*.sh adapter, NOT
#     wired into bin/fm-backend.sh's runtime-backend dispatch, and NOT called
#     from bin/fm-spawn.sh/bin/fm-teardown.sh/bin/fm-watch.sh. It does not
#     source those files and they do not source it, so it can be deleted or
#     handed off to Parlay's future spawn primitive (decision-3ae,
#     ~/code/parlay/docs/PARLAY_FIRSTMATE_FOLD.md) without touching them.
#   - Credentials = never-inject: this script NEVER types git/gh credentials,
#     SSH keys, or tokens into a mini pane. Working git/gh auth on the target
#     mini is a hard PREREQUISITE, checked read-only via `gh auth status`
#     (fm_remote_check_gh_auth) and refused on if absent. There is no code
#     path anywhere in this file that runs `gh auth login`, writes an SSH key,
#     or sets `git config credential.*` - that invariant is structural, not
#     just documented, so keep it that way in any future edit.
#
# The bridge has no auth of its own (confirmed in the design report); every
# remote shell command this script sends is visible to anything that can
# reach the bridge, exactly like the proven mini3 launch.
#
# Remote shell state (project presence, dirty/diverged checks, gh auth,
# landed-work checks) is read over the terminal websocket by wrapping a shell
# command with unique start/end markers and decoding the returned ANSI stream
# with `pyte` (fm_remote_ws_probe) - there is no bridge RPC for filesystem or
# git state. This is the same technique used by hand in the mini3 launch,
# generalized and automated here. It depends on python3 with the `websockets`
# and `pyte` modules; a missing dependency is refused with a clear message,
# never silently skipped.
#
# EXPERIMENTAL: the exact JSON envelope shape of a few bridge responses
# (workspace.create, snapshot) was confirmed by the design report only via
# behavior/log evidence, not a captured raw JSON sample of every field, so
# this script parses defensively (accepts both a flat body and a
# `{"result": {...}}` envelope). The websocket probe's marker-based ANSI
# parsing has NOT been exercised by this task's automated tests (python3 is
# faked in tests/fm-remote-launch.test.sh, matching the existing fakebin
# convention) - verify it by hand against a live bridge before relying on it
# for a real dirty/auth decision, the same way docs/herdr-backend.md flags its
# own experimental surfaces. Every task-scoped spawn always uses an isolated
# `git worktree` on the mini (never the base clone directly), mirroring
# firstmate's own local one-task-one-worktree contract; a "standing" agent
# shape like the mini3 parlay-dev launch (working directly in a plain clone)
# is out of scope for this script.
#
# Usage:
#   fm-remote-launch.sh <mini> <project> <task-id> <prompt...>   # spin up
#   fm-remote-launch.sh reclaim <task-id> [--force]              # spin down
#   fm-remote-launch.sh reconcile                                # rediscover
#   fm-remote-launch.sh status <task-id>                         # inspect
#
# State: writes/reads state/<task-id>.meta exactly like every other backend
# (bin/fm-backend.sh's fm_meta_get convention, deliberately re-implemented
# below rather than sourced, to keep this script fully self-contained and
# collision-free with in-flight edits to fm-backend.sh/fm-spawn.sh/
# fm-teardown.sh). Fields: backend=remote-bridge, remote_mini=,
# remote_workspace_id=, remote_tab_id=, remote_pane_id=, remote_terminal_id=,
# remote_project_path=, project=, label=fm-<task-id>.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

BRIDGE_URL="${FM_REMOTE_BRIDGE_URL:-http://localhost:8787}"
RL_HTTP_TIMEOUT="${FM_REMOTE_LAUNCH_HTTP_TIMEOUT:-10}"
RL_REACHABLE_TIMEOUT="${FM_REMOTE_LAUNCH_REACHABLE_TIMEOUT:-5}"
RL_PROBE_TIMEOUT="${FM_REMOTE_LAUNCH_PROBE_TIMEOUT:-25}"
RL_CLONE_TIMEOUT="${FM_REMOTE_LAUNCH_CLONE_TIMEOUT:-90}"
RL_FRAME_DELAY="${FM_REMOTE_LAUNCH_FRAME_DELAY:-2}"

usage() {
  cat <<'USAGE' >&2
usage:
  fm-remote-launch.sh <mini> <project> <task-id> <prompt...>
  fm-remote-launch.sh reclaim <task-id> [--force]
  fm-remote-launch.sh reconcile
  fm-remote-launch.sh status <task-id>
USAGE
}

# --- small helpers -----------------------------------------------------

fm_remote_validate_name() {  # <value> <label>
  case "$1" in
    '' | *[!A-Za-z0-9_.-]*)
      echo "error: invalid $2 '$1' (only letters, digits, '.', '_', '-' allowed)" >&2
      return 1
      ;;
  esac
  return 0
}

# Mirrors bin/fm-backend.sh's fm_meta_get exactly (grep last key=, never
# errors); re-implemented here rather than sourced so this file has zero
# runtime dependency on fm-backend.sh (see header: collision-avoidance with
# other in-flight edits to that file).
fm_remote_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_remote_tmp_dir() {
  if [ -z "${RL_TMP:-}" ]; then
    RL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-launch.XXXXXX")
  fi
  printf '%s\n' "$RL_TMP"
}

# --- bridge REST calls ---------------------------------------------------

fm_remote_bridge_command() {  # <mini> <method> <params-json> -> prints response body
  local mini=$1 method=$2 params=$3 url body resp http_code resp_body
  url="$BRIDGE_URL/api/remote/$mini/command"
  body=$(jq -n --arg method "$method" --argjson params "$params" \
    '{id: ("fm-" + (now | tostring)), method: $method, params: $params}')
  resp=$(curl -sS --max-time "$RL_HTTP_TIMEOUT" -w '\n%{http_code}' -X POST "$url" \
    -H 'Content-Type: application/json' -d "$body") || {
    echo "error: curl failed contacting $url" >&2
    return 1
  }
  http_code=${resp##*$'\n'}
  resp_body=${resp%$'\n'*}
  case "$http_code" in
    2??)
      printf '%s\n' "$resp_body"
      return 0
      ;;
    *)
      echo "error: bridge command $method on $mini failed (HTTP $http_code): $resp_body" >&2
      return 1
      ;;
  esac
}

fm_remote_reachable() {  # <mini>
  local mini=$1 code
  code=$(curl -sS --max-time "$RL_REACHABLE_TIMEOUT" -o /dev/null -w '%{http_code}' \
    "$BRIDGE_URL/api/remote/$mini/snapshot" 2>/dev/null) || return 1
  [ "$code" = "200" ]
}

fm_remote_snapshot() {  # <mini> -> prints JSON body
  curl -sS --max-time "$RL_HTTP_TIMEOUT" "$BRIDGE_URL/api/remote/$mini/snapshot"
}

fm_remote_workspace_create() {  # <mini> -> prints "workspace_id<TAB>tab_id<TAB>pane_id<TAB>terminal_id"
  local mini=$1 resp
  resp=$(fm_remote_bridge_command "$mini" workspace.create '{"focus":true}') || return 1
  printf '%s' "$resp" | jq -r '
    (.result // .) as $r
    | [$r.workspace_id, $r.tab_id, $r.pane_id, $r.terminal_id] | @tsv
  '
}

fm_remote_workspace_rename() {  # <mini> <workspace_id> <label>
  local mini=$1 wid=$2 label=$3 params
  params=$(jq -n --arg w "$wid" --arg l "$label" '{workspace_id: $w, label: $l}')
  fm_remote_bridge_command "$mini" workspace.rename "$params" >/dev/null
}

fm_remote_workspace_close() {  # <mini> <workspace_id>
  local mini=$1 wid=$2 params
  params=$(jq -n --arg w "$wid" '{workspace_id: $w}')
  fm_remote_bridge_command "$mini" workspace.close "$params" >/dev/null
}

# --- terminal websocket (python helper: probe with capture, send fire-and-forget) ---

fm_remote_ws_base() {
  case "$BRIDGE_URL" in
    https://*) printf 'wss://%s\n' "${BRIDGE_URL#https://}" ;;
    http://*) printf 'ws://%s\n' "${BRIDGE_URL#http://}" ;;
    *) printf '%s\n' "$BRIDGE_URL" ;;
  esac
}

fm_remote_terminal_ws_url() {  # <mini> <terminal_id>
  printf '%s/ws/remote/%s/terminal?terminal_id=%s\n' "$(fm_remote_ws_base)" "$1" "$2"
}

fm_remote_require_python() {
  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required (terminal websocket I/O) but not found" >&2
    return 1
  }
  python3 -c "import websockets, pyte" >/dev/null 2>&1 || {
    echo "error: python3 modules 'websockets' and 'pyte' are required but not importable" >&2
    return 1
  }
  return 0
}

# fm_remote_write_probe_py: a small python client that sends one shell command
# over the terminal websocket wrapped in unique start/end markers, decodes the
# returned ANSI stream with pyte, and prints the text between the markers,
# exiting with the remote command's own exit code. Bounded by an overall
# timeout. See header EXPERIMENTAL note: the exact terminal echo behavior of
# every mini's shell has not been verified by automated tests here.
fm_remote_write_probe_py() {
  local dir
  dir=$(fm_remote_tmp_dir)
  [ -f "$dir/probe.py" ] && return 0
  cat > "$dir/probe.py" <<'PY'
import sys, asyncio, json, base64, time, uuid
import websockets
import pyte


async def run(ws_url, command, timeout_s):
    marker = uuid.uuid4().hex
    start_tag, end_tag = f"FMRLSTART{marker}", f"FMRLEND{marker}"
    payload = f'printf "\\n{start_tag}\\n"; {command}\nprintf "{end_tag}:%s\\n" "$?"\r'
    screen = pyte.Screen(220, 400)
    stream = pyte.Stream(screen)
    deadline = time.monotonic() + timeout_s
    text = ""
    try:
        async with websockets.connect(ws_url, max_size=None, open_timeout=min(10, timeout_s)) as ws:
            await ws.send(json.dumps({"type": "input", "data": payload}))
            while time.monotonic() < deadline:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=remaining)
                except asyncio.TimeoutError:
                    break
                if isinstance(msg, (bytes, bytearray)):
                    stream.feed(msg.decode("utf-8", "replace"))
                elif isinstance(msg, str):
                    stream.feed(msg)
                text = "\n".join(screen.display)
                if end_tag in text:
                    break
    except Exception as exc:  # noqa: BLE001 - report and exit, this is a leaf CLI tool
        print(f"FM_REMOTE_LAUNCH_ERROR: websocket failure: {exc}", file=sys.stderr)
        sys.exit(3)
    if end_tag not in text:
        print("FM_REMOTE_LAUNCH_ERROR: timed out waiting for probe output", file=sys.stderr)
        sys.exit(2)
    lines = text.splitlines()
    starts = [i for i, l in enumerate(lines) if start_tag in l]
    ends = [i for i, l in enumerate(lines) if end_tag in l]
    if not starts or not ends:
        print("FM_REMOTE_LAUNCH_ERROR: markers not found in captured output", file=sys.stderr)
        sys.exit(2)
    # The command line itself is echoed back by the pty before its real
    # output, and it also contains the marker text, so take the LAST start
    # marker (the printed one) and the first end marker after it.
    si = starts[-1]
    ei = next((i for i in ends if i > si), ends[-1])
    captured = "\n".join(lines[si + 1:ei]).rstrip()
    rc_str = lines[ei].split(":")[-1].strip()
    print(captured)
    try:
        sys.exit(int(rc_str))
    except ValueError:
        sys.exit(1)


def main():
    ws_url, command_b64, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
    command = base64.b64decode(command_b64).decode()
    asyncio.run(run(ws_url, command, timeout_s))


if __name__ == "__main__":
    main()
PY
}

# fm_remote_write_send_py: fire-and-forget client that sends a sequence of raw
# input frames with a delay between each, no output capture. Used to start the
# agent and type its task prompt (pane.send_input is not a bridge RPC method -
# this websocket is the only channel).
fm_remote_write_send_py() {
  local dir
  dir=$(fm_remote_tmp_dir)
  [ -f "$dir/send.py" ] && return 0
  cat > "$dir/send.py" <<'PY'
import sys, asyncio, json, base64
import websockets


async def send_all(ws_url, frames, delay_s):
    async with websockets.connect(ws_url, max_size=None) as ws:
        for i, frame in enumerate(frames):
            if i > 0:
                await asyncio.sleep(delay_s)
            await ws.send(json.dumps({"type": "input", "data": frame}))


def main():
    ws_url = sys.argv[1]
    delay_s = float(sys.argv[2])
    frames = [base64.b64decode(a).decode() for a in sys.argv[3:]]
    asyncio.run(send_all(ws_url, frames, delay_s))


if __name__ == "__main__":
    main()
PY
}

fm_remote_ws_probe() {  # <mini> <terminal_id> <command> [timeout] -> captured stdout; returns remote exit code
  local mini=$1 terminal_id=$2 command=$3 timeout=${4:-$RL_PROBE_TIMEOUT} ws_url b64
  fm_remote_require_python || return 1
  fm_remote_write_probe_py
  ws_url=$(fm_remote_terminal_ws_url "$mini" "$terminal_id")
  b64=$(printf '%s' "$command" | base64 | tr -d '\n')
  python3 "$(fm_remote_tmp_dir)/probe.py" "$ws_url" "$b64" "$timeout"
}

fm_remote_ws_send() {  # <mini> <terminal_id> <frame...> -> fire-and-forget
  local mini=$1 terminal_id=$2 ws_url
  shift 2
  fm_remote_require_python || return 1
  fm_remote_write_send_py
  ws_url=$(fm_remote_terminal_ws_url "$mini" "$terminal_id")
  local b64args=() f
  for f in "$@"; do
    b64args+=("$(printf '%s' "$f" | base64 | tr -d '\n')")
  done
  python3 "$(fm_remote_tmp_dir)/send.py" "$ws_url" "$RL_FRAME_DELAY" "${b64args[@]}"
}

# --- credential prerequisite (never-inject) ------------------------------

# Checks working git/gh auth READ-ONLY. Never runs `gh auth login`, never
# writes an SSH key or git credential - see the header's never-inject
# invariant.
fm_remote_check_gh_auth() {  # <mini> <terminal_id>
  local mini=$1 terminal_id=$2 out rc
  set +e
  out=$(fm_remote_ws_probe "$mini" "$terminal_id" \
    'command -v git >/dev/null 2>&1 && command -v gh >/dev/null 2>&1 && gh auth status' \
    "$RL_PROBE_TIMEOUT")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "error: mini $mini does not have working git/gh authentication; refusing without provisioning credentials remotely" >&2
    [ -n "$out" ] && echo "$out" >&2
    return 1
  fi
  return 0
}

# --- project presence / clone / dirty-refuse ------------------------------

fm_remote_local_origin_url() {  # <project> -> prints the primary's own registered origin URL
  local project=$1 path url
  path="$PROJECTS/$project"
  [ -d "$path" ] || {
    echo "error: project '$project' is not cloned locally at $path; cannot determine its registered origin" >&2
    return 1
  }
  url=$(git -C "$path" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || {
    echo "error: local clone $path has no 'origin' remote" >&2
    return 1
  }
  printf '%s\n' "$url"
}

fm_remote_project_present() {  # <mini> <terminal_id> <project> -> 0 present / 1 absent
  local mini=$1 terminal_id=$2 project=$3 rc
  set +e
  fm_remote_ws_probe "$mini" "$terminal_id" "test -d ~/code/$project/.git" "$RL_PROBE_TIMEOUT" >/dev/null
  rc=$?
  set -e
  return "$rc"
}

# Prints "PORCELAIN<TAB>AHEAD<TAB>BEHIND" for ~/code/<project> on the mini
# after a `git fetch origin`. AHEAD/BEHIND are relative to the branch's own
# upstream, or "NA" when there is none.
fm_remote_project_clean_state() {  # <mini> <terminal_id> <project>
  local mini=$1 terminal_id=$2 project=$3 cmd
  cmd="cd ~/code/$project && git fetch origin >/dev/null 2>&1; p=\$(git status --porcelain | wc -l | tr -d ' '); a=\$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo NA); b=\$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo NA); printf '%s\\t%s\\t%s\\n' \"\$p\" \"\$a\" \"\$b\""
  fm_remote_ws_probe "$mini" "$terminal_id" "$cmd" "$RL_PROBE_TIMEOUT"
}

fm_remote_clone_project() {  # <mini> <terminal_id> <project> <origin_url>
  local mini=$1 terminal_id=$2 project=$3 url=$4 out rc
  set +e
  out=$(fm_remote_ws_probe "$mini" "$terminal_id" \
    "mkdir -p ~/code && cd ~/code && [ -d '$project/.git' ] || git clone '$url' '$project'" \
    "$RL_CLONE_TIMEOUT")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || {
    echo "error: clone of $project failed on $mini: $out" >&2
    return 1
  }
  return 0
}

fm_remote_worktree_add() {  # <mini> <terminal_id> <project> <task_id> -> prints worktree path
  local mini=$1 terminal_id=$2 project=$3 task_id=$4 wt out rc
  # shellcheck disable=SC2088 # deliberate: this is remote shell command text sent
  # over the terminal websocket, expanded by the mini's own shell, not this one.
  wt="~/code/.fm-worktrees/$task_id"
  set +e
  out=$(fm_remote_ws_probe "$mini" "$terminal_id" \
    "mkdir -p ~/code/.fm-worktrees && cd ~/code/$project && git worktree add -b fm/$task_id $wt >/dev/null 2>&1 && cd $wt && pwd" \
    "$RL_PROBE_TIMEOUT")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ -n "$out" ] || {
    echo "error: git worktree add failed on $mini for $project/$task_id: $out" >&2
    return 1
  }
  printf '%s\n' "$out" | tail -1
}

fm_remote_start_agent_and_send() {  # <mini> <terminal_id> <worktree_path> <prompt>
  local mini=$1 terminal_id=$2 wt=$3 prompt=$4
  fm_remote_ws_send "$mini" "$terminal_id" \
    "cd $wt && claude"$'\r' \
    $'\r' \
    "$prompt" \
    $'\r' \
    $'\r'
}

# --- state/<id>.meta ---------------------------------------------------

fm_remote_meta_write() {  # <id> <mini> <project> <wid> <tid> <pid> <term> <path>
  local id=$1 mini=$2 project=$3 wid=$4 tid=$5 pid=$6 term=$7 path=$8
  {
    echo "endpoint_task_id=$id"
    echo "backend=remote-bridge"
    echo "kind=ship"
    echo "project=$project"
    echo "remote_mini=$mini"
    echo "remote_workspace_id=$wid"
    echo "remote_tab_id=$tid"
    echo "remote_pane_id=$pid"
    echo "remote_terminal_id=$term"
    echo "remote_project_path=$path"
    echo "label=fm-$id"
  } > "$STATE/$id.meta"
}

# --- landed-work gate (mirrors bin/fm-teardown.sh's own definition, scoped
# down: remote-tracking reachability first, a locally-run `gh` merged-PR
# lookup as fallback for the common squash-merge case) --------------------

fm_remote_pr_merged() {  # <branch> -> 0 if a local `gh` reports a merged PR for this branch
  command -v gh >/dev/null 2>&1 || return 1
  local n
  n=$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null) || return 1
  [ "${n:-0}" -gt 0 ]
}

fm_remote_landed() {  # <mini> <terminal_id> <path> <branch> -> 0 landed / 1 not landed
  local mini=$1 terminal_id=$2 path=$3 branch=$4 out rc porcelain ahead
  set +e
  out=$(fm_remote_ws_probe "$mini" "$terminal_id" \
    "cd $path && git fetch origin >/dev/null 2>&1; p=\$(git status --porcelain | wc -l | tr -d ' '); a=\$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo NA); printf '%s\\t%s\\n' \"\$p\" \"\$a\"" \
    "$RL_PROBE_TIMEOUT")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || {
    echo "error: could not verify landed state for $path on $mini" >&2
    return 1
  }
  porcelain=$(printf '%s' "$out" | tail -1 | cut -f1)
  ahead=$(printf '%s' "$out" | tail -1 | cut -f2)
  if [ "$porcelain" != "0" ]; then
    echo "refusing: $path on $mini has uncommitted changes" >&2
    return 1
  fi
  if [ "$ahead" = "NA" ]; then
    echo "refusing: $path on $mini has no upstream tracking branch (never pushed)" >&2
    return 1
  fi
  if [ "$ahead" != "0" ]; then
    if fm_remote_pr_merged "$branch"; then
      return 0
    fi
    echo "refusing: $path on $mini has $ahead local commit(s) not reachable from any remote-tracking branch and no merged PR found for $branch" >&2
    return 1
  fi
  return 0
}

# --- CLI: spawn ------------------------------------------------------------

cmd_spawn() {
  local mini=${1:-} project=${2:-} id=${3:-}
  [ $# -ge 3 ] || { usage; return 1; }
  shift 3
  local prompt="$*"
  [ -n "$mini" ] && [ -n "$project" ] && [ -n "$id" ] && [ -n "$prompt" ] || { usage; return 1; }
  fm_remote_validate_name "$mini" mini || return 1
  fm_remote_validate_name "$project" project || return 1
  fm_remote_validate_name "$id" task-id || return 1

  if [ -f "$STATE/$id.meta" ]; then
    echo "error: state/$id.meta already exists; refusing to spawn a duplicate remote task for id $id" >&2
    return 1
  fi
  mkdir -p "$STATE"

  echo "fm-remote-launch: checking reachability of $mini..." >&2
  fm_remote_reachable "$mini" || {
    echo "error: mini '$mini' is unreachable via $BRIDGE_URL/api/remote/$mini/snapshot" >&2
    return 1
  }

  local origin_url
  origin_url=$(fm_remote_local_origin_url "$project") || return 1

  echo "fm-remote-launch: creating workspace on $mini..." >&2
  local created wid tid pid term
  created=$(fm_remote_workspace_create "$mini") || return 1
  IFS=$'\t' read -r wid tid pid term <<<"$created"
  [ -n "$wid" ] && [ -n "$pid" ] && [ -n "$term" ] || {
    echo "error: workspace.create on $mini returned an unexpected response: $created" >&2
    return 1
  }

  fm_remote_check_gh_auth "$mini" "$term" || {
    fm_remote_workspace_close "$mini" "$wid" >/dev/null 2>&1 || true
    return 1
  }

  if fm_remote_project_present "$mini" "$term" "$project"; then
    local state porcelain ahead
    state=$(fm_remote_project_clean_state "$mini" "$term" "$project") || {
      fm_remote_workspace_close "$mini" "$wid" >/dev/null 2>&1 || true
      return 1
    }
    porcelain=$(printf '%s' "$state" | tail -1 | cut -f1)
    ahead=$(printf '%s' "$state" | tail -1 | cut -f2)
    if [ "$porcelain" != "0" ] || { [ "$ahead" != "0" ] && [ "$ahead" != "NA" ]; }; then
      echo "error: ~/code/$project on $mini is dirty or has local commits not on its remote-tracking branch; refusing to touch it automatically (mirrors hard rule 3)" >&2
      fm_remote_workspace_close "$mini" "$wid" >/dev/null 2>&1 || true
      return 1
    fi
  else
    echo "fm-remote-launch: $project not present on $mini, cloning $origin_url..." >&2
    fm_remote_clone_project "$mini" "$term" "$project" "$origin_url" || {
      fm_remote_workspace_close "$mini" "$wid" >/dev/null 2>&1 || true
      return 1
    }
  fi

  local wt
  wt=$(fm_remote_worktree_add "$mini" "$term" "$project" "$id") || {
    fm_remote_workspace_close "$mini" "$wid" >/dev/null 2>&1 || true
    return 1
  }

  echo "fm-remote-launch: starting agent on $mini..." >&2
  fm_remote_start_agent_and_send "$mini" "$term" "$wt" "$prompt" || {
    fm_remote_workspace_close "$mini" "$wid" >/dev/null 2>&1 || true
    return 1
  }

  fm_remote_workspace_rename "$mini" "$wid" "fm-$id" \
    || echo "warning: could not rename workspace to fm-$id (non-fatal)" >&2

  fm_remote_meta_write "$id" "$mini" "$project" "$wid" "$tid" "$pid" "$term" "$wt"
  echo "done: launched task $id on mini $mini (workspace $wid, pane $pid) at $wt"
}

# --- CLI: reclaim ------------------------------------------------------------

cmd_reclaim() {
  local id=${1:-} force=${2:-}
  [ -n "$id" ] || { usage; return 1; }
  local meta="$STATE/$id.meta"
  [ -f "$meta" ] || {
    echo "error: no state/$id.meta found for task $id" >&2
    return 1
  }
  local backend mini wid term path
  backend=$(fm_remote_meta_get "$meta" backend)
  [ "$backend" = remote-bridge ] || {
    echo "error: task $id is not a remote-bridge task (backend=$backend)" >&2
    return 1
  }
  mini=$(fm_remote_meta_get "$meta" remote_mini)
  wid=$(fm_remote_meta_get "$meta" remote_workspace_id)
  term=$(fm_remote_meta_get "$meta" remote_terminal_id)
  path=$(fm_remote_meta_get "$meta" remote_project_path)

  fm_remote_reachable "$mini" || {
    echo "error: mini '$mini' is unreachable; cannot verify landed work, refusing to close workspace $wid" >&2
    return 1
  }

  if [ "$force" = "--force" ]; then
    echo "warning: --force reclaiming task $id without a landed-work check" >&2
  else
    fm_remote_landed "$mini" "$term" "$path" "fm/$id" || {
      echo "error: task $id's work on $mini is not confirmed landed; refusing to close workspace $wid (pass --force only with explicit captain-authorized discard)" >&2
      return 1
    }
  fi

  fm_remote_workspace_close "$mini" "$wid" || {
    echo "error: workspace.close failed for $wid on $mini" >&2
    return 1
  }
  mv "$meta" "$meta.reclaimed"
  echo "done: reclaimed task $id (workspace $wid on $mini closed)"
}

# --- CLI: reconcile ------------------------------------------------------------

# Never sweeps a mini's full workspace list for anything unrecognized - only
# checks the specific ids THIS home already recorded in state/*.meta
# (AGENTS.md section 5's "reconcile only this home's recorded direct
# reports"). A recorded pane missing from the snapshot is left alone and
# surfaced, never auto-reclaimed.
cmd_reconcile() {
  local f id mini wid pid label snap found
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    [ "$(fm_remote_meta_get "$f" backend)" = remote-bridge ] || continue
    id=$(basename "$f" .meta)
    mini=$(fm_remote_meta_get "$f" remote_mini)
    wid=$(fm_remote_meta_get "$f" remote_workspace_id)
    pid=$(fm_remote_meta_get "$f" remote_pane_id)
    label=$(fm_remote_meta_get "$f" label)
    if ! fm_remote_reachable "$mini"; then
      echo "stale: $id -> mini $mini unreachable"
      continue
    fi
    snap=$(fm_remote_snapshot "$mini") || {
      echo "stale: $id -> snapshot read failed on $mini"
      continue
    }
    found=$(printf '%s' "$snap" | jq -r --arg pid "$pid" '[.. | objects | select(.pane_id? == $pid)] | length' 2>/dev/null || echo 0)
    if [ "${found:-0}" -gt 0 ]; then
      echo "ok: $id -> pane $pid present on $mini (workspace $wid, label $label)"
    else
      echo "missing: $id -> recorded pane $pid not found on $mini snapshot (left for manual triage, never auto-reclaimed)"
    fi
  done
}

# --- CLI: status ------------------------------------------------------------

cmd_status() {
  local id=${1:-} meta
  [ -n "$id" ] || { usage; return 1; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || {
    echo "error: no state/$id.meta found for task $id" >&2
    return 1
  }
  cat "$meta"
  local mini pid
  mini=$(fm_remote_meta_get "$meta" remote_mini)
  pid=$(fm_remote_meta_get "$meta" remote_pane_id)
  if fm_remote_reachable "$mini"; then
    fm_remote_snapshot "$mini" | jq --arg pid "$pid" '[.. | objects | select(.pane_id? == $pid)] | first // {}'
  else
    echo "mini $mini unreachable" >&2
  fi
}

# --- dispatch ------------------------------------------------------------

main() {
  local sub=${1:-}
  case "$sub" in
    reclaim)
      shift
      cmd_reclaim "$@"
      ;;
    reconcile)
      shift
      cmd_reconcile "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      cmd_spawn "$@"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  trap '[ -n "${RL_TMP:-}" ] && rm -rf "$RL_TMP"' EXIT
  main "$@"
fi
