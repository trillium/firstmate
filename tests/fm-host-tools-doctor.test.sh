#!/usr/bin/env bash
# tests/fm-host-tools-doctor.test.sh - the host tool and authentication
# readiness checks (bin/fm-host-tools-lib.sh, bin/fm-host-tools-doctor.sh).
#
# Hermetic: every tool is a stub on a private PATH that touches no network or
# credential; git access runs against local bare repositories. Each case builds
# a host where one thing is wrong and asserts the failing check, its exact fix
# command, and the non-zero exit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCTOR="$ROOT/bin/fm-host-tools-doctor.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-host-tools-doctor)
GIT_BIN=$(command -v git)
JQ_BIN=$(command -v jq)
BASH_BIN=$(command -v bash)
fm_git_identity

# The doctor finds a tool by looking on PATH, so a host's base PATH must not
# carry the real machine's copy of a tool under test: CI images ship gh in
# /usr/bin, which would turn the missing-gh host into an unauthenticated one.
# SYS_BIN is /usr/bin and /bin with every checked tool left out.
HOST_TOOLS="gh claude pi bd dolt task no-mistakes treehouse bun"
SYS_BIN="$TMP_ROOT/sysbin"
mkdir -p "$SYS_BIN"
ln -s /usr/bin/* "$SYS_BIN/" 2>/dev/null || true
ln -s /bin/* "$SYS_BIN/" 2>/dev/null || true
for tool in $HOST_TOOLS; do
  rm -f "$SYS_BIN/$tool"
done

# One healthy host: <name> is a private directory holding stub tools, a home
# with one fleet clone whose origin is a local bare repository, and a fake ssh.
# OMIT lists tools to leave off the PATH; NO_CLONE=1 leaves out the fleet clone.
make_host() { # <name>
  local h=$TMP_ROOT/$1 tool
  mkdir -p "$h/bin" "$h/home/projects" "$h/home/config" "$h/home/data" "$h/home/state"
  ln -sf "$GIT_BIN" "$h/bin/git"
  ln -sf "$JQ_BIN" "$h/bin/jq"
  for tool in $HOST_TOOLS; do
    case " ${OMIT:-} " in *" $tool "*) continue ;; esac
    printf '#!%s\nexit 0\n' "$BASH_BIN" > "$h/bin/$tool"
    chmod +x "$h/bin/$tool"
  done
  # pi lists a model so the unpinned sign-in check passes.
  case " ${OMIT:-} " in *" pi "*) ;; *)
    printf '#!%s\necho "anthropic claude-x"\n' "$BASH_BIN" > "$h/bin/pi" ;;
  esac
  printf '#!%s\nexit 0\n' "$BASH_BIN" > "$h/ssh"
  chmod +x "$h/ssh"
  printf '%s\n' "peer1" > "$h/home/config/host-peers"
  if [ "${NO_CLONE:-0}" != 1 ]; then
    git init -q --bare "$h/origin.git"
    git init -q "$h/home/projects/fleetrepo"
    git -C "$h/home/projects/fleetrepo" commit -q --allow-empty -m init
    git -C "$h/home/projects/fleetrepo" remote add origin "$h/origin.git"
    git -C "$h/home/projects/fleetrepo" push -q origin HEAD:refs/heads/main
  fi
  printf '%s\n' "$h"
}

run_doctor() { # <host-dir> [args...]
  local h=$1
  shift
  env -i HOME="$h" PATH="$h/bin:$SYS_BIN" FM_HOME="$h/home" FM_HOST_TOOLS_SSH_BIN="$h/ssh" \
    FM_HOST_TOOLS_PEERS="${PEERS:-}" FM_HOST_TOOLS_TIMEOUT=10 "$BASH_BIN" "$DOCTOR" "$@" 2>&1
}

assert_gap() { # <host-dir> <check> <fix-substring> [doctor-args...]
  local h=$1 check=$2 fix=$3 out rc
  shift 3
  out=$(run_doctor "$h" "$@"); rc=$?
  [ "$rc" -eq 1 ] || fail "$check gap must exit 1, got $rc: $out"
  case "$out" in *"check $check=human:"*) ;; *) fail "$check must be a human check: $out" ;; esac
  case "$out" in *"action: $check: "*"$fix"*) ;; *) fail "$check must print the fix '$fix': $out" ;; esac
}

stub() { # <host-dir> <tool> <script-body>
  printf '#!%s\n%s\n' "$BASH_BIN" "$3" > "$1/bin/$2"
  chmod +x "$1/bin/$2"
}

test_healthy_host_passes_every_check() {
  local h out rc name
  h=$(make_host healthy)
  out=$(run_doctor "$h"); rc=$?
  [ "$rc" -eq 0 ] || fail "healthy host must exit 0, got $rc: $out"
  for name in host-gh host-git-access host-claude host-pi host-store host-no-mistakes host-treehouse host-bun host-ssh-peer1; do
    case "$out" in *"check $name=ok:"*) ;; *) fail "$name must be ok: $out" ;; esac
  done
  case "$out" in *"human:"*) fail "a healthy host reports no gap: $out" ;; esac
  pass "a host with every tool present and authenticated passes all checks"
}

test_unauthenticated_gh_prints_login_fix() {
  local h
  h=$(make_host gh-unauth)
  # shellcheck disable=SC2016 # the single-quoted body expands in the stub's own shell
  stub "$h" gh '[ "$1 $2" = "auth status" ] && exit 1
exit 0'
  assert_gap "$h" host-gh "gh auth login"
  pass "an unauthenticated gh is a failing check that prints gh auth login"
}

test_missing_tool_prints_install_fix() {
  local h tool check
  for tool in bun treehouse no-mistakes claude pi gh; do
    h=$(OMIT=$tool make_host "missing-$tool")
    check=host-$tool
    assert_gap "$h" "$check" "install"
  done
  pass "each missing tool is a failing check that prints an install command"
}

test_claude_and_pi_auth_failures() {
  local h
  h=$(make_host claude-unauth)
  # shellcheck disable=SC2016 # the single-quoted body expands in the stub's own shell
  stub "$h" claude '[ "$1 $2" = "auth status" ] && exit 1
exit 0'
  assert_gap "$h" host-claude "claude auth login"
  h=$(make_host pi-unauth)
  stub "$h" pi 'exit 0'
  assert_gap "$h" host-pi "pi auth login"
  h=$(make_host pi-pinned)
  printf '%s\n%s\n' "/root" "openai" > "$h/home/config/pi-account"
  # shellcheck disable=SC2016 # the single-quoted body expands in the stub's own shell
  stub "$h" pi '[ "$1" = auth ] && exit 1
exit 0'
  assert_gap "$h" host-pi "pi auth login openai"
  pass "claude and pi sign-in failures print their login fixes, pinned providers included"
}

test_store_unreachable_and_missing() {
  local h
  h=$(make_host store-down)
  stub "$h" task 'exit 1'
  assert_gap "$h" host-store "dolt-server"
  h=$(OMIT=dolt make_host no-dolt)
  assert_gap "$h" host-store "dolt"
  pass "an unreachable store or a missing dolt is a failing check with a fix"
}

test_git_access_read_and_push_failures() {
  local h out
  h=$(make_host git-read)
  git -C "$h/home/projects/fleetrepo" remote set-url origin "$h/missing.git"
  assert_gap "$h" host-git-access "gh auth setup-git"
  h=$(make_host git-push)
  git -C "$h/home/projects/fleetrepo" remote set-url --push origin "$h/missing.git"
  assert_gap "$h" host-git-access "gh auth refresh"
  h=$(NO_CLONE=1 make_host git-none)
  out=$(run_doctor "$h")
  case "$out" in *"check host-git-access=skip:"*) ;; *) fail "no clone must skip, not pass or fail: $out" ;; esac
  pass "git read and push failures are failing checks; no fleet clone is a skip"
}

test_ssh_peer_failure_and_peer_sources() {
  local h out name
  h=$(make_host ssh-bad)
  stub "$h" ../ssh 'exit 255'
  assert_gap "$h" host-ssh-peer1 "ssh-copy-id peer1"
  h=$(make_host ssh-sources)
  printf '%s\n' '- mate - summary (host: mini0; root: /r; home: /h; scope: s; projects: p; added 2026-01-01)' > "$h/home/data/secondmates.md"
  out=$(PEERS=envpeer run_doctor "$h")
  for name in host-ssh-mini0 host-ssh-peer1 host-ssh-envpeer; do
    case "$out" in *"check $name=ok:"*) ;; *) fail "$name must be checked: $out" ;; esac
  done
  pass "ssh peers come from remote secondmates, config/host-peers, and the environment"
}

test_record_and_ingest_write_the_fleet_record() {
  local h rec
  h=$(make_host record)
  # shellcheck disable=SC2016 # the single-quoted body expands in the stub's own shell
  stub "$h" gh '[ "$1 $2" = "auth status" ] && exit 1
exit 0'
  run_doctor "$h" --record --host studio >/dev/null
  rec=$h/home/state/host-readiness/studio.json
  jq -e '.schema == "fm-host-readiness.v1" and .host == "studio" and .ready == false
    and (.checks[] | select(.name == "host-gh") | .status == "human" and .action == "gh auth login")' "$rec" >/dev/null ||
    fail "record wrong: $(cat "$rec")"
  printf '%s\n' 'check host-gh=ok: gh is signed in' 'check required=ok: ignored' 'check host-bun=human: bun is not installed on this host' 'action: host-bun: brew install oven-sh/bun/bun' |
    FM_HOME="$h/home" "$BASH_BIN" "$DOCTOR" --ingest far >/dev/null || fail "ingest must exit 0"
  jq -e '.host == "far" and (.checks | length) == 2 and .ready == false
    and (.checks[] | select(.name == "host-bun") | .action == "brew install oven-sh/bun/bun")' "$h/home/state/host-readiness/far.json" >/dev/null ||
    fail "ingest record wrong: $(cat "$h/home/state/host-readiness/far.json")"
  pass "--record and --ingest write the record the fleet snapshot reads"
}

fm_test_run \
  test_healthy_host_passes_every_check \
  test_unauthenticated_gh_prints_login_fix \
  test_missing_tool_prints_install_fix \
  test_claude_and_pi_auth_failures \
  test_store_unreachable_and_missing \
  test_git_access_read_and_push_failures \
  test_ssh_peer_failure_and_peer_sources \
  test_record_and_ingest_write_the_fleet_record
