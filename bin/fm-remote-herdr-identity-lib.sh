#!/usr/bin/env bash
# Which Herdr session and launch-agent label one Firstmate code root's remote
# second mates use on this account.
#
# Source this file; it defines functions only. It is the single owner of that
# identity: bin/fm-remote-doctor.sh prepares the service under it, and
# bin/fm-remote-secondmate-control.sh launches, relaunches, and validates
# endpoints under it, so readiness and launch always name the same service.
# bin/fm-spawn.sh validates a remote route's reported session against the
# names this library can produce.
#
# The deployment's FM_REMOTE_HERDR_SESSION setting selects the mode, and an
# unset setting means `default`:
#   default                 The host's own shared session. Firstmate runs no
#                           launch agent for it and owns no server lifecycle,
#                           so no owner record applies.
#   fm-remote               The managed, per-code-root identity below.
#   anything else           A dedicated session of that name, with the label
#                           dev.firstmate.herdr.<name> and the owner record
#                           remote-herdr-session-owner-<name>. The name is the
#                           operator's choice, so it is never root-derived.
# A derived fm-remote-<root-id> left in the environment selects the managed
# mode again, so resolving twice names the same service.
#
# In the managed mode, the code root recorded in
# ~/.firstmate/remote-herdr-owner owns the primary
# fm-remote session and dev.firstmate.herdr.fm-remote label. Before owner
# records existed, the guard path in the primary darwin launch agent was the
# only durable evidence of its root, so it stands in for a missing record. Every
# other code root on the account gets fm-remote-<root-id> and
# dev.firstmate.herdr.fm-remote-<root-id>, recorded in
# ~/.firstmate/remote-herdr-owner-<root-id>, where <root-id> is the first 16
# hex digits of the SHA-256 of the root path.
#
# Functions:
#   fm_remote_herdr_identity <fm-root>
#     Sets FM_REMOTE_HERDR_SESSION, FM_REMOTE_HERDR_LABEL,
#     FM_REMOTE_HERDR_DEDICATED (1 when Firstmate manages the session's
#     server lifecycle, 0 for the host-owned default session),
#     FM_REMOTE_HERDR_OWNER_DIR, FM_REMOTE_HERDR_OWNER_FILE, and
#     FM_REMOTE_HERDR_OWNER_ROOT (the root proven to own the resolved
#     session, empty when unproven). Returns 1 with
#     FM_REMOTE_HERDR_IDENTITY_ERROR set when the setting is not a usable
#     session name or <fm-root> needs a root-derived identity and no SHA-256
#     tool resolves.
#   fm_remote_herdr_session_acceptable <session>
#     Succeeds when <session> is one this deployment's setting can produce;
#     the parent-side check of what a remote launch reports, since the parent
#     cannot compute the remote host's root-derived name.
#   fm_remote_herdr_recorded_owner <owner-file>
#     Prints the root recorded in <owner-file>, nothing when it is absent or
#     not a plain file in a plain directory.
#   fm_remote_herdr_session_name_valid <session>
#     Succeeds for fm-remote and fm-remote-<root-id> only.

fm_remote_herdr_recorded_owner() { # <owner-file>
  local file=$1 dir owner=
  dir=${file%/*}
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r owner < "$file" || true
  printf '%s' "$owner"
}

fm_remote_herdr_root_id() { # <fm-root>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    read -r digest _ < <(printf '%s' "$1" | shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    read -r digest _ < <(printf '%s' "$1" | sha256sum) || return 1
  else
    return 1
  fi
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "${digest:0:16}"
}

# Decode the first shell-quoted argument of the stored `exec` command without
# evaluating it. The renderer uses single quotes, with '\'' for apostrophes.
fm_remote_herdr_legacy_guard() { # <plist>
  local command rest part guard=
  command=$(sed -n 's/^[[:space:]]*<string>exec //p' "$1")
  rest=$command
  while [[ "$rest" == "'"* ]]; do
    rest=${rest#\'}
    [[ "$rest" == *"'"* ]] || return 1
    part=${rest%%\'*}
    guard=$guard$part
    rest=${rest#*\'}
    if [[ "$rest" == "\\'"* ]]; then
      guard="$guard'"
      rest=${rest#??}
    else
      [[ "$rest" == ' '* ]] || return 1
      case "$guard" in */bin/fm-remote-herdr-guard.sh) printf '%s' "$guard"; return 0 ;; esac
      return 1
    fi
  done
  return 1
}

# The root proven to own a service: its owner record, else on darwin the guard
# path in its launch agent's plist (the only evidence before owner records).
fm_remote_herdr_proven_owner() { # <owner-file> <plist>
  local owner guard
  owner=$(fm_remote_herdr_recorded_owner "$1")
  if [ -z "$owner" ] && [ -f "$2" ] && [ ! -L "$2" ]; then
    case "${FM_REMOTE_JOB_PLATFORM_OVERRIDE:-$(uname -s 2>/dev/null || true)}" in
      Darwin|darwin)
        guard=$(fm_remote_herdr_legacy_guard "$2" 2>/dev/null || true)
        owner=${guard%/bin/fm-remote-herdr-guard.sh}
        ;;
    esac
  fi
  printf '%s' "$owner"
}

# Whether the setting selects the managed per-code-root identity.
fm_remote_herdr_managed_request() { # <requested-session>
  fm_remote_herdr_session_name_valid "$1"
}

# Consumed by the sourcing caller, so its assignments read as unused here.
# shellcheck disable=SC2034
fm_remote_herdr_identity() { # <fm-root>
  local root=$1 requested=${FM_REMOTE_HERDR_SESSION:-default} owner id
  FM_REMOTE_HERDR_IDENTITY_ERROR=
  FM_REMOTE_HERDR_OWNER_DIR="${HOME:-}/.firstmate"
  FM_REMOTE_HERDR_DEDICATED=1
  if [ "$requested" = default ]; then
    FM_REMOTE_HERDR_SESSION=default
    FM_REMOTE_HERDR_LABEL=dev.firstmate.herdr.default
    FM_REMOTE_HERDR_OWNER_FILE=
    FM_REMOTE_HERDR_OWNER_ROOT=
    FM_REMOTE_HERDR_DEDICATED=0
    return 0
  fi
  if ! fm_remote_herdr_managed_request "$requested"; then
    case "$requested" in
      ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
        FM_REMOTE_HERDR_IDENTITY_ERROR="FM_REMOTE_HERDR_SESSION '$requested' is not a usable session name; use letters, digits, dot, underscore, or dash, starting with a letter or digit"
        return 1
        ;;
    esac
    FM_REMOTE_HERDR_SESSION=$requested
    FM_REMOTE_HERDR_LABEL="dev.firstmate.herdr.$requested"
    FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-session-owner-$requested"
    FM_REMOTE_HERDR_OWNER_ROOT=$(fm_remote_herdr_proven_owner "$FM_REMOTE_HERDR_OWNER_FILE" \
      "${HOME:-}/Library/LaunchAgents/$FM_REMOTE_HERDR_LABEL.plist")
    return 0
  fi
  FM_REMOTE_HERDR_SESSION=fm-remote
  FM_REMOTE_HERDR_LABEL=dev.firstmate.herdr.fm-remote
  FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner"
  owner=$(fm_remote_herdr_proven_owner "$FM_REMOTE_HERDR_OWNER_FILE" \
    "${HOME:-}/Library/LaunchAgents/$FM_REMOTE_HERDR_LABEL.plist")
  FM_REMOTE_HERDR_OWNER_ROOT=$owner
  [ -n "$owner" ] && [ "$owner" != "$root" ] || return 0
  id=$(fm_remote_herdr_root_id "$root") || {
    FM_REMOTE_HERDR_IDENTITY_ERROR="no SHA-256 tool resolves to name the Herdr session for code root $root"
    return 1
  }
  FM_REMOTE_HERDR_SESSION="fm-remote-$id"
  FM_REMOTE_HERDR_LABEL="dev.firstmate.herdr.fm-remote-$id"
  FM_REMOTE_HERDR_OWNER_FILE="$FM_REMOTE_HERDR_OWNER_DIR/remote-herdr-owner-$id"
  FM_REMOTE_HERDR_OWNER_ROOT=$(fm_remote_herdr_recorded_owner "$FM_REMOTE_HERDR_OWNER_FILE")
}

fm_remote_herdr_session_name_valid() { # <session>
  local id
  [ "$1" != fm-remote ] || return 0
  case "$1" in fm-remote-*) ;; *) return 1 ;; esac
  id=${1#fm-remote-}
  [ "${#id}" -eq 16 ] || return 1
  case "$id" in *[!0-9a-f]*) return 1 ;; esac
}

fm_remote_herdr_session_acceptable() { # <session>
  local requested=${FM_REMOTE_HERDR_SESSION:-default}
  if fm_remote_herdr_managed_request "$requested"; then
    fm_remote_herdr_session_name_valid "$1"
  else
    [ "$1" = "$requested" ]
  fi
}
