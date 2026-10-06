#!/usr/bin/env bash
# fm-stack-doctor-lib.sh - evidence helpers for bin/fm-stack-doctor.sh.
#
# This library owns the primitives the stack doctor composes: one probe per
# fact, every probe bounded by a short timeout, and every probe printing the
# observed value rather than a judgement about it.
# It never mutates anything, so a diagnostic run cannot change the stack it
# describes, and it never hides a missing tool behind silence: an absent tool
# is reported as evidence too.
#
# Callers source this file and use fm_sd_emit as the only output entry point,
# so the layer line protocol stays stated in exactly one place.

# Return 0 and print the absolute path when a tool resolves on PATH.
fm_sd_tool() { # <tool>
  command -v "$tool" 2>/dev/null || true
}

# Print one `name=<tool> path=<path|absent> status=<present|missing>` line per
# tool, because a probe that silently did not run is the failure mode this
# whole command exists to remove.
fm_sd_report_tools() { # <tool...>
  local tool path
  for tool in "$@"; do
    path=$(fm_sd_tool "$tool")
    if [ -n "$path" ] && [ -x "$path" ]; then
      fm_sd_emit tools "$tool" "path=$path" status=present
    else
      fm_sd_emit tools "$tool" path=absent status=missing
    fi
  done
}

# Print the single evidence line every layer shares.
# $1 is the layer, $2 its subject, and the rest are key=value pairs.
fm_sd_emit() { # <layer> <subject> <key=value...>
  local layer=$1 subject=$2
  shift 2
  local line pair
  line="[$layer] $subject"
  for pair in "$@"; do
    line="$line $pair"
  done
  printf '%s\n' "$line"
}

# Print a run-wide elapsed marker under the summary layer.
fm_sd_emit_summary() { # <down-count> <layer-count>
  local elapsed verdict
  elapsed=$(( $(fm_sd_epoch) - ${FM_SD_STARTED:-0} ))
  if [ "$1" -eq 0 ]; then verdict=ok; else verdict=degraded; fi
  fm_sd_emit summary doctor \
    "layers=$2" "down=$1" "elapsed=${elapsed}s" "budget=${FM_SD_BUDGET:-30}s" \
    "verdict=$verdict"
}

# Seconds since the epoch, so callers never depend on a platform date flag.
fm_sd_epoch() { date +%s; }

# Convert ps etime output (DD-HH:MM:SS, HH:MM:SS, MM:SS) into a compact span.
fm_sd_compact_uptime() { # <ps-etime>
  local raw=$1 days hours minutes seconds
  days=0
  case "$raw" in
    *-*) days=${raw%%-*}; raw=${raw#*-} ;;
  esac
  hours=${raw%%:*}
  minutes=${raw#*:}
  minutes=${minutes%%:*}
  seconds=${raw##*:}
  case "$days$hours$minutes$seconds" in
    ''|*[!0-9]*) printf 'unknown(%s)' "$1"; return 0 ;;
  esac
  # 10# keeps a zero-padded field such as 09 minutes from being read as octal.
  days=$((10#$days)) hours=$((10#$hours)) minutes=$((10#$minutes)) seconds=$((10#$seconds))
  if [ "$days" -gt 0 ]; then
    printf '%sd%02dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh%02dm' "$hours" "$minutes"
  else
    printf '%dm%02ds' "$minutes" "$seconds"
  fi
}

# Print the pid listening on a TCP port, or nothing when none is.
# The listening socket, rather than a process-name search, is the evidence that
# a layer actually holds its port.
fm_sd_port_pid() { # <port>
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -F pn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2); next }
    /^n/ && pid != "" { print pid; exit }
  '
}

# Print the local address a port listens on, in `addr:port` form.
fm_sd_listen_addr() { # <port>
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fn 2>/dev/null | awk '
    /^n/ { print substr($0, 2); exit }
  '
}

# Print `pid=<pid> uptime=<span> state=<running|gone>` for a process.
fm_sd_process_facts() { # <pid>
  local pid=$1 etime
  if ! ps -p "$pid" -o pid= >/dev/null 2>&1; then
    printf 'pid=%s uptime=unknown state=gone' "$pid"
    return 0
  fi
  etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)
  printf 'pid=%s uptime=%s state=running' "$pid" "$(fm_sd_compact_uptime "${etime:-unknown}")"
}

# Print the full command line of a process, whitespace collapsed.
fm_sd_cmdline() { # <pid>
  ps -p "$1" -o command= 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' || true
}

# Print the working directory of a process.
fm_sd_cwd() { # <pid>
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }' || true
}

# Print the launchd label owning a pid, or unknown.
# The service label is what a reader needs in order to inspect or restart a
# layer, so it belongs in the same line as the pid.
fm_sd_launchd_label() { # <pid>
  command -v launchctl >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  launchctl list 2>/dev/null | awk -v want="$1" '
    $1 == want && $2 ~ /^-?[0-9]+$/ { print $3; found = 1; exit }
    END { if (!found) print "unknown" }
  '
}

# Print the deployed revision facts for a source directory.
# dirty=yes is evidence that the running code may not match the commit, which
# is exactly the mismatch a revision question is trying to rule out.
fm_sd_git_facts() { # <dir>
  local dir=$1 short when branch dirty
  if ! command -v git >/dev/null 2>&1; then
    printf 'revision=unknown reason=git-absent'
    return 0
  fi
  short=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)
  if [ -z "$short" ]; then
    printf 'revision=unknown reason=git-could-not-resolve-head-at-this-path'
    return 0
  fi
  when=$(git -C "$dir" log -1 --format=%cI 2>/dev/null || true)
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null | head -1 || true)
  printf 'revision=%s revision_date=%s branch=%s dirty=%s' \
    "$short" "${when:-unknown}" "${branch:-detached}" \
    "$( [ -n "$dirty" ] && printf yes || printf no )"
}

# Probe an HTTP URL and print `status=<code> body=<one-line excerpt>`.
# A bare status is not a verdict, so the excerpt travels with the code.
fm_sd_http_probe() { # <url> [timeout]
  local url=$1 timeout=${2:-3} out code body
  if ! command -v curl >/dev/null 2>&1; then
    printf 'status=unprobed reason=curl-absent'
    return 0
  fi
  out=$(curl -s -m "$timeout" -o - -w '\n%{http_code}' "$url" 2>/dev/null) || out=''
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *) code="curl-error(${code:-no-response})" ;;
  esac
  printf 'status=%s body=%s' "$code" "$(fm_sd_one_line "$body" 160)"
}

# Collapse whitespace and truncate, so a body stays one readable fact.
fm_sd_one_line() { # <text> [max-chars]
  local text=${1-} max=${2:-120} out
  out=$(printf '%s' "$text" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
  if [ "${#out}" -gt "$max" ]; then
    printf '%s...' "${out:0:$max}"
  else
    printf '%s' "$out"
  fi
}

# Run a real MCP initialize handshake against a streamable-HTTP endpoint and
# then list its tools, printing what the server actually answered.
#
# A 200 on the POST is not proof of an MCP route, so this prints the
# negotiated protocol version, the server identity it reported, and the tool
# count: a route that answers with a status without completing the handshake
# is visible as such instead of passing as healthy.
#
# The doctor therefore generates real MCP traffic against every group it
# probes, which the upstream servers record in their own logs.
fm_sd_mcp_probe() { # <endpoint> [timeout]
  local endpoint=$1 timeout=${2:-5}
  if ! command -v curl >/dev/null 2>&1; then
    printf 'handshake=unprobed reason=curl-absent'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'handshake=unprobed reason=jq-absent'
    return 0
  fi
  local dir headers body code session result
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-stack-doctor.XXXXXX") || dir=${TMPDIR:-/tmp}
  headers="$dir/headers"
  code=$(curl -s -m "$timeout" -D "$headers" -o "$dir/body" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"fm-stack-doctor","version":"1"}}}' \
    "$endpoint" 2>/dev/null) || code=''
  body=$(cat "$dir/body" 2>/dev/null || true)
  session=$(awk 'BEGIN { IGNORECASE = 1 } tolower($1) == "mcp-session-id:" { gsub(/\r/, "", $2); print $2; exit }' \
    "$headers" 2>/dev/null || true)
  result=$(printf '%s' "$body" | jq -c '.result // empty' 2>/dev/null || true)
  if [ "$code" != 200 ]; then
    local error
    error=$(printf '%s' "$body" | jq -r '.error // empty | tostring' 2>/dev/null || true)
    rm -rf "$dir"
    printf 'handshake=failed stage=initialize http=%s result=%s' \
      "${code:-no-response}" "$(fm_sd_one_line "$error" 120)"
    return 0
  fi
  local protocol server version
  protocol=$(printf '%s' "$result" | jq -r '.protocolVersion // "unreported"' 2>/dev/null || printf 'unreported')
  server=$(printf '%s' "$result" | jq -r '.serverInfo.name // "unreported"' 2>/dev/null || printf 'unreported')
  version=$(printf '%s' "$result" | jq -r '.serverInfo.version // "unreported"' 2>/dev/null || printf 'unreported')
  if [ -z "$session" ]; then
    rm -rf "$dir"
    printf 'handshake=failed stage=initialize-reason-no-session-id http=200 server="%s" server_version=%s' \
      "$server" "$version"
    return 0
  fi
  curl -s -m "$timeout" -o /dev/null -X POST -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $session" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$endpoint" >/dev/null 2>&1 || true
  local tools_body tools sample
  tools_body=$(curl -s -m "$timeout" -X POST -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $session" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$endpoint" 2>/dev/null) || tools_body=''
  rm -rf "$dir"
  if ! printf '%s' "$tools_body" | jq -e '.result.tools' >/dev/null 2>&1; then
    printf 'handshake=failed stage=tools-list http=200 session=yes server="%s" result=%s' \
      "$server" "$(fm_sd_one_line "$tools_body" 120)"
    return 0
  fi
  tools=$(printf '%s' "$tools_body" | jq '[.result.tools[].name] | length' 2>/dev/null || printf 0)
  sample=$(printf '%s' "$tools_body" | jq -r '[.result.tools[0:3][].name] | join(", ")' 2>/dev/null || true)
  printf 'handshake=ok stage=complete protocol=%s server="%s" server_version=%s session=yes tools=%s sample="%s"' \
    "$protocol" "$server" "$version" "$tools" "$sample"
}

# Print the tailscale serve mapping document, and set the reason it is
# unavailable in FM_SD_SERVE_REASON when it cannot be read.
# The reason travels in a variable rather than on stdout, because every caller
# reads this document through a command substitution that would swallow a line.
# An empty FM_SD_SERVE_REASON means the document was read.
fm_sd_serve_json() {
  # The reason travels in a variable rather than on stdout, because every caller
  # reads this document through a command substitution that would swallow a line.
  # shellcheck disable=SC2034 # The caller reads these after this call returns.
  FM_SD_SERVE_REASON=''
  # shellcheck disable=SC2034 # The caller reads these after this call returns.
  FM_SD_SERVE_DETAIL=''
  if ! command -v tailscale >/dev/null 2>&1; then
    FM_SD_SERVE_REASON=tailscale-absent
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC2034 # The caller reads this after the call returns.
    FM_SD_SERVE_REASON=jq-absent
    return 1
  fi
  local json
  if ! json=$(tailscale serve status --json 2>/dev/null) || [ -z "$json" ]; then
    # shellcheck disable=SC2034 # The caller reads this after the call returns.
    FM_SD_SERVE_REASON=tailscale-serve-status-unavailable
    return 1
  fi
  printf '%s' "$json"
  return 0
}

# Print one `host|path|target|funnel=yes|no` line per serve mapping.
# The fourth field is the funnel verdict alone, so a consumer reads it as a
# flag rather than re-parsing a label out of the field.
# The funnel verdict comes from the same document tailscale printed, so a
# mapping is never described as public because of how it looks.
fm_sd_serve_mappings() { # <json>
  printf '%s' "$1" | jq -r '
    . as $root
    | (($root.Web // {}) | to_entries[]) as $w
    | (($w.value.Handlers // {}) | to_entries[]) as $h
    | "\($w.key)|\($h.key)|\($h.value.Proxy // "-")|"
      + (if (($root.AllowFunnel // {})[$w.key] // false) then "yes" else "no" end)
  ' 2>/dev/null || true
  printf '%s' "$1" | jq -r '
    ((.TCP // {}) | to_entries[])
    | select(.value.TCPForward != null)
    | "*:\(.key)|tcp|\(.value.TCPForward)|no"
  ' 2>/dev/null || true
}

# Print a histogram of the request paths a log records, most frequent first.
# The composition of a log is what tells a reader which layer it can answer
# for, so the histogram is evidence in its own right.
fm_sd_log_paths() { # <path> [top-n]
  local file=$1 top=${2:-6}
  [ -f "$file" ] || return 0
  awk '
    {
      path = ""
      for (i = 1; i < NF; i++) {
        if ($i ~ /^(GET|POST|PUT|PATCH|DELETE|HEAD)$/) { path = $(i + 1); break }
      }
      if (path != "") { counts[path]++; last[path] = $1 }
    }
    END { for (p in counts) printf "%s|%d|%s\n", p, counts[p], last[p] }
  ' "$file" | sort -t'|' -k2,2nr | head -"$top"
}

# Count the lines of a log matching an extended regular expression.
# grep exits non-zero on zero matches while still printing its count, so the
# count is read from stdout rather than from the exit status.
fm_sd_log_count() { # <path> <ere>
  local file=$1 ere=$2 count
  if [ ! -f "$file" ]; then printf 0; return 0; fi
  count=$(grep -c -E -- "$ere" "$file" 2>/dev/null || true)
  case "$count" in
    ''|*[!0-9]*) printf 0 ;;
    *) printf '%s' "$count" ;;
  esac
}

# Print the newest line of a log matching an extended regular expression.
fm_sd_log_last() { # <path> <ere>
  local file=$1 ere=$2
  [ -f "$file" ] || return 0
  grep -E -- "$ere" "$file" 2>/dev/null | tail -1 || true
}

# Describe one log: what it is authoritative for, and what it is not.
# Silence about a layer is evidence only when the log can record that layer,
# so each line states both directions instead of leaving a reader to guess.
fm_sd_emit_log() { # <layer> <subject> <path> <authoritative-for> <not-authoritative-for>
  local file=$3 for=$4 not_for=$5 size lines modified stamp
  if [ ! -f "$file" ]; then
    fm_sd_emit "$1" "$2" "path=$file" status=absent \
      "authoritative_for=$for" "not_authoritative_for=$not_for" \
      'note=this layer has no log file at the reported path, so nothing this layer did can be read from logs'
    return 0
  fi
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ' || printf 0)
  lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || printf 0)
  stamp=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || printf 0)
  modified=$(fm_sd_iso_from_epoch "$stamp")
  fm_sd_emit "$1" "$2" "path=$file" status=present \
    "bytes=$size" "lines=$lines" "modified=$modified" \
    "authoritative_for=$for" "not_authoritative_for=$not_for"
}

# Print the launchd standard output and error log paths of a service label.
# A front's own log is the one its launch agent names, so that is where a
# reader has to look; the conventional path is never guessed here.
fm_sd_launchd_log_paths() { # <launchd-label>
  local label=${1:-} uid dump out err
  case "$label" in
    ''|unknown) return 0 ;;
  esac
  command -v launchctl >/dev/null 2>&1 || return 0
  uid=$(id -u 2>/dev/null || printf '')
  dump=$(launchctl print "gui/$uid/$label" 2>/dev/null) || return 0
  out=$(printf '%s' "$dump" | sed -n 's/.*stdout path = \(.*\)/\1/p' | head -1)
  err=$(printf '%s' "$dump" | sed -n 's/.*stderr path = \(.*\)/\1/p' | head -1)
  printf 'launchd_standard_out=%s launchd_standard_error=%s' "${out:-unknown}" "${err:-unknown}"
}

# Print a UTC timestamp for an epoch value, or unknown when it is not usable.
fm_sd_iso_from_epoch() { # <epoch>
  case "${1:-}" in
    ''|*[!0-9]*) printf 'unknown'; return 0 ;;
  esac
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf 'unknown'
}