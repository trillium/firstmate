#!/usr/bin/env bash
# fm-install-fetch-lib.sh - shared download step of CI's pinned-tool installers.
#
# Sourced by fm-install-{shellcheck,actionlint,herdr,hc,treehouse}.sh. Each
# installer keeps owning its pin, its checksum, and its own post-download
# verification; this library only decides where the bytes come from.
#
#   fm_install_fetch <label> <url> <dest> <sha256> [max-bytes]
#
# When FM_INSTALL_CACHE_DIR is set, the cache holds one file per pinned
# SHA-256, named by that digest, so a version bump can never hit a stale entry.
# A cache entry is used only if it hashes to the pin; a mismatching entry is
# ignored and overwritten by the next verified download. A download is stored
# only after it hashes to the pin. Without the variable the cache is not touched.
#
# A cache miss downloads with up to FM_INSTALL_ATTEMPTS attempts (default 6),
# sleeping 5, 10, 20, 40, 80 seconds between them (about 2.5 minutes) so a
# short upstream 5xx window does not fail the job.

fm_install_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fm_install_fetch() {
  local label=$1 url=$2 dest=$3 sha256=$4 max_bytes=${5:-}
  local cached actual attempts=${FM_INSTALL_ATTEMPTS:-6} attempt=1
  local -a curl_args=(-fsSL)
  [ -z "$max_bytes" ] || curl_args+=(--max-filesize "$max_bytes")

  cached=
  if [ -n "${FM_INSTALL_CACHE_DIR:-}" ]; then
    cached="$FM_INSTALL_CACHE_DIR/$sha256"
    if [ -f "$cached" ]; then
      actual=$(fm_install_sha256 "$cached" || true)
      if [ "$actual" = "$sha256" ]; then
        cp "$cached" "$dest"
        printf '%s: using cached %s\n' "$label" "$sha256" >&2
        return 0
      fi
      printf '%s: ignoring cached entry that does not match its pin\n' "$label" >&2
    fi
  fi

  printf '%s: downloading from %s\n' "$label" "$url" >&2
  while ! curl "${curl_args[@]}" "$url" -o "$dest"; do
    if [ "$attempt" -ge "$attempts" ]; then
      printf '%s: download failed after %s attempts\n' "$label" "$attempts" >&2
      return 1
    fi
    printf '%s: download attempt %s failed; retrying\n' "$label" "$attempt" >&2
    sleep $((5 << (attempt - 1)))
    attempt=$((attempt + 1))
  done

  if [ -n "$cached" ]; then
    actual=$(fm_install_sha256 "$dest" || true)
    if [ "$actual" = "$sha256" ]; then
      mkdir -p "$FM_INSTALL_CACHE_DIR"
      cp "$dest" "$cached"
    fi
  fi
}
