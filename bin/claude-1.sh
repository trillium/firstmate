#!/usr/bin/env bash
# claude-1.sh: launch claude on account 1. See claude-account.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/claude-account.sh" 1 "$@"
