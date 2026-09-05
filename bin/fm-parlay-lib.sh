# shellcheck shell=bash
# bin/fm-parlay-lib.sh - shared read-only view of parlay's own durable spawn
# records, so helpers that parlay spawned (and firstmate never recorded as
# state/<id>.meta) stay visible to the fleet digest and fleet snapshot.
# Usage: . bin/fm-parlay-lib.sh
#
# READ-SIDE ONLY by design (robots-fyqf): this lib never mutates, closes, or
# reaps a parlay agent, never writes to parlay's store, and never reaches the
# parlay relay. It walks the same local store parlay's own launch listing
# scans - ${PARLAY_AGENT_HOME:-$HOME/.parlay/agents}/<id>/ with identity.md
# frontmatter, a session-start epoch, and an optional status file
# (bin/fm-parlay.sh's relay-free inventory; tools/cli/internal/identity/
# store.go owns AgentsRoot).
#
# Local-only on purpose: bin/fm-session-start.sh's fleet-state stage runs
# BEFORE the deferred network stage (AGENTS.md section 3), so nothing here may
# block on the relay. State therefore comes from the agent's own status file
# only; a live-but-silent or never-statused agent reads "unknown" rather than
# a relay answer, and absent/reachable state is never probed.
#
# One caller renders nothing when parlay is not in use: fm_parlay_store_present
# requires both the parlay binary and the store directory, so a machine that
# never runs parlay stays silent (quiet degradation, same gate the session-start
# PARLAY section already uses for `parlay sweep`).

# fm_parlay_store_root: print the store directory firstmate reads for
# parlay-spawned agents. Honors PARLAY_AGENT_HOME when set, else matches
# parlay's own default of "$HOME/.parlay/agents".
fm_parlay_store_root() {
  printf '%s' "${PARLAY_AGENT_HOME:-$HOME/.parlay/agents}"
}

# fm_parlay_store_present: true only when parlay is installed AND its store
# directory exists. The binary gate mirrors print_parlay_section's rule so
# "parlay absent" degrades silently everywhere; the store gate keeps an empty
# or never-used parlay quiet too.
fm_parlay_store_present() {
  command -v parlay >/dev/null 2>&1 || return 1
  [ -d "$(fm_parlay_store_root)" ] || return 1
  return 0
}

# fm_parlay_identity_value <file> <key>: first value for <key> in the YAML
# frontmatter of <file>, with surrounding double quotes stripped.
fm_parlay_identity_value() {
  local file=$1 key=$2 value
  value=$(sed -n "s/^${key}:[[:space:]]*//p" "$file" 2>/dev/null | head -1)
  case "$value" in
    \"*\") value=${value#\"} ; value=${value%\"} ;;
  esac
  printf '%s' "$value"
}

# fm_parlay_state_of <agent-dir>: the last non-empty status line's verb
# (the *: prefix), or "unknown" when there is no status file or no verb.
fm_parlay_state_of() {
  local dir=$1 line
  [ -f "$dir/status" ] || { printf 'unknown'; return 0; }
  line=$(awk 'NF { last=$0 } END { print last }' "$dir/status" 2>/dev/null)
  [ -n "$line" ] || { printf 'unknown'; return 0; }
  if [ "$line" != "${line%%:*}" ] && [ -n "${line%%:*}" ]; then
    printf '%s' "${line%%:*}"
  else
    printf 'unknown'
  fi
}

# fm_parlay_age_of <agent-dir> <now>: age in whole seconds from the agent's
# session-start epoch, or "unknown" when that file is missing or not a number.
fm_parlay_age_of() {
  local dir=$1 now=${2:-$(date +%s)} ts
  [ -f "$dir/session-start" ] || { printf 'unknown'; return 0; }
  ts=$(tr -d '[:space:]' < "$dir/session-start" 2>/dev/null)
  case "$ts" in
    ''|*[!0-9]*) printf 'unknown' ;;
    *) printf '%s' "$(( now - ts ))" ;;
  esac
}

# fm_parlay_agent_records [<root>]: one tab-separated line per recorded parlay
# agent, sorted by id:
#   <id>  <name>  <model>  <workdir>  <age|unknown>  <state|unknown>
# <workdir> is the identity's cwd, falling back to its worktree, then "-".
# Prints nothing when the store directory is absent.
fm_parlay_agent_records() {
  local root=${1:-$(fm_parlay_store_root)}
  local dir id name model cwd worktree workdir state age now
  [ -d "$root" ] || return 0
  now=$(date +%s)
  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/identity.md" ] || continue
    id=$(basename "$dir")
    name=$(fm_parlay_identity_value "$dir/identity.md" name)
    model=$(fm_parlay_identity_value "$dir/identity.md" model)
    cwd=$(fm_parlay_identity_value "$dir/identity.md" cwd)
    worktree=$(fm_parlay_identity_value "$dir/identity.md" worktree)
    workdir=${cwd:-$worktree}
    [ -n "$workdir" ] || workdir=-
    state=$(fm_parlay_state_of "$dir")
    age=$(fm_parlay_age_of "$dir" "$now")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$name" "$model" "$workdir" "$age" "$state"
  done | LC_ALL=C sort
}

# fm_fmt_parlay_age <seconds|unknown>: human age for the fleet digest.
fm_fmt_parlay_age() {
  local secs=$1
  case "$secs" in
    unknown) printf 'unknown' ;;
    ''|*[!0-9]*) printf 'unknown' ;;
    *)
      if [ "$secs" -lt 60 ]; then
        printf '%ss' "$secs"
      elif [ "$secs" -lt 3600 ]; then
        printf '%sm' "$(( secs / 60 ))"
      else
        printf '%sh %sm' "$(( secs / 3600 ))" "$(( (secs % 3600) / 60 ))"
      fi
      ;;
  esac
}