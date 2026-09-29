#!/usr/bin/env bash
# tests/fm-remote-session-config.test.sh - the remote Herdr session name is a
# deployment choice, not a constant.
#
# Drives the real bin/fm-remote-doctor.sh against a minimal darwin fixture (a
# private HOME, a stub launchctl, no herdr) and asserts through the stable line
# protocol: FM_REMOTE_HERDR_SESSION unset targets session `default` with label
# dev.firstmate.herdr.default, an explicit value targets that session with its
# derived label, and a leftover dev.firstmate.herdr.fm-remote agent reports as
# fixable in check mode and is retired by --fix. Nothing here touches the
# runner's own launch agents or Herdr server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-session-config)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'fm_test_cleanup || true' EXIT

UID_NUM=$(id -u 2>/dev/null)

make_world() { # <name> -> sets WORLD_HOME and WORLD_BIN (stub launchctl)
  local name=$1 home bin
  home=$TMP_ROOT/$name-home
  bin=$TMP_ROOT/$name-bin
  mkdir -p "$home/Library/LaunchAgents" "$home/.local/bin" "$bin"
  cat > "$bin/launchctl" <<EOF
#!/usr/bin/env bash
set -u
domain=\${2:-}
case "\${1:-}" in
  print)
    case "\$domain" in
      gui/$UID_NUM) exit 0 ;;
      *) exit 113 ;;
    esac
    ;;
  bootout) exit 0 ;;
  bootstrap) printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 5 ;;
  kickstart) printf 'Kickstart failed\n' >&2; exit 5 ;;
esac
exit 0
EOF
  chmod +x "$bin/launchctl"
  WORLD_HOME=$home
  WORLD_BIN=$bin
}

run_doctor() { # <home> <bin> [args...]; DOCTOR_SESSION unset means env unset
  local home=$1 bin=$2
  shift 2
  set +e
  if [ "${DOCTOR_SESSION-unset}" = unset ]; then
    DOCTOR_OUT=$(env -u FM_REMOTE_HERDR_SESSION \
      HOME="$home" FM_HOME="$TMP_ROOT/project-home" \
      PATH="$home/.local/bin:$bin:/usr/bin:/bin" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=darwin SHELL=/bin/sh \
      "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1)
  else
    DOCTOR_OUT=$(FM_REMOTE_HERDR_SESSION="$DOCTOR_SESSION" \
      HOME="$home" FM_HOME="$TMP_ROOT/project-home" \
      PATH="$home/.local/bin:$bin:/usr/bin:/bin" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=darwin SHELL=/bin/sh \
      "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1)
  fi
  set -e
}

mkdir -p "$TMP_ROOT/project-home"

make_world default
unset DOCTOR_SESSION
run_doctor "$WORLD_HOME" "$WORLD_BIN"
assert_contains "$DOCTOR_OUT" "check launchagent=fixable: no Firstmate herdr launch agent at $WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.default.plist" "the unset default did not derive label dev.firstmate.herdr.default"
assert_contains "$DOCTOR_OUT" "check launchagent-legacy=ok: no legacy dev.firstmate.herdr.fm-remote agent remains" "a clean default home wrongly reported a legacy agent"
pass "unset FM_REMOTE_HERDR_SESSION targets session default"

make_world custom
DOCTOR_SESSION=custom run_doctor "$WORLD_HOME" "$WORLD_BIN"
assert_contains "$DOCTOR_OUT" "check launchagent=fixable: no Firstmate herdr launch agent at $WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.custom.plist" "FM_REMOTE_HERDR_SESSION=custom did not derive label dev.firstmate.herdr.custom"
pass "FM_REMOTE_HERDR_SESSION=custom targets session custom"

make_world legacy
printf '%s\n' "stale legacy plist" > "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist"
unset DOCTOR_SESSION
run_doctor "$WORLD_HOME" "$WORLD_BIN"
assert_contains "$DOCTOR_OUT" "check launchagent-legacy=fixable: legacy launch agent dev.firstmate.herdr.fm-remote remains from the previous fm-remote session" "check mode did not flag the leftover fm-remote agent"
run_doctor "$WORLD_HOME" "$WORLD_BIN" --fix
assert_contains "$DOCTOR_OUT" "fix launchagent-legacy=applied:" "--fix did not report retiring the leftover fm-remote agent"
assert_absent "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist" "--fix left the legacy fm-remote plist behind"
run_doctor "$WORLD_HOME" "$WORLD_BIN"
assert_contains "$DOCTOR_OUT" "check launchagent-legacy=ok: no legacy dev.firstmate.herdr.fm-remote agent remains" "the retired legacy agent still reports after --fix"
pass "the leftover fm-remote agent is retired by --fix"
