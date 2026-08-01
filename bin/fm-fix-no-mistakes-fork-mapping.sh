#!/usr/bin/env bash
# Fix no-mistakes daemon fork/remote URL mapping for forked repositories.
#
# When a repo is a fork (e.g., trillium/firstmate is a fork of kunchenguid/firstmate),
# the no-mistakes daemon may incorrectly use the parent repo URL for PR creation instead of
# the fork URL. This script detects and fixes that by setting fork_url correctly in the
# daemon's state database.
#
# Usage:
#   fm-fix-no-mistakes-fork-mapping.sh [<repo-path>]
#   fm-fix-no-mistakes-fork-mapping.sh  # uses current repo
#
# This is needed when:
# - no-mistakes is creating PRs against the wrong upstream (the parent repo)
# - The repo is a fork but the user wants PRs against the fork, not the parent
# - fork_url in ~/.no-mistakes/state.sqlite is empty or incorrect

set -eu

REPO_PATH="${1:-.}"
DB_PATH="${HOME}/.no-mistakes/state.sqlite"

# Verify database exists
if [ ! -f "$DB_PATH" ]; then
  echo "error: no-mistakes database not found at $DB_PATH" >&2
  exit 1
fi

# Get the repo's configured origin
cd "$REPO_PATH"
ORIGIN_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
if [ -z "$ORIGIN_URL" ]; then
  echo "error: no origin remote configured" >&2
  exit 1
fi

# Normalize URL to https format (remove .git suffix for comparison)
ORIGIN_NORMALIZED="${ORIGIN_URL%.git}"
ORIGIN_NORMALIZED="${ORIGIN_NORMALIZED#git@github.com:}"
ORIGIN_NORMALIZED="${ORIGIN_NORMALIZED#https://github.com/}"

echo "Detected origin: $ORIGIN_URL"
echo "Normalized: github.com/$ORIGIN_NORMALIZED"

# Query existing fork_url
EXISTING_FORK=$(sqlite3 "$DB_PATH" \
  "SELECT fork_url FROM repos WHERE upstream_url LIKE '%$ORIGIN_NORMALIZED%' OR upstream_url = '$ORIGIN_URL' LIMIT 1;" 2>/dev/null || echo "")

echo "Existing fork_url: ${EXISTING_FORK:-empty}"

# Update fork_url to match origin
sqlite3 "$DB_PATH" \
  "UPDATE repos SET fork_url = '$ORIGIN_URL' WHERE upstream_url = '$ORIGIN_URL' OR upstream_url LIKE '%$ORIGIN_NORMALIZED%';" 2>/dev/null

UPDATED=$(sqlite3 "$DB_PATH" \
  "SELECT fork_url FROM repos WHERE upstream_url LIKE '%$ORIGIN_NORMALIZED%' OR upstream_url = '$ORIGIN_URL' LIMIT 1;" 2>/dev/null || echo "")

if [ "$UPDATED" = "$ORIGIN_URL" ]; then
  echo "✓ Fixed: fork_url now correctly set to $ORIGIN_URL"
  echo "✓ Next no-mistakes run will use the correct fork for PR creation"
  exit 0
else
  echo "error: failed to update fork_url in database" >&2
  exit 1
fi
