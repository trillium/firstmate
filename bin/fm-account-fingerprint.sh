#!/usr/bin/env bash
# fm-account-fingerprint.sh - inspect and report credential fingerprint,
# auth method, and account usage bucket for a worker task or the current
# environment, with live-worker grouping.
#
# Usage:
#   fm-account-fingerprint.sh [<task-id>] [--json]
#   fm-account-fingerprint.sh --current [--json]
#   fm-account-fingerprint.sh --group [--json]
#   fm-account-fingerprint.sh --list [--json]
#   fm-account-fingerprint.sh --help
#
# Output fields:
#   target:       task id or "current"
#   harness:      worker harness (claude, pi, codex, grok, etc.)
#   auth_method:  setup token | subscription login | API key | other | unknown
#   account:      account or usage-bucket label from non-secret local records
#   fingerprint:  short non-reversible 12-hex-character digest of the credential,
#                 or "unknown" if the credential cannot be read
#
# Fingerprint stability and domain-separation label:
# The credential fingerprint is computed as:
#   SHA-256("fm-credential-fingerprint-v1:" + <credential>)[0..11]
#
# Tradeoff note:
# A fixed, non-secret domain-separation label is deliberately chosen over a
# per-machine salt so that fingerprints are stable across runs on one machine
# and comparable across machines and fleet environments (e.g. comparing workers
# across hosts or secondmate homes to detect whether they share a credential or
# usage bucket).
# The tradeoff is that because the domain label is fixed and public, an attacker
# who already possesses candidate credentials can compute their fingerprints to
# verify whether any match a known fingerprint (offline dictionary/preimage
# verification). However, high-entropy secrets (long-lived setup tokens, OAuth
# refresh tokens, and 256-bit API keys) cannot be reversed from the 12-hex-character
# truncated digest.
#
# Secret containment:
# Never prints, logs, or writes the secret or any prefix of it.
# Credentials are read directly in-process or via owner-only (0600) file loaders,
# piped to the hash function over stdin, and immediately cleared from memory.
set +x
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DOMAIN_LABEL="fm-credential-fingerprint-v1:"

# shellcheck source=bin/fm-worker-account-lib.sh
if [ -f "$SCRIPT_DIR/fm-worker-account-lib.sh" ]; then
  . "$SCRIPT_DIR/fm-worker-account-lib.sh"
fi
# shellcheck source=bin/fm-backend.sh
if [ -f "$SCRIPT_DIR/fm-backend.sh" ]; then
  . "$SCRIPT_DIR/fm-backend.sh"
fi

usage() {
  cat <<'EOF'
Usage:
  fm-account-fingerprint.sh [<task-id>] [--json]
  fm-account-fingerprint.sh --current [--json]
  fm-account-fingerprint.sh --group [--json]
  fm-account-fingerprint.sh --list [--json]
  fm-account-fingerprint.sh -h | --help

Inspect and report credential fingerprint, auth method, and account usage
bucket for a worker task or the current environment, with live-worker grouping.

Options:
  <task-id>     Inspect the recorded worker task under state/<task-id>.meta
  --current     Inspect the current process environment and active pins
  --group       List all live workers and group them by credential fingerprint
  --list        Alias for --group
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
# Returns "auth_method<TAB>account<TAB>fingerprint"
read_pi_auth() {
  local auth_file=$1 provider=${2:-}
  if [ ! -f "$auth_file" ] || [ ! -r "$auth_file" ]; then
    printf 'API key\t%s\tunknown\n' "${provider:-unknown}"
    return 0
  fi
  if [ -z "$provider" ]; then
    provider=$(jq -r 'keys | if length == 1 then .[0] else empty end' "$auth_file" 2>/dev/null || true)
  fi
  if [ -z "$provider" ]; then
    printf 'API key\tpi\tunknown\n'
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
  if [ -n "$pkey" ]; then
    fp=$(fingerprint_credential "$pkey")
    unset pkey
  fi
  printf '%s\t%s\t%s\n' "$auth" "$acct" "$fp"
}

# inspect_worker <task-id>
# Emits "target<TAB>harness<TAB>auth_method<TAB>account<TAB>fingerprint"
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
            unset tok
          else
            out_fp="unknown"
          fi
        else
          out_account=$(token_account_label "$token_spec")
          out_fp="unknown"
        fi
      elif [ "$account" = ordinary ] || [ "$account_request" = ordinary ] || [ -z "$account" ]; then
        out_auth="subscription login"
        out_account="ordinary"
        local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
        if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
          local tok
          tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
          [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            unset tok
          else
            out_fp="unknown"
          fi
        else
          out_fp="unknown"
        fi
      else
        # Config directory
        out_auth="subscription login"
        out_account="$account"
        local cred_file="$account/.credentials.json"
        if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
          local tok
          tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
          [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            unset tok
          else
            out_fp="unknown"
          fi
        else
          out_fp="unknown"
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
      out_auth=${pi_auth%%$'\t'*}
      local rest=${pi_auth#*$'\t'}
      out_account=${rest%%$'\t'*}
      out_fp=${rest#*$'\t'}
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
        out_account="codex"
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          unset tok
        else
          out_fp="unknown"
        fi
      elif [ -n "${OPENAI_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="OPENAI_API_KEY"
        out_fp=$(fingerprint_credential "$OPENAI_API_KEY")
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
      fi
      ;;

    grok)
      local grok_auth="$HOME/.grok/auth.json"
      if [ -f "$grok_auth" ] && [ -r "$grok_auth" ]; then
        out_auth="subscription login"
        out_account="grok"
        local tok
        tok=$(jq -r 'to_entries[0].value.access_token // to_entries[0].value.token // empty' "$grok_auth" 2>/dev/null || true)
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          unset tok
        else
          out_fp="unknown"
        fi
      elif [ -n "${XAI_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="XAI_API_KEY"
        out_fp=$(fingerprint_credential "$XAI_API_KEY")
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
      fi
      ;;

    gemini|agy)
      local gemini_auth="$HOME/.gemini/gemini-credentials.json"
      if [ -f "$gemini_auth" ] && [ -r "$gemini_auth" ]; then
        out_auth="subscription login"
        out_account=$(jq -r '.email // .account // "gemini-credentials"' "$gemini_auth" 2>/dev/null || true)
        local tok
        tok=$(jq -r '.access_token // .refresh_token // .token // empty' "$gemini_auth" 2>/dev/null || true)
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          unset tok
        else
          out_fp="unknown"
        fi
      elif [ -n "${GEMINI_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="GEMINI_API_KEY"
        out_fp=$(fingerprint_credential "$GEMINI_API_KEY")
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
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
          unset tok
        else
          out_fp="unknown"
        fi
      elif [ -n "${META_API_KEY:-}" ]; then
        out_auth="API key"
        out_account="META_API_KEY"
        out_fp=$(fingerprint_credential "$META_API_KEY")
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
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
          unset tok
        else
          out_fp="unknown"
        fi
      else
        out_auth="unknown"
        out_account="unknown"
        out_fp="unknown"
      fi
      ;;

    *)
      out_auth="unknown"
      out_account="unknown"
      out_fp="unknown"
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$out_harness" "$out_auth" "$out_account" "$out_fp"
}

# inspect_current_env
# Emits "target<TAB>harness<TAB>auth_method<TAB>account<TAB>fingerprint" for current env.
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

  # 1. Environment variables check
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    out_harness="claude"
    out_auth="setup token"
    out_account="CLAUDE_CODE_OAUTH_TOKEN"
    out_fp=$(fingerprint_credential "$CLAUDE_CODE_OAUTH_TOKEN")
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    out_harness="claude"
    out_auth="API key"
    out_account="ANTHROPIC_API_KEY"
    out_fp=$(fingerprint_credential "$ANTHROPIC_API_KEY")
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="codex"
    out_auth="API key"
    out_account="OPENAI_API_KEY"
    out_fp=$(fingerprint_credential "$OPENAI_API_KEY")
  elif [ -n "${GEMINI_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="gemini"
    out_auth="API key"
    out_account="GEMINI_API_KEY"
    out_fp=$(fingerprint_credential "$GEMINI_API_KEY")
  elif [ -n "${META_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="muse"
    out_auth="API key"
    out_account="META_API_KEY"
    out_fp=$(fingerprint_credential "$META_API_KEY")
  elif [ -n "${XAI_API_KEY:-}" ]; then
    [ -n "$detected_harness" ] && out_harness="$detected_harness" || out_harness="grok"
    out_auth="API key"
    out_account="XAI_API_KEY"
    out_fp=$(fingerprint_credential "$XAI_API_KEY")
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
          unset tok
        else
          out_fp="unknown"
        fi
      else
        out_account=$(token_account_label "$pin_val")
        out_fp="unknown"
      fi
    elif [ "$pin_val" = ordinary ]; then
      out_auth="subscription login"
      out_account="ordinary"
      local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
      if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
        local tok
        tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
        [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          unset tok
        fi
      fi
    elif [ -n "$pin_val" ]; then
      out_auth="subscription login"
      out_account="$pin_val"
      local cred_file="$pin_val/.credentials.json"
      if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
        local tok
        tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
        [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
        if [ -n "$tok" ]; then
          out_fp=$(fingerprint_credential "$tok")
          unset tok
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
    out_auth=${pi_auth%%$'\t'*}
    local rest=${pi_auth#*$'\t'}
    out_account=${rest%%$'\t'*}
    out_fp=${rest#*$'\t'}
  # 4. Fallback to detected harness default files
  else
    case "$out_harness" in
      claude)
        out_auth="subscription login"
        out_account="ordinary"
        local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
        if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
          local tok
          tok=$(jq -r '.sessionKey // .accessToken // .token // .idToken // empty' "$cred_file" 2>/dev/null || true)
          [ -n "$tok" ] || tok=$(cat "$cred_file" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            unset tok
          fi
        fi
        ;;
      pi|pi-signed)
        local pi_auth
        pi_auth=$(read_pi_auth "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json")
        out_auth=${pi_auth%%$'\t'*}
        local rest=${pi_auth#*$'\t'}
        out_account=${rest%%$'\t'*}
        out_fp=${rest#*$'\t'}
        ;;
      codex)
        local codex_auth="$HOME/.codex/auth.json"
        if [ -f "$codex_auth" ] && [ -r "$codex_auth" ]; then
          out_auth="subscription login"
          out_account="codex"
          local tok
          tok=$(jq -r '.tokens.access_token // .tokens.refresh_token // .OPENAI_API_KEY // empty' "$codex_auth" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            unset tok
          fi
        fi
        ;;
      grok)
        local grok_auth="$HOME/.grok/auth.json"
        if [ -f "$grok_auth" ] && [ -r "$grok_auth" ]; then
          out_auth="subscription login"
          out_account="grok"
          local tok
          tok=$(jq -r 'to_entries[0].value.access_token // to_entries[0].value.token // empty' "$grok_auth" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            unset tok
          fi
        fi
        ;;
      gemini|agy)
        local gemini_auth="$HOME/.gemini/gemini-credentials.json"
        if [ -f "$gemini_auth" ] && [ -r "$gemini_auth" ]; then
          out_auth="subscription login"
          out_account=$(jq -r '.email // .account // "gemini-credentials"' "$gemini_auth" 2>/dev/null || true)
          local tok
          tok=$(jq -r '.access_token // .refresh_token // .token // empty' "$gemini_auth" 2>/dev/null || true)
          if [ -n "$tok" ]; then
            out_fp=$(fingerprint_credential "$tok")
            unset tok
          fi
        fi
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$out_target" "$out_harness" "$out_auth" "$out_account" "$out_fp"
}

# format_single_result <tab-separated-line> <json-flag>
format_single_result() {
  local line=$1 json_flag=${2:-0}
  local target harness auth account fp rest
  target=${line%%$'\t'*}
  rest=${line#*$'\t'}
  harness=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  auth=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  account=${rest%%$'\t'*}
  fp=${rest#*$'\t'}

  if [ "$json_flag" -eq 1 ]; then
    jq -n \
      --arg target "$target" \
      --arg harness "$harness" \
      --arg auth_method "$auth" \
      --arg account "$account" \
      --arg fingerprint "$fp" \
      '{target: $target, harness: $harness, auth_method: $auth_method, account: $account, fingerprint: $fingerprint}'
  else
    printf 'target: %s\n' "$target"
    printf 'harness: %s\n' "$harness"
    printf 'auth_method: %s\n' "$auth"
    printf 'account: %s\n' "$account"
    printf 'fingerprint: %s\n' "$fp"
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
      | map({target: .[0], harness: .[1], auth_method: .[2], account: .[3], fingerprint: .[4]})
      | . as $workers
      | group_by(if .fingerprint == "unknown" then (.fingerprint + ":" + .harness + ":" + .auth_method + ":" + .account) else .fingerprint end)
      | map({
          fingerprint: .[0].fingerprint,
          harness: .[0].harness,
          auth_method: .[0].auth_method,
          account: .[0].account,
          workers: map(.target)
        }) as $groups
      | {workers: $workers, groups: $groups}
    '
  else
    # Group in shell: known fingerprints group together; unknown fingerprints group by harness+account
    local -a group_keys=()
    local -A group_fp=() group_harness=() group_auth=() group_account=() group_workers=()

    while IFS=$'\t' read -r target harness auth account fp || [ -n "$target" ]; do
      [ -n "$target" ] || continue
      local key
      if [ "$fp" = "unknown" ]; then
        key="unknown:$harness:$auth:$account"
      else
        key="$fp"
      fi
      if [ -z "${group_workers[$key]+x}" ]; then
        group_keys+=("$key")
        group_fp[$key]=$fp
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
      printf 'fingerprint: %s [harness: %s, auth: %s, account: %s]\n' \
        "${group_fp[$key]}" "${group_harness[$key]}" "${group_auth[$key]}" "${group_account[$key]}"
      for w in ${group_workers[$key]}; do
        printf '  - %s\n' "$w"
      done
    done
  fi
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
  default)
    # If no task ID was supplied, inspect current environment
    line=$(inspect_current_env) || exit 1
    format_single_result "$line" "$JSON_OUT"
    ;;
esac
