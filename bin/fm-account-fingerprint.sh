#!/usr/bin/env bash
# fm-account-fingerprint.sh - inspect and report credential fingerprint,
# auth method, and account usage bucket for a worker task or the current
# environment, with live-worker grouping and fleet-wide collection.
#
# Usage:
#   fm-account-fingerprint.sh [<task-id>] [--json]
#   fm-account-fingerprint.sh --current [--json]
#   fm-account-fingerprint.sh --group [--json]
#   fm-account-fingerprint.sh --list [--json]
#   fm-account-fingerprint.sh --fleet [--json]
#   fm-account-fingerprint.sh --help
#
# Output fields:
#   target:       task id or "current"
#   harness:      worker harness (claude, pi, codex, grok, etc.)
#   auth_method:  setup token | subscription login | API key | other | unknown
#   account:      account or usage-bucket label from non-secret local records
#   fingerprint:  short non-reversible 12-hex-character digest of the credential,
#                 or "unknown" if the credential cannot be read
#   derivation:   token-derived | identity-derived | unknown
#
# Fingerprint stability and domain-separation label:
# The credential fingerprint is computed as:
#   SHA-256("fm-credential-fingerprint-v1:" + <credential>)[0..11]
#
# Tradeoff note and secret containment:
# A fixed, non-secret domain-separation label is deliberately chosen over a
# per-machine salt so that fingerprints are stable across runs on one machine
# and comparable across machines and fleet environments (e.g. comparing workers
# across hosts or secondmate homes to detect whether they share a credential or
# usage bucket).
# High-entropy secrets cannot be reversed from the 12-hex-character truncated
# digest.
#
# Never prints, logs, or writes the secret or any prefix of it.
# Credentials are read directly in-process or via owner-only (0600) file loaders,
# piped to the hash function over stdin, and immediately cleared from memory.
#
# Fleet-wide mode (--fleet) and remote execution rationale:
# For remote secondmate homes declared in data/secondmates.md, the script is
# shipped over SSH stdin (`bash -s -- --group --json`) rather than copying
# credential files to this machine.
# Why shipping the script over stdin was chosen over transferring files:
# 1. Secret containment: Credentials (tokens, API keys, session keys) are read
#    and hashed strictly on the host where they reside; raw secrets never travel
#    over the network or cross machine boundaries.
# 2. Only the 12-character truncated SHA-256 digest and public metadata (task id,
#    harness, auth method, account label) are transmitted back over stdout.
# 3. No pre-installation is required on remote hosts; the remote host needs only
#    bash and standard hashing tools (shasum, sha256sum, openssl, or perl), which
#    are already required on all Firstmate nodes.
# 4. If remote files were read locally over SSH instead, secret files
#    (.credentials.json, token files, auth.json) would have to be transferred
#    across SSH to this machine, violating the hard rule never to expose or
#    transfer credentials.
set +x
set -u

SCRIPT_SRC="${BASH_SOURCE[0]:-${0:-bash}}"
if [ -n "$SCRIPT_SRC" ] && [ -d "$(dirname "$SCRIPT_SRC")" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi

if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT="$FM_ROOT_OVERRIDE"
elif [ -d "$SCRIPT_DIR/.." ]; then
  FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  FM_ROOT="$SCRIPT_DIR"
fi
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

DOMAIN_LABEL="fm-credential-fingerprint-v1:"

SCRIPT_PATH="$FM_ROOT/bin/fm-account-fingerprint.sh"
if [ ! -f "$SCRIPT_PATH" ]; then
  SCRIPT_PATH=$(perl -e 'use Cwd "abs_path"; print abs_path($ARGV[0]);' -- "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
fi
[ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ] || SCRIPT_PATH="${BASH_SOURCE[0]:-${0:-}}"

# shellcheck source=bin/fm-worker-account-lib.sh
if [ -f "$SCRIPT_DIR/fm-worker-account-lib.sh" ]; then
  . "$SCRIPT_DIR/fm-worker-account-lib.sh"
fi
# shellcheck source=bin/fm-backend.sh
if [ -f "$SCRIPT_DIR/fm-backend.sh" ]; then
  . "$SCRIPT_DIR/fm-backend.sh"
fi
# shellcheck source=bin/fm-secondmate-registry-lib.sh
if [ -f "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" ]; then
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
fi
# shellcheck source=bin/fm-timeout-lib.sh
if [ -f "$SCRIPT_DIR/fm-timeout-lib.sh" ]; then
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
fi

usage() {
  cat <<'EOF'
Usage:
  fm-account-fingerprint.sh [<task-id>] [--json]
  fm-account-fingerprint.sh --current [--json]
  fm-account-fingerprint.sh --group [--json]
  fm-account-fingerprint.sh --list [--json]
  fm-account-fingerprint.sh --fleet [--json]
  fm-account-fingerprint.sh -h | --help

Inspect and report credential fingerprint, auth method, and account usage
bucket for a worker task or the current environment, with live-worker grouping
and fleet-wide inspection across registered secondmate homes.

Options:
  <task-id>     Inspect the recorded worker task under state/<task-id>.meta
  --current     Inspect the current process environment and active pins
  --group       List all live workers in this home and group by credential fingerprint
  --list        Alias for --group
  --fleet       List all live workers across the fleet (primary + secondmates) grouped by fingerprint
  --json        Format output as JSON
  -h, --help    Show this help message and exit
EOF
}

# fm_meta_get fallback if fm-backend.sh was not sourced
if ! command -v fm_meta_get >/dev/null 2>&1; then
  fm_meta_get() {
    local meta=$1 key=$2 line value=''
    [ -f "$meta" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) value=${line#*=} ;;
      esac
    done < "$meta" 2>/dev/null || true
    printf '%s' "$value"
  }
fi

# secondmate_registry_parse_line fallback if fm-secondmate-registry-lib.sh was not sourced
# shellcheck disable=SC2034
if ! command -v secondmate_registry_parse_line >/dev/null 2>&1; then
  secondmate_registry_parse_line() {
    local line=$1
    local local_re='^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
    local remote_re='^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
    SECONDMATE_REGISTRY_ID=
    SECONDMATE_REGISTRY_SUMMARY=
    SECONDMATE_REGISTRY_HOST=
    SECONDMATE_REGISTRY_ROOT=
    SECONDMATE_REGISTRY_HOME=
    SECONDMATE_REGISTRY_SCOPE=
    SECONDMATE_REGISTRY_PROJECTS=
    SECONDMATE_REGISTRY_ADDED=
    SECONDMATE_REGISTRY_REMOTE=0
    if [[ "$line" =~ $local_re ]]; then
      SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
      SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
      SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[3]}
      SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[4]}
      SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[5]}
      SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[6]}
    elif [[ "$line" =~ $remote_re ]]; then
      SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
      SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
      SECONDMATE_REGISTRY_HOST=${BASH_REMATCH[3]}
      SECONDMATE_REGISTRY_ROOT=${BASH_REMATCH[4]}
      SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[5]}
      SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[6]}
      SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[7]}
      SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[8]}
      SECONDMATE_REGISTRY_REMOTE=1
    else
      return 1
    fi
    [ -n "$SECONDMATE_REGISTRY_HOME" ] || return 1
    return 0
  }
fi

# fingerprint_credential <secret-string>
# Computes the 12-hex-character truncated SHA-256 digest of DOMAIN_LABEL + secret.
# Never echoes or exposes the secret. Unsets the input variable immediately.
fingerprint_credential() {
  local cred=${1:-} digest=''
  [ -n "$cred" ] || { printf 'unknown\n'; return 0; }
  cred=$(printf '%s' "$cred" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$cred" ] || { printf 'unknown\n'; return 0; }

  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s%s' "$DOMAIN_LABEL" "$cred" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s%s' "$DOMAIN_LABEL" "$cred" | sha256sum 2>/dev/null | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s%s' "$DOMAIN_LABEL" "$cred" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
  else
    digest=$(perl -e 'use Digest::SHA qw(sha256_hex); print sha256_hex($ARGV[0] . $ARGV[1]);' -- "$DOMAIN_LABEL" "$cred" 2>/dev/null)
  fi
  unset cred
  if [ -n "$digest" ] && [ "$digest" != "none" ]; then
    printf '%s\n' "${digest:0:12}"
  else
    printf 'unknown\n'
  fi
}

# resolve_token_file <token-spec> [<mate-id>]
# Resolves a token:<path> or token:<basename> to an existing absolute file path.
resolve_token_file() {
  local spec=${1:-} mate=${2:-} cand='' cand_f=''
  spec=${spec#token:}
  [ -n "$spec" ] || return 1
  case "$spec" in
    /*)
      if [ -f "$spec" ]; then
        printf '%s\n' "$spec"
        return 0
      fi
      ;;
  esac

  # Search in config/claude-account
  if [ -f "$CONFIG/claude-account" ]; then
    cand=$(grep -E "^token:.*/${spec}$" "$CONFIG/claude-account" 2>/dev/null | head -n 1 || true)
    if [ -n "$cand" ] && [ -f "${cand#token:}" ]; then
      printf '%s\n' "${cand#token:}"
      return 0
    fi
  fi

  # Search in config/claude-accounts
  if [ -f "$CONFIG/claude-accounts" ]; then
    cand=$(grep -E "^token:.*/${spec}$" "$CONFIG/claude-accounts" 2>/dev/null | head -n 1 || true)
    if [ -n "$cand" ] && [ -f "${cand#token:}" ]; then
      printf '%s\n' "${cand#token:}"
      return 0
    fi
  fi

  # Search in secondmate config
  if [ -n "$mate" ] && [ -f "$CONFIG/secondmate-accounts/$mate/claude-account" ]; then
    cand=$(grep -E "^token:.*/${spec}$" "$CONFIG/secondmate-accounts/$mate/claude-account" 2>/dev/null | head -n 1 || true)
    if [ -n "$cand" ] && [ -f "${cand#token:}" ]; then
      printf '%s\n' "${cand#token:}"
      return 0
    fi
  fi
  for cand_f in "$CONFIG"/secondmate-accounts/*/claude-account; do
    if [ -f "$cand_f" ]; then
      cand=$(grep -E "^token:.*/${spec}$" "$cand_f" 2>/dev/null | head -n 1 || true)
      if [ -n "$cand" ] && [ -f "${cand#token:}" ]; then
        printf '%s\n' "${cand#token:}"
        return 0
      fi
    fi
  done

  # Search ~/.config/claude-tokens
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-tokens"
  if [ -f "$dir/$spec" ]; then
    printf '%s\n' "$dir/$spec"
    return 0
  fi
  if [ -f "$dir/$spec.token" ]; then
    printf '%s\n' "$dir/$spec.token"
    return 0
  fi
  return 1
}

# token_account_label <token-path-or-spec>
# Reads the account email/label from a companion .meta file if present,
# otherwise returns the declared token name.
token_account_label() {
  local path=$1 mf acct base
  path=${path#token:}
  mf="${path%.token}.meta"
  if [ -f "$mf" ]; then
    acct=$(awk -F': *' '$1 == "account" { print $2; exit }' "$mf" 2>/dev/null || true)
    if [ -n "$acct" ]; then
      printf '%s\n' "$acct"
      return 0
    fi
  fi
  base=$(basename "$path")
  printf '%s\n' "token:$base"
}

# read_pi_auth <auth-json-path> <provider>
# Returns "auth_method<TAB>account<TAB>fingerprint<TAB>derivation"
read_pi_auth() {
  local auth_file=$1 provider=${2:-}
  if [ ! -f "$auth_file" ] || [ ! -r "$auth_file" ]; then
    printf 'API key\t%s\tunknown\tunknown\n' "${provider:-unknown}"
    return 0
  fi
  if [ -z "$provider" ]; then
    provider=$(jq -r 'keys | if length == 1 then .[0] else empty end' "$auth_file" 2>/dev/null || true)
  fi
  if [ -z "$provider" ]; then
    printf 'API key\tpi\tunknown\tunknown\n'
    return 0
  fi

  local ptype pemail pkey
  ptype=$(jq -r --arg p "$provider" '.[$p].type // empty' "$auth_file" 2>/dev/null || true)
  pemail=$(jq -r --arg p "$provider" '.[$p].email // empty' "$auth_file" 2>/dev/null || true)
  local acct="${pemail:-$provider}"
  local auth="API key"
  if [ "$ptype" = "api_key" ]; then
    auth="API key"
    pkey=$(jq -r --arg p "$provider" '.[$p].key // empty' "$auth_file" 2>/dev/null || true)
  elif [ "$ptype" = "oauth" ]; then
    auth="subscription login"
    pkey=$(jq -r --arg p "$provider" '.[$p].refresh // .[$p].access // empty' "$auth_file" 2>/dev/null || true)
  else
    auth="other"
    pkey=$(jq -r --arg p "$provider" '.[$p].key // .[$p].access // .[$p].token // empty' "$auth_file" 2>/dev/null || true)
  fi

  local fp="unknown"
  local deriv="unknown"
  if [ -n "$pkey" ]; then
    fp=$(fingerprint_credential "$pkey")
    deriv="token-derived"
    unset pkey
  elif [ -n "$pemail" ]; then
    fp=$(fingerprint_credential "$pemail")
    deriv="identity-derived"
  fi
  printf '%s\t%s\t%s\t%s\n' "$auth" "$acct" "$fp" "$deriv"
}

# inspect_worker <task-id>
# Emits "target<TAB>harness<TAB>auth_method<TAB>account<TAB>fingerprint<TAB>derivation"
inspect_worker() {
  local id=$1 meta="$STATE/$1.meta"
  if [ ! -f "$meta" ]; then
    echo "error: task not found in state: $id" >&2
    return 1
  fi

  local harness account account_request account_provider kind
  harness=$(fm_meta_get "$meta" harness)
  account=$(fm_meta_get "$meta" account)
  account_request=$(fm_meta_get "$meta" account_request)
  account_provider=$(fm_meta_get "$meta" account_provider)
  kind=$(fm_meta_get "$meta" kind)

  [ -n "$harness" ] || harness=unknown

  local out_harness="$harness"
  local out_auth="unknown"
  local out_account="unknown"
  local out_fp="unknown"
  local out_derivation="unknown"

  case "$out_harness" in
    claude)
      local token_spec="" token_path=""
      if [[ "$account_request" == token:* ]]; then
        token_spec="$account_request"
      elif [[ "$account" == token:* ]]; then
        token_spec="$account"
      fi

      if [ -n "$token_spec" ]; then
        out_auth="setup token"
        local mate=""
        [ "$kind" = secondmate ] && mate="$id"
        token_path=$(resolve_token_file "$token_spec" "$mate" || true)
        if [ -n "$token_path" ]; then
          out_account=$(token_account_label "$token_path")
          local tok=""
          if command -v fm_worker_account_token_load >/dev/null 2>&1; then
            tok=$(fm_worker_account_token_load "$token_path" 2>/dev/null || true)
          fi
          if [ -z "$tok" ] && [ -f "$token_path" ] && [ -r "$token_path" ]; then
            # Direct owner-only check fallback
            tok=$(perl -e '
              my ($f) = @ARGV;
              my @st = stat $f or exit 1;
              ($st[2] & 077) == 0 or exit 1;
              open(my $fh, "<", $f) or exit 1;
              my $b = do { local $/; <$fh> } // "";
              $b =~ s/\A\s+//; $b =~ s/\s+\z//;
              print $b;
            ' -- "$token_path" 2>/dev/null || true)
          fi
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            out_derivation="token-derived"
            unset tok
          else
            out_fp="unknown"
            out_derivation="unknown"
          fi
        else
          out_account=$(token_account_label "$token_spec")
          out_fp="unknown"
          out_derivation="unknown"
        fi
      else
        out_auth="subscription login"
        local cred_dir=""
        local claude_json=""
        if [ "$account" = ordinary ] || [ "$account_request" = ordinary ] || [ -z "$account" ]; then
          out_account="ordinary"
          cred_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
          claude_json="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
        else
          out_account="$account"
          cred_dir="$account"
          claude_json="$account/.claude.json"
        fi

        local cred_file="$cred_dir/.credentials.json"
        local tok=""
        if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
          tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
          [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
        fi

        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        else
          # Token not available on disk (e.g. stored in macOS Keychain or absent).
          # Inspect non-secret config (.claude.json) for account identity.
          local ident=""
          if [ -f "$claude_json" ] && [ -r "$claude_json" ]; then
            ident=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.organizationUuid // .oauthAccount.accountUuid // empty' "$claude_json" 2>/dev/null || true)
          fi

          if [ -n "$ident" ]; then
            out_account="$ident"
            out_fp=$(fingerprint_credential "$ident")
            out_derivation="identity-derived"
          else
            out_fp="unknown"
            out_derivation="unknown"
          fi
        fi
      fi
      ;;

    pi|pi-signed)
      local pi_root="${account:-}"
      if [ -z "$pi_root" ] || [ "$pi_root" = ordinary ]; then
        pi_root="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
      fi
      local pi_auth
      pi_auth=$(read_pi_auth "$pi_root/auth.json" "${account_provider:-}")
      out_auth=$(printf '%s' "$pi_auth" | cut -f1)
      out_account=$(printf '%s' "$pi_auth" | cut -f2)
      out_fp=$(printf '%s' "$pi_auth" | cut -f3)
      out_derivation=$(printf '%s' "$pi_auth" | cut -f4)
      [ -n "$out_derivation" ] || out_derivation="token-derived"
      [ "$out_fp" != "unknown" ] || out_derivation="unknown"
      ;;

    codex)
      local codex_auth="$HOME/.codex/auth.json"
      if [ -f "$codex_auth" ] && [ -r "$codex_auth" ]; then
        local mode tok
        mode=$(jq -r '.auth_mode // empty' "$codex_auth" 2>/dev/null || true)
        if [ "$mode" = "chatgpt" ] || [ "$mode" = "oauth" ]; then
          out_auth="subscription login"
          tok=$(jq -r '.tokens.access_token // .tokens.refresh_token // .tokens.id_token // empty' "$codex_auth" 2>/dev/null || true)
        elif [ -n "$(jq -r '.OPENAI_API_KEY // empty' "$codex_auth" 2>/dev/null || true)" ]; then
          out_auth="API key"
          tok=$(jq -r '.OPENAI_API_KEY // empty' "$codex_auth" 2>/dev/null || true)
        else
          out_auth="subscription login"
          tok=$(jq -r '.tokens.access_token // .tokens.refresh_token // empty' "$codex_auth" 2>/dev/null || true)
        fi
        local acct_id
        acct_id=$(jq -r '.tokens.account_id // empty' "$codex_auth" 2>/dev/null || true)
        [ -n "$acct_id" ] && out_account="$acct_id" || out_account="codex"
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        elif [ -n "$acct_id" ]; then
          out_fp=$(fingerprint_credential "$acct_id")
          out_derivation="identity-derived"
        else
          out_fp="unknown"
          out_derivation="unknown"
        fi
      elif [ -n "${OPENAI_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="OPENAI_API_KEY"
        out_fp=$(fingerprint_credential "$OPENAI_API_KEY")
        out_derivation="token-derived"
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
        out_derivation="unknown"
      fi
      ;;

    grok)
      local grok_auth="$HOME/.grok/auth.json"
      if [ -f "$grok_auth" ] && [ -r "$grok_auth" ]; then
        out_auth="subscription login"
        local tok acct
        tok=$(jq -r 'to_entries[0].value | .access_token // .token // .refresh_token // .key // empty' "$grok_auth" 2>/dev/null || true)
        acct=$(jq -r 'to_entries[0].value | .email // .user_id // empty' "$grok_auth" 2>/dev/null || true)
        [ -n "$acct" ] && out_account="$acct" || out_account="grok"
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        elif [ -n "$acct" ]; then
          out_fp=$(fingerprint_credential "$acct")
          out_derivation="identity-derived"
        else
          out_fp="unknown"
          out_derivation="unknown"
        fi
      elif [ -n "${XAI_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="XAI_API_KEY"
        out_fp=$(fingerprint_credential "$XAI_API_KEY")
        out_derivation="token-derived"
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
        out_derivation="unknown"
      fi
      ;;

    gemini|agy)
      local gemini_oauth="$HOME/.gemini/oauth_creds.json"
      local gemini_legacy="$HOME/.gemini/gemini-credentials.json"
      local google_accts="$HOME/.gemini/google_accounts.json"
      local tok="" acct=""
      if [ -f "$google_accts" ] && [ -r "$google_accts" ]; then
        acct=$(jq -r '.active // empty' "$google_accts" 2>/dev/null || true)
      fi
      if [ -f "$gemini_oauth" ] && [ -r "$gemini_oauth" ]; then
        tok=$(jq -r '.access_token // .refresh_token // .token // empty' "$gemini_oauth" 2>/dev/null || true)
        [ -n "$acct" ] || acct=$(jq -r '.email // .account // empty' "$gemini_oauth" 2>/dev/null || true)
      elif [ -f "$gemini_legacy" ] && [ -r "$gemini_legacy" ]; then
        tok=$(jq -r '.access_token // .refresh_token // .token // empty' "$gemini_legacy" 2>/dev/null || true)
        [ -n "$acct" ] || acct=$(jq -r '.email // .account // empty' "$gemini_legacy" 2>/dev/null || true)
      fi

      if [ -n "$tok" ]; then
        out_auth="subscription login"
        [ -n "$acct" ] && out_account="$acct" || out_account="$out_harness"
        out_fp=$(fingerprint_credential "$tok")
        out_derivation="token-derived"
        unset tok
      elif [ -n "$acct" ]; then
        out_auth="subscription login"
        out_account="$acct"
        out_fp=$(fingerprint_credential "$acct")
        out_derivation="identity-derived"
      elif [ -n "${GEMINI_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="GEMINI_API_KEY"
        out_fp=$(fingerprint_credential "$GEMINI_API_KEY")
        out_derivation="token-derived"
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
        out_derivation="unknown"
      fi
      ;;

    muse)
      local muse_auth="${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json"
      if [ -f "$muse_auth" ] && [ -r "$muse_auth" ]; then
        out_auth="subscription login"
        out_account="muse"
        local tok
        tok=$(jq -r '.access_token // .token // .api_key // empty' "$muse_auth" 2>/dev/null || true)
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        else
          out_fp="unknown"
          out_derivation="unknown"
        fi
      elif [ -n "${META_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="META_API_KEY"
        out_fp=$(fingerprint_credential "$META_API_KEY")
        out_derivation="token-derived"
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
        out_derivation="unknown"
      fi
      ;;

    commandcode)
      local cc_auth="$HOME/.commandcode/auth.json"
      if [ -f "$cc_auth" ] && [ -r "$cc_auth" ]; then
        out_auth="subscription login"
        out_account="commandcode"
        local tok
        tok=$(jq -r '.token // .access_token // .api_key // empty' "$cc_auth" 2>/dev/null || true)
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        else
          out_fp="unknown"
          out_derivation="unknown"
        fi
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
        out_derivation="unknown"
      fi
      ;;

    *)
      out_auth="unknown"
      out_account="unknown"
      out_fp="unknown"
      out_derivation="unknown"
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$out_harness" "$out_auth" "$out_account" "$out_fp" "$out_derivation"
}

# inspect_current_env
# Emits "target<TAB>harness<TAB>auth_method<TAB>account<TAB>fingerprint<TAB>derivation" for current env.
inspect_current_env() {
  local detected_harness=""
  if [ -x "$FM_ROOT/bin/fm-harness.sh" ]; then
    detected_harness=$("$FM_ROOT/bin/fm-harness.sh" 2>/dev/null || true)
  fi
  [ "$detected_harness" != "unknown" ] || detected_harness=""

  local out_target="current"
  local out_harness="${detected_harness:-unknown}"
  local out_auth="unknown"
  local out_account="unknown"
  local out_fp="unknown"
  local out_derivation="unknown"

  # 1. Environment variables check
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    out_harness="claude"
    out_auth="setup token"
    out_account="CLAUDE_CODE_OAUTH_TOKEN"
    out_fp=$(fingerprint_credential "$CLAUDE_CODE_OAUTH_TOKEN")
    out_derivation="token-derived"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    out_harness="claude"
    out_auth="API key"
    out_account="ANTHROPIC_API_KEY"
    out_fp=$(fingerprint_credential "$ANTHROPIC_API_KEY")
    out_derivation="token-derived"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="codex"
    out_auth="API key"
    out_account="OPENAI_API_KEY"
    out_fp=$(fingerprint_credential "$OPENAI_API_KEY")
    out_derivation="token-derived"
  elif [ -n "${GEMINI_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="gemini"
    out_auth="API key"
    out_account="GEMINI_API_KEY"
    out_fp=$(fingerprint_credential "$GEMINI_API_KEY")
    out_derivation="token-derived"
  elif [ -n "${META_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="muse"
    out_auth="API key"
    out_account="META_API_KEY"
    out_fp=$(fingerprint_credential "$META_API_KEY")
    out_derivation="token-derived"
  elif [ -n "${XAI_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="grok"
    out_auth="API key"
    out_account="XAI_API_KEY"
    out_fp=$(fingerprint_credential "$XAI_API_KEY")
    out_derivation="token-derived"
  # 2. Config pin check (config/claude-account)
  elif [ -f "$CONFIG/claude-account" ]; then
    out_harness="claude"
    local pin_val
    pin_val=$(grep -v '^[[:space:]]*$' "$CONFIG/claude-account" 2>/dev/null | head -n 1 | tr -d '\r\n' || true)
    if [[ "$pin_val" == token:* ]]; then
      out_auth="setup token"
      local token_path
      token_path=$(resolve_token_file "$pin_val" || true)
      if [ -n "$token_path" ]; then
        out_account=$(token_account_label "$token_path")
        local tok=""
        if command -v fm_worker_account_token_load >/dev/null 2>&1; then
          tok=$(fm_worker_account_token_load "$token_path" 2>/dev/null || true)
        fi
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        else
          out_fp="unknown"
          out_derivation="unknown"
        fi
      else
        out_account=$(token_account_label "$pin_val")
        out_fp="unknown"
        out_derivation="unknown"
      fi
    elif [ "$pin_val" = ordinary ]; then
      out_auth="subscription login"
      out_account="ordinary"
      local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
      local tok=""
      if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
        tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
        [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
      fi
      if [ -n "$tok" ]; then
        out_fp=$(fingerprint_credential "$tok")
        out_derivation="token-derived"
        unset tok
      else
        local claude_json="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
        local ident=""
        if [ -f "$claude_json" ] && [ -r "$claude_json" ]; then
          ident=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.organizationUuid // .oauthAccount.accountUuid // empty' "$claude_json" 2>/dev/null || true)
        fi
        if [ -n "$ident" ]; then
          out_account="$ident"
          out_fp=$(fingerprint_credential "$ident")
          out_derivation="identity-derived"
        fi
      fi
    elif [ -n "$pin_val" ]; then
      out_auth="subscription login"
      out_account="$pin_val"
      local cred_file="$pin_val/.credentials.json"
      local tok=""
      if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
        tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
        [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
      fi
      if [ -n "$tok" ]; then
        out_fp=$(fingerprint_credential "$tok")
        out_derivation="token-derived"
        unset tok
      else
        local claude_json="$pin_val/.claude.json"
        local ident=""
        if [ -f "$claude_json" ] && [ -r "$claude_json" ]; then
          ident=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.organizationUuid // .oauthAccount.accountUuid // empty' "$claude_json" 2>/dev/null || true)
        fi
        if [ -n "$ident" ]; then
          out_account="$ident"
          out_fp=$(fingerprint_credential "$ident")
          out_derivation="identity-derived"
        fi
      fi
    fi
  # 3. Pi pin check (config/pi-account)
  elif [ -f "$CONFIG/pi-account" ]; then
    out_harness="pi"
    local pi_root pi_providers pi_auth
    pi_root=$(head -n 1 "$CONFIG/pi-account" 2>/dev/null | tr -d '\r\n' || true)
    pi_providers=$(sed -n '2p' "$CONFIG/pi-account" 2>/dev/null || true)
    local first_p=${pi_providers%% *}
    if [ "$pi_root" = ordinary ] || [ -z "$pi_root" ]; then
      pi_root="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    fi
    pi_auth=$(read_pi_auth "$pi_root/auth.json" "$first_p")
    out_auth=$(printf '%s' "$pi_auth" | cut -f1)
    out_account=$(printf '%s' "$pi_auth" | cut -f2)
    out_fp=$(printf '%s' "$pi_auth" | cut -f3)
    out_derivation=$(printf '%s' "$pi_auth" | cut -f4)
    [ -n "$out_derivation" ] || out_derivation="token-derived"
    [ "$out_fp" != "unknown" ] || out_derivation="unknown"
  # 4. Fallback to detected harness default files
  else
    case "$out_harness" in
      claude)
        out_auth="subscription login"
        out_account="ordinary"
        local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
        local tok=""
        if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
          tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
          [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
        fi
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        else
          local claude_json="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
          local ident=""
          if [ -f "$claude_json" ] && [ -r "$claude_json" ]; then
            ident=$(jq -r '.oauthAccount.emailAddress // .oauthAccount.organizationUuid // .oauthAccount.accountUuid // empty' "$claude_json" 2>/dev/null || true)
          fi
          if [ -n "$ident" ]; then
            out_account="$ident"
            out_fp=$(fingerprint_credential "$ident")
            out_derivation="identity-derived"
          fi
        fi
        ;;
      pi|pi-signed)
        local pi_auth
        pi_auth=$(read_pi_auth "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json")
        out_auth=$(printf '%s' "$pi_auth" | cut -f1)
        out_account=$(printf '%s' "$pi_auth" | cut -f2)
        out_fp=$(printf '%s' "$pi_auth" | cut -f3)
        out_derivation=$(printf '%s' "$pi_auth" | cut -f4)
        [ -n "$out_derivation" ] || out_derivation="token-derived"
        [ "$out_fp" != "unknown" ] || out_derivation="unknown"
        ;;
      codex)
        local codex_auth="$HOME/.codex/auth.json"
        if [ -f "$codex_auth" ] && [ -r "$codex_auth" ]; then
          out_auth="subscription login"
          local acct_id
          acct_id=$(jq -r '.tokens.account_id // empty' "$codex_auth" 2>/dev/null || true)
          [ -n "$acct_id" ] && out_account="$acct_id" || out_account="codex"
          local tok
          tok=$(jq -r '.tokens.access_token // .tokens.refresh_token // .OPENAI_API_KEY // empty' "$codex_auth" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            out_derivation="token-derived"
            unset tok
          elif [ -n "$acct_id" ]; then
            out_fp=$(fingerprint_credential "$acct_id")
            out_derivation="identity-derived"
          fi
        fi
        ;;
      grok)
        local grok_auth="$HOME/.grok/auth.json"
        if [ -f "$grok_auth" ] && [ -r "$grok_auth" ]; then
          out_auth="subscription login"
          local tok acct
          tok=$(jq -r 'to_entries[0].value | .access_token // .token // .refresh_token // .key // empty' "$grok_auth" 2>/dev/null || true)
          acct=$(jq -r 'to_entries[0].value | .email // .user_id // empty' "$grok_auth" 2>/dev/null || true)
          [ -n "$acct" ] && out_account="$acct" || out_account="grok"
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            out_derivation="token-derived"
            unset tok
          elif [ -n "$acct" ]; then
            out_fp=$(fingerprint_credential "$acct")
            out_derivation="identity-derived"
          fi
        fi
        ;;
      gemini|agy)
        local gemini_oauth="$HOME/.gemini/oauth_creds.json"
        local gemini_legacy="$HOME/.gemini/gemini-credentials.json"
        local google_accts="$HOME/.gemini/google_accounts.json"
        local tok="" acct=""
        if [ -f "$google_accts" ] && [ -r "$google_accts" ]; then
          acct=$(jq -r '.active // empty' "$google_accts" 2>/dev/null || true)
        fi
        if [ -f "$gemini_oauth" ] && [ -r "$gemini_oauth" ]; then
          tok=$(jq -r '.access_token // .refresh_token // .token // empty' "$gemini_oauth" 2>/dev/null || true)
          [ -n "$acct" ] || acct=$(jq -r '.email // .account // empty' "$gemini_oauth" 2>/dev/null || true)
        elif [ -f "$gemini_legacy" ] && [ -r "$gemini_legacy" ]; then
          tok=$(jq -r '.access_token // .refresh_token // .token // empty' "$gemini_legacy" 2>/dev/null || true)
          [ -n "$acct" ] || acct=$(jq -r '.email // .account // empty' "$gemini_legacy" 2>/dev/null || true)
        fi

        if [ -n "$tok" ]; then
          out_auth="subscription login"
          [ -n "$acct" ] && out_account="$acct" || out_account="$out_harness"
          out_fp=$(fingerprint_credential "$tok")
          out_derivation="token-derived"
          unset tok
        elif [ -n "$acct" ]; then
          out_auth="subscription login"
          out_account="$acct"
          out_fp=$(fingerprint_credential "$acct")
          out_derivation="identity-derived"
        fi
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$out_target" "$out_harness" "$out_auth" "$out_account" "$out_fp" "$out_derivation"
}

# format_single_result <tab-separated-line> <json-flag>
format_single_result() {
  local line=$1 json_flag=${2:-0}
  local target harness auth account fp derivation rest
  target=${line%%$'\t'*}
  rest=${line#*$'\t'}
  harness=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  auth=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  account=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  if [[ "$rest" == *$'\t'* ]]; then
    fp=${rest%%$'\t'*}
    derivation=${rest#*$'\t'}
  else
    fp=$rest
    [ "$fp" = "unknown" ] && derivation="unknown" || derivation="token-derived"
  fi

  if [ "$json_flag" -eq 1 ]; then
    jq -n \
      --arg target "$target" \
      --arg harness "$harness" \
      --arg auth_method "$auth" \
      --arg account "$account" \
      --arg fingerprint "$fp" \
      --arg derivation "$derivation" \
      '{target: $target, harness: $harness, auth_method: $auth_method, account: $account, fingerprint: $fingerprint, derivation: $derivation}'
  else
    printf 'target: %s\n' "$target"
    printf 'harness: %s\n' "$harness"
    printf 'auth_method: %s\n' "$auth"
    printf 'account: %s\n' "$account"
    if [ "$derivation" = "identity-derived" ]; then
      printf 'fingerprint: %s (identity-derived)\n' "$fp"
    else
      printf 'fingerprint: %s\n' "$fp"
    fi
  fi
}

# format_grouped_results <json-flag>
format_grouped_results() {
  local json_flag=${1:-0}
  local input
  input=$(cat)

  if [ -z "$input" ]; then
    if [ "$json_flag" -eq 1 ]; then
      printf '{"workers":[],"groups":[]}\n'
    else
      echo "no live workers found"
    fi
    return 0
  fi

  if [ "$json_flag" -eq 1 ]; then
    printf '%s\n' "$input" | jq -sR '
      split("\n")
      | map(select(length > 0))
      | map(split("\t"))
      | map({
          target: .[0],
          harness: .[1],
          auth_method: .[2],
          account: .[3],
          fingerprint: .[4],
          derivation: (.[5] // if .[4] == "unknown" then "unknown" else "token-derived" end)
        })
      | . as $workers
      | group_by(if .fingerprint == "unknown" then (.fingerprint + ":" + .harness + ":" + .auth_method + ":" + .account) else .fingerprint end)
      | map({
          fingerprint: .[0].fingerprint,
          derivation: .[0].derivation,
          harness: .[0].harness,
          auth_method: .[0].auth_method,
          account: .[0].account,
          workers: map(.target)
        }) as $groups
      | {workers: $workers, groups: $groups}
    '
  else
    # Group in shell: known fingerprints group together; unknown fingerprints group by harness+auth+account
    local -a group_keys=()
    local -A group_fp=() group_deriv=() group_harness=() group_auth=() group_account=() group_workers=()

    while IFS=$'\t' read -r target harness auth account fp derivation || [ -n "$target" ]; do
      [ -n "$target" ] || continue
      [ -n "$derivation" ] || { [ "$fp" = "unknown" ] && derivation="unknown" || derivation="token-derived"; }
      local key
      if [ "$fp" = "unknown" ]; then
        key="unknown:$harness:$auth:$account"
      else
        key="$fp"
      fi
      if [ -z "${group_workers[$key]+x}" ]; then
        group_keys+=("$key")
        group_fp[$key]=$fp
        group_deriv[$key]=$derivation
        group_harness[$key]=$harness
        group_auth[$key]=$auth
        group_account[$key]=$account
        group_workers[$key]="$target"
      else
        group_workers[$key]="${group_workers[$key]} $target"
      fi
    done <<< "$input"

    local first=1
    for key in "${group_keys[@]}"; do
      if [ "$first" -eq 0 ]; then
        printf '\n'
      fi
      first=0
      local deriv_label=""
      if [ "${group_deriv[$key]}" = "identity-derived" ]; then
        deriv_label=" (identity-derived)"
      fi
      printf 'fingerprint: %s%s [harness: %s, auth: %s, account: %s]\n' \
        "${group_fp[$key]}" "$deriv_label" "${group_harness[$key]}" "${group_auth[$key]}" "${group_account[$key]}"
      for w in ${group_workers[$key]}; do
        printf '  - %s\n' "$w"
      done
    done
  fi
}

# format_fleet_results <json-flag> <workers-tab-lines> <unreachable-tab-lines>
format_fleet_results() {
  local json_flag=${1:-0}
  local workers_input=${2:-}
  local unreachable_input=${3:-}

  if [ "$json_flag" -eq 1 ]; then
    jq -n \
      --arg workers_raw "$workers_input" \
      --arg unreach_raw "$unreachable_input" '
      ($workers_raw | split("\n") | map(select(length > 0)) | map(split("\t")) | map({
        host: .[0],
        home: .[1],
        home_path: .[2],
        target: .[3],
        harness: .[4],
        auth_method: .[5],
        account: .[6],
        fingerprint: .[7],
        derivation: (.[8] // if .[7] == "unknown" then "unknown" else "token-derived" end)
      })) as $workers
      | ($unreach_raw | split("\n") | map(select(length > 0)) | map(split("\t")) | map({
        host: .[0],
        home: .[1],
        home_path: .[2],
        reason: .[3]
      })) as $unreachable
      | ($workers
        | group_by(if .fingerprint == "unknown" then (.fingerprint + ":" + .harness + ":" + .auth_method + ":" + .account) else .fingerprint end)
        | map({
            fingerprint: .[0].fingerprint,
            derivation: .[0].derivation,
            harness: .[0].harness,
            auth_method: .[0].auth_method,
            account: .[0].account,
            workers: map({
              host: .host,
              home: .home,
              home_path: .home_path,
              target: .target,
              harness: .harness,
              auth_method: .auth_method
            })
          })) as $groups
      | {workers: $workers, groups: $groups, unreachable: $unreachable}
    '
  else
    local -a group_keys=()
    local -A group_fp=() group_deriv=() group_harness=() group_auth=() group_account=() group_workers=()

    while IFS=$'\t' read -r r_host r_home _r_hpath r_target r_harness r_auth r_account r_fp r_deriv || [ -n "$r_target" ]; do
      [ -n "$r_target" ] || continue
      [ -n "$r_deriv" ] || { [ "$r_fp" = "unknown" ] && r_deriv="unknown" || r_deriv="token-derived"; }
      local key
      if [ "$r_fp" = "unknown" ]; then
        key="unknown:$r_harness:$r_auth:$r_account"
      else
        key="$r_fp"
      fi
      local w_entry="host: $r_host, home: $r_home, task: $r_target, harness: $r_harness, auth: $r_auth"
      if [ -z "${group_workers[$key]+x}" ]; then
        group_keys+=("$key")
        group_fp[$key]=$r_fp
        group_deriv[$key]=$r_deriv
        group_harness[$key]=$r_harness
        group_auth[$key]=$r_auth
        group_account[$key]=$r_account
        group_workers[$key]="$w_entry"
      else
        group_workers[$key]="${group_workers[$key]}"$'\n'"$w_entry"
      fi
    done <<< "$workers_input"

    if [ "${#group_keys[@]}" -eq 0 ]; then
      printf 'no live workers found\n'
      if [ -n "$unreachable_input" ]; then
        printf '\nunreachable homes:\n'
        while IFS=$'\t' read -r u_host u_home _u_hpath u_reason || [ -n "$u_host" ]; do
          [ -n "$u_host" ] || continue
          printf '  - host: %s, home: %s (reason: %s)\n' "$u_host" "$u_home" "$u_reason"
        done <<< "$unreachable_input"
      fi
      return 0
    fi

    local first=1
    for key in "${group_keys[@]}"; do
      if [ "$first" -eq 0 ]; then
        printf '\n'
      fi
      first=0
      local deriv_label=""
      if [ "${group_deriv[$key]}" = "identity-derived" ]; then
        deriv_label=" (identity-derived)"
      fi
      printf 'fingerprint: %s%s [harness: %s, auth: %s, account: %s]\n' \
        "${group_fp[$key]}" "$deriv_label" "${group_harness[$key]}" "${group_auth[$key]}" "${group_account[$key]}"
      while IFS= read -r w_line; do
        [ -n "$w_line" ] || continue
        printf '  - %s\n' "$w_line"
      done <<< "${group_workers[$key]}"
    done

    if [ -n "$unreachable_input" ]; then
      if [ "$first" -eq 0 ]; then
        printf '\n'
      fi
      printf 'unreachable homes:\n'
      while IFS=$'\t' read -r u_host u_home _u_hpath u_reason || [ -n "$u_host" ]; do
        [ -n "$u_host" ] || continue
        printf '  - host: %s, home: %s (reason: %s)\n' "$u_host" "$u_home" "$u_reason"
      done <<< "$unreachable_input"
    fi
  fi
}

# collect_remote_home <host> <id> <home_path> <out_file> <err_file> <status_file> <script_file>
collect_remote_home() {
  local host=$1 id=$2 home_path=$3 out_file=$4 err_file=$5 status_file=$6 script_file=$7
  local ssh_bin=${FM_SSH_BIN:-ssh}
  local connect_timeout=${FM_SSH_CONNECT_TIMEOUT:-5}

  local -a ssh_cmd=(
    "$ssh_bin"
    -o BatchMode=yes
    -o "ConnectTimeout=$connect_timeout"
    -o ForwardAgent=no
    -o ClearAllForwardings=yes
    -o 'SendEnv=-*'
    -- "$host"
    "FM_HOME='$home_path' bash -s -- --group --json"
  )

  local rc=0
  if command -v fm_run_timed >/dev/null 2>&1; then
    fm_run_timed "$connect_timeout" "${ssh_cmd[@]}" < "$script_file" > "$out_file" 2> "$err_file" || rc=$?
  else
    "${ssh_cmd[@]}" < "$script_file" > "$out_file" 2> "$err_file" || rc=$?
  fi

  if [ "$rc" -eq 0 ] && [ -s "$out_file" ] && jq -e '.workers' "$out_file" >/dev/null 2>&1; then
    printf 'ok\n' > "$status_file"
  else
    local reason=""
    if [ -s "$err_file" ]; then
      reason=$(head -n 1 "$err_file" | tr -d '\r\n')
    fi
    [ -n "$reason" ] || reason="ssh exited with code $rc"
    printf '%s\n' "$reason" > "$status_file"
  fi
}

# run_fleet_inspection <json-flag>
run_fleet_inspection() {
  local json_flag=${1:-0}
  local local_host="${FM_SNAPSHOT_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo local)}"
  local workers_buf=""
  local unreachable_buf=""

  # 1. Primary home
  local primary_home="$FM_HOME"
  local primary_state="$STATE"

  shopt -s nullglob
  local primary_metas=("$primary_state"/*.meta)
  shopt -u nullglob

  for meta in "${primary_metas[@]}"; do
    [ -f "$meta" ] || continue
    local id
    id=$(basename "$meta" .meta)
    local res
    res=$(inspect_worker "$id" 2>/dev/null || true)
    if [ -n "$res" ]; then
      local target harness auth account fp derivation rest
      target=${res%%$'\t'*}
      rest=${res#*$'\t'}
      harness=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      auth=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      account=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      if [[ "$rest" == *$'\t'* ]]; then
        fp=${rest%%$'\t'*}
        derivation=${rest#*$'\t'}
      else
        fp=$rest
        [ "$fp" = "unknown" ] && derivation="unknown" || derivation="token-derived"
      fi
      local row="$local_host"$'\t'"primary"$'\t'"$primary_home"$'\t'"$target"$'\t'"$harness"$'\t'"$auth"$'\t'"$account"$'\t'"$fp"$'\t'"$derivation"
      workers_buf="${workers_buf:+${workers_buf}$'\n'}$row"
    fi
  done

  # 2. Enumerate secondmates from data/secondmates.md
  local reg="$DATA/secondmates.md"
  local -a remote_jobs=()
  local tmp_dir=""
  tmp_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-acctfp-fleet.XXXXXX") || {
    echo "error: failed to create temporary directory for fleet inspection" >&2
    exit 1
  }

  local -A seen_routes=()
  seen_routes["local:$primary_home"]=1

  if [ -f "$reg" ] && [ -r "$reg" ]; then
    local line
    local slot=0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      if ! secondmate_registry_parse_line "$line"; then
        continue
      fi

      local sm_id="$SECONDMATE_REGISTRY_ID"
      local sm_home="$SECONDMATE_REGISTRY_HOME"
      local sm_host="$SECONDMATE_REGISTRY_HOST"
      local sm_remote="$SECONDMATE_REGISTRY_REMOTE"

      if [ "$sm_remote" -eq 0 ]; then
        # Local secondmate home
        if [ -n "${seen_routes["local:$sm_home"]+x}" ]; then
          continue
        fi
        seen_routes["local:$sm_home"]=1

        if [ ! -d "$sm_home" ] || [ ! -r "$sm_home" ]; then
          local unreach_row="$local_host"$'\t'"$sm_id"$'\t'"$sm_home"$'\t'"directory not found or inaccessible"
          unreachable_buf="${unreachable_buf:+${unreachable_buf}$'\n'}$unreach_row"
          continue
        fi

        # Inspect local secondmate home
        shopt -s nullglob
        local sm_metas=("$sm_home/state"/*.meta)
        shopt -u nullglob

        for meta in "${sm_metas[@]}"; do
          [ -f "$meta" ] || continue
          local tid
          tid=$(basename "$meta" .meta)
          local res
          res=$(
            STATE="$sm_home/state" CONFIG="$sm_home/config" FM_HOME="$sm_home" \
            inspect_worker "$tid" 2>/dev/null || true
          )
          if [ -n "$res" ]; then
            local target harness auth account fp derivation rest
            target=${res%%$'\t'*}
            rest=${res#*$'\t'}
            harness=${rest%%$'\t'*}
            rest=${rest#*$'\t'}
            auth=${rest%%$'\t'*}
            rest=${rest#*$'\t'}
            account=${rest%%$'\t'*}
            rest=${rest#*$'\t'}
            if [[ "$rest" == *$'\t'* ]]; then
              fp=${rest%%$'\t'*}
              derivation=${rest#*$'\t'}
            else
              fp=$rest
              [ "$fp" = "unknown" ] && derivation="unknown" || derivation="token-derived"
            fi
            local row="$local_host"$'\t'"$sm_id"$'\t'"$sm_home"$'\t'"$target"$'\t'"$harness"$'\t'"$auth"$'\t'"$account"$'\t'"$fp"$'\t'"$derivation"
            workers_buf="${workers_buf:+${workers_buf}$'\n'}$row"
          fi
        done
      else
        # Remote secondmate home
        if [ -z "$sm_host" ]; then
          local unreach_row="unknown"$'\t'"$sm_id"$'\t'"$sm_home"$'\t'"missing SSH host alias in registry"
          unreachable_buf="${unreachable_buf:+${unreachable_buf}$'\n'}$unreach_row"
          continue
        fi

        local route_key="ssh:$sm_host:$sm_home"
        if [ -n "${seen_routes["$route_key"]+x}" ]; then
          continue
        fi
        seen_routes["$route_key"]=1

        slot=$((slot + 1))
        local out_file="$tmp_dir/$slot.out"
        local err_file="$tmp_dir/$slot.err"
        local status_file="$tmp_dir/$slot.status"

        collect_remote_home \
          "$sm_host" "$sm_id" "$sm_home" \
          "$out_file" "$err_file" "$status_file" "$SCRIPT_PATH" &
        remote_jobs+=("$! $slot $sm_host $sm_id $sm_home")
      fi
    done < "$reg"
  fi

  # Wait for all remote jobs
  for job_info in "${remote_jobs[@]}"; do
    local pid slot sm_host sm_id sm_home
    read -r pid slot sm_host sm_id sm_home <<< "$job_info"
    wait "$pid" 2>/dev/null || true

    local out_file="$tmp_dir/$slot.out"
    local status_file="$tmp_dir/$slot.status"
    local status="failed"
    [ -f "$status_file" ] && status=$(cat "$status_file")

    if [ "$status" = "ok" ] && [ -f "$out_file" ]; then
      while IFS=$'\t' read -r target harness auth account fp derivation || [ -n "$target" ]; do
        [ -n "$target" ] || continue
        [ -n "$derivation" ] || { [ "$fp" = "unknown" ] && derivation="unknown" || derivation="token-derived"; }
        local row="$sm_host"$'\t'"$sm_id"$'\t'"$sm_home"$'\t'"$target"$'\t'"$harness"$'\t'"$auth"$'\t'"$account"$'\t'"$fp"$'\t'"$derivation"
        workers_buf="${workers_buf:+${workers_buf}$'\n'}$row"
      done < <(jq -r '.workers[]? | [.target // "", .harness // "", .auth_method // "", .account // "", .fingerprint // "", .derivation // ""] | @tsv' "$out_file" 2>/dev/null || true)
    else
      local reason="$status"
      local unreach_row="$sm_host"$'\t'"$sm_id"$'\t'"$sm_home"$'\t'"$reason"
      unreachable_buf="${unreachable_buf:+${unreachable_buf}$'\n'}$unreach_row"
    fi
  done

  rm -rf -- "$tmp_dir"
  format_fleet_results "$json_flag" "$workers_buf" "$unreachable_buf"
}

# --- CLI parsing -------------------------------------------------------------
MODE="default"
JSON_OUT=0
TASK_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --current|--env)
      MODE="current"
      shift
      ;;
    --group|--list|--live|group|list|live)
      MODE="group"
      shift
      ;;
    --fleet|fleet)
      MODE="fleet"
      shift
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$TASK_ID" ]; then
        echo "error: only one task id may be specified: $1" >&2
        exit 2
      fi
      TASK_ID=$1
      MODE="task"
      shift
      ;;
  esac
done

case "$MODE" in
  task)
    line=$(inspect_worker "$TASK_ID") || exit 1
    format_single_result "$line" "$JSON_OUT"
    ;;
  current)
    line=$(inspect_current_env) || exit 1
    format_single_result "$line" "$JSON_OUT"
    ;;
  group)
    shopt -s nullglob
    metas=("$STATE"/*.meta)
    shopt -u nullglob

    buf=""
    for meta in "${metas[@]}"; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      res=$(inspect_worker "$id" 2>/dev/null || true)
      if [ -n "$res" ]; then
        buf="${buf:+${buf}$'\n'}$res"
      fi
    done
    printf '%s\n' "$buf" | format_grouped_results "$JSON_OUT"
    ;;
  fleet)
    run_fleet_inspection "$JSON_OUT"
    ;;
  default)
    # If no task ID was supplied, inspect current environment
    line=$(inspect_current_env) || exit 1
    format_single_result "$line" "$JSON_OUT"
    ;;
esac
