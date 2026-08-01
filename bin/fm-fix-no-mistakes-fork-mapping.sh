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

# Escape single quotes for SQL (fix for SQL injection vulnerability)
ORIGIN_URL_ESCAPED="${ORIGIN_URL//\'/\'\'}"

echo "Detected origin: $ORIGIN_URL"

# Query existing fork_url using exact URL matching to prevent unintended matches
EXISTING_FORK=$(sqlite3 "$DB_PATH" \
  "SELECT fork_url FROM repos WHERE upstream_url = '$ORIGIN_URL_ESCAPED' LIMIT 1;") || {
  echo "error: database query failed" >&2
  exit 1
}

if [ -z "$EXISTING_FORK" ]; then
  echo "error: repository not found in no-mistakes database" >&2
  echo "hint: run 'no-mistakes init' in the target repository first" >&2
  exit 1
fi

echo "Existing fork_url: ${EXISTING_FORK:-empty}"

# Update fork_url to match origin (use exact matching and escaped value)
sqlite3 "$DB_PATH" \
  "UPDATE repos SET fork_url = '$ORIGIN_URL_ESCAPED' WHERE upstream_url = '$ORIGIN_URL_ESCAPED';" || {
  echo "error: database update failed" >&2
  exit 1
}

# Verify the update succeeded
UPDATED=$(sqlite3 "$DB_PATH" \
  "SELECT fork_url FROM repos WHERE upstream_url = '$ORIGIN_URL_ESCAPED' LIMIT 1;") || {
  echo "error: verification query failed" >&2
  exit 1
}

if [ "$UPDATED" = "$ORIGIN_URL" ]; then
  echo "✓ Fixed: fork_url now correctly set to $ORIGIN_URL"
  echo "✓ Next no-mistakes run will use the correct fork for PR creation"
  exit 0
elif [ -z "$UPDATED" ]; then
  echo "error: repository not found in database (upstream_url = $ORIGIN_URL)" >&2
  exit 1
else
  echo "error: fork_url not updated correctly in database" >&2
  exit 1
fi
