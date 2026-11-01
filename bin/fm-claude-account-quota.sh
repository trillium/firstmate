#!/usr/bin/env bash
# fm-claude-account-quota.sh - measure each Claude account a home declares in
# config/claude-accounts, in isolation, and print each one's quota facts.
#
# Usage:
#   fm-claude-account-quota.sh [--model <model>] [--json]
#
# For every declared entry in config/claude-accounts, in file order, measures
# that account's own quota without touching or falling back to any ambient
# login:
#   token:<file>          a `claude setup-token` file (validated via
#                         bin/fm-worker-account-lib.sh without printing or
#                         logging its content): runs quota-axi --provider claude
#                         --allow-claude-inference --json through
#                         bin/fm-claude-token-exec.sh with an empty isolated
#                         CLAUDE_CONFIG_DIR so neither ~/.claude nor Keychain
#                         can answer for it. Because the inference probe spends
#                         one tiny turn, valid readings are cached per entry for
#                         FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS (default 300;
#                         0 disables) under the home's state directory (mode
#                         0600, invalidated when <file>'s mtime advances).
#   <root>/.credentials.json
#                         a stored login file (at <dir>/.credentials.json, or
#                         ~/.claude/.credentials.json for `ordinary`): runs
#                         CLAUDE_CONFIG_DIR=<root> quota-axi --provider claude
#                         --profile-only --json, reading only that file.
#   neither               a login kept in the macOS Keychain: runs
#                         quota-axi --provider claude --json with ambient
#                         credentials removed and CLAUDE_CONFIG_DIR set to
#                         <dir> (unset for `ordinary`).
# QUOTA_AXI_SNAPSHOT and FM_WORKER_ACCOUNT_CLAUDE_SHED variables are removed
# from every read so an ambient token, API key, or fixture never answers for
# another account. When quota-axi exits nonzero (for example when the vendor
# rate-limits the quota endpoint) yet prints a valid snapshot naming that
# state, the snapshot is retained so the account reports the vendor's own
# reason rather than a generic read failure.
#
# Each entry binds to its own snapshot's claude row and to the scopes that
# bound --model: all_models/all_products plus model:<id> and product:<id> for
# the bare id.
#
# Output:
#   Default (stdout, TOON-style block):
#     claude-account-quota:
#       row: <declared>  root=<root>  scope=<scope>  status=..  remaining=..%  spendPriority=..  runway=..  usableRunwaySeconds=..  confidence=..
#       row: <declared>  root=<root>  uncertainty: <why this account is not fully measured>
#   --json (stdout, JSON object):
#     {"accounts": [{"account": "<entry>", "declared": "<declared>", "root": "<root>", "snapshot": {...} | "error": "..."}]}
#   Readings exit 0 (including when quota-axi is not installed, reported in-band
#   so callers treat unmeasured accounts as disclosed uncertainty). Exit 2 only
#   for a usage error, missing jq, an absent list, or a malformed list.
#
# Never prints, logs, caches, or passes on argv the contents of any token file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

FM_CLAUDE_ACCOUNT_QUOTA_SECONDS=${FM_CLAUDE_ACCOUNT_QUOTA_SECONDS:-60}
CACHE_SECONDS=${FM_CLAUDE_ACCOUNT_QUOTA_CACHE_SECONDS:-300}
case "$CACHE_SECONDS" in '' | *[!0-9]*) CACHE_SECONDS=300 ;; esac
CACHE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

scrub_token_from_file() {
  local token_file=$1 target_file=$2
  [ -f "$target_file" ] || return 0
  perl -i -e '
    my ($tf) = shift @ARGV;
    open(my $fh, "<", $tf) or exit 0;
    my $tok = do { local $/; <$fh> } // "";
    $tok =~ s/\A\s+//;
    $tok =~ s/\s+\z//;
    exit 0 unless length $tok;
    while (<>) {
      s/\Q$tok\E/[REDACTED]/g;
      print;
    }
  ' "$token_file" "$target_file" 2>/dev/null || true
}

MODEL=
JSON_OUT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ -n "${2-}" ] || die "--model needs a value"
      MODEL=$2
      shift 2
      ;;
    --model=*)
      MODEL=${1#--model=}
      [ -n "$MODEL" ] || die "--model needs a value"
      shift
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

command -v jq >/dev/null 2>&1 || die "jq is required"
LISTED=$(fm_worker_account_list claude "$CONFIG") || exit 2
[ -n "$LISTED" ] || die "this home declares no config/claude-accounts; there is nothing to measure"

if ! command -v quota-axi >/dev/null 2>&1; then
  if [ "$JSON_OUT" -eq 1 ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      declared=$(fm_worker_account_declared_name "$entry")
      root=$entry
      [ "$entry" != ordinary ] || root="${HOME:-}/.claude"
      jq -cn --arg account "$entry" --arg declared "$declared" --arg root "$root" \
        '{account: $account, declared: $declared, root: $root, error: "quota-axi not installed"}'
    done <<< "$LISTED" | jq -cs '{error: "quota-axi not installed", accounts: .}'
  else
    printf 'claude-account-quota:\n  error: quota-axi not installed\n'
  fi
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-account-quota.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/empty-claude-config"

SHED_ARGS=(-u QUOTA_AXI_SNAPSHOT)
for shed_var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
  SHED_ARGS+=(-u "$shed_var")
done

# Every entry becomes {account, declared, root, snapshot} or {account, declared, root, error}.
: > "$WORK/accounts.jsonl"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  declared=$(fm_worker_account_declared_name "$entry")
  root=$entry
  error=
  cache=
  read_rc=0
  : > "$WORK/snapshot.json"
  case "$entry" in
  token:*)
    token_file=${entry#token:}
    if ! fm_worker_account_token_validate "$token_file" "config/claude-accounts" 2> "$WORK/token-error"; then
      error="setup-token file unusable: $(head -n 1 "$WORK/token-error" | tr -d '\r')"
    else
      if [ "$CACHE_SECONDS" -gt 0 ]; then
        cache="$CACHE_DIR/.claude-account-quota-$(printf '%s' "$entry" | cksum | tr ' ' '-').json"
      fi
      if [ -n "$cache" ] && [ -f "$cache" ] &&
        perl -e '
          my ($cf, $tf, $ttl) = @ARGV;
          my @cs = stat $cf or exit 1;
          my @ts = stat $tf or exit 1;
          exit((time - $cs[9] < $ttl && $cs[9] >= $ts[9]) ? 0 : 1);
        ' -- "$cache" "$token_file" "$CACHE_SECONDS" &&
        fm_quota_json_valid < "$cache"; then
        cp "$cache" "$WORK/snapshot.json"
      else
        fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env "${SHED_ARGS[@]}" \
          "CLAUDE_CONFIG_DIR=$WORK/empty-claude-config" \
          "$SCRIPT_DIR/fm-claude-token-exec.sh" "$token_file" \
          quota-axi --provider claude --allow-claude-inference --json \
          > "$WORK/snapshot.json" 2>/dev/null </dev/null || read_rc=$?
        scrub_token_from_file "$token_file" "$WORK/snapshot.json"
        if [ "$read_rc" -eq 0 ] && [ -n "$cache" ] && fm_quota_json_valid < "$WORK/snapshot.json"; then
          if mkdir -p "$CACHE_DIR" 2>/dev/null; then
            cache_tmp=$(umask 077 && mktemp "$CACHE_DIR/.claude-account-quota-tmp.XXXXXX" 2>/dev/null) || cache_tmp=
            if [ -n "$cache_tmp" ]; then
              if cp "$WORK/snapshot.json" "$cache_tmp" 2>/dev/null && chmod 600 "$cache_tmp" 2>/dev/null; then
                mv -f "$cache_tmp" "$cache" 2>/dev/null || rm -f "$cache_tmp"
              else
                rm -f "$cache_tmp"
              fi
            fi
          fi
        fi
      fi
    fi
    ;;
  ordinary)
    root="${HOME:?HOME is required to measure the ordinary account}/.claude"
    if [ -f "$root/.credentials.json" ]; then
      fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env "${SHED_ARGS[@]}" "CLAUDE_CONFIG_DIR=$root" \
        quota-axi --provider claude --profile-only --json > "$WORK/snapshot.json" 2>/dev/null </dev/null || read_rc=$?
    else
      fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env "${SHED_ARGS[@]}" -u CLAUDE_CONFIG_DIR \
        quota-axi --provider claude --json > "$WORK/snapshot.json" 2>/dev/null </dev/null || read_rc=$?
    fi
    ;;
  *)
    if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
      error="account directory is not readable: $root"
    elif [ -f "$root/.credentials.json" ]; then
      fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env "${SHED_ARGS[@]}" "CLAUDE_CONFIG_DIR=$root" \
        quota-axi --provider claude --profile-only --json > "$WORK/snapshot.json" 2>/dev/null </dev/null || read_rc=$?
    else
      fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env "${SHED_ARGS[@]}" "CLAUDE_CONFIG_DIR=$root" \
        quota-axi --provider claude --json > "$WORK/snapshot.json" 2>/dev/null </dev/null || read_rc=$?
    fi
    ;;
  esac
  if [ -n "$error" ]; then
    :
  elif [ "$read_rc" -eq 0 ]; then
    fm_quota_json_valid < "$WORK/snapshot.json" || error="quota-axi returned an invalid snapshot"
  elif ! fm_quota_json_valid < "$WORK/snapshot.json"; then
    error="quota-axi could not read this account"
  fi
  if [ -n "$error" ]; then
    jq -cn --arg account "$entry" --arg declared "$declared" --arg root "$root" --arg error "$error" \
      '{account: $account, declared: $declared, root: $root, error: $error}'
  else
    jq -c --arg account "$entry" --arg declared "$declared" --arg root "$root" \
      '{account: $account, declared: $declared, root: $root, snapshot: .}' "$WORK/snapshot.json"
  fi >> "$WORK/accounts.jsonl" || die "cannot record the quota reading for $declared"
done <<< "$LISTED"

if [ "$JSON_OUT" -eq 1 ]; then
  jq -cs '{accounts: .}' "$WORK/accounts.jsonl" || die "cannot format JSON quota readings"
  exit 0
fi

jq -rs --arg model "$MODEL" '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def bare($m): ($m | split("/") | last);
  def applicable($row):
    bare($model) as $b |
    [$row.quotaSemantics.effectiveAvailability[]? | select(
      .scope == "all_models" or .scope == "all_products" or
      ($model != "" and (.scope == ("model:" + $b) or .scope == ("product:" + $b)))
    )];
  "claude-account-quota:",
  (.[] | "  row: \(.declared | flat)  root=\(.root | flat)" as $head |
    if .error then "\($head)  uncertainty: \(.error | flat)"
    else
      ([.snapshot.providers[]? | select(.provider == "claude")] | first) as $row |
      if $row == null then "\($head)  uncertainty: no claude quota row"
      else
        applicable($row) as $rows |
        (if (["known", "partial"] | index($row.quotaSemantics.status)) == null then
          "\($head)  uncertainty: quota \(show($row.quotaSemantics.status))\(if $row.state.status then " (\($row.state.status | flat): \(show($row.state.error)))" else "" end)"
         else empty end),
        (if ($rows | length) == 0 then "\($head)  uncertainty: no applicable quota scope" else empty end),
        ($rows[] | "\($head)  scope=\(.scope | flat)  status=\(show(.status))  remaining=\(show(.effectivePercentRemaining))%  spendPriority=\(show(.selection.spendPriority))  runway=\(show(.runway.status))"
          + (if .runway.usableRunwaySeconds != null or .runway.status == "projected_exhaustion"
             then "  usableRunwaySeconds=\(show(.runway.usableRunwaySeconds))" else "" end)
          + ((.runway.projectionConfidence // .confidence) as $c | if $c then "  confidence=\($c | flat)" else "" end))
      end
    end)
' "$WORK/accounts.jsonl" || die "cannot format the quota readings"
