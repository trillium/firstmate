#!/usr/bin/env bash
# fm-host-tools-lib.sh - the host tool and authentication readiness checks.
#
# Source this file and call:
#   fm_host_tools_collect <emit-fn>
#
# Each check calls `<emit-fn> <name> <value> [operator-action]`, the same
# record shape bin/fm-remote-doctor.sh uses, where <value> is `ok: <evidence>`
# or `human: <what is missing>` and the action is the exact command that closes
# the gap. A missing or unauthenticated tool is therefore a failing check that
# prints its own fix, and a caller prints `check <name>=<value>` and
# `action: <name>: <fix>` lines exactly as the remote doctor does.
# bin/fm-host-tools-doctor.sh is the standalone entry point,
# `fm-remote-doctor.sh --host-tools` appends the same checks to a remote
# second-mate readiness report, and bin/fm-fleet-snapshot.sh reads the recorded
# result. This file is the single owner of the checks.
#
# Checks (every name begins `host-`):
#   host-gh            gh present and `gh auth status` signed in
#   host-git-access    for each fleet repo clone under $FM_HOME/projects with an
#                      origin: `git ls-remote origin` (clone/fetch access) and
#                      `git push --dry-run` (push access); no clone is a skip
#   host-claude        claude present and `claude auth status` signed in
#   host-pi            pi present and signed in: `pi auth check` for each
#                      provider on line 2 of config/pi-account, else a non-empty
#                      `pi --list-models`
#   host-store         bd (or the task wrapper) and dolt present, and the
#                      configured store command answers
#   host-no-mistakes   no-mistakes present and its daemon status answers
#   host-treehouse     treehouse present and answering
#   host-bun           bun present and answering
#   host-ssh-<peer>    BatchMode ssh to each peer: the hosts of remote
#                      secondmates in data/secondmates.md, plus config/host-peers
#                      (one alias per line) and FM_HOST_TOOLS_PEERS (space
#                      separated); no peers is a skip
#
# Environment knobs: FM_HOST_TOOLS_TIMEOUT (seconds per probe, default 15),
# FM_HOST_TOOLS_STORE_CMD (store reachability command, default `task list
# --limit 1`, falling back to `bd list --limit 1`), FM_HOST_TOOLS_SSH_BIN (ssh
# executable, default ssh).

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

fm_host_tools_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    *) echo other ;;
  esac
}

# The exact install command for a tool on this host.
fm_host_tools_install_cmd() { # <tool>
  local brew=0
  command -v brew >/dev/null 2>&1 && brew=1
  case "$1" in
    gh) [ "$brew" -eq 1 ] && echo 'brew install gh' || echo 'install gh from https://cli.github.com' ;;
    claude) echo 'npm install -g @anthropic-ai/claude-code' ;;
    pi) echo 'npm install -g @mariozechner/pi-coding-agent' ;;
    beads) [ "$brew" -eq 1 ] && echo 'brew install beads' || echo 'npm install -g @beads/bd' ;;
    dolt) [ "$brew" -eq 1 ] && echo 'brew install dolt' || echo 'install dolt from https://github.com/dolthub/dolt/releases' ;;
    no-mistakes) echo 'install no-mistakes from https://github.com/kunchenguid/no-mistakes' ;;
    treehouse) echo 'install treehouse from https://github.com/kunchenguid/treehouse' ;;
    bun) [ "$brew" -eq 1 ] && echo 'brew install oven-sh/bun/bun' || echo 'curl -fsSL https://bun.sh/install | bash' ;;
    ssh) echo 'install an OpenSSH client (apt install openssh-client)' ;;
    *) echo "install $1 and put it on PATH" ;;
  esac
}

# Run a bounded probe with no stdin; stdout and stderr are discarded unless the
# caller captures them.
fm_host_tools_probe() { # <command...>
  fm_run_timed "${FM_HOST_TOOLS_TIMEOUT:-15}" "$@" </dev/null
}

fm_host_tools_missing() { # <emit-fn> <name> <tool>
  "$1" "$2" "human: $3 is not installed on this host" "$(fm_host_tools_install_cmd "$3")"
}

fm_host_tools_check_simple() { # <emit-fn> <name> <tool> <probe-args...>
  local emit=$1 name=$2 tool=$3
  shift 3
  command -v "$tool" >/dev/null 2>&1 || { fm_host_tools_missing "$emit" "$name" "$tool"; return 0; }
  if fm_host_tools_probe "$tool" "$@" >/dev/null 2>&1; then
    "$emit" "$name" "ok: $tool answers $*"
  else
    "$emit" "$name" "human: $tool is installed but \`$tool $*\` fails" "run \`$tool $*\` and repair what it reports"
  fi
}

fm_host_tools_check_gh() { # <emit-fn>
  command -v gh >/dev/null 2>&1 || { fm_host_tools_missing "$1" host-gh gh; return 0; }
  if fm_host_tools_probe gh auth status >/dev/null 2>&1; then
    "$1" host-gh "ok: gh is signed in"
  else
    "$1" host-gh "human: gh is not logged in" "gh auth login"
  fi
}

fm_host_tools_fleet_repos() { # prints one clone directory per line
  local home=${FM_HOME:-} dir
  [ -d "$home/projects" ] || return 0
  for dir in "$home"/projects/*/; do
    [ -e "${dir}.git" ] || continue
    git -C "$dir" remote get-url origin >/dev/null 2>&1 || continue
    printf '%s\n' "${dir%/}"
  done
}

fm_host_tools_check_git() { # <emit-fn>
  local emit=$1 dir name bad='' good=0 first_fix=''
  command -v git >/dev/null 2>&1 || { fm_host_tools_missing "$emit" host-git-access git; return 0; }
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    name=${dir##*/}
    if ! fm_host_tools_probe git -C "$dir" ls-remote origin >/dev/null 2>&1; then
      bad="${bad:+$bad, }$name (cannot read origin)"
      first_fix=${first_fix:-"gh auth setup-git && git -C $dir ls-remote origin"}
    elif ! fm_host_tools_probe git -C "$dir" push --dry-run origin HEAD:refs/heads/fm-host-readiness-probe >/dev/null 2>&1; then
      bad="${bad:+$bad, }$name (no push access)"
      first_fix=${first_fix:-"gh auth refresh -s repo && git -C $dir push --dry-run origin HEAD:refs/heads/fm-host-readiness-probe"}
    else
      good=$((good + 1))
    fi
  done < <(fm_host_tools_fleet_repos)
  if [ -n "$bad" ]; then
    "$emit" host-git-access "human: git access failed for $bad" "$first_fix"
  elif [ "$good" -eq 0 ]; then
    "$emit" host-git-access "skip: no fleet repo clone with an origin under ${FM_HOME:-FM_HOME}/projects"
  else
    "$emit" host-git-access "ok: clone and push access to $good fleet repo(s)"
  fi
}

fm_host_tools_check_claude() { # <emit-fn>
  command -v claude >/dev/null 2>&1 || { fm_host_tools_missing "$1" host-claude claude; return 0; }
  if fm_host_tools_probe claude auth status >/dev/null 2>&1; then
    "$1" host-claude "ok: claude is signed in"
  else
    "$1" host-claude "human: claude is not signed in" "claude auth login"
  fi
}

fm_host_tools_check_pi() { # <emit-fn>
  local emit=$1 providers='' provider bad='' out
  command -v pi >/dev/null 2>&1 || { fm_host_tools_missing "$emit" host-pi pi; return 0; }
  [ ! -f "${FM_HOME:-}/config/pi-account" ] || providers=$(sed -n '2p' "$FM_HOME/config/pi-account")
  if [ -n "$providers" ]; then
    for provider in $providers; do
      fm_host_tools_probe pi auth check --provider "$provider" --json --no-refresh >/dev/null 2>&1 \
        || bad="${bad:+$bad }$provider"
    done
    if [ -n "$bad" ]; then
      "$emit" host-pi "human: pi is not signed in for provider(s): $bad" "pi auth login ${bad%% *}"
    else
      "$emit" host-pi "ok: pi is signed in for $providers"
    fi
    return 0
  fi
  out=$(fm_host_tools_probe pi --list-models 2>/dev/null || true)
  if [ -n "$out" ]; then
    "$emit" host-pi "ok: pi lists authenticated models"
  else
    "$emit" host-pi "human: pi lists no authenticated model" "pi auth login <provider>"
  fi
}

fm_host_tools_check_store() { # <emit-fn>
  local emit=$1 cmd missing=''
  command -v dolt >/dev/null 2>&1 || missing=dolt
  if ! command -v bd >/dev/null 2>&1 && ! command -v task >/dev/null 2>&1; then
    missing="${missing:+$missing }beads"
  fi
  if [ -n "$missing" ]; then
    "$emit" host-store "human: $missing not installed, so the beads/dolt store is unreachable" \
      "$(fm_host_tools_install_cmd "${missing%% *}")"
    return 0
  fi
  cmd=${FM_HOST_TOOLS_STORE_CMD:-}
  if [ -z "$cmd" ]; then
    if command -v task >/dev/null 2>&1; then cmd='task list --limit 1'; else cmd='bd list --limit 1'; fi
  fi
  # shellcheck disable=SC2086
  if fm_host_tools_probe $cmd >/dev/null 2>&1; then
    "$emit" host-store "ok: store command answers ($cmd)"
  else
    "$emit" host-store "human: store command \`$cmd\` fails, so the dolt server is unreachable" \
      "dolt sql-server must answer on :3307; on the store host run: launchctl kickstart -k gui/\$(id -u)/com.brain.dolt-server, elsewhere re-open the :3307 forward, then rerun \`$cmd\`"
  fi
}

fm_host_tools_check_no_mistakes() { # <emit-fn>
  local emit=$1
  command -v no-mistakes >/dev/null 2>&1 || { fm_host_tools_missing "$emit" host-no-mistakes no-mistakes; return 0; }
  if fm_host_tools_probe no-mistakes daemon status >/dev/null 2>&1; then
    "$emit" host-no-mistakes "ok: no-mistakes daemon answers"
  else
    "$emit" host-no-mistakes "human: no-mistakes daemon is not answering" "no-mistakes daemon status (firstmate starts the daemon: no-mistakes daemon start)"
  fi
}

fm_host_tools_peers() { # prints one peer alias per line, deduplicated
  local home=${FM_HOME:-} peer
  {
    [ ! -f "$home/data/secondmates.md" ] || sed -n 's/.*(host:[[:space:]]*\([^;)]*\);.*/\1/p' "$home/data/secondmates.md"
    [ ! -f "$home/config/host-peers" ] || sed -e 's/#.*//' -e 's/[[:space:]]//g' "$home/config/host-peers"
    for peer in ${FM_HOST_TOOLS_PEERS:-}; do printf '%s\n' "$peer"; done
  } | sed '/^$/d' | awk '!seen[$0]++'
}

fm_host_tools_check_ssh() { # <emit-fn>
  local emit=$1 ssh_bin=${FM_HOST_TOOLS_SSH_BIN:-ssh} peer n=0
  if ! command -v "$ssh_bin" >/dev/null 2>&1; then
    fm_host_tools_missing "$emit" host-ssh ssh
    return 0
  fi
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    n=$((n + 1))
    if fm_host_tools_probe "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=5 "$peer" true >/dev/null 2>&1; then
      "$emit" "host-ssh-$peer" "ok: ssh to $peer works without a prompt"
    else
      "$emit" "host-ssh-$peer" "human: ssh to $peer fails in BatchMode" "ssh-copy-id $peer && ssh -o BatchMode=yes $peer true"
    fi
  done < <(fm_host_tools_peers)
  [ "$n" -gt 0 ] || "$emit" host-ssh "skip: no ssh peers configured (data/secondmates.md hosts, config/host-peers, FM_HOST_TOOLS_PEERS)"
}

fm_host_tools_collect() { # <emit-fn>
  local emit=$1
  fm_host_tools_check_gh "$emit"
  fm_host_tools_check_git "$emit"
  fm_host_tools_check_claude "$emit"
  fm_host_tools_check_pi "$emit"
  fm_host_tools_check_store "$emit"
  fm_host_tools_check_no_mistakes "$emit"
  fm_host_tools_check_simple "$emit" host-treehouse treehouse --version
  fm_host_tools_check_simple "$emit" host-bun bun --version
  fm_host_tools_check_ssh "$emit"
}
