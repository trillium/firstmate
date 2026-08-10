#!/usr/bin/env bash
# fm-agent-axi.sh - read-only, data-gated triage of the live agent surface (task-lzlj Layer 1).
#
# Answers ONE question safely: "which agent sessions are safe to reap?" It is
# strictly READ-ONLY. It never closes a tab, tears down an agent, or mutates any
# pane, repo, or queue; there is no --reap action in this layer by design. It
# exists because a raw `herdr tab close` once killed a live secondmate: no
# liveness, unlanded-work, or pipeline gate was checked first. This tool checks
# all three and fails CLOSED.
#
# What it does, per herdr pane:
#   1. Enumerate the surface. `herdr tab list` gives per-tab label/ui-status but
#      NOT pane ids, so panes are enumerated from `herdr pane list` (which joins
#      pane_id -> tab_id) and labels are joined back from `herdr tab list`. Each
#      pane's authoritative process set comes from
#      `herdr pane process-info --pane <pane_id>`, whose foreground_processes[]
#      (argv/name/pid/cwd) plus shell_pid decide liveness.
#      CRITICAL SEMANTIC: liveness is a LIVE CHILD PROCESS, never the UI status
#      string. `agent_status:"done"` means the agent's last turn ended / it is
#      idle-between-turns; it is NOT process-terminated. A pane whose UI says
#      "done" but which still has a live `claude` (or other agent) foreground
#      child is a LIVE agent and is held.
#   2. Join work-state per derived agent cwd: `git -C <cwd> status --porcelain`
#      (dirty tree?) and ahead/behind vs upstream via
#      `git -C <cwd> rev-list --left-right --count @{u}...HEAD`, guarded for the
#      no-upstream case, to produce an "unlanded work" signal.
#   3. Join the no-mistakes queue: `no-mistakes status` in that cwd. A run whose
#      branch matches the pane's checked-out branch is a run "tied" to this
#      agent; an agent gating on no-mistakes is never classified safe.
#   4. Classify each pane into exactly one of:
#        SAFE-TO-REAP | HOLD-LIVE | HOLD-UNLANDED | HOLD-QUEUED | HOLD-UNKNOWN
#      Precedence (first match wins): unverifiable process probe -> HOLD-UNKNOWN;
#      live child -> HOLD-LIVE; tied no-mistakes run -> HOLD-QUEUED; dirty or
#      ahead -> HOLD-UNLANDED; everything provably clear -> SAFE-TO-REAP;
#      otherwise HOLD-UNKNOWN. SAFE-TO-REAP requires ALL of: no live agent child,
#      clean tree, nothing ahead of upstream, and no tied no-mistakes run. Any
#      probe that fails or is inconclusive degrades that one row to HOLD-UNKNOWN
#      and the sweep keeps going; the default is always to fail toward HOLD.
#   5. Output BOTH a human table (default) and structured JSON (`--json`). The
#      JSON envelope `fm-agent-axi.v1` carries every raw signal plus the
#      classification per pane, so it is a machine-readable "axi surface".
#
# Every external probe (herdr, git, no-mistakes) is bounded (fm-timeout-lib.sh)
# and tolerates the failure of one pane or repo without aborting the sweep.
# Portable by construction: no `stat`, and only portable `date -u +FORMAT`, so
# there is no GNU-vs-BSD dialect branch (robots-xw8p).
#
# Usage:
#   fm-agent-axi.sh            human triage table (default)
#   fm-agent-axi.sh --json     structured fm-agent-axi.v1 JSON
#   fm-agent-axi.sh --help     print this usage
#
# Environment overrides:
#   FM_AGENT_AXI_TIMEOUT   per-probe hard bound in seconds (default 10)
#   FM_AGENT_AXI_AGENTS    '|'-separated agent command basenames counted as a
#                          live agent (default claude|codex|opencode|grok|kimi|muse|pi)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

PROBE_TIMEOUT=${FM_AGENT_AXI_TIMEOUT:-10}
case "$PROBE_TIMEOUT" in
  ''|*[!0-9]*|0) echo "fm-agent-axi: FM_AGENT_AXI_TIMEOUT must be a positive integer" >&2; exit 2 ;;
esac
AGENT_RE=${FM_AGENT_AXI_AGENTS:-'claude|codex|opencode|grok|kimi|muse|pi'}
GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

usage() {
  sed -n '2,45{s/^# \{0,1\}//;p;}' "$SCRIPT_DIR/fm-agent-axi.sh"
}

MODE=table
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) MODE=json ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-agent-axi: jq not found" >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "fm-agent-axi: herdr not found" >&2; exit 1; }

NM_AVAILABLE=0
command -v no-mistakes >/dev/null 2>&1 && NM_AVAILABLE=1

WS_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-axi.XXXXXX") || exit 1
cleanup() { rm -rf "$WS_CACHE_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WS_EMPTY='{"git":{"probe_ok":false,"is_repo":false,"dirty":null,"branch":null,"has_upstream":false,"ahead":null,"behind":null},"no_mistakes":{"available":false,"probe_ok":false,"applicable":false,"active":false,"run_branch":null,"run_status":null,"run_id":null}}'
PI_EMPTY='{"ok":false,"live":null,"agent_cmdline":null,"agent_pid":null,"agent_cwd":null,"deep_cwd":null,"shell_pid":null}'

# probe_processes <pane_id> - authoritative liveness from the pane's foreground
# process set. Emits one normalized JSON object. process-info returns rc 0 even
# for a missing pane (payload carries {"error":...} with no .result), so failure
# is detected by the absence of .result.process_info, never by exit status.
probe_processes() {  # <pane_id>
  local pane_id=$1 raw
  raw=$(fm_run_timed "$PROBE_TIMEOUT" herdr pane process-info --pane "$pane_id" 2>/dev/null) || raw=""
  [ -n "$raw" ] || raw='{}'
  # shellcheck disable=SC2016  # $re/$p are jq variables, not shell expansions.
  printf '%s' "$raw" | jq -c --arg re "$AGENT_RE" '
    if (.result.process_info | type) == "object" then
      .result.process_info as $p
      | ([ $p.foreground_processes[]?
           | select(((.argv0 // .name // "") | split("/") | last) | test("^(" + $re + ")$")) ]) as $agents
      | { ok: true,
          live: (($agents | length) > 0),
          agent_cmdline: ($agents[0].cmdline // $agents[0].argv0 // null),
          agent_pid: ($agents[0].pid // null),
          agent_cwd: ($agents[0].cwd // null),
          deep_cwd: ($p.foreground_processes[-1].cwd // null),
          shell_pid: ($p.shell_pid // null) }
    else
      { ok: false, live: null, agent_cmdline: null, agent_pid: null,
        agent_cwd: null, deep_cwd: null, shell_pid: null }
    end' 2>/dev/null || printf '%s' "$PI_EMPTY"
}

# probe_workstate <cwd> - git + no-mistakes signals for one cwd. Emits one JSON
# object {git:{...},no_mistakes:{...}}. Cached per cwd so panes that share a
# checkout are probed once. Every git/no-mistakes failure degrades that field to
# probe_ok:false rather than aborting.
probe_workstate() {  # <cwd>
  local cwd=$1 key cache out ab porc nm_out
  local git_probe_ok is_repo dirty branch has_upstream ahead behind
  local nm_available nm_probe_ok nm_applicable nm_active nm_branch nm_status nm_id

  if [ -z "$cwd" ]; then
    printf '%s' "$WS_EMPTY"
    return 0
  fi
  key=$(printf '%s' "$cwd" | cksum | tr -d ' ')
  cache="$WS_CACHE_DIR/$key"
  if [ -f "$cache" ]; then
    cat "$cache"
    return 0
  fi

  git_probe_ok=true
  is_repo=false
  dirty=null
  branch=
  has_upstream=false
  ahead=null
  behind=null
  if [ "$(fm_run_timed "$PROBE_TIMEOUT" git -C "$cwd" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    is_repo=true
    branch=$(fm_run_timed "$PROBE_TIMEOUT" git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if porc=$(fm_run_timed "$PROBE_TIMEOUT" git -C "$cwd" status --porcelain 2>/dev/null); then
      if [ -n "$porc" ]; then dirty=true; else dirty=false; fi
    else
      git_probe_ok=false
    fi
    if ab=$(fm_run_timed "$PROBE_TIMEOUT" git -C "$cwd" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
      behind=${ab%%[[:space:]]*}
      ahead=${ab##*[[:space:]]}
      case "$behind" in ''|*[!0-9]*) behind=null ;; esac
      case "$ahead" in
        ''|*[!0-9]*) ahead=null; has_upstream=false ;;
        *) has_upstream=true ;;
      esac
    else
      has_upstream=false
      ahead=null
    fi
  fi

  nm_available=false
  nm_probe_ok=false
  nm_applicable=false
  nm_active=false
  nm_branch=
  nm_status=
  nm_id=
  if [ "$NM_AVAILABLE" = 1 ]; then
    nm_available=true
    if [ "$is_repo" = true ]; then
      nm_applicable=true
      # shellcheck disable=SC2016  # $0 is the child bash positional (the cwd), not a shell expansion here.
      if nm_out=$(fm_run_timed "$PROBE_TIMEOUT" bash -c 'cd "$0" 2>/dev/null && no-mistakes status 2>/dev/null' "$cwd"); then
        if [ -n "$nm_out" ]; then
          nm_probe_ok=true
          if printf '%s\n' "$nm_out" | grep -q 'not in a git repository'; then
            nm_active=false
          else
            nm_branch=$(printf '%s\n' "$nm_out" | awk '/^[[:space:]]*branch:[[:space:]]*/{v=$2; gsub(/"/,"",v); print v; exit}')
            nm_status=$(printf '%s\n' "$nm_out" | awk '/^[[:space:]]*status:[[:space:]]*/{v=$2; gsub(/"/,"",v); print v; exit}')
            nm_id=$(printf '%s\n' "$nm_out" | awk '/^[[:space:]]*id:[[:space:]]*/{v=$2; gsub(/"/,"",v); print v; exit}')
            if [ -n "$nm_branch" ]; then nm_active=true; else nm_active=false; fi
          fi
        fi
      fi
    else
      nm_applicable=false
      nm_probe_ok=true
    fi
  fi

  out=$(jq -n \
    --argjson git_probe_ok "$git_probe_ok" \
    --argjson is_repo "$is_repo" \
    --argjson dirty "$dirty" \
    --arg branch "$branch" \
    --argjson has_upstream "$has_upstream" \
    --argjson ahead "$ahead" \
    --argjson behind "$behind" \
    --argjson nm_available "$nm_available" \
    --argjson nm_probe_ok "$nm_probe_ok" \
    --argjson nm_applicable "$nm_applicable" \
    --argjson nm_active "$nm_active" \
    --arg nm_branch "$nm_branch" \
    --arg nm_status "$nm_status" \
    --arg nm_id "$nm_id" '
    { git: { probe_ok: $git_probe_ok, is_repo: $is_repo, dirty: $dirty,
             branch: (if $branch == "" then null else $branch end),
             has_upstream: $has_upstream, ahead: $ahead, behind: $behind },
      no_mistakes: { available: $nm_available, probe_ok: $nm_probe_ok,
             applicable: $nm_applicable, active: $nm_active,
             run_branch: (if $nm_branch == "" then null else $nm_branch end),
             run_status: (if $nm_status == "" then null else $nm_status end),
             run_id: (if $nm_id == "" then null else $nm_id end) } }') \
    || out=$WS_EMPTY
  printf '%s' "$out" | tee "$cache"
}

tabs_json=$(fm_run_timed "$PROBE_TIMEOUT" herdr tab list 2>/dev/null) || tabs_json=""
printf '%s' "$tabs_json" | jq -e '.result.tabs | type == "array"' >/dev/null 2>&1 || tabs_json=""

panes_json=$(fm_run_timed "$PROBE_TIMEOUT" herdr pane list 2>/dev/null) || panes_json=""
if ! printf '%s' "$panes_json" | jq -e '.result.panes | type == "array"' >/dev/null 2>&1; then
  echo "fm-agent-axi: could not enumerate panes via 'herdr pane list'" >&2
  exit 1
fi

# Iterate one compact JSON object per pane and extract each field with jq.
# A field is never split on a delimiter here, so an absent/empty field (e.g. a
# pane with no detected `agent`) can never collapse and shift later columns the
# way an @tsv line read with a whitespace IFS (tab) would.
records=""
while IFS= read -r pane_obj || [ -n "${pane_obj:-}" ]; do
  [ -n "${pane_obj:-}" ] || continue
  pane_id=$(printf '%s' "$pane_obj" | jq -r '.pane_id // ""')
  [ -n "$pane_id" ] || continue
  tab_id=$(printf '%s' "$pane_obj" | jq -r '.tab_id // ""')
  ws_id=$(printf '%s' "$pane_obj" | jq -r '.workspace_id // ""')
  ui_agent=$(printf '%s' "$pane_obj" | jq -r '.agent // ""')
  ui_status=$(printf '%s' "$pane_obj" | jq -r '.agent_status // ""')
  fg_cwd=$(printf '%s' "$pane_obj" | jq -r '.foreground_cwd // .cwd // ""')
  title=$(printf '%s' "$pane_obj" | jq -r '.terminal_title_stripped // .terminal_title // ""')
  pi_norm=$(probe_processes "$pane_id")
  chosen_cwd=$(printf '%s' "$pi_norm" | jq -r '(.agent_cwd // .deep_cwd // "")' 2>/dev/null)
  [ -n "$chosen_cwd" ] || chosen_cwd=$fg_cwd
  ws=$(probe_workstate "$chosen_cwd")
  label=$(printf '%s' "$tabs_json" | jq -r --arg t "$tab_id" 'first(.result.tabs[]? | select(.tab_id == $t) | .label) // ""' 2>/dev/null)
  rec=$(jq -n \
    --arg pane_id "$pane_id" \
    --arg tab_id "$tab_id" \
    --arg workspace_id "$ws_id" \
    --arg label "$label" \
    --arg ui_agent "$ui_agent" \
    --arg ui_status "$ui_status" \
    --arg terminal_title "$title" \
    --arg cwd "$chosen_cwd" \
    --argjson process "$pi_norm" \
    --argjson work "$ws" '
    { pane_id: $pane_id,
      tab_id: (if $tab_id == "" then null else $tab_id end),
      workspace_id: (if $workspace_id == "" then null else $workspace_id end),
      label: (if $label == "" then null else $label end),
      ui_agent: (if $ui_agent == "" then null else $ui_agent end),
      ui_status: (if $ui_status == "" then null else $ui_status end),
      terminal_title: (if $terminal_title == "" then null else $terminal_title end),
      cwd: (if $cwd == "" then null else $cwd end),
      process_probe_ok: $process.ok,
      live: $process.live,
      agent_cmdline: $process.agent_cmdline,
      agent_pid: $process.agent_pid,
      shell_pid: $process.shell_pid,
      git: $work.git,
      no_mistakes: $work.no_mistakes }') || rec=""
  [ -n "$rec" ] && records="$records$rec"$'\n'
done < <(printf '%s' "$panes_json" | jq -c '.result.panes[]?')

# Single source of truth for the classification, applied to the raw signals.
# --json and the human table both read .classification from this output.
# shellcheck disable=SC2016  # jq program: $ tokens are jq variables/fields.
AXI_JSON=$(printf '%s' "$records" | jq -s --arg generated "$GENERATED" '
  def tied:
    (.no_mistakes.active == true)
    and (.no_mistakes.run_branch != null)
    and (.git.branch != null)
    and (.no_mistakes.run_branch == .git.branch);
  def gitclear:
    if (.git.probe_ok != true) then false
    elif (.git.is_repo != true) then true
    else ((.git.dirty == false) and (.git.has_upstream == true) and (.git.ahead == 0)) end;
  def nmclear:
    if (.git.is_repo != true) then true
    elif (.no_mistakes.available == true and .no_mistakes.probe_ok == true) then (tied | not)
    else false end;
  def classify:
    if (.process_probe_ok != true) then
      { classification: "HOLD-UNKNOWN", reason: "process probe failed; liveness unverifiable" }
    elif (.live == true) then
      { classification: "HOLD-LIVE", reason: "live agent foreground process present" }
    elif tied then
      { classification: "HOLD-QUEUED", reason: ("no-mistakes run " + (.no_mistakes.run_id // "?") + " tied to branch " + (.git.branch // "?")) }
    elif (.git.dirty == true) then
      { classification: "HOLD-UNLANDED", reason: "uncommitted changes in worktree" }
    elif ((.git.ahead // 0) > 0) then
      { classification: "HOLD-UNLANDED", reason: ("branch ahead of upstream by " + ((.git.ahead) | tostring) + " commit(s)") }
    elif (gitclear and nmclear) then
      { classification: "SAFE-TO-REAP", reason: "no live agent, clean tree, nothing ahead, no tied no-mistakes run" }
    else
      { classification: "HOLD-UNKNOWN",
        reason: (
          if (.git.probe_ok != true) then "git work-state probe failed"
          elif (.git.is_repo == true and .git.has_upstream != true) then "branch has no upstream; landed state unconfirmable"
          elif (.no_mistakes.available != true or .no_mistakes.probe_ok != true) then "no-mistakes state unverifiable"
          else "inconclusive signals" end) }
    end;
  ([ .[] | . + classify ]) as $agents
  | { schema: "fm-agent-axi.v1",
      generated: $generated,
      agents: $agents,
      summary: { total: ($agents | length),
        by_classification: (reduce $agents[] as $a ({}; .[$a.classification] = ((.[$a.classification] // 0) + 1))) } }')

if [ "$MODE" = json ]; then
  printf '%s\n' "$AXI_JSON"
  exit 0
fi

printf '%s' "$AXI_JSON" | jq -r '
  def dash($v): if $v == null or $v == "" then "-" else ($v | tostring) end;
  def livecol: if .process_probe_ok != true then "?" elif .live == true then "yes" else "no" end;
  def dirtycol:
    if .git.is_repo != true then "n/a"
    elif .git.probe_ok != true then "?"
    elif .git.dirty == true then "yes"
    elif .git.dirty == false then "no"
    else "?" end;
  def aheadcol:
    if .git.is_repo != true then "n/a"
    elif .git.has_upstream != true then "?"
    else (.git.ahead | tostring) end;
  def nmcol:
    if .git.is_repo != true then "n/a"
    elif (.no_mistakes.available != true or .no_mistakes.probe_ok != true) then "?"
    elif ((.no_mistakes.active == true) and (.git.branch != null) and (.no_mistakes.run_branch == .git.branch)) then "tied"
    else "clear" end;
  "# Agent Axi Surface (Layer 1 - read-only reap triage)",
  "",
  "Schema: \(.schema)   Generated: \(.generated)",
  "Panes: \(.summary.total)   " + (.summary.by_classification | to_entries | map("\(.key)=\(.value)") | join("   ")),
  "",
  "| Pane | Label | UI | Live | Branch | Dirty | Ahead | No-Mistakes | Classification | Reason | CWD |",
  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  (.agents[] | "| \(.pane_id) | \(dash(.label)) | \(dash(.ui_status)) | \(livecol) | \(dash(.git.branch)) | \(dirtycol) | \(aheadcol) | \(nmcol) | \(.classification) | \(.reason) | \(dash(.cwd)) |")
'
