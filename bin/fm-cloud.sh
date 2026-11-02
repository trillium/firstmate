#!/usr/bin/env bash
# fm-cloud.sh - the default command for Claude Code cloud runs: launch one from
# the command line, track it in a durable local record, poll its result branch,
# and retire the record.
#
# Usage:
#   fm-cloud.sh launch [--file <prompt-file>] [--environment <id>] [--repo <dir>]
#                      [--branch <name>] [--] [<prompt>...]
#   fm-cloud.sh launch --task <task-id> [--repo <dir>] [--environment <id>]
#                      [--mode <mode>] [--yolo on|off]
#   fm-cloud.sh status [<run-id>]
#   fm-cloud.sh list
#   fm-cloud.sh cleanup <run-id>
#   fm-cloud.sh check <task-id>
#   fm-cloud.sh land <task-id>
#   fm-cloud.sh teardown <task-id> [--force]
#   fm-cloud.sh continue [--resolve-key <key>]... <task-id> <text>
#   fm-cloud.sh credit
#   fm-cloud.sh doctor
#
# launch runs `claude --cloud <prompt>` from --repo (default: the current
# directory), passing --environment through when given, and records the run as
# state/cloud-runs/<run-id>.run (key=value lines, one record per run): the
# session id and url parsed from the CLI's output, the repo and its remote, the
# base branch, the expected result namespace (claude/*), the claude/* branch
# heads that already existed at launch, and the prompt's length and sha256.
# claude needs a terminal for --cloud, so it runs under script(1); its output is
# parsed from a private log that is deleted afterwards, and a branch-ahead
# warning from claude is repeated. The prompt text itself is never stored or printed. --branch is recorded as the
# base branch and nothing else: this tool does not switch branches.
#
# status polls the recorded remote (the branch's upstream remote, else origin,
# never the no-mistakes gate remote) with `git ls-remote --heads` and prints each
# claude/* branch that is new or moved since launch; it reads only branch names
# and commit ids. list prints one line per recorded run without touching the
# network.
#
# launch --task makes the run an ordinary firstmate dispatch: the prompt is
# data/<task-id>/brief.md (the scaffold bin/fm-brief.sh writes) plus a short
# cloud trailer (work on claude/<task-id>, push it, open a PR against the default
# branch, no secrets). It refuses before launching when the task has no backlog
# item or already has a record, then publishes state/<task-id>.meta (backend=cloud,
# no worktree; cloud_run, cloud_session and cloud_url link the run), moves the
# backlog item to In flight with bin/fm-backlog-transition-lib.sh, appends a
# working status line carrying the session url, and registers
# state/<task-id>.check.sh (bin/fm-check-register.sh) so the watcher runs `check`.
#
# check <task-id> is what that script runs. It prints one line, and only when
# firstmate should wake: a claude/* branch is new or moved since launch, a PR for
# it appears, or the run is silent past the time limit (config/cloud-timeout in
# minutes, default 240; the line says possibly stuck and names the session url).
# Each distinct result is reported once.
#
# land <task-id> finds the run's PR and hands it to bin/fm-pr-check.sh, which
# replaces the check with the ordinary merge poll; from there merge, cleanup and
# teardown are the direct-PR path.
#
# teardown <task-id> is what bin/fm-teardown.sh runs for a backend=cloud task. It
# refuses unless the recorded PR is merged (--force discards an unlanded run),
# then retires the check, PR poll, run record and task record and closes the
# backlog item.
#
# Worker -> firstmate: the cloud trailer tells the worker to append local-grammar
# status lines (`<state> [at=<epoch>]: <text>`, grammar owned by
# bin/fm-classify-lib.sh) to .fm-cloud/status on claude/<task-id> and push after
# each one. check fetches that branch into a private bare repository under
# state/cloud-runs (the project clone is never written) and emits each new line
# once as a wake line, also appending it to state/<task-id>.status so a
# needs-decision or blocked opens a decision exactly as a local worker's does.
# Only the verbs working, blocked, needs-decision, paused, done, failed and
# resolved are taken; lines are control-stripped and capped. The file is kept out
# of the PR diff by the worker's LAST commit, `git rm .fm-cloud/status`; check
# reads the newest commit that still carried the file, so that deletion does not
# hide the final done: line. Side-ref alternative not used: the worker would need
# a second branch to push.
#
# Firstmate -> worker: the installed claude CLI has no non-interactive send to an
# existing cloud session (--cloud <session_id> attaches a terminal), so `continue`
# launches a follow-up cloud run on the same claude/<task-id> branch carrying the
# brief, the steer and the prior status lines, and records it against the same
# task (meta cloud_run/cloud_session/cloud_url move to the new run; the old run
# record is retired). bin/fm-send.sh routes a backend=cloud task here, and its
# --resolve-key closes the named decision. Replies arrive through the status file.
#
# credit reads config/cloud-credit (amount=<usd> and expires=<YYYY-MM-DD>) and
# reports the days remaining and the runs launched; doctor prints the same line.
# It also reports runs per task, runs per UTC day, and wall time per run from
# launch to the last status line, branch move or PR sighting. The dollar balance
# has no CLI or API: it is read on claude.ai, and this tool never reports dollars
# spent.
#
# cleanup retires a run record and PRINTS the web-only steps that remain; it
# performs none of them. A run still bound to a task is torn down with teardown. The steps are owned by runbooks-e8k (the
# cloud-environment settings and the Tailscale key have no CLI).
#
# doctor reports whether the claude CLI is present and supports --cloud,
# --environment, and --teleport, and lists what still needs the web UI.
#
# Hard rules: this script never prints, logs, or stores an auth key, token, or
# environment value, never drives a browser, never touches Tailscale or
# claude.ai settings, and never creates a Codespace.
#
# Environment: FM_HOME and FM_STATE_OVERRIDE resolve the home like the other
# bin/ scripts. Exit: 0 ok, 1 operational failure, 2 usage error.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RUNS="$STATE/cloud-runs"
LAUNCH_LEDGER="$RUNS/.launched"
ACTIVITY_LEDGER="$RUNS/.activity"

die() { printf 'fm-cloud: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'fm-cloud: %s\n' "$*" >&2; sed -n '6,19p' "${BASH_SOURCE[0]}" >&2; exit 2; }

valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac; }

rec_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

rec_set() {  # <file> <key> <value>: replace or add one key=value line
  local f=$1 k=$2 v=$3 tmp
  tmp="$f.tmp.$$"
  { grep -v "^$k=" "$f" || true; printf '%s=%s\n' "$k" "$v"; } > "$tmp" && mv "$tmp" "$f"
}

epoch_date() {  # <epoch> -> YYYY-MM-DD (UTC)
  date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F 2>/dev/null || printf 'unknown'
}

# Record that a run did something observable (status line, branch move, PR): the
# run record's last_activity_at and an append-only ledger that outlives teardown,
# so the credit report can show wall time per run after the record is gone.
note_activity() {  # <run-id> <epoch>
  local run=$1 at=$2
  [ ! -f "$RUNS/$run.run" ] || rec_set "$RUNS/$run.run" last_activity_at "$at"
  printf '%s %s\n' "$run" "$at" >> "$ACTIVITY_LEDGER"
}

rec_path() {  # <run-id>
  valid_id "$1" || usage_die "invalid run id: $1"
  [ -f "$RUNS/$1.run" ] || die "no such run record: $1"
  printf '%s\n' "$RUNS/$1.run"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

# Libraries for the task-bound commands; plain launch and status need none.
load_task_libs() {
  [ -z "${_FM_CLOUD_LIBS:-}" ] || return 0
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SELF_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SELF_DIR/fm-backlog-transition-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SELF_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SELF_DIR/fm-classify-lib.sh"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SELF_DIR/fm-pr-lib.sh"
  _FM_CLOUD_LIBS=1
}

# A task's cloud trailer: where the work lands and what it must never contain.
cloud_trailer() {  # <task-id> <base-branch>
  printf '\n\n---\nCloud run: work on a branch named claude/%s, push it, and open a pull request against %s.\n' "$1" "${2:-the default branch}"
  printf 'Put no secrets, tokens or credentials in the branch, the pull request or its description.\n'
  cloud_status_trailer "$1"
}

# The worker -> firstmate channel. A cloud worker cannot write firstmate's status
# file, so it appends the same status lines a local worker would (grammar owned by
# bin/fm-classify-lib.sh) to .fm-cloud/status on its branch and pushes after each
# one; `fm-cloud.sh check` reads them back.
cloud_status_trailer() {  # <task-id>
  printf '\nStatus channel: firstmate cannot see your session, so report by appending one line to .fm-cloud/status on branch claude/%s and pushing that branch right after each append.\n' "$1"
  # shellcheck disable=SC2016  # backticks are literal prompt text
  printf 'Line format: <state> [at=<epoch>]: <one short line>, where <epoch> is the number printed by `date +%%s` and <state> is one of working, needs-decision, blocked, paused, done, failed.\n'
  printf 'Be sparse: working lines only for real milestones (setup done, fix implemented, validation passed). Use blocked: or needs-decision: with the exact question and then stop and wait; a follow-up run will deliver the answer. Never put secrets in a line.\n'
  # shellcheck disable=SC2016  # backticks are literal prompt text
  printf 'Finish in this order: open the pull request, append `done [at=<epoch>]: PR <full https url>` and push, then make your LAST commit `git rm .fm-cloud/status` and push, so the file is not in the pull request diff.\n'
}

# config/cloud-timeout: minutes of silence before a run reports as possibly stuck.
cloud_timeout_minutes() {
  local v=""
  [ ! -f "$CONFIG/cloud-timeout" ] || v=$(tr -d '[:space:]' < "$CONFIG/cloud-timeout")
  case "$v" in ''|*[!0-9]*) v=${FM_CLOUD_TIMEOUT_MINUTES:-240} ;; esac
  case "$v" in ''|*[!0-9]*) v=240 ;; esac
  printf '%s\n' "$v"
}

# <owner>/<repo> for a github.com remote url, else nothing.
github_slug() {  # <remote-url>
  printf '%s\n' "$1" | sed -En 's#^(https?://|ssh://)?(git@)?github\.com[:/]([^/]+/[^/]+)$#\3#p' | sed 's#\.git$##' | head -n 1
}

# The PR number of a claude/* branch via gh-axi, or nothing.
pr_number_for_branch() {  # <slug> <branch>
  local out
  command -v gh-axi >/dev/null 2>&1 || return 0
  out=$(gh-axi pr list --repo "$1" --state all --head "$2" --limit 1 2>/dev/null) || return 0
  printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -n 1
}

# The run's result branch: new or moved claude/* heads since launch, preferring
# the claude/<task-id>* name the trailer asked for. Prints "<ref> <sha>" or nothing;
# returns 1 when the remote cannot be read.
run_result_branch() {  # <record-file> <task-id>
  local f=$1 task=$2 repo remote before now sha ref first="" want=""
  repo=$(rec_get "$f" repo); remote=$(rec_get "$f" remote); before=$(rec_get "$f" heads_before)
  now=$(git -C "$repo" ls-remote --heads "$remote" 'refs/heads/claude/*' 2>/dev/null) || return 1
  while read -r sha ref; do
    [ -n "$ref" ] || continue
    case ",$before," in *",$sha:$ref,"*) continue ;; esac
    ref=${ref#refs/heads/}
    [ -n "$first" ] || first="$ref $sha"
    case "$ref" in "claude/$task"*) [ -n "$want" ] || want="$ref $sha" ;; esac
  done <<< "$now"
  printf '%s\n' "${want:-$first}"
}

# Run `claude --cloud <prompt>` from <repo> under a pseudo-terminal and parse its
# output into CLOUD_URL, CLOUD_SESSION and CLOUD_WARN. The prompt is never
# printed; the private log is removed afterwards.
claude_cloud_run() {  # <repo> <prompt> [<environment>]
  local repo=$1 prompt=$2 env_id=${3:-}
  local args=(--cloud "$prompt")
  [ -z "$env_id" ] || args+=(--environment "$env_id")
  # claude refuses --cloud without a terminal, so run it under a pseudo-terminal
  # with its output in a private log that is removed afterwards.
  local log out rc=0
  log=$(mktemp "${TMPDIR:-/tmp}/fm-cloud.XXXXXX") || die "cannot create a temporary log"
  chmod 600 "$log"
  if [ "$(uname -s)" = Darwin ]; then
    (cd "$repo" && script -q "$log" claude "${args[@]}" </dev/null >/dev/null 2>&1) || rc=$?
  else
    local cmdline
    cmdline=$(printf '%q ' claude "${args[@]}")
    (cd "$repo" && script -qec "$cmdline" "$log" </dev/null >/dev/null 2>&1) || rc=$?
  fi
  out=$(LC_ALL=C sed -e $'s/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' -e 's/\r//g' "$log" 2>/dev/null || true)
  rm -f "$log"
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" | tail -n 5 >&2; die "claude --cloud failed (exit $rc)"; }
  if printf '%s\n' "$out" | grep -q 'requires an interactive terminal'; then
    die "claude refused --cloud: no terminal available"
  fi
  CLOUD_WARN=$(printf '%s\n' "$out" | grep -E 'commits? ahead of' | head -n 1 || true)
  CLOUD_URL=$(printf '%s\n' "$out" | grep -Eo 'https://claude\.ai/code/[A-Za-z0-9_./-]+' | head -n 1 || true)
  CLOUD_SESSION=$(printf '%s\n' "$CLOUD_URL" | sed -n 's#.*/\(session_[A-Za-z0-9_]*\).*#\1#p' | head -n 1)
  [ -n "$CLOUD_SESSION" ] || CLOUD_SESSION=$(printf '%s\n' "$out" | grep -Eo 'claude --teleport session_[A-Za-z0-9]+' | grep -Eo 'session_[A-Za-z0-9]+' | head -n 1 || true)
  [ -n "$CLOUD_SESSION" ] || CLOUD_SESSION=$(printf '%s\n' "$out" | grep -Eo 'session_[A-Za-z0-9]+' | head -n 1 || true)
  return 0
}

cmd_launch() {
  local file="" env_id="" repo="" branch="" prompt="" task="" mode="" yolo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || usage_die "--task needs a value"; task=$2; shift 2 ;;
      --mode) [ $# -ge 2 ] || usage_die "--mode needs a value"; mode=$2; shift 2 ;;
      --yolo) [ $# -ge 2 ] || usage_die "--yolo needs a value"; yolo=$2; shift 2 ;;
      --file) [ $# -ge 2 ] || usage_die "--file needs a value"; file=$2; shift 2 ;;
      --environment) [ $# -ge 2 ] || usage_die "--environment needs a value"; env_id=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || usage_die "--repo needs a value"; repo=$2; shift 2 ;;
      --branch) [ $# -ge 2 ] || usage_die "--branch needs a value"; branch=$2; shift 2 ;;
      --) shift; break ;;
      -*) usage_die "unknown launch option: $1" ;;
      *) break ;;
    esac
  done
  if [ -n "$task" ]; then
    [ -z "$file" ] && [ $# -eq 0 ] || usage_die "--task supplies the prompt; give no prompt argument or --file"
    valid_id "$task" || usage_die "invalid task id: $task"
    case "$mode" in ''|direct-PR) mode=direct-PR ;; *) usage_die "a cloud run delivers by direct-PR; --mode $mode is not supported" ;; esac
    case "$yolo" in ''|on|off) ;; *) usage_die "--yolo takes on or off" ;; esac
  else
    [ -z "$mode$yolo" ] || usage_die "--mode and --yolo apply to --task launches"
    if [ -n "$file" ]; then
      [ $# -eq 0 ] || usage_die "give a prompt argument or --file, not both"
      [ -f "$file" ] || die "prompt file not found: $file"
      prompt=$(cat "$file")
    else
      prompt="$*"
    fi
    [ -n "$prompt" ] || usage_die "launch needs a prompt argument or --file"
  fi
  command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH (run: fm-cloud.sh doctor)"
  repo=${repo:-$PWD}
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git repository: $repo"
  repo=$(git -C "$repo" rev-parse --show-toplevel)
  local backlog_transition=0 default_branch=""
  if [ -n "$task" ]; then
    load_task_libs
    [ -f "$DATA/$task/brief.md" ] || die "task $task has no brief at $DATA/$task/brief.md (write it with bin/fm-brief.sh first)"
    [ ! -e "$STATE/$task.meta" ] && [ ! -L "$STATE/$task.meta" ] || die "task $task already has a record at $STATE/$task.meta; refusing a second launch"
    [ ! -e "$STATE/$task.backlog-close" ] || die "task $task has a pending backlog close; finish it before launching"
    # Prove the row is transitionable BEFORE anything is launched, as fm-spawn does.
    local gate=0 row_state
    fm_backlog_transition_applies "$CONFIG" "$DATA" ship || gate=$?
    if [ "$gate" -eq 0 ]; then
      backlog_transition=1
      if fm_backlog_row_probe "$DATA" "$task"; then
        row_state=$FM_BACKLOG_ROW_STATE
      elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
        die "task $task has no backlog item in this home, so dispatching it would leave a run no record owns; add it first (bin/fm-tasks-axi.sh add $task '<title>') and re-run"
      else
        die "task $task's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)"
      fi
      fm_backlog_row_dispatchable "$row_state" || die "backlog item $task is not dispatchable in state $row_state; refusing to launch"
    elif [ "$gate" -eq 2 ]; then
      die "task $task cannot be dispatched because its backlog is unavailable ($FM_BACKLOG_TRANSITION_ERROR)"
    fi
    if [ -z "$yolo" ]; then
      yolo=$("$SELF_DIR/fm-project-mode.sh" "$(basename "$repo")" 2>/dev/null | awk '{print $2}' || true)
      [ "$yolo" = on ] || yolo=off
    fi
    default_branch=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    prompt="$(cat "$DATA/$task/brief.md")$(cloud_trailer "$task" "${default_branch:-the default branch}")"
  fi
  local remote_name remote_url base before
  # Cloud sessions push to the forge, so poll the branch's upstream remote, else
  # origin, else any remote - never the no-mistakes gate remote.
  local cur_branch
  cur_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  remote_name=$(git -C "$repo" config "branch.$cur_branch.remote" 2>/dev/null || true)
  if [ -z "$remote_name" ] || [ "$remote_name" = no-mistakes ] || [ "$remote_name" = . ]; then
    if git -C "$repo" remote | grep -qx origin; then remote_name=origin
    else remote_name=$(git -C "$repo" remote | grep -vx no-mistakes | head -n 1 || true); fi
  fi
  [ -n "$remote_name" ] || die "repository has no remote to poll for the result branch: $repo"
  remote_url=$(git -C "$repo" remote get-url "$remote_name")
  # A remote URL may embed credentials; keep only its host and path.
  remote_url=$(printf '%s' "$remote_url" | sed -E 's#^([a-z+]+://)[^@/]*@#\1#')
  base=${branch:-$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}
  before=$(git -C "$repo" ls-remote --heads "$remote_name" 'refs/heads/claude/*' 2>/dev/null \
    | awk '{print $1":"$2}' | paste -sd, - || true)

  local warn url session
  claude_cloud_run "$repo" "$prompt" "$env_id"
  warn=$CLOUD_WARN; url=$CLOUD_URL; session=$CLOUD_SESSION

  local id now
  now=$(date +%s)
  id="cloud-$now-$$"
  mkdir -p "$RUNS"
  {
    printf 'id=%s\n' "$id"
    printf 'launched_at=%s\n' "$now"
    printf 'session=%s\n' "$session"
    printf 'url=%s\n' "$url"
    printf 'environment=%s\n' "$env_id"
    printf 'repo=%s\n' "$repo"
    printf 'remote=%s\n' "$remote_name"
    printf 'remote_url=%s\n' "$remote_url"
    printf 'base_branch=%s\n' "$base"
    printf 'result_branch=claude/*\n'
    printf 'heads_before=%s\n' "$before"
    printf 'prompt_bytes=%s\n' "$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
    printf 'prompt_sha256=%s\n' "$(printf '%s' "$prompt" | sha256_of)"
    [ -z "$task" ] || printf 'task=%s\n' "$task"
  } > "$RUNS/$id.run"
  printf '%s %s %s\n' "$id" "$now" "${task:--}" >> "$LAUNCH_LEDGER"
  printf 'run: %s\n' "$id"
  printf 'session: %s\n' "${session:-unknown}"
  printf 'url: %s\n' "${url:-unknown}"
  printf 'result: claude/* branch on %s (poll: fm-cloud.sh status %s)\n' "$remote_name" "$id"
  [ -z "$warn" ] || printf 'warning: %s\n' "$warn"
  [ -n "$session" ] || printf 'note: no session id found in the claude output; the run is recorded without one\n'
  if [ -n "$task" ]; then
    bind_task "$task" "$id" "$session" "$url" "$repo" "$mode" "$yolo" "$backlog_transition"
    printf 'task: %s (in flight; check armed, wakes firstmate on a branch, PR or %s minutes of silence)\n' "$task" "$(cloud_timeout_minutes)"
  fi
  return 0
}

# Publish the task record for a launched run, move the backlog item to In flight,
# note the session on the status log, and arm the finish check. The run is
# already launched, so a failure here keeps the run record and says what to repair.
bind_task() {  # <task> <run-id> <session> <url> <repo> <mode> <yolo> <backlog-transition>
  local task=$1 run=$2 session=$3 url=$4 repo=$5 mode=$6 yolo=$7 transition=$8
  local gen tmp lock check
  gen="s$(date +%s).$$.$RANDOM"
  tmp="$STATE/.$task.meta.spawn.$$"
  lock=$(fm_meta_lock_path "$STATE/$task.meta") || die "cannot resolve the task record lock"
  fm_lock_acquire_wait "$lock"
  {
    echo "endpoint_task_id=$task"
    echo "project=$repo"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=$mode"
    echo "yolo=$yolo"
    echo "branch=claude/$task"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=$gen"
    echo "backend=cloud"
    echo "cloud_run=$run"
    echo "cloud_session=$session"
    echo "cloud_url=$url"
  } > "$tmp" || { fm_lock_release "$lock"; die "task record for $task could not be prepared; run $run is launched and recorded, repair by hand"; }
  if ! fm_backlog_atomic_transition publish "$tmp" "$STATE/$task.meta" "task record" "$STATE"; then
    rm -f "$tmp"; fm_lock_release "$lock"
    die "task record for $task could not be published ($FM_BACKLOG_TRANSITION_ERROR); run $run is launched and recorded"
  fi
  if [ "$transition" = 1 ] && ! fm_backlog_atomic_transition dispatch "$STATE/$task.meta" "$DATA" "$task" "$STATE"; then
    fm_backlog_record_remove "$STATE/$task.meta" "provisional task record" "$STATE" || true
    fm_lock_release "$lock"
    die "backlog item $task could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); run $run is launched and recorded, so bind it by hand"
  fi
  fm_lock_release "$lock"
  printf 'working [at=%s]: cloud run launched, session %s\n' "$(date +%s)" "${url:-${session:-unknown}}" >> "$STATE/$task.status"
  check="$STATE/$task.check.sh"
  {
    echo '#!/usr/bin/env bash'
    printf 'FM_HOME=%q FM_STATE_OVERRIDE=%q FM_DATA_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q exec %q check %q\n' \
      "$FM_HOME" "$STATE" "$DATA" "$CONFIG" "$SELF_DIR/fm-cloud.sh" "$task"
  } > "$check"
  chmod 0700 "$check"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SELF_DIR/fm-check-register.sh" "$task" >/dev/null \
    || die "run $run is bound to task $task but its finish check could not be registered; run: fm-cloud.sh status $run"
}

cmd_list() {
  local f any=0
  [ -d "$RUNS" ] || { printf 'no cloud runs recorded\n'; return 0; }
  for f in "$RUNS"/*.run; do
    [ -e "$f" ] || continue
    any=1
    printf '%s session=%s environment=%s base=%s url=%s task=%s\n' \
      "$(rec_get "$f" id)" "$(rec_get "$f" session)" "$(rec_get "$f" environment)" \
      "$(rec_get "$f" base_branch)" "$(rec_get "$f" url)" "$(rec_get "$f" task)"
  done
  [ "$any" -eq 1 ] || printf 'no cloud runs recorded\n'
}

status_one() {  # <record-file>
  local f=$1 repo remote before now sha ref found=0
  repo=$(rec_get "$f" repo); remote=$(rec_get "$f" remote); before=$(rec_get "$f" heads_before)
  printf 'run: %s\nsession: %s\nurl: %s\nresult: %s on %s\n' "$(rec_get "$f" id)" \
    "$(rec_get "$f" session)" "$(rec_get "$f" url)" "$(rec_get "$f" result_branch)" "$remote"
  if ! now=$(git -C "$repo" ls-remote --heads "$remote" 'refs/heads/claude/*' 2>/dev/null); then
    printf 'poll: failed (remote unreachable)\n'; return 0
  fi
  while read -r sha ref; do
    [ -n "$ref" ] || continue
    case ",$before," in *",$sha:$ref,"*) continue ;; esac
    found=1
    printf 'branch: %s %s\n' "${ref#refs/heads/}" "$sha"
  done <<< "$now"
  [ "$found" -eq 1 ] || printf 'branch: none yet\n'
  return 0
}

cmd_status() {
  local f any=0
  if [ $# -ge 1 ]; then
    status_one "$(rec_path "$1")"; return 0
  fi
  [ -d "$RUNS" ] || { printf 'no cloud runs recorded\n'; return 0; }
  for f in "$RUNS"/*.run; do
    [ -e "$f" ] || continue
    any=1; status_one "$f"; printf '\n'
  done
  [ "$any" -eq 1 ] || printf 'no cloud runs recorded\n'
}

cmd_cleanup() {
  [ $# -eq 1 ] || usage_die "cleanup needs exactly one run id"
  local f
  f=$(rec_path "$1")
  local bound
  bound=$(rec_get "$f" task)
  if [ -n "$bound" ] && [ -f "$STATE/$bound.meta" ]; then
    die "run $1 is bound to task $bound; retire it with: bin/fm-cloud.sh teardown $bound"
  fi
  if [ -n "$bound" ]; then
    rm -f "$STATE/$bound.check.sh" "$STATE/$bound.check-trust"
  fi
  rm -f "$f" "${f%.run}.seen" "${f%.run}.stuck"
  printf 'retired run record: %s\n' "$1"
  cat <<'WEB'
web-only steps (this tool performs none of them; runbook: runbooks-e8k):
  1. remove TS_AUTHKEY from the cloud environment
  2. revoke the Tailscale auth key
  3. restore the environment's network access to its normal setting
WEB
}

# The run bound to a task: prints the record path, or dies.
task_run_record() {  # <task-id>
  local task=$1 meta run
  valid_id "$task" || usage_die "invalid task id: $task"
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || die "no task record for $task"
  [ "$(rec_get "$meta" backend)" = cloud ] || die "task $task is not a cloud run"
  run=$(rec_get "$meta" cloud_run)
  rec_path "$run"
}

# The worker's status file from its branch. The file is deleted by the worker's
# last commit, so it is read from the newest commit that still had it, in a private
# bare repository under state/cloud-runs (the project clone is never written).
# Prints the file's text; returns 1 when the remote cannot be read. A branch
# without the file prints nothing.
branch_status_text() {  # <record-file> <task-id>
  local f=$1 task=$2 repo remote url ref sha cache seen_sha c
  repo=$(rec_get "$f" repo); remote=$(rec_get "$f" remote)
  ref="refs/heads/claude/$task"
  sha=$(git -C "$repo" ls-remote --heads "$remote" "$ref" 2>/dev/null | awk 'NR==1{print $1}') || return 1
  [ -n "$sha" ] || return 0
  cache="$RUNS/$task.statusrepo"
  seen_sha=""
  [ ! -f "$cache.sha" ] || seen_sha=$(cat "$cache.sha")
  if [ "$sha" != "$seen_sha" ] || [ ! -d "$cache" ]; then
    [ -d "$cache" ] || git init -q --bare "$cache" 2>/dev/null || return 1
    url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null) || return 1
    git --git-dir="$cache" fetch -q --no-tags "$url" "+$ref:refs/heads/status" 2>/dev/null || return 1
    printf '%s\n' "$sha" > "$cache.sha"
  fi
  c=$(git --git-dir="$cache" log -1 --format=%H --diff-filter=AM refs/heads/status -- .fm-cloud/status 2>/dev/null || true)
  [ -n "$c" ] || return 0
  git --git-dir="$cache" show "$c:.fm-cloud/status" 2>/dev/null || true
}

# Emit each status line the worker has pushed since the last check, once. Only
# lines in the local grammar's verbs are taken (the file is worker-written data):
# they are control-stripped, capped, stamped when untagged, appended to the task's
# status log exactly as a local worker's line would be (so a needs-decision opens a
# decision there), and printed as a wake line.
ingest_cloud_status() {  # <task-id> <record-file> <run-id>
  local task=$1 f=$2 run=$3 text n done_n line verb out last_at=""
  local status="$STATE/$task.status" cnt="$RUNS/$task.statuslines"
  text=$(branch_status_text "$f" "$task") || return 0
  [ -n "$text" ] || return 0
  n=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
  done_n=0
  [ ! -f "$cnt" ] || done_n=$(cat "$cnt")
  case "$done_n" in ''|*[!0-9]*) done_n=0 ;; esac
  [ "$n" -ge "$done_n" ] || done_n=0  # a rewritten file: prefer a duplicate to a lost line
  [ "$n" -gt "$done_n" ] || return 0
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr '\r\t' '  ' | LC_ALL=C tr -d '\000-\037\177')
    line=${line:0:600}
    case "$line" in *:*) ;; *) continue ;; esac
    verb=$(status_line_verb "$line")
    case "$verb" in working|blocked|needs-decision|paused|done|failed|resolved) ;; *) continue ;; esac
    line=$(status_stamp_line "$line")
    printf '%s\n' "$line" >> "$status"
    out=$line
    printf 'cloud run %s: %s\n' "$task" "$out"
    last_at=$(status_line_at_epoch "$line" || true)
  done < <(printf '%s\n' "$text" | tail -n +$((done_n + 1)))
  printf '%s\n' "$n" > "$cnt"
  note_activity "$run" "${last_at:-$(date +%s)}"
}

# What the watcher runs for a cloud task: print one line only when firstmate
# should wake, and never fail (a silent check is a quiet one).
cmd_check() {
  [ $# -eq 1 ] || usage_die "check needs exactly one task id"
  local task=$1 meta f ref sha branch slug n url sig seen age limit url_s
  valid_id "$task" || usage_die "invalid task id: $task"
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 0
  [ -z "$(rec_get "$meta" pr)" ] || return 0  # the PR poll owns the task now
  f="$RUNS/$(rec_get "$meta" cloud_run).run"
  [ -f "$f" ] || return 0
  url_s=$(rec_get "$f" url)
  load_task_libs
  ingest_cloud_status "$task" "$f" "$(rec_get "$meta" cloud_run)"
  if ! branch=$(run_result_branch "$f" "$task"); then
    return 0  # remote unreachable: say nothing, try again next poll
  fi
  if [ -n "$branch" ]; then
    ref=${branch% *}; sha=${branch#* }
    slug=$(github_slug "$(rec_get "$f" remote_url)")
    n=""
    [ -z "$slug" ] || n=$(pr_number_for_branch "$slug" "$ref")
    sig="$ref:$sha:${n:-nopr}"
    seen=""
    [ ! -f "$RUNS/$(rec_get "$meta" cloud_run).seen" ] || seen=$(cat "$RUNS/$(rec_get "$meta" cloud_run).seen")
    [ "$sig" != "$seen" ] || return 0
    printf '%s\n' "$sig" > "$RUNS/$(rec_get "$meta" cloud_run).seen"
    note_activity "$(rec_get "$meta" cloud_run)" "$(date +%s)"
    if [ -n "$n" ]; then
      printf 'cloud run %s: PR https://github.com/%s/pull/%s opened from %s - hand it to the landing path with: bin/fm-cloud.sh land %s (session %s)\n' \
        "$task" "$slug" "$n" "$ref" "$task" "${url_s:-unknown}"
    else
      printf 'cloud run %s: branch %s pushed, no PR yet (session %s)\n' "$task" "$ref" "${url_s:-unknown}"
    fi
    return 0
  fi
  local since
  since=$(rec_get "$f" last_activity_at)
  case "$since" in ''|*[!0-9]*) since=$(rec_get "$f" launched_at) ;; esac
  age=$(( $(date +%s) - since ))
  limit=$(( $(cloud_timeout_minutes) * 60 ))
  if [ "$age" -ge "$limit" ] && [ ! -e "$RUNS/$(rec_get "$meta" cloud_run).stuck" ]; then
    : > "$RUNS/$(rec_get "$meta" cloud_run).stuck"
    printf 'cloud run %s: no branch or PR after %s minutes, possibly stuck - check the session %s\n' \
      "$task" "$(( age / 60 ))" "${url_s:-unknown}"
  fi
  return 0
}

# Steer a cloud worker. The installed claude CLI has no non-interactive way to
# message an existing cloud session (--cloud <session_id> only attaches a
# terminal), so a steer launches a follow-up cloud run on the SAME claude/<task>
# branch: the brief, the steer, and the worker's prior status file, recorded
# against the same task. The previous run record is retired; the launch and
# activity ledgers keep its history for `credit`.
cmd_continue() {
  local task="" text="" keys="" k
  while [ $# -gt 0 ]; do
    case "$1" in
      --resolve-key) [ $# -ge 2 ] || usage_die "--resolve-key needs a value"; keys="$keys $2"; shift 2 ;;
      --) shift; break ;;
      -*) usage_die "unknown continue option: $1" ;;
      *) break ;;
    esac
  done
  [ $# -ge 2 ] || usage_die "continue needs a task id and the steer text"
  task=$1; shift; text="$*"
  [ -n "$text" ] || usage_die "continue needs the steer text"
  for k in $keys; do valid_id "$k" || usage_die "invalid decision key: $k"; done
  load_task_libs
  command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH (run: fm-cloud.sh doctor)"
  local f meta old repo remote before status prior prompt now id warn url session
  f=$(task_run_record "$task") || exit $?
  meta="$STATE/$task.meta"
  old=$(rec_get "$meta" cloud_run)
  [ -f "$DATA/$task/brief.md" ] || die "task $task has no brief at $DATA/$task/brief.md"
  repo=$(rec_get "$f" repo); remote=$(rec_get "$f" remote)
  prior=$(branch_status_text "$f" "$task" 2>/dev/null | tail -n 40 || true)
  prompt="$(cat "$DATA/$task/brief.md")$(cloud_trailer "$task" "$(rec_get "$f" base_branch)")"
  prompt="$prompt
---
Follow-up run for this task. Firstmate steers you with the message below; the work so far is on branch claude/$task. Check out that existing branch, do NOT start a new one, and continue from it. Keep appending to .fm-cloud/status there (recreate it if it is missing).

Steer from firstmate:
$text

Your earlier status lines (most recent last):
${prior:-(none pushed)}
"
  before=$(git -C "$repo" ls-remote --heads "$remote" 'refs/heads/claude/*' 2>/dev/null | awk '{print $1":"$2}' | paste -sd, - || true)
  claude_cloud_run "$repo" "$prompt" "$(rec_get "$f" environment)"
  warn=$CLOUD_WARN; url=$CLOUD_URL; session=$CLOUD_SESSION
  now=$(date +%s)
  id="cloud-$now-$$"
  {
    printf 'id=%s\n' "$id"
    printf 'launched_at=%s\n' "$now"
    printf 'session=%s\n' "$session"
    printf 'url=%s\n' "$url"
    printf 'environment=%s\n' "$(rec_get "$f" environment)"
    printf 'repo=%s\n' "$repo"
    printf 'remote=%s\n' "$remote"
    printf 'remote_url=%s\n' "$(rec_get "$f" remote_url)"
    printf 'base_branch=%s\n' "$(rec_get "$f" base_branch)"
    printf 'result_branch=claude/*\n'
    printf 'heads_before=%s\n' "$before"
    printf 'prompt_bytes=%s\n' "$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
    printf 'prompt_sha256=%s\n' "$(printf '%s' "$prompt" | sha256_of)"
    printf 'task=%s\n' "$task"
    printf 'continues=%s\n' "$old"
  } > "$RUNS/$id.run"
  printf '%s %s %s\n' "$id" "$now" "$task" >> "$LAUNCH_LEDGER"
  rec_set "$meta" cloud_run "$id"
  rec_set "$meta" cloud_session "$session"
  rec_set "$meta" cloud_url "$url"
  rm -f "$f" "${f%.run}.seen" "${f%.run}.stuck"
  status="$STATE/$task.status"
  printf 'working [at=%s]: steer delivered by a follow-up cloud run, session %s\n' "$now" "${url:-${session:-unknown}}" >> "$status"
  for k in $keys; do
    printf 'resolved [at=%s] [key=%s]: answered by a steer (follow-up cloud run)\n' "$now" "$k" >> "$status"
  done
  printf 'run: %s (continues %s)\n' "$id" "$old"
  printf 'session: %s\n' "${session:-unknown}"
  printf 'url: %s\n' "${url:-unknown}"
  printf 'steer: delivered as a follow-up run on claude/%s; replies arrive through the status channel\n' "$task"
  [ -z "$warn" ] || printf 'warning: %s\n' "$warn"
  [ -z "$(rec_get "$meta" pr)" ] || printf 'note: a PR is recorded, so the PR poll (not the status channel) owns wakes for this task\n'
  return 0
}

# Hand the run's PR to the ordinary landing path.
cmd_land() {
  [ $# -eq 1 ] || usage_die "land needs exactly one task id"
  local task=$1 f branch ref slug n url
  f=$(task_run_record "$task")
  branch=$(run_result_branch "$f" "$task") || die "cannot read the remote to find the run's branch"
  [ -n "$branch" ] || die "run for $task has no result branch yet (status: fm-cloud.sh status $(rec_get "$f" id))"
  ref=${branch% *}
  slug=$(github_slug "$(rec_get "$f" remote_url)")
  [ -n "$slug" ] || die "the run's remote is not a github.com repository; record its PR with bin/fm-pr-check.sh $task <url>"
  n=$(pr_number_for_branch "$slug" "$ref")
  [ -n "$n" ] || die "branch $ref has no pull request yet"
  url="https://github.com/$slug/pull/$n"
  sed -i.bak "s#^branch=.*#branch=$ref#" "$STATE/$task.meta" 2>/dev/null && rm -f "$STATE/$task.meta.bak" || true
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SELF_DIR/fm-pr-check.sh" "$task" "$url"
  printf 'landing: %s armed for merge polling\n' "$url"
}

# Retire everything a cloud task owns, once its PR is merged (or --force).
cmd_teardown() {
  local task="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      -*) usage_die "unknown teardown option: $1" ;;
      *) [ -z "$task" ] || usage_die "teardown takes one task id"; task=$1 ;;
    esac
    shift
  done
  [ -n "$task" ] || usage_die "teardown needs a task id"
  load_task_libs
  local f meta pr_url run state_json proj lock gen args=() transition_applies=0 gate=0
  f=$(task_run_record "$task") || exit $?
  meta="$STATE/$task.meta"
  run=$(rec_get "$meta" cloud_run)
  pr_url=$(rec_get "$meta" pr)
  if [ "$force" -ne 1 ]; then
    [ -n "$pr_url" ] || die "REFUSED: run $run has no recorded PR, so its work is not known to have landed; land it (fm-cloud.sh land $task) or pass --force to discard it"
    command -v gh >/dev/null 2>&1 || die "REFUSED: gh is unavailable, so the PR state of $pr_url cannot be read"
    state_json=$(gh pr view "$pr_url" --json state -q .state 2>/dev/null) || die "REFUSED: the state of $pr_url cannot be read; nothing was changed"
    [ "$state_json" = MERGED ] || die "REFUSED: $pr_url is $state_json, not merged; nothing was changed (--force discards the run)"
  fi
  proj=$(rec_get "$meta" project)
  gen=$(rec_get "$meta" spawn_gen)
  lock=$(fm_meta_lock_path "$meta") || die "cannot resolve the task record lock"
  fm_lock_acquire_wait "$lock"
  [ -z "$pr_url" ] || args=(--pr "$pr_url")
  fm_backlog_transition_applies "$CONFIG" "$DATA" ship || gate=$?
  if [ "$gate" -eq 0 ]; then
    transition_applies=1
    if ! fm_backlog_close_marker_write "$STATE" "$task" "$DATA" "$gen" "${args[@]+"${args[@]}"}"; then
      fm_lock_release "$lock"; die "the pending backlog close for $task could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); nothing was changed"
    fi
  elif [ "$gate" -eq 2 ]; then
    fm_lock_release "$lock"; die "backlog unavailable ($FM_BACKLOG_TRANSITION_ERROR); nothing was changed"
  fi
  # The run's volatile records: finish check, PR poll, run record, status notes.
  fm_pr_poll_retirement_recover_one "$STATE" "$task" "$SELF_DIR/fm-pr-poll.sh" || true
  fm_pr_poll_merge_notified_remove "$STATE" "$task" || true
  rm -f "$STATE/$task.check.sh" "$STATE/$task.check-trust" "$STATE/$task.pr-poll" \
    "$STATE/$task.pr-poll-registration" "$STATE/$task.pr-poll-retirement" "$STATE/$task.merge-authority" \
    "$RUNS/$run.run" "$RUNS/$run.seen" "$RUNS/$run.stuck" \
    "$RUNS/$task.statuslines" "$RUNS/$task.statusrepo.sha"
  rm -rf "$RUNS/$task.statusrepo"
  status_retire_presentation_task "$STATE" "$task" || true
  rm -rf "$STATE/$task.inbox"
  if [ "$transition_applies" -eq 1 ]; then
    if ! fm_backlog_atomic_transition close "$meta" "$(fm_backlog_close_marker_path "$STATE" "$task")" "$DATA" "$task" "$STATE" "${args[@]+"${args[@]}"}"; then
      fm_lock_release "$lock"
      die "$task's run is retired, but its backlog item could not be closed ($FM_BACKLOG_TRANSITION_ERROR); the pending close is recorded and the next session start retries it"
    fi
  elif ! fm_backlog_atomic_transition remove "$meta" "task record" "$STATE"; then
    fm_lock_release "$lock"
    die "$task's run is retired, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)"
  fi
  fm_lock_release "$lock"
  [ -z "$pr_url" ] || [ -z "$proj" ] || "$SELF_DIR/fm-fleet-sync.sh" "$proj" >/dev/null 2>&1 || true
  printf 'teardown %s complete (cloud run %s retired)\n' "$task" "$run"
}

# config/cloud-credit: amount=<usd> and expires=<YYYY-MM-DD>.
epoch_of_date() {  # <YYYY-MM-DD> -> epoch of 00:00 UTC, or nothing
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac
  date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null \
    || date -u -d "$1 00:00:00" +%s 2>/dev/null || true
}

credit_line() {
  local f="$CONFIG/cloud-credit" amount expires exp now days runs=0
  [ -f "$f" ] || { printf 'credit: not configured (add %s with amount= and expires=YYYY-MM-DD)\n' "$f"; return 0; }
  amount=$(rec_get "$f" amount); expires=$(rec_get "$f" expires)
  exp=$(epoch_of_date "$expires")
  [ -z "$exp" ] || exp=$(( exp + 86400 ))  # the credit lasts through the expiry date
  [ ! -f "$LAUNCH_LEDGER" ] || runs=$(wc -l < "$LAUNCH_LEDGER" | tr -d ' ')
  now=$(date +%s)
  if [ -z "$exp" ]; then
    printf 'credit: $%s, expiry %s is not a YYYY-MM-DD date; runs launched: %s\n' "${amount:-?}" "${expires:-unset}" "$runs"
  elif [ "$now" -ge "$exp" ]; then
    printf 'credit: $%s expired %s; runs launched: %s\n' "${amount:-?}" "$expires" "$runs"
  else
    days=$(( (exp - now + 86399) / 86400 ))
    printf 'credit: $%s expires %s, %s day(s) remaining; runs launched: %s (cloud is a preferred route for self-contained GitHub work until then)\n' \
      "${amount:-?}" "$expires" "$days" "$runs"
  fi
}

# Usage from the two ledgers: runs per task, runs per UTC day, and wall time per
# run from launch to its last status line, branch move or PR sighting.
credit_report() {
  [ -s "$LAUNCH_LEDGER" ] || { printf 'usage: no runs launched yet\n'; return 0; }
  local id at task last wall tot=0 n=0
  printf 'runs per task:\n'
  awk '{t=($3=="" ? "-" : $3); c[t]++} END{for (t in c) printf "  %s: %d\n", t, c[t]}' "$LAUNCH_LEDGER" | sort
  printf 'runs per day (UTC):\n'
  while read -r id at task; do
    [ -n "$at" ] || continue
    epoch_date "$at"; printf '\n'
  done < "$LAUNCH_LEDGER" | sort | uniq -c | awk '{printf "  %s: %d\n", $2, $1}'
  printf 'wall time per run (launch to last status or PR):\n'
  while read -r id at task; do
    [ -n "$id" ] || continue
    last=""
    [ ! -f "$ACTIVITY_LEDGER" ] || last=$(awk -v r="$id" '$1==r && $2>m {m=$2} END{if (m) print m}' "$ACTIVITY_LEDGER")
    if [ -n "$last" ] && [ "$last" -ge "$at" ]; then
      wall=$(( last - at )); tot=$(( tot + wall )); n=$(( n + 1 ))
      printf '  %s task=%s: %dm%02ds\n' "$id" "${task:--}" $(( wall / 60 )) $(( wall % 60 ))
    else
      printf '  %s task=%s: no activity seen\n' "$id" "${task:--}"
    fi
  done < "$LAUNCH_LEDGER"
  [ "$n" -eq 0 ] || printf '  total with activity: %dm across %d run(s)\n' $(( tot / 60 )) "$n"
}

cmd_credit() {
  [ $# -eq 0 ] || usage_die "credit takes no arguments"
  credit_line
  credit_report
  printf 'balance: the remaining dollar balance has no CLI or API here; read it on claude.ai. The report above counts runs and time only, never dollars.\n'
}

cmd_doctor() {
  local rc=0 help ver flag
  if ! command -v claude >/dev/null 2>&1; then
    printf 'claude: MISSING (install Claude Code, then rerun doctor)\n'; rc=1
  else
    ver=$(claude --version 2>/dev/null | head -n 1 || true)
    printf 'claude: %s\n' "${ver:-version unknown}"
    help=$(claude --help 2>&1 || true)
    for flag in --cloud --environment --teleport; do
      if printf '%s\n' "$help" | grep -q -- "$flag"; then
        printf 'flag %s: supported\n' "$flag"
      else
        printf 'flag %s: NOT FOUND in claude --help\n' "$flag"
        [ "$flag" != --cloud ] || rc=1
      fi
    done
  fi
  if command -v git >/dev/null 2>&1; then printf 'git: present\n'; else printf 'git: MISSING\n'; rc=1; fi
  if command -v gh-axi >/dev/null 2>&1; then printf 'gh-axi: present\n'; else printf 'gh-axi: not installed (optional; status uses git ls-remote)\n'; fi
  credit_line
  printf 'steer: no supported non-interactive message to an existing cloud session (claude --cloud <session_id> only attaches a terminal); fm-cloud.sh continue relaunches on the task branch\n'
  printf 'still needs the web UI (no CLI): cloud-environment network allowlist and environment variables, Tailscale key minting\n'
  printf 'runbook: runbooks-e8k\n'
  return "$rc"
}

[ $# -ge 1 ] || usage_die "missing subcommand"
sub=$1; shift
case "$sub" in
  launch) cmd_launch "$@" ;;
  status) cmd_status "$@" ;;
  list) cmd_list "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  continue) cmd_continue "$@" ;;
  check) cmd_check "$@" ;;
  land) cmd_land "$@" ;;
  teardown) cmd_teardown "$@" ;;
  credit) cmd_credit "$@" ;;
  doctor) cmd_doctor "$@" ;;
  -h|--help|help) sed -n '2,104p' "${BASH_SOURCE[0]}" ;;
  *) usage_die "unknown subcommand: $sub" ;;
esac
