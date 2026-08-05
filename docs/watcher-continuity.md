# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
While supervision is still needed and away mode remains inactive, an actionable close or typed failure wakes the idle session through exit 2.

The hook is the adapter the arm layer defers to when it prints `watcher: idle`, so it verifies that deferral rather than assuming it.
After an arm closes quietly - no actionable reason and no failure - the hook rechecks supervision need and then `fm_watcher_healthy`, and re-arms in place whenever no live watcher answers.
That loop is bounded by `FM_AUTOARM_MAX_REARMS` (default 20) and runs in the hook's own foreground process tree; the hook never spawns a detached successor, because a watcher with no owner to notify converts a loud supervision-down alarm into a silent one.
Exhausting the budget, or finding a wake already queued, escalates to an exit-2 rewake carrying an explicit continuity-lost banner instead of exiting silently.
This closes the harness-kill path: `bin/fm-watch-arm.sh` kills its watcher child on TERM and records `reason=arm-interrupted`, which previously ended supervision with a still-fresh beacon and nothing scheduled to notice.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the unchanged bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
No PreToolUse hook denies fleet commands based on watcher status.
The model no longer re-arms after ordinary wakes.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success off a genuinely down fleet.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon and attaches to a verified healthy successor when one exists.
With no verified successor it classifies the cycle end by the liveness beacon.
A beacon still fresh within grace proves a watcher was alive and healthy right up to the moment the cycle ended - a clean one-shot actionable exit (whose reason another owner already propagated and whose wake `fm-watch.sh` already enqueued durably before exiting) or a benign empty poll - so the arm prints a non-FAILED `watcher: idle` line and exits zero, leaving the re-arm to the adapter layer rather than raising a false alarm.
Only a stale, expired, or absent beacon - the signature of a wedged, crashed, or absent watcher - emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and applies the same beacon-gated terminal classification when that chain ends without one.
This keeps a benign one-shot exit from spamming a false supervision-down alarm while a stale beacon still fails loudly; the synchronous turn-end guard remains the immediate backstop for a genuinely dead fleet because it re-blocks on the same stale-beacon predicate.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

`bin/fm-watch-cycle-lib.sh` is the only reader of that ledger.
It exists because the ledger already classified supervision death correctly while nothing acted on or reported the classification.
`bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` now print its one-line description inside their supervision-down banners, so every harness - not only Claude - sees whether the last cycle was terminated or ended.
The reader deliberately never cites `successor=`: only an adapter passing `FM_WATCH_PREDECESSOR_ARM_PID` (the OpenCode plugin and the Pi extension) back-fills that field, so it reads `none` on a Claude primary even when a healthy successor took over.
It also never classifies from `beacon_age=`, which stays fresh for a watcher killed while healthy; only the reason field separates a kill from a clean end.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, exit-2 translation, and the quiet-close continuity check: silent exit behind a verified live watcher, re-arm when none answers, and the continuity-lost rewake when the bounded budget is exhausted or a wake is already queued.
`tests/fm-watch-cycle-lib.test.sh` covers the ledger reader's parsing of `=`-bearing values, cleared state after a failed read, the exact `arm-interrupted` predicate, and the refusal to quote the unreliable `successor` field.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
