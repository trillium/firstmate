#!/usr/bin/env bash
# Check, and optionally repair, one remote account's second-mate readiness.
#
# Usage:
#   bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh [--fix]
#
# Run it through fm-on.sh so the fixed entrypoint invokes this readiness owner
# over its plain SSH bootstrap. The command reports the same filesystem-composed
# PATH used by worker jobs while retaining authority to inspect and repair the
# worker itself.
#
# A remote second mate always runs on the Herdr backend in the dedicated
# fm-remote session. Its account therefore needs the Firstmate-owned Aqua Herdr
# agent plus the sibling dev.firstmate.remote-job worker that runs normal fm-on
# commands through the Aqua or Linux job-worker path. Doctor remains invokable
# over the plain-SSH bootstrap path to inspect and repair that worker. SSH cannot
# create an Aqua session, so a host with no GUI login is a human gap rather than
# something --fix attempts to bypass.
#
# Line protocol, one fact per line, stable for script consumers:
#   mode=check|fix
#   path=<the child PATH this command inherited>
#   entrypoint=yes|no
#   platform=darwin|linux|<uname -s>|unknown
#   required <tool>=<path>|MISSING
#   optional <tool>=<path>|absent
#   fix <check>=applied: <what changed>       (--fix only)
#   fix <check>=failed: <why the repair did not land>   (--fix only)
#   check <check>=ok: <evidence>
#   check <check>=skip: <why this host is exempt>
#   check <check>=fixable: <gap --fix can close>
#   check <check>=human: <gap only a person at that machine can close>
#   check <check>=info: <gap no repair here can close>
#   action: <check>: <the exact step to take>
#   repairable-advisory: <check>   (a non-gating gap --fix can still close)
# Every check line is authoritative for the moment it printed: under --fix it is
# the state after the repair attempt, so a human gap is never presented as
# fixed. Any remaining fixable or human gap on a GATING check, and any missing
# required tool, exits non-zero.
#
# NON-GATING checks (see NON_GATING_CHECKS below) are the exception, and they
# are exempt from the VERDICT only: they print their state and their operator
# action like every other check, --fix still repairs a fixable one, and an open
# repairable one still prints repairable-advisory so the readiness gate runs
# its repair pass. What no value of theirs ever does is make this command exit
# non-zero, because they do not describe whether an agent can run on this host.
#
# --fix is idempotent and closes only automatable gaps: it writes and reloads
# both Firstmate-owned Aqua agents, starts the Linux workers where no Aqua agent
# applies, recreates the entrypoint symlink, and may add an owned ~/.local/bin
# wrapper for a required tool it can discover under nvm, asdf, or mise. It never
# installs packages, creates a login session, writes an auto-login password,
# changes FileVault, stores an account password, or replaces a non-Firstmate
# wrapper; those remain reported gaps.
#
# The beads-store check is the one backend-gated check here: it runs only when
# the home this command was pointed at selects config/backlog-backend=beads,
# and is skipped entirely otherwise, so the tasks-axi and manual backends see
# no change. It exists because a remote home inherits that backend setting from
# its parent while nothing provisions the beads CLI or store on that host. Its
# repair publishes an owned BEADS_DIR-pinning `task` wrapper in front of a bd
# binary already present on the host, then provisions a store with the
# non-destructive `bd bootstrap` only when none answers; a host with no bd
# binary stays a reported gap, because --fix installs no packages. It is also
# the one NON-GATING check, so none of its states withholds the readiness
# verdict, while a repairable one still asks the readiness gate to repair it.
set -eu

# Resolve this script's directory with builtins only: a host missing a required
# tool must still reach the report that names it, not die on a bare PATH.
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
REQUIRED_TOOLS=(git jq herdr tasks-axi treehouse)
HARNESS_TOOLS=(claude codex opencode pi pi-signed grok kimi)
OPTIONAL_TOOLS=(tmux no-mistakes gh)
LAUNCH_AGENT_LABEL=dev.firstmate.herdr.fm-remote
# The dedicated remote-secondmate session. The user's interactive Herdr work
# remains in the separate default session, which this readiness check never
# requires or changes.
HERDR_SESSION_NAME=fm-remote
LAUNCH_AGENT_DIR="${HOME:-}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_AGENT_LOG_DIR="${HOME:-}/Library/Logs"
LAUNCH_AGENT_LOG="$LAUNCH_AGENT_LOG_DIR/$LAUNCH_AGENT_LABEL.log"
ENTRYPOINT_LINK="${HOME:-}/.local/bin/fm-remote-entrypoint.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE=check
case "${1:-}" in
  '') ;;
  --fix) MODE=fix; shift ;;
  --worker-tool-probe)
    [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || { printf 'error: worker tool probe requires the remote job worker\n' >&2; exit 64; }
    MODE='worker-tool-probe'
    shift
    ;;
  *) usage ;;
esac
[ "$#" -eq 0 ] || usage

PLATFORM=$(fm_remote_job_platform)
UID_NUM=$(id -u 2>/dev/null) || UID_NUM=

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()

record() { # <name> <value> [operator-action]
  CHECK_NAMES+=("$1")
  CHECK_VALUES+=("$2")
  CHECK_ACTIONS+=("${3:-}")
}

check_value() { # <name>; prints the recorded value, empty when unrecorded
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      printf '%s' "${CHECK_VALUES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

check_is_ok() { # <name>
  case "$(check_value "$1" 2>/dev/null || true)" in ok:*) return 0 ;; esac
  return 1
}

# A non-gating check suppresses exactly one thing: the readiness VERDICT. It is
# still checked, still printed with its operator action, still repaired by
# --fix, and an open repairable one still publishes the repairable-advisory
# line below so the readiness gate knows to run its repair pass. Nothing about
# this list means "ignore".
#
# beads-store is the only one, and deliberately so. "Ready for a remote second
# mate" means that host can start and supervise an agent; the task store is a
# separate concern that the parent home's inherited backlog backend drags onto
# a host whose route already works. Gating on it would refuse every seed,
# launch, and liveness relaunch through bin/fm-remote-readiness-lib.sh over a
# gap unrelated to the agent runtime - and in the no-bd case, over one --fix
# cannot close at all, because this command installs no packages.
NON_GATING_CHECKS="beads-store"

check_is_non_gating() { # <name>
  case " $NON_GATING_CHECKS " in *" $1 "*) return 0 ;; esac
  return 1
}

set_check() { # <name> <value> [operator-action]
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      CHECK_VALUES[i]=$2
      CHECK_ACTIONS[i]=${3:-}
      return 0
    fi
    i=$((i + 1))
  done
  record "$@"
}

herdr_cli_available() {
  local herdr_bin jq_bin
  herdr_bin=$(command -v herdr 2>/dev/null || true)
  jq_bin=$(command -v jq 2>/dev/null || true)
  [ -n "$herdr_bin" ] && [ -x "$herdr_bin" ] && [ -n "$jq_bin" ] && [ -x "$jq_bin" ]
}

# The herdr adapter is the single owner of session-scoped herdr invocation and
# of starting a server, so read and start through it rather than restating
# either here. Sourced only when both tools resolve, so a bare host still
# reports its gaps instead of failing to load.
herdr_adapter_load() {
  [ -z "${FM_REMOTE_DOCTOR_HERDR_LOADED:-}" ] || return 0
  herdr_cli_available || return 1
  [ -f "$SCRIPT_DIR/fm-backend.sh" ] && [ -f "$SCRIPT_DIR/backends/herdr.sh" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  FM_REMOTE_DOCTOR_HERDR_LOADED=1
}

herdr_server_running() {
  local running
  herdr_adapter_load || return 1
  running=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" status --json 2>/dev/null \
    | jq -r '.server.running // false' 2>/dev/null) || return 1
  [ "$running" = true ]
}

launch_agent_is_aqua() {
  local stripped
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  stripped=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  case "$stripped" in
    *'<key>LimitLoadToSessionType</key><string>Aqua</string>'*) return 0 ;;
  esac
  return 1
}

render_launch_agent() { # <resolved-herdr-path>
  local herdr_bin=$1
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCH_AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$herdr_bin</string>
		<string>server</string>
		<string>--session</string>
		<string>$HERDR_SESSION_NAME</string>
	</array>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
</dict>
</plist>
XML
}

launch_agent_contract_matches() {
  local herdr_bin actual expected
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  actual=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  expected=$(render_launch_agent "$herdr_bin" | tr -d ' \t\r\n') || return 1
  [ "$actual" = "$expected" ]
}

launch_agent_loaded_contract_matches() {
  local loaded herdr_bin herdr_compact plist_compact log_compact args
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  loaded=$(launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>/dev/null) || return 1
  loaded=$(printf '%s' "$loaded" | tr -d ' \t\r\n') || return 1
  herdr_compact=$(printf '%s' "$herdr_bin" | tr -d ' \t\r\n') || return 1
  plist_compact=$(printf '%s' "$LAUNCH_AGENT_PLIST" | tr -d ' \t\r\n') || return 1
  log_compact=$(printf '%s' "$LAUNCH_AGENT_LOG" | tr -d ' \t\r\n') || return 1
  args="arguments={$herdr_compact"'server--session'"$HERDR_SESSION_NAME}"
  [[ "$loaded" == *"path=$plist_compact"* ]] || return 1
  [[ "$loaded" == *"program=$herdr_compact"* ]] || return 1
  [[ "$loaded" == *"$args"* ]] || return 1
  [[ "$loaded" == *"stdoutpath=$log_compact"* ]] || return 1
  [[ "$loaded" == *"stderrpath=$log_compact"* ]] || return 1
  [[ "$loaded" == *'properties=keepalive|runatload'* ]] || return 1
}

# --- remote job and tool checks ---------------------------------------------

remote_job_existing_state() {
  local root
  root=${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}
  root=$(fm_remote_job_canonical_existing_dir "$root") || return 1
  fm_remote_job_canonical_existing_dir "$root/jobs" >/dev/null || return 1
  # shellcheck disable=SC2034 # The sourceable worker helpers consume the validated state root.
  FM_REMOTE_JOB_STATE=$root
}

remote_job_probe_ok() {
  local ready mtime now
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_existing_state || return 1
  ready="$FM_REMOTE_JOB_STATE/worker.ready"
  [ -f "$ready" ] && [ ! -L "$ready" ] || return 1
  mtime=$(fm_remote_job_path_mtime "$ready" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -le 10 ]
}

remote_job_identity_ok() {
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_probe_ok || return 1
  fm_remote_job_worker_identity_matches "$FM_ROOT" "${HOME:-}"
}

check_remote_job_worker() {
  local worker
  worker="$FM_ROOT/bin/fm-remote-job-worker.sh"
  if [ ! -f "$worker" ] || [ -L "$worker" ] || [ ! -x "$worker" ]; then
    record remote-job-worker "human: the configured Firstmate code root has no safe remote job worker" \
      "update the remote Firstmate checkout, then rerun this command with --fix"
    record remote-job-worker-loaded "skip: no worker executable is available"
    record remote-job-probe "skip: no worker executable is available"
    return 0
  fi
  if [ "$PLATFORM" = darwin ]; then
    fm_remote_job_launchagent_paths "${HOME:-}"
    if fm_remote_job_launchagent_contract_matches "$FM_ROOT" "${HOME:-}"; then
      record remote-job-worker "ok: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST matches the Firstmate-owned Aqua worker contract"
    else
      record remote-job-worker "fixable: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST does not match the Firstmate-owned Aqua worker contract" \
        "rerun this command with --fix to write dev.firstmate.remote-job"
    fi
    if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
      record remote-job-worker-loaded "human: the remote job worker cannot be inspected without launchctl and an account uid" \
        "restore launchctl and a readable account uid, then rerun this command"
    elif fm_remote_job_launchagent_loaded "$FM_ROOT" "${HOME:-}" "$UID_NUM"; then
      record remote-job-worker-loaded "ok: $FM_REMOTE_JOB_LABEL is loaded in gui/$UID_NUM"
    elif check_is_ok gui-session; then
      record remote-job-worker-loaded "fixable: $FM_REMOTE_JOB_LABEL is not loaded in gui/$UID_NUM" \
        "rerun this command with --fix to bootstrap the worker"
    else
      record remote-job-worker-loaded "human: $FM_REMOTE_JOB_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
        "close the login-session gap first; SSH cannot create an Aqua session"
    fi
  else
    local pid
    pid=$(cat "${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}/worker.pid" 2>/dev/null || true)
    if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] ||
      { remote_job_existing_state && case "$pid" in ''|*[!0-9]*) false ;; *) kill -0 "$pid" 2>/dev/null ;; esac; }; then
      record remote-job-worker "ok: the Linux remote job worker is running"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    else
      record remote-job-worker "fixable: the Linux remote job worker is not running" \
        "rerun this command with --fix to start it"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    fi
  fi
  if ! remote_job_probe_ok; then
    record remote-job-probe "fixable: the remote job worker has not reported a fresh probe" \
      "rerun this command with --fix to restart the worker, then rerun through fm-on.sh"
  elif ! remote_job_identity_ok; then
    set_check remote-job-worker "fixable: the running remote job worker does not match the current Firstmate code" \
      "rerun this command with --fix to reload the current worker"
    record remote-job-probe "fixable: the remote job worker identity is stale, so its runtime cannot be probed" \
      "rerun this command with --fix to reload the current worker"
  else
    record remote-job-probe "ok: the remote job worker published a fresh heartbeat"
  fi
}

report_required_tools() {
  local tool resolved harness
  MISSING=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      if [ "$tool" = tasks-axi ] && ! fm_tasks_axi_compatible; then
        printf 'required tasks-axi=MISSING (incompatible)\n'
        MISSING+=(tasks-axi)
      else
        printf 'required %s=%s\n' "$tool" "$resolved"
      fi
    else
      printf 'required %s=MISSING\n' "$tool"
      MISSING+=("$tool")
    fi
  done
  for harness in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$harness" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      printf 'required harness=%s:%s\n' "$harness" "$resolved"
      return 0
    fi
  done
  printf 'required harness=MISSING\n'
  MISSING+=(harness)
}

report_required_tools_from_worker() {
  local job_id probe_stdout probe_stderr probe_exit line fact name value
  local expected=6 count=0 valid=1 seen=' '
  if ! job_id=$(fm_remote_job_stage "${HOME:-}" "$FM_ROOT" "${FM_HOME:-}" \
    fm-remote-doctor.sh --worker-tool-probe </dev/null); then
    set_check remote-job-probe "fixable: the remote job worker could not accept the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  if ! fm_remote_job_wait "${HOME:-}" "$job_id"; then
    fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
    set_check remote-job-probe "fixable: the remote job worker did not complete the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  probe_stdout=$FM_REMOTE_JOB_STDOUT
  probe_stderr=$FM_REMOTE_JOB_STDERR
  probe_exit=$FM_REMOTE_JOB_EXIT
  MISSING=()
  while IFS= read -r line; do
    case "$line" in required\ *=*) ;; *) valid=0; continue ;; esac
    fact=${line#required }
    name=${fact%%=*}
    value=${fact#*=}
    case "$name" in git|jq|herdr|tasks-axi|treehouse|harness) ;; *) valid=0; continue ;; esac
    case "$seen" in *" $name "*) valid=0; continue ;; esac
    seen="$seen$name "
    count=$((count + 1))
    case "$value" in MISSING*) MISSING+=("$name") ;; '') valid=0 ;; esac
  done < "$probe_stdout"
  [ "$count" -eq "$expected" ] || valid=0
  [ ! -s "$probe_stderr" ] || valid=0
  case "$probe_exit:${#MISSING[@]}" in 0:0|1:[1-9]*) ;; *) valid=0 ;; esac
  if [ "$valid" -eq 1 ]; then
    cat "$probe_stdout"
    set_check remote-job-probe "ok: the remote job worker completed the required-tool probe"
  else
    set_check remote-job-probe "fixable: the remote job worker returned an invalid required-tool probe result" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
  fi
  fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
}

wrapper_is_firstmate_owned() { # <path>
  local path=$1 first second
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r first < "$path" || return 1
  IFS= read -r second < <(tail -n +2 "$path") || return 1
  [ "$first" = '#!/usr/bin/env bash' ] && [ "$second" = '# Firstmate remote tool wrapper v1' ]
}

repair_tool_wrapper() { # <tool>
  local tool=$1 target wrapper tmp
  local resolved
  resolved=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$resolved" ] && [ -x "$resolved" ] && return 0
  target=$(fm_remote_job_manager_tool "${HOME:-}" "$tool" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  wrapper="${HOME:-}/.local/bin/$tool"
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    if ! wrapper_is_firstmate_owned "$wrapper"; then
      fix_report "required-$tool" failed "$wrapper exists and is not Firstmate-owned"
      return 1
    fi
  else
    if ! mkdir -p "${HOME:-}/.local/bin" 2>/dev/null || [ -L "${HOME:-}/.local/bin" ]; then
      fix_report "required-$tool" failed "cannot create ${HOME:-}/.local/bin"
      return 1
    fi
  fi
  tmp="${HOME:-}/.local/bin/.$tool.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Firstmate remote tool wrapper v1'
    printf 'exec %q "$@"\n' "$target"
  } > "$tmp" || { rm -f -- "$tmp"; fix_report "required-$tool" failed "cannot write $wrapper"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp"
    fix_report "required-$tool" failed "cannot publish $wrapper"
    return 1
  fi
  fix_report "required-$tool" applied "linked the discoverable version-manager tool at $wrapper"
}

repair_required_wrappers() {
  local tool resolved
  for tool in "${REQUIRED_TOOLS[@]}"; do
    repair_tool_wrapper "$tool" || true
  done
  for tool in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    [ -z "$resolved" ] || [ ! -x "$resolved" ] || return 0
  done
  for tool in "${HARNESS_TOOLS[@]}"; do
    fm_remote_job_manager_tool "${HOME:-}" "$tool" >/dev/null 2>&1 || continue
    repair_tool_wrapper "$tool" && return 0
  done
}

fix_remote_job_worker() {
  if fm_remote_job_ensure_worker "$FM_ROOT" "${HOME:-}"; then
    [ "$FM_REMOTE_JOB_REPAIRED" -eq 0 ] || fix_report remote-job-worker applied "installed or reloaded $FM_REMOTE_JOB_LABEL"
    return 0
  fi
  fix_report remote-job-worker failed "${FM_REMOTE_JOB_ERROR:-the remote job worker could not start}"
  return 1
}

# --- checks -----------------------------------------------------------------

check_herdr() {
  local resolved
  if resolved=$(command -v herdr 2>/dev/null) && [ -x "$resolved" ]; then
    record herdr "ok: $resolved"
    return 0
  fi
  record herdr "human: the herdr CLI does not resolve on the remote runtime PATH" \
    "install herdr from https://herdr.dev on that account, or add a ~/.local/bin wrapper for it; a remote second mate always runs on the Herdr backend"
}

check_gui_session() {
  if [ "$PLATFORM" != darwin ]; then
    record gui-session "skip: no Aqua login session applies on $PLATFORM"
    return 0
  fi
  if [ -z "$UID_NUM" ]; then
    record gui-session "human: the account uid could not be read, so its login session cannot be inspected" \
      "run 'id -u' on that account and report the failure; Firstmate cannot address gui/<uid> without it"
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    record gui-session "human: launchctl does not resolve, so the login session cannot be inspected" \
      "restore /bin/launchctl on that macOS account; without it no launch agent can be inspected or loaded"
    return 0
  fi
  if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    record gui-session "ok: gui/$UID_NUM"
    return 0
  fi
  record gui-session "human: no Aqua login session exists for uid $UID_NUM" \
    "log that account in once at the console, and enable automatic login in System Settings > Users & Groups if the machine runs headless; SSH cannot create a GUI session, and Firstmate never writes an auto-login password or changes FileVault"
}

check_launch_agent() {
  if [ "$PLATFORM" != darwin ]; then
    record launchagent "skip: launch agents apply only on darwin"
    record launchagent-scope "skip: launch agents apply only on darwin"
    record launchagent-loaded "skip: launch agents apply only on darwin"
    return 0
  fi
  if [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ]; then
    if launch_agent_contract_matches; then
      record launchagent "ok: $LAUNCH_AGENT_PLIST matches the Firstmate-owned contract"
    else
      record launchagent "fixable: $LAUNCH_AGENT_PLIST does not match the current Firstmate-owned contract" \
        "rerun this command with --fix to rewrite its label, program arguments, session scope, restart policy, and log paths"
    fi
    if launch_agent_is_aqua; then
      record launchagent-scope "ok: LimitLoadToSessionType=Aqua"
    else
      record launchagent-scope "fixable: $LAUNCH_AGENT_PLIST is not scoped to the Aqua login session" \
        "rerun this command with --fix to rewrite it with LimitLoadToSessionType=Aqua"
    fi
  else
    record launchagent "fixable: no Firstmate herdr launch agent at $LAUNCH_AGENT_PLIST" \
      "rerun this command with --fix to install it"
    record launchagent-scope "skip: no launch agent is installed yet"
  fi
  check_launch_agent_loaded
}

check_launch_agent_loaded() {
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    record launchagent-loaded "human: the launch agent domain gui/<uid> cannot be inspected on this account" \
      "restore launchctl and a readable account uid, then rerun this command"
    return 0
  fi
  if launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    if launch_agent_loaded_contract_matches; then
      record launchagent-loaded "ok: gui/$UID_NUM/$LAUNCH_AGENT_LABEL matches the effective contract"
    else
      record launchagent-loaded "fixable: gui/$UID_NUM/$LAUNCH_AGENT_LABEL does not match the effective Firstmate-owned contract" \
        "rerun this command with --fix to replace the loaded job with the current launch-agent contract"
    fi
    return 0
  fi
  if check_is_ok gui-session; then
    record launchagent-loaded "fixable: $LAUNCH_AGENT_LABEL is not loaded into gui/$UID_NUM" \
      "rerun this command with --fix to bootstrap and start it"
    return 0
  fi
  record launchagent-loaded "human: $LAUNCH_AGENT_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
    "close the login-session gap first; a launch agent can only be bootstrapped into an existing GUI session"
}

check_herdr_server() {
  if ! herdr_cli_available; then
    record herdr-server "human: herdr server status cannot be read without both herdr and jq on the runtime PATH" \
      "install the missing tool reported above, then rerun this command"
    return 0
  fi
  if herdr_server_running; then
    record herdr-server "ok: session $HERDR_SESSION_NAME is running"
    return 0
  fi
  if [ "$PLATFORM" = darwin ] && ! check_is_ok gui-session; then
    record herdr-server "human: the herdr server for session $HERDR_SESSION_NAME is not running and there is no GUI login session to start it in" \
      "close the login-session gap first; a server started over SSH would not belong to an Aqua session"
    return 0
  fi
  record herdr-server "fixable: the herdr server for session $HERDR_SESSION_NAME is not running" \
    "rerun this command with --fix to start it"
}

check_entrypoint_link() {
  local want
  if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
    record entrypoint-link "skip: this run did not come through the fixed remote entrypoint"
    return 0
  fi
  want="$FM_ROOT_OVERRIDE/bin/fm-remote-entrypoint.sh"
  if [ -L "$ENTRYPOINT_LINK" ] && [ "$(readlink "$ENTRYPOINT_LINK")" = "$want" ]; then
    record entrypoint-link "ok: $ENTRYPOINT_LINK"
    return 0
  fi
  if [ -e "$ENTRYPOINT_LINK" ] || [ -L "$ENTRYPOINT_LINK" ]; then
    record entrypoint-link "human: $ENTRYPOINT_LINK exists but is not the symlink to $want" \
      "inspect that path yourself and replace it with 'ln -sfn $want $ENTRYPOINT_LINK' if it is stale; Firstmate never overwrites a file it did not create there"
    return 0
  fi
  record entrypoint-link "fixable: no entrypoint symlink at $ENTRYPOINT_LINK" \
    "rerun this command with --fix to create it"
}

# --- beads store readiness (config/backlog-backend=beads only) --------------
#
# A remote home inherits config/backlog-backend from its parent, but nothing
# ever provisioned the beads CLI or store on that host, so the home comes up
# with the backend selected and the task queue dead. This check closes exactly
# that gap and is scoped to remote hosts by construction: it runs only inside
# this remote readiness command, and only when the home it was pointed at
# actually selects the beads backend.
#
# It deliberately does NOT test for a .beads/ directory in the home. The `task`
# wrapper pins BEADS_DIR for the whole federation, so a home with no local
# .beads/ can be perfectly healthy while a host with one can still be broken;
# the only meaningful test is whether the CLI answers a read.
beads_home_config_dir() {
  local home=${FM_HOME:-}
  [ -n "$home" ] || return 1
  printf '%s/config\n' "$home"
}

beads_backend_selected() {
  local config_dir
  config_dir=$(beads_home_config_dir) || return 1
  [ -d "$config_dir" ] || return 1
  [ "$(fm_backlog_backend_value "$config_dir")" = beads ]
}

# The wrapper this host needs is the same shape as the parent's `task`: a
# BEADS_DIR-pinning shim in front of the bd binary. Without it a bare `bd`
# auto-discovers from the working directory, finds nothing, and fails with "no
# beads database found" even when a perfectly good store exists on the host -
# the exact failure a remote home reports today.
BEADS_TASK_WRAPPER="${HOME:-}/.local/bin/task"
BEADS_STORE_DIR="${HOME:-}/data/tasks/.beads"

# Probes PATH first, then the two account-local install locations a
# non-interactive ssh PATH routinely omits - `go install` writes ~/go/bin and
# beads' own installer writes ~/.local/bin, and neither is on the stripped PATH
# a remote command inherits. Every candidate stays inside PATH or HOME so this
# check reports on the account it was pointed at and never on the host running it.
beads_bd_binary() {
  local resolved
  resolved=$(command -v bd 2>/dev/null || true)
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then printf '%s\n' "$resolved"; return 0; fi
  for resolved in "${HOME:-}/go/bin/bd" "${HOME:-}/.local/bin/bd"; do
    [ -x "$resolved" ] && { printf '%s\n' "$resolved"; return 0; }
  done
  return 1
}

# The `task` wrapper this check reports on and publishes lives in ~/.local/bin,
# which the remote runtime PATH always contains but a plain-SSH invocation of
# this command routinely does not - the same PATH hole beads_bd_binary probes
# around for bd. Resolving the CLI through a bare `command -v task` would
# therefore misreport a healthy host as broken, and would make --fix verify its
# own freshly published wrapper through a PATH that cannot see it. Both helpers
# run in a subshell so the augmented PATH never leaks into the `path=` line this
# command reports or into any other check.
beads_store_reachable_here() (
  # shellcheck disable=SC2030,SC2031 # The subshell-local PATH is the point: it must not escape.
  PATH="${HOME:-}/.local/bin:${PATH:-}"
  fm_beads_store_reachable
)

beads_bootstrap_store_here() (
  # shellcheck disable=SC2030,SC2031 # The subshell-local PATH is the point: it must not escape.
  PATH="${HOME:-}/.local/bin:${PATH:-}"
  fm_beads_bootstrap_store
)

check_beads_store() {
  local bd_bin
  if ! beads_backend_selected; then
    record beads-store "skip: this home does not select the beads backlog backend"
    return 0
  fi
  if beads_store_reachable_here; then
    record beads-store "ok: the task CLI resolves and the beads store answers a read"
    return 0
  fi
  if ! bd_bin=$(beads_bd_binary); then
    record beads-store "info: this home selects the beads backend but no bd binary exists on this host" \
      "install beads on that account with 'go install github.com/steveyegge/beads/cmd/bd@latest', then rerun this command with --fix to add the task wrapper and provision the store"
    return 0
  fi
  # Only a gap --fix can actually close may be reported fixable, because a
  # fixable non-gating gap is what makes the readiness gate spend a repair pass
  # and a re-check on every seed, launch, and liveness relaunch. fix_beads_store
  # refuses an operator-owned wrapper by design, so that gap would never
  # converge and must be classified as the informational gap it is.
  if { [ -e "$BEADS_TASK_WRAPPER" ] || [ -L "$BEADS_TASK_WRAPPER" ]; } &&
    ! wrapper_is_firstmate_owned "$BEADS_TASK_WRAPPER"; then
    record beads-store "info: bd resolves at $bd_bin but $BEADS_TASK_WRAPPER is not Firstmate-owned, so no repair here can replace it" \
      "on that account, either make $BEADS_TASK_WRAPPER export BEADS_DIR=$BEADS_STORE_DIR before exec'ing $bd_bin, or remove it and rerun this command with --fix"
    return 0
  fi
  record beads-store "fixable: bd resolves at $bd_bin but the task CLI does not answer a read" \
    "rerun this command with --fix to add the BEADS_DIR-pinning task wrapper and run the non-destructive 'task bootstrap'"
}

# Repair is two steps, in order: publish the wrapper so `task` exists and is
# pinned, then bootstrap a store only if one still does not answer.
#
# `bd bootstrap` is the only provisioning verb used here because it is the
# documented non-destructive one; `bd init --force` is never run. The
# reachability guard inside fm_beads_bootstrap_store is what makes that safe in
# practice, because bootstrap's own detection reads the .beads/ directory and
# reports a healthy Dolt server-mode store as absent.
fix_beads_store() {
  local bd_bin tmp
  if ! bd_bin=$(beads_bd_binary); then
    fix_report beads-store failed "no bd binary on this host to point a wrapper at"
    return 1
  fi
  if [ -e "$BEADS_TASK_WRAPPER" ] || [ -L "$BEADS_TASK_WRAPPER" ]; then
    if ! wrapper_is_firstmate_owned "$BEADS_TASK_WRAPPER"; then
      fix_report beads-store failed "$BEADS_TASK_WRAPPER exists and is not Firstmate-owned"
      return 1
    fi
  elif ! mkdir -p "${HOME:-}/.local/bin" 2>/dev/null || [ -L "${HOME:-}/.local/bin" ]; then
    fix_report beads-store failed "cannot create ${HOME:-}/.local/bin"
    return 1
  fi
  tmp="${HOME:-}/.local/bin/.task.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Firstmate remote tool wrapper v1'
    printf 'export BEADS_DIR=%q\n' "$BEADS_STORE_DIR"
    printf '%s\n' 'export BD_NAME=task'
    printf 'exec %q "$@"\n' "$bd_bin"
  } > "$tmp" || { rm -f -- "$tmp"; fix_report beads-store failed "cannot write $BEADS_TASK_WRAPPER"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$BEADS_TASK_WRAPPER"; then
    rm -f -- "$tmp"
    fix_report beads-store failed "cannot publish $BEADS_TASK_WRAPPER"
    return 1
  fi
  fix_report beads-store applied "wrote $BEADS_TASK_WRAPPER pinning BEADS_DIR=$BEADS_STORE_DIR in front of $bd_bin"

  if beads_store_reachable_here; then
    fix_report beads-store applied "the beads store answers a read through the new wrapper; no bootstrap needed"
    return 0
  fi
  if ! mkdir -p "$BEADS_STORE_DIR" 2>/dev/null; then
    fix_report beads-store failed "cannot create $BEADS_STORE_DIR"
    return 1
  fi
  if beads_bootstrap_store_here >/dev/null 2>&1; then
    fix_report beads-store applied "provisioned the store with the non-destructive 'task bootstrap'"
    return 0
  fi
  fix_report beads-store failed "'task bootstrap' did not leave a store that answers a read"
  return 1
}

run_checks() {
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  check_beads_store
  check_herdr
  check_gui_session
  check_remote_job_worker
  check_launch_agent
  check_herdr_server
  check_entrypoint_link
}

# --- repairs ----------------------------------------------------------------

fix_report() { # <check> applied|failed <text>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

write_launch_agent() {
  local herdr_bin tmp
  if ! herdr_bin=$(command -v herdr 2>/dev/null); then
    fix_report launchagent failed "herdr does not resolve, so no launch agent was written"
    return 1
  fi
  case "$herdr_bin" in
    *'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
      fix_report launchagent failed "the resolved herdr path contains characters that cannot be embedded in a property list: $herdr_bin"
      return 1
      ;;
  esac
  if ! mkdir -p "$LAUNCH_AGENT_DIR" 2>/dev/null; then
    fix_report launchagent failed "cannot create $LAUNCH_AGENT_DIR"
    return 1
  fi
  mkdir -p "$LAUNCH_AGENT_LOG_DIR" 2>/dev/null || true
  tmp="$LAUNCH_AGENT_DIR/.$LAUNCH_AGENT_LABEL.plist.tmp.$$"
  render_launch_agent "$herdr_bin" > "$tmp"
  chmod 0644 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
    rm -f -- "$tmp"
    fix_report launchagent failed "cannot publish $LAUNCH_AGENT_PLIST"
    return 1
  fi
  fix_report launchagent applied "wrote the Aqua-scoped $LAUNCH_AGENT_LABEL launch agent running $herdr_bin server"
}

# Reload rather than plain bootstrap so a rewritten plist replaces a stale
# in-memory copy, and kickstart so the server is running now rather than at the
# next login. Both are safe to repeat.
reload_launch_agent() { # <check-to-report-under>
  local report=$1 out
  [ -f "$LAUNCH_AGENT_PLIST" ] || {
    fix_report "$report" failed "there is no launch agent to load at $LAUNCH_AGENT_PLIST"
    return 1
  }
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    fix_report "$report" failed "launchctl or the account uid is unavailable"
    return 1
  fi
  launchctl bootout "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  if ! out=$(launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT_PLIST" 2>&1); then
    fix_report "$report" failed "launchctl bootstrap gui/$UID_NUM refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! out=$(launchctl kickstart -k "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>&1); then
    fix_report "$report" failed "launchctl kickstart gui/$UID_NUM/$LAUNCH_AGENT_LABEL refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! wait_for_herdr_server; then
    fix_report "$report" failed "the herdr server for session $HERDR_SESSION_NAME did not report running within 10s"
    return 1
  fi
  fix_report "$report" applied "bootstrapped and started $LAUNCH_AGENT_LABEL in gui/$UID_NUM"
}

wait_for_herdr_server() {
  local i=0
  while [ "$i" -lt 20 ]; do
    herdr_server_running && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

start_herdr_server() {
  if ! herdr_adapter_load; then
    fix_report herdr-server failed "herdr and jq must both resolve before the server can be started"
    return 1
  fi
  if fm_backend_herdr_server_ensure "$HERDR_SESSION_NAME" >/dev/null 2>&1; then
    fix_report herdr-server applied "started the herdr server for session $HERDR_SESSION_NAME"
    return 0
  fi
  fix_report herdr-server failed "the herdr server for session $HERDR_SESSION_NAME did not come up"
  return 1
}

link_entrypoint() {
  local want="${FM_ROOT_OVERRIDE:-}/bin/fm-remote-entrypoint.sh"
  if ! mkdir -p "$(dirname "$ENTRYPOINT_LINK")" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create $(dirname "$ENTRYPOINT_LINK")"
    return 1
  fi
  if ! ln -s "$want" "$ENTRYPOINT_LINK" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create the symlink at $ENTRYPOINT_LINK"
    return 1
  fi
  fix_report entrypoint-link applied "linked $ENTRYPOINT_LINK to $want"
}

apply_fixes() {
  local i name value launch_agent_written=0 launch_agent_reloaded=0 remote_job_fixed=0
  repair_required_wrappers
  i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    name=${CHECK_NAMES[$i]}
    value=${CHECK_VALUES[$i]}
    i=$((i + 1))
    case "$value" in fixable:*) ;; *) continue ;; esac
    case "$name" in
      beads-store)
        fix_beads_store || true
        ;;
      remote-job-worker|remote-job-worker-loaded|remote-job-probe)
        [ "$remote_job_fixed" -eq 0 ] || continue
        remote_job_fixed=1
        fix_remote_job_worker || true
        ;;
      launchagent|launchagent-scope)
        [ "$launch_agent_written" -eq 0 ] || continue
        launch_agent_written=1
        write_launch_agent || continue
        # A freshly written plist runs nothing until it is (re)loaded, and only
        # an existing GUI session can hold it.
        check_is_ok gui-session || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      launchagent-loaded)
        [ "$launch_agent_reloaded" -eq 0 ] || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      herdr-server)
        # On darwin the launch agent owns the server, so restart it through
        # launchd rather than starting a stray one outside the Aqua session. A
        # reload earlier in this same pass has already done that.
        if [ "$PLATFORM" = darwin ] && [ -f "$LAUNCH_AGENT_PLIST" ] && check_is_ok gui-session; then
          [ "$launch_agent_reloaded" -eq 0 ] || continue
          launch_agent_reloaded=1
          reload_launch_agent herdr-server || true
          continue
        fi
        start_herdr_server || true
        ;;
      entrypoint-link) link_entrypoint || true ;;
    esac
  done
}

# --- report -----------------------------------------------------------------

if [ "$MODE" = worker-tool-probe ]; then
  report_required_tools
  [ "${#MISSING[@]}" -eq 0 ]
  exit
fi

printf 'mode=%s\n' "$MODE"
# This is the launch PATH, deliberately unaffected by the beads helpers' own
# subshell-local augmentation above; reporting that augmented PATH here is the
# bug those subshells exist to prevent.
# shellcheck disable=SC2031
printf 'path=%s\n' "${PATH:-}"
# shellcheck disable=SC2031
if [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ "${PATH%%:*}" = "$FM_ROOT_OVERRIDE/bin" ]; then
  printf 'entrypoint=yes\n'
else
  printf 'entrypoint=no\n'
  printf 'note: not launched through the fixed remote entrypoint; the reported PATH is this caller environment.\n' >&2
fi
printf 'platform=%s\n' "$PLATFORM"

run_checks
if [ "$MODE" = fix ]; then
  apply_fixes
  # Re-derive every check from the host itself, so what prints below is the
  # state after repair rather than the intent of a repair.
  run_checks
fi

if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || ! remote_job_identity_ok; then
  report_required_tools
else
  report_required_tools_from_worker
fi
for tool in "${OPTIONAL_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'optional %s=%s\n' "$tool" "$resolved"
  else
    printf 'optional %s=absent\n' "$tool"
  fi
done

GAPS=()
ADVISORIES=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  if check_is_non_gating "${CHECK_NAMES[$i]}"; then
    case "${CHECK_VALUES[$i]}" in
      fixable:*|human:*|info:*) ADVISORIES+=("$i") ;;
    esac
  else
    case "${CHECK_VALUES[$i]}" in
      fixable:*|human:*) GAPS+=("$i") ;;
    esac
  fi
  i=$((i + 1))
done
for i in ${GAPS[@]+"${GAPS[@]}"} ${ADVISORIES[@]+"${ADVISORIES[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
done
# A non-gating check that --fix CAN close still needs the readiness gate to run
# its repair pass, which it only does when the read-only run reports something.
# Withholding the verdict is what must not happen; withholding the repair would
# leave a host provisioned exactly as badly as before this check existed. This
# line is that signal, and bin/fm-remote-readiness-lib.sh is its only consumer.
for i in ${ADVISORIES[@]+"${ADVISORIES[@]}"}; do
  case "${CHECK_VALUES[$i]}" in
    fixable:*) printf 'repairable-advisory: %s\n' "${CHECK_NAMES[$i]}" ;;
  esac
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'error: required tools do not resolve on the remote runtime PATH: %s\n' "${MISSING[*]}" >&2
  printf 'fix: install each one where it resolves on the path reported above, or put a wrapper script for it in %s/.local/bin, which is always on that PATH.\n' "${HOME:-~}" >&2
  printf 'fix: tools in an unselected nvm version or outside the discovered asdf or mise paths need an absolute wrapper; see docs/remote-secondmates.md for the wrapper recipe.\n' >&2
fi
if [ "${#MISSING[@]}" -gt 0 ] || [ "${#GAPS[@]}" -gt 0 ]; then
  NAMES=
  for i in ${GAPS[@]+"${GAPS[@]}"}; do
    NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
  done
  printf 'error: this host is not ready for a remote second mate%s\n' "${NAMES:+; unresolved: $NAMES}" >&2
  exit 1
fi
printf 'ok: remote second-mate readiness confirmed on this host\n'
