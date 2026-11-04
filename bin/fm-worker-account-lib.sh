#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# and per-secondmate account pins: which runners can be pinned, how a pin file
# is parsed and resolved, the launch-time sign-in check under it, and the
# environment credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh, bin/fm-control.sh, and bin/fm-claude-token-exec.sh.
#
# A single Claude launch can override the home-wide default with a per-launch
# account (bin/fm-spawn.sh --account, bin/fm-control.sh relaunch --account, or
# a dispatch profile's account): the same value grammar as config/claude-account,
# the same validation, sign-in check, and credential shedding, so the ordinary
# login and a setup-token account can be used side by side.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# A Claude pin can instead be `token:<absolute path>`: a `claude setup-token`
# long-lived OAuth token kept in an owner-only (0600) file, for a second
# subscription that has no config root of its own. The launch leaves
# CLAUDE_CONFIG_DIR unset like `ordinary`, sheds the same credentials, and runs
# the agent through bin/fm-claude-token-exec.sh, which reads the file and
# exports CLAUDE_CODE_OAUTH_TOKEN for that one process. The token value is
# never an argument, never in the staged launch text, and never in a task
# record, status line, or diagnostic: only the file's path and basename are.
# Its resolved root is `token:<path>` and its declared (reported) name is
# `token:<basename>`.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in. A token
#           pin runs it through bin/fm-claude-token-exec.sh so the token is in
#           that check's environment and nowhere else, and requires its JSON
#           to report loggedIn with authMethod oauth_token.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.
#
# A home that spends several Claude subscriptions declares them instead in
# config/claude-accounts: one entry per line, each `ordinary` or an absolute
# path exactly as config/claude-account would hold it, with no blank lines,
# duplicates, or control characters, and an optional final newline. The list is
# opt-in in the same way: absent, nothing here changes. Present, it replaces the
# home-wide pin, which must then be absent, and every Claude ship or scout
# launch names one declared entry with --account; Firstmate chooses it at
# intake (bin/fm-claude-account-quota.sh measures each entry), or a spawn that
# names none lets fm_worker_account_autopick choose the entry with the most
# headroom. Nothing defaults to the first entry or the ambient account. The named
# entry passes the same root, raw-command, and sign-in refusals as a pin and is
# recorded as account=, which a ship or scout relaunch reuses unless an
# explicit --account moves it. A local secondmate's agent never draws from the
# list: it needs its own per-secondmate pin.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}
FM_WORKER_ACCOUNT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_token_load <file>
# Prints the setup token held in <file> and nothing else, so the only caller
# that may let the output reach a process environment is
# bin/fm-claude-token-exec.sh; every other caller discards it. Status: 0 ok, 3
# missing, 4 not a regular file, 5 unreadable, 6 readable by group or other,
# 7 owned by another user, 8 empty, 9 not one run of printable characters.
# The file is followed through a symbolic link, and its own mode decides.
fm_worker_account_token_load() {
  perl -e '
    my ($f) = @ARGV;
    my @st = stat $f or exit 3;
    -f _ or exit 4;
    $st[4] == $> or exit 7;
    ($st[2] & 077) == 0 or exit 6;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ s/\A\s+//;
    $body =~ s/\s+\z//;
    length $body or exit 8;
    $body =~ /\A[\x21-\x7e]+\z/ or exit 9;
    print $body;
  ' -- "$1"
}

# fm_worker_account_token_refusal <status> <file> <setting>
# Prints the one refusal for a non-zero fm_worker_account_token_load status.
# It names the file and the reason, never any of the file's content.
fm_worker_account_token_refusal() {
  local why
  case "$1" in
  3) why="does not exist" ;;
  4) why="is not a regular file" ;;
  5) why="is not readable" ;;
  6) why="is readable by group or other; run chmod 600 on it" ;;
  7) why="is owned by another user" ;;
  8) why="is empty; write the output of claude setup-token into it" ;;
  *) why="must hold one token with no spaces or line breaks" ;;
  esac
  echo "error: $3 pins Claude workers to a setup token, but the token file $2 $why" >&2
}

# fm_worker_account_token_validate <file> <setting>
# Returns 0 when the token file is usable; otherwise prints one refusal and
# returns 1. The token itself is read and discarded.
fm_worker_account_token_validate() {
  local rc
  fm_worker_account_token_load "$1" >/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  fm_worker_account_token_refusal "$rc" "$1" "$2"
  return 1
}

# fm_worker_account_read <harness> <file>
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary`, the absolute path, or (Claude only) `token:` plus the absolute
# path of a setup-token file, and providers is empty for Claude. The final
# newline is optional; any other control byte, including a CR, is malformed.
# Parses bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      $body =~ /\A(ordinary|(?:token:)?\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
      print $1, "\t";
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_config <harness> <config-dir> [<secondmate-id>]
# Prints the directory containing the applicable pin. Only a missing per-mate
# file falls back to the home pin; unreadable or malformed files still select
# the override so the ordinary parser refuses them. Non-pinnable runners and
# ordinary workers keep the supplied directory unchanged.
fm_worker_account_config() {
  local harness=$1 config=$2 mate=${3:-} file candidate rc
  if [ -z "$mate" ] || ! file=$(fm_worker_account_file "$harness"); then
    printf '%s\n' "$config"
    return 0
  fi
  candidate="$config/secondmate-accounts/$mate"
  fm_worker_account_read "$harness" "$candidate/$file" >/dev/null
  rc=$?
  case "$rc" in
  3) printf '%s\n' "$config" ;;
  4) return 1 ;;
  *) printf '%s\n' "$candidate" ;;
  esac
}

# fm_worker_account_resolve <harness> <config-dir> <setting>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset). Prints nothing and returns 0 when the runner is
# not pinnable or the home has no pin. On refusal prints one error naming the
# file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 setting=$3 file cfg token rc
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: $setting must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: $setting must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: $setting must hold 'ordinary', one absolute path, or token:<absolute path of a setup-token file> on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  fm_worker_account_resolve_declared "$harness" "${token%%$'\t'*}" "$setting" "$cfg" "${token#*$'\t'}"
}

# fm_worker_account_value_valid <value>
# Returns 0 when <value> is a well-formed Claude account value: `ordinary`, an
# absolute path, or `token:` plus an absolute path, with no control bytes. This
# is the same grammar fm_worker_account_read enforces for config/claude-account.
fm_worker_account_value_valid() {
  perl -e '
    my ($v) = @ARGV;
    exit(($v =~ /\A(?:ordinary|(?:token:)?\/[^\x00-\x1f\x7f]*)\z/) ? 0 : 1);
  ' -- "$1"
}

# fm_worker_account_resolve_declared <harness> <declared> <setting> <where> <providers>
# The shared back half of a pin: turns one already-parsed declared value into
# "declared<TAB>root<TAB>providers", validating the token file or root. <where>
# only names the source in a refusal (the pin file, or the per-launch flag).
fm_worker_account_resolve_declared() {
  local harness=$1 declared=$2 setting=$3 cfg=$4 providers=${5:-} root fallback
  root=$declared
  case "$declared" in
  token:*)
    # Resolved root is the full token:<path>; the reported name is only the
    # file's basename, which is all that reaches a task record or digest.
    fm_worker_account_token_validate "${declared#token:}" "$setting" || return 1
    printf '%s\t%s\t%s\n' "token:${declared##*/}" "$declared" ""
    return 0
    ;;
  esac
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: $setting must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "$providers"
}

# fm_worker_account_list <harness> <config-dir>
# Prints the entries config/claude-accounts declares, one per line, for a
# Claude launch. Prints nothing and returns 0 for another runner or when the
# list is absent. On a malformed or unreadable list prints one error naming the
# file and returns 1.
fm_worker_account_list() {
  local harness=$1 cfg="$2/claude-accounts" out rc
  [ "$harness" = claude ] || return 0
  out=$(perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\A(?:(?:ordinary|\/[^\x00-\x1f\x7f]*)\n)*(?:ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
    my %seen;
    for my $entry (split /\n/, $body) {
      exit 7 if $seen{$entry}++;
      print $entry, "\n";
    }
  ' -- "$cfg")
  rc=$?
  case "$rc" in
  0) printf '%s\n' "$out" ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/claude-accounts must be a readable regular file: $cfg" >&2
    return 1
    ;;
  7)
    echo "error: config/claude-accounts declares the same account twice: $cfg" >&2
    return 1
    ;;
  *)
    echo "error: config/claude-accounts must hold one account per line, each 'ordinary' or an absolute path, with no blank lines or control characters: $cfg" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_low_threshold <config-dir>
# Prints the remaining-quota percentage below which an account is no longer
# chosen automatically: FM_CLAUDE_ACCOUNT_LOW_THRESHOLD, else the first line of
# config/claude-account-low-threshold, else 20. Returns 1 with one error when
# the value is not a number from 0 to 100.
fm_worker_account_low_threshold() {
  local value=${FM_CLAUDE_ACCOUNT_LOW_THRESHOLD:-} file="$1/claude-account-low-threshold"
  if [ -z "$value" ] && [ -f "$file" ] && [ -r "$file" ]; then
    IFS= read -r value < "$file" || true
  fi
  [ -n "$value" ] || value=20
  case "$value" in
  '' | *[!0-9.]* | *.*.* | . | *.)
    echo "error: the Claude account low-headroom threshold must be a percentage from 0 to 100 (FM_CLAUDE_ACCOUNT_LOW_THRESHOLD or config/claude-account-low-threshold): $value" >&2
    return 1
    ;;
  esac
  awk -v v="$value" 'BEGIN { exit !(v + 0 <= 100) }' || {
    echo "error: the Claude account low-headroom threshold must be a percentage from 0 to 100 (FM_CLAUDE_ACCOUNT_LOW_THRESHOLD or config/claude-account-low-threshold): $value" >&2
    return 1
  }
  printf '%s\n' "$value"
}

# fm_worker_account_autopick <config-dir> <model>
# Chooses the declared config/claude-accounts entry a Claude ship or scout
# spawn that names no --account launches on. Each entry's headroom is the
# lowest remaining percentage across the scopes bin/fm-claude-account-quota.sh
# reports for <model>. The highest headroom at or above the low threshold wins,
# ties going to the earlier entry. An entry with no usable reading stays
# eligible, behind every measured one, so a failed read never strands a launch.
# An entry below the threshold is never chosen. Prints
# "entry<TAB>reason" on success. Returns 1 with one error when every entry is
# measured and low, or when the list or threshold is unusable; the spawn then
# needs an explicit --account. Reads quota facts only: no login, token, or
# account file is read or changed.
fm_worker_account_autopick() {
  local config=$1 model=${2:-} threshold readings pick
  threshold=$(fm_worker_account_low_threshold "$config") || return 1
  readings=$(FM_CONFIG_OVERRIDE=$config "$FM_WORKER_ACCOUNT_LIB_DIR/fm-claude-account-quota.sh" ${model:+--model "$model"} 2>/dev/null) || {
    echo "error: bin/fm-claude-account-quota.sh could not measure config/claude-accounts, so no account can be chosen automatically; name one with --account" >&2
    return 1
  }
  pick=$(printf '%s\n' "$readings" | awk -v thr="$threshold" '
    function entry(line,   s, i) {
      s = substr(line, index(line, "row: ") + 5)
      i = index(s, "  root=")
      return i ? substr(s, 1, i - 1) : s
    }
    /^  row: / {
      e = entry($0)
      if (!(e in seen)) { seen[e] = 1; order[++n] = e }
      if (match($0, /  remaining=[0-9.]+%/)) {
        r = substr($0, RSTART + 12, RLENGTH - 13) + 0
        if (!(e in low) || r < low[e]) low[e] = r
      }
    }
    END {
      best = ""; bestv = -1; lowlist = ""; unknown = ""
      for (i = 1; i <= n; i++) {
        e = order[i]
        if (!(e in low)) { if (unknown == "") unknown = e; continue }
        if (low[e] < thr) { lowlist = lowlist ((lowlist == "" ? "" : ", ")) e "=" low[e] "%"; continue }
        if (low[e] > bestv) { best = e; bestv = low[e] }
      }
      if (best != "") printf "%s\tauto-selected %s (%s%% headroom >= %s%% threshold%s)\n", best, best, bestv, thr, (lowlist == "" ? "" : "; skipped low: " lowlist)
      else if (unknown != "") printf "%s\tauto-selected %s (no usable quota reading, kept eligible%s)\n", unknown, unknown, (lowlist == "" ? "" : "; skipped low: " lowlist)
      else printf "\tevery declared Claude account is below the %s%% low-headroom threshold (%s)\n", thr, lowlist
    }')
  if [ -z "${pick%%$'\t'*}" ]; then
    echo "error: ${pick#*$'\t'}; name an account with --account to launch anyway" >&2
    return 1
  fi
  printf '%s\n' "$pick"
}

# fm_worker_account_relaunch_request <harness> <config-dir> <prior-harness> <recorded-account> <explicit-account> [<secondmate-id>]
# Prints the declared account a relaunch asks fm_worker_account_select for:
# the explicit one when given, otherwise the task's recorded account when the
# home declares config/claude-accounts and a Claude ship or scout stays on
# Claude. Prints nothing otherwise, so a relaunch without a list re-reads the
# pin exactly as before. Returns 1 when the explicit account holds a control
# character or the list cannot be read.
fm_worker_account_relaunch_request() {
  local harness=$1 config=$2 prior=$3 recorded=$4 explicit=$5 mate=${6:-} listed
  fm_worker_account_request_valid "$explicit" || return 1
  if [ -n "$explicit" ] || [ -n "$mate" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  listed=$(fm_worker_account_list "$harness" "$config") || return 1
  [ -n "$listed" ] && [ "$prior" = claude ] || return 0
  printf '%s\n' "$recorded"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>] [<setting>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} setting=${6:-} out verdict name
  [ -n "$setting" ] || setting="config/$(fm_worker_account_file "$harness")"
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    case "$root" in
    token:*)
      # Claude reads the token offline, so this proves the token is present
      # and is the credential Claude selects, not that Anthropic accepts it.
      out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$FM_WORKER_ACCOUNT_LIB_DIR/fm-claude-token-exec.sh" "${root#token:}" \
        "$executable" auth status 2>/dev/null </dev/null) &&
        [ "$(printf '%s\n' "$out" | jq -r 'select(type == "object") | "\(.loggedIn) \(.authMethod)"' 2>/dev/null)" = "true oauth_token" ] &&
        return 0
      echo "error: $setting pins Claude workers to the setup token in ${root#token:}, but claude auth status does not report it as the signed-in credential; create a new one with claude setup-token, or change the pin" >&2
      return 1
      ;;
    esac
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: $setting pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: $setting pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: $setting pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_request_valid <account>
# Refuses an --account value holding a control character. Declared entries
# never hold one, and a newline would otherwise split the value before the
# whole-entry membership check or the account= record sees it.
fm_worker_account_request_valid() {
  case "$1" in
  *[[:cntrl:]]*)
    echo "error: --account must name one config/claude-accounts entry exactly, with no control characters" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>] [<secondmate-id>] [<account>]
# The whole launch-time decision. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one, or a Claude
# ship or scout launching on a per-launch account, prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude), after the model guard and the sign-in check pass.
# <account> is the per-launch --account value. Under a declared
# config/claude-accounts list it must name one declared entry exactly; without
# that list it takes the config/claude-account grammar (ordinary, an absolute
# config directory, or token:<absolute path>) and replaces the home-wide pin
# for this launch. It is refused for any runner but Claude and for a
# secondmate. On refusal prints one error and returns 1. bin/fm-spawn.sh runs
# it before any endpoint exists, and bin/fm-control.sh before a relaunch stops
# the live agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} mate=${6:-} account=${7:-}
  local selection declared root providers word provider='' selected_config setting listed count
  fm_worker_account_request_valid "$account" || return 1
  if [ -n "$account" ] && [ "$harness" != claude ]; then
    echo "error: --account selects a Claude account and applies to Claude workers only, not $harness; remove --account, or launch with --harness claude" >&2
    return 1
  fi
  if [ -n "$account" ] && [ -n "$mate" ]; then
    echo "error: --account applies to ships and scouts; secondmate $mate launches on its own config/secondmate-accounts/$mate/claude-account pin" >&2
    return 1
  fi
  listed=$(fm_worker_account_list "$harness" "$config") || return 1
  if [ -n "$listed" ] && { [ -e "$config/claude-account" ] || [ -L "$config/claude-account" ]; }; then
    echo "error: config/claude-accounts and config/claude-account are both present; keep the account list or the single pin, not both" >&2
    return 1
  fi
  selected_config=$(fm_worker_account_config "$harness" "$config" "$mate") || return 1
  setting="config/$(fm_worker_account_file "$harness")"
  [ "$selected_config" = "$config" ] || setting="$selected_config/$(fm_worker_account_file "$harness")"
  if [ -n "$listed" ] && [ -n "$mate" ] && [ "$selected_config" = "$config" ]; then
    echo "error: config/claude-accounts chooses accounts for ships and scouts only; secondmate $mate needs its own pin in config/secondmate-accounts/$mate/claude-account" >&2
    return 1
  elif [ -n "$listed" ] && [ -z "$mate" ]; then
    setting=config/claude-accounts
    if [ -z "$account" ]; then
      count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
      echo "error: config/claude-accounts declares $count Claude accounts, so a Claude ship or scout launch must name one with --account; bin/fm-claude-account-quota.sh measures each, and Firstmate never picks a default" >&2
      return 1
    fi
    declared=
    while IFS= read -r word; do
      [ "$word" != "$account" ] || { declared=$account; break; }
    done <<< "$listed"
    [ -n "$declared" ] || {
      echo "error: account '$account' is not declared in config/claude-accounts; name a declared entry with --account" >&2
      return 1
    }
    declared=$account
    root=$account
    [ "$declared" != ordinary ] || root=
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      # shellcheck disable=SC2088  # Literal text for the refusal.
      echo "error: $setting must name readable, searchable existing directories (ordinary means ~/.claude with CLAUDE_CONFIG_DIR unset): $root" >&2
      return 1
    fi
    providers=
  elif [ -n "$account" ]; then
    # No declared list: a per-launch account replaces the home-wide pin for
    # this one launch; everything after the selection is shared.
    fm_worker_account_value_valid "$account" || {
      echo "error: --account must be 'ordinary', one absolute path, or token:<absolute path of a setup-token file> with no control characters: $account" >&2
      return 1
    }
    setting="--account"
    selection=$(fm_worker_account_resolve_declared "$harness" "$account" "$setting" "$account" "") || return 1
    declared=${selection%%$'\t'*}
    root=${selection#*$'\t'}
    providers=${root#*$'\t'}
    root=${root%%$'\t'*}
  else
    selection=$(fm_worker_account_resolve "$harness" "$selected_config" "$setting") || return 1
    if [ -z "$selection" ]; then
      [ "$selected_config" = "$config" ] && return 0
      echo "error: secondmate account pin disappeared during selection: $setting" >&2
      return 1
    fi
    declared=${selection%%$'\t'*}
    root=${selection#*$'\t'}
    providers=${root#*$'\t'}
    root=${root%%$'\t'*}
  fi
  if [ "$harness" = claude ]; then
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: $setting pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove $setting" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: $setting pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: $setting pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: $setting pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" "$setting" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
