# Laya stale-wake triage

This document owns the staged plan for cutting the main agent's cost of stale wakes that need no action, and the design contract each stage must honor.
Phases 0 and 1 are built; this file records what they do and points at the scripts that own their mechanics.
Phases 2 to 4 are design only; nothing in this repository runs a model against a wake yet.

The motivating record is `robots-q1nrd`: a parked or finished worker's pane keeps producing stale wakes, each of which turns the main agent over for a full supervision turn that ends in "nothing to do".
The staged plan is the captain's design in `idea-gb6f`: the main agent already decides each stale wake correctly, so a small model (Laya) shadows those decisions, learns from them, and may take over one narrow category of wake once its agreement is proven.

## Vocabulary

- A **stale wake** is a `stale: <window>` row the watcher queues when a crew pane stops changing while its crew is not provably working (`bin/fm-watch.sh` header).
- A **verdict** is the watcher's decision on one stale sighting: `surface` queues a wake, `absorb` does not.
- A **repeat** is a new pane hash under a status log that has not changed since the watcher last surfaced it.
- The **status-log signature** is `fm_wake_signal_sig` over the task's status file, which changes on any append, truncation, or replacement (`bin/fm-wake-lib.sh`).
- The **surfaced marker** is the per-task heartbeat presentation marker `mark_surfaced` commits after a status log is presented to the main agent (`bin/fm-push-transition-lib.sh`, `bin/fm-classify-lib.sh`).
- The **tier-1 never-absorb list** names the wake classes no automatic stage may drop; it is defined under Phase 4 and is authoritative over every later stage.

## Phase 0: deterministic repeat bound (built)

`terminal_repeat_stale_bound` in `bin/fm-watch.sh` bounds a terminal stale alarm whose captain-relevant status was already presented whole and is unchanged since.
It runs only in the terminal stale branch, after the provably-working override and after the open captain-call bound, and only when no captain call already bounds the sighting.
It is a delay, never a silence: the first sight of any status-log state alarms exactly as before, repeat sightings inside `FM_PAUSE_RESURFACE_SECS` are absorbed, and the next new pane hash after that window alarms once more.

The proof a repeat needs has two parts, both required:

1. The surfaced marker for the task covers the whole status log, which only a completed presentation writes.
2. The window's re-surface marker holds the `terminal-surfaced:<status-log signature>` declaration that only a stale alarm for that exact status-log state records.

A status presented by the signal path alone, with no stale alarm yet for that state, fails the second test and alarms on its first stale sighting.
Any status append changes the signature, so a new decision, a resolution, or a fresh failure starts its own window and alarms on first sight.
A marker short of the log's end, or one from an earlier incarnation of the log, fails the first test and alarms.
The bound applies to every captain-relevant terminal line the stale path already recognizes, which is `done`, `needs-decision`, `blocked`, and `failed`; the Firstmate spec's "done/decision" names the two common cases and the implementation does not carve a blocker or failure out of the same already-presented-and-unchanged rule, because the proof is identical.
Absorbed repeats are written to the triage debug log as `absorbed stale (repeat of an already-surfaced unchanged terminal status)`.

Phase 0 is not configurable; it is the standing behavior of the stale path.
The captain-call bound keeps precedence, because its declaration carries the call's lifecycle identity and must keep alarming a re-held task.

Verification: `tests/fm-watch-triage.test.sh`, `test_surfaced_terminal_status_repeat_absorbed_then_resurfaced`, exercises the first sight, the absorbed churn, the elapsed-window re-alarm, and the alarm after an append, for a delivery, a blocker, and an open decision.
`test_stale_churn_without_a_captain_call_still_alarms` keeps the non-terminal worker-line case alarming on every new hash.

## Phase 1: decision log and labels (built)

`bin/fm-wake-decision-lib.sh` is the single owner of the decision log.
Its header owns the file layout, the row fields, the label semantics, and the knobs.
The log is on by default and is log-only: no writer in it can change a verdict, block an acknowledgement, or exit its caller.

Every stale verdict the watcher reaches writes one `decision` row naming the rule that decided it:

| Rule | Branch |
| --- | --- |
| `provably-working` | terminal stale absorbed because the crew is provably working |
| `captain-call-bound` | terminal stale absorbed under an open captain call |
| `terminal-repeat` | terminal stale absorbed by Phase 0 |
| `terminal-surface` | terminal stale surfaced |
| `nonterminal-declared-wait` | non-terminal stale under a declared `paused:` wait |
| `nonterminal-captain-held` | non-terminal stale under a declared captain-held transfer |
| `nonterminal-captain-call-bound` | non-terminal stale absorbed under an open captain call |
| `nonterminal-captain-call-first` | non-terminal stale surfaced as the first sight of an open captain call |
| `nonterminal-surface` | non-terminal stale with no wait or call |

The features on each row are the cheap facts the watcher already had in hand: the last status verb and line, the status log's age and size, whether the surfaced marker covers it, how many stale surfaces this exact status-log state already had, whether a keyed decision is open, the captain-call state, the away posture, pane busyness, the wedge escalation count, and the re-surface marker's age.
A surfaced row also carries the queued wake's sequence and is held pending its label.

The label is the main agent's handling, read as a side effect rather than an intent.
When `bin/fm-wake-drain.sh` acknowledges a wake it consumed, the library compares the task's fingerprint at acknowledgement with the one captured at surfacing and writes one `label` row: `acted` when the status log, steering inbox, metadata, or captain call changed, `noop` when none did, and `gone` when the task's records no longer exist.
The limits are deliberate: a main agent that read the wake, inspected the pane, and decided nothing was needed is `noop`, while one that steered the worker is `acted`, so the label answers "did handling change anything durable", not "was the wake worth a turn".
A wake answered by a captain message that changed nothing on the task is also `noop`.
Phase 3 treats `noop` as the only absorbable class and must keep that reading in mind when it scores.

Verification: `tests/fm-wake-decision-log.test.sh` drives the library's public functions and the real drain.

## Phase 2: shadow scoring (design)

Phase 2 adds a scorer that reads the decision log and writes its own prediction beside each row, and nothing else.
It never queues, drops, delays, or rewrites a wake, and the watcher never waits on it.

- The model is `laya:en` served by ollaya on `lnx-server`; the scorer calls it over the network from a separate process, never from the watcher's poll loop.
- The scorer tails `.wake-decisions.jsonl`, scores each `surface` row as `absorb` or `act`, and appends a `shadow` row carrying the row's sequence, the predicted class, the raw top probability, the margin to the second class, the model name and version, and the scorer's own latency.
- A scorer that cannot reach the model, times out, or crashes writes nothing and changes nothing; the next run resumes from the last sequence it scored.
- The scorer is a separately started, tracked session like `bin/fm-attended-start.sh`, so a stopped scorer is visible rather than silently absent.
- The prompt shows the model only the features the decision row carries, never the pane text, so a scored row is reproducible from the log alone.

The output of this phase is agreement data: each `shadow` row joins to the `label` row for the same sequence.
Shadow scoring runs for at least as long as it takes to collect the held-out split Phase 3 needs, and keeps running after graduation to feed the drift check.

## Phase 3: calibrated acceptor and absorb-precision gate (design)

Laya's raw softmax is known to be overconfident, and `brain-mavhj` found no raw threshold that was reliable on the broader routing task, so the raw probability is never the acceptor.
A separate acceptor maps the row's top probability and margin to accept or defer, and only an accepted `absorb` may ever count toward graduation.

The gate follows the TRACER parity-gate shape (alphaxiv.org/abs/2604.14531):

1. Split labelled rows by time into a training window and a held-out window; the held-out rows are never used to fit the acceptor or pick a threshold.
2. Score absorb precision on the held-out window, not overall accuracy: a false absorb (predicted `absorb`, labelled `acted`) is the costly error, while a false surface only costs the turn the system pays today.
3. Choose the lowest acceptor threshold whose held-out absorb precision meets the target, with ninety-nine percent as the starting target, and reject any threshold whose coverage (the share of held-out `surface` rows it would absorb) falls under a minimum floor, so a gate that passes by absorbing almost nothing does not graduate.
4. Record the gate run as a dated report under `data/` with the split boundaries, counts, precision, coverage, and the chosen threshold, so a later run can be compared against it.

The gate is re-run as the labelled set grows, and a threshold is never carried across a model or prompt change without a fresh held-out pass.

## Phase 4: graduation (design)

Graduation lets the scorer absorb a wake instead of only predicting, inside one narrow category, under standing guards that no configuration relaxes:

- Laya may absorb only within the stale-repeat category: a `surface` row whose features show an already-presented, unchanged terminal status with at least one prior surface, which is the population Phase 0 already bounds and Phase 4 may bound more tightly.
- The tier-1 never-absorb list stays authoritative and is checked before the model is consulted: the first sight of any status-log state, any `needs-decision` whose keyed decision is still open and has not been presented, any `blocked` or `failed` first sight, any wake while the away posture is active, any wake whose task has an unread steering message, any secondmate wake, any wedge escalation, and any wake whose features are missing or unparseable.
- A five percent audit sample of accepted absorbs still surfaces, marked as an audit, so the main agent's label on them keeps measuring precision in production.
- The gate re-runs on the growing labelled set, and an absorb precision that falls under the target on any run demotes the scorer to shadow automatically; re-graduation needs a fresh passing gate.
- Agreement with the agent is not correctness: every absorbed wake is tracked to its outcome, and a task whose next surfaced wake or captain message shows the absorbed wake mattered counts against the scorer the same as a false absorb.
- Every absorb the scorer takes writes a decision row with rule `laya-absorb`, so the log stays complete.

Enabling graduation is a captain decision recorded in the backlog, never a default, and it ships behind a configuration file that is absent until the captain creates it.

## Lineage note

The original plan named `bin/fm-attended-triage-lib.sh` as the Phase 0 home.
That library exists only on the archived lineage, not on `main`, so Phase 0 is built where `main` decides stale wakes: the watcher's terminal stale branch.
A home still running the archived lineage does not receive Phase 0 until it moves to `main`.
