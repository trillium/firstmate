#!/usr/bin/env bash
# fm-pool-lease-tick.sh - one renew/release pass over this home's quota pool
# leases (bin/fm-pool-lease-lib.sh owns the contract and what each pass does).
#
# Usage: fm-pool-lease-tick.sh
#
# The watcher (bin/fm-watch.sh) starts this detached when state/ holds a
# state/<id>.pool-lease record, so lease renewal rides the existing watcher
# cycle with no daemon of its own and a slow authority never stalls the beacon.
# A lock keeps overlapping passes from racing, and the script exits 0 always:
# a failed pass is retried by the next cycle, and TTL expiry at the authority
# covers a holder that is never renewed.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-pool-lease-lib.sh
. "$SCRIPT_DIR/fm-pool-lease-lib.sh"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
compgen -G "$STATE/*.pool-lease" >/dev/null || exit 0
LOCK="$STATE/.pool-lease-tick.lock"
fm_lock_try_acquire "$LOCK" || exit 0
trap 'fm_lock_release "$LOCK" || true' EXIT
fm_pool_lease_tick "$STATE"
exit 0
