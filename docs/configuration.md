# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Persona (persona.md / config/persona.md)

The captain-facing voice - address term, seasoning policy, house vocabulary, and the fixed routine acknowledgment phrase - lives entirely in [`persona.md`](../persona.md), not in `AGENTS.md`.
`AGENTS.md` carries only a pointer to it; `AGENTS.md` section 9's functional etiquette (talking in outcomes, the internal-to-plain-English translation table, escalation triggers, evidence-first reporting) is separate and is never affected by a persona swap.
Swap the voice by editing tracked `persona.md` directly, or by dropping a local, gitignored `config/persona.md` in this home; when present, the local file fully replaces the tracked default rather than merging with it, mirroring `config/crew-harness`'s override pattern.
`bin/fm-session-start.sh` resolves and prints the active persona's full contents unconditionally, every session, labeled by source (tracked default vs local override), so the voice is always in force with no per-reply trigger to load it.
An absent persona (both tracked `persona.md` and `config/persona.md` missing) is reported distinctly from an `ABSENT` context-digest file: unlike `data/captain.md` or `data/learnings.md`, there is no built-in-defaults fallback, so it signals the tracked file needs repair.
A present but unreadable active persona file (for example, a permissions problem) is reported as its own distinct `UNREADABLE` repair failure rather than silently falling back to the other candidate or going unreported.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, and scout reports.
`state/` holds runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, inactive terminal-outcome receipts under `state/terminal-outcomes/`, away-mode state, generated Relay artifacts, private secondmate config-reread generations with their retry and quarantine state, per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`), and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Firstmate reads but changes only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
Untracked files and directories whose names begin with `scratchpad` are also gitignored, so temporary scratch does not make porcelain-based secondmate sync guards treat a home as dirty.

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and Relay helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, away-mode, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`bin/fm-startup-network.sh`'s header owns the deferred network stage that keeps every external-network call off that digest's blocking path, including its state files and the safety argument for running them later.
`docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Pi Calm preference (config/calm)

The Pi Calm extension stores the captain's home-local presentation choice in gitignored `config/calm` under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
`max` is the legacy value written by a removed third presentation level whose behavior is now ordinary Calm, and it is still read as `on`, so a home upgraded from it keeps Calm on rather than dropping to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Pi supervision branch

On a Pi primary, a persistent in-process supervision branch handles eligible task-local wake rows and selected heartbeat reviews while keeping main-only rows on the captain-facing path; [docs/pi-supervision-branch.md](pi-supervision-branch.md) owns row eligibility, mixed-queue dispatch, heartbeat routing, and the pre-drain recheck.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch is eligible for every task with no captain grant file required.
A genuinely no-op heartbeat is absorbed in bash and never reaches Pi, and every watcher-failure alarm stays on the captain-facing main path.
Away mode still declines every wake offer, and a broken branch still falls back to today's wake-to-main path.
The branch's role stays bounded exactly as the captain-approved architecture set it: it cannot merge a PR, land local work, or freshly spawn, and every existing captain gate remains unchanged.
Homes on any other primary harness never load this feature and are entirely unaffected.
`AGENTS.md`'s `state/` inventory routes the branch's runtime files to their format and lifecycle owners.
A captain-facing (verdict `captain`) branch outcome opens exactly one follow-up turn on main - that turn is the captain-visible result, and Pi never separately prints or renders the merge note itself.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note, while every other routine outcome still appends a rendered, sailboat-prefixed note.

## Pi supervision branch model and effort (config/supervision-branch-model, config/supervision-branch-effort)

Supervision is an easier job than the captain's own conversation, so the branch can run on a cheaper model than main.
It is also an easier job than the captain's own conversation needs reasoning for, so the branch can run at a shallower effort than main as well.
The Pi `/supervision-model` command settles both in one flow: it opens a selector over the models that Pi reports with configured credentials and that this home's stored credentials let the isolated supervision branch resolve, plus a first "Follow main" entry, and then a second picker for the branch's reasoning effort.
In Pi's terminal TUI, the model step uses Pi's bounded scrolling list with its input and fuzzy filtering primitives, the same list primitive Pi's `/model` picker scrolls: typing filters the entries, "Follow main" stays the first entry whenever it still matches, and a long catalog scrolls inside the dialog instead of running off the terminal.
The non-TUI RPC, JSON, and print modes have no custom-component surface and keep Pi's generic selector without search, where terminal overflow does not apply.
The effort list is a handful of levels and stays on Pi's plain selector dialog.
Both picks change the supervision branch alone and never the captain's own conversation model or effort.
It persists the model pick in gitignored `config/supervision-branch-model` and the effort pick in gitignored `config/supervision-branch-effort`, both under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
Firstmate keeps no model catalog of its own; the list is the intersection of what Pi reports when the picker opens and what a fresh isolated branch runtime can run.
A provider that exists only because an extension registered it inside the captain's session is not offered, while stored OAuth and API-key credentials retain their native credential type because Firstmate never copies, converts, installs, or overwrites credentials for the branch runtime.
The file holds one `<provider>/<model-id>` line followed by one newline, split at the first `/` so a provider-qualified model id such as `openrouter/anthropic/claude-sonnet-4-5` survives intact.
An absent, unreadable, or unparseable file means no pin, and the branch then follows main's own current model, applied explicitly and live whenever main changes models mid-session.
A valid pin wins over main and remains unaffected by main's model changes.
Picking "Follow main" removes the file, and the command writes a pin at mode `0600` and replaces it atomically so a failed write leaves the current choice unchanged rather than claiming persistence.
The file's current state decides the branch model on every branch build - the first wake of a cold start and the reopen after `/new`, `/resume`, `/fork`, or reload - and it overrides Pi's restore of whatever model a reopened branch session recorded, so the choice survives all of them.
That override is what keeps "Follow main" honest: a branch conversation that ran under an earlier pin still records that model, so clearing the file explicitly applies main's model rather than letting the reopened session restore the old one.
Only when main's own model is unknown, or this home's stored credentials cannot run it in the isolated branch runtime, does an unpinned build fall back to passing no override at all, which is the behavior from before this file existed; the wake is never lost over model choice, and the command says plainly when main's model could not be applied instead of reporting a change that did not take effect.
A pin naming a model Pi cannot hand back, because the model is unknown or has no configured credentials, is never silently downgraded onto main's model: the branch refuses to build and the wake falls back to the captain-facing main path naming the unusable pin, exactly as any other unreachable branch does.
Picking also releases the live branch so the next wake reopens the same persistent branch conversation under the new model without waiting for a session replacement.

The effort file holds one Pi thinking level followed by one newline, and the two pins are independent: a captain may pin a model, an effort, both, or neither.
The effort step runs after the model step because the effective branch model decides which levels exist: its menu is Pi's own supported-level list, so a model that maps no extended levels simply does not offer them and a non-reasoning model offers only `off`.
The picker keeps no effort catalog of its own; when main's model cannot be resolved, it first resolves the model recorded by the persistent branch conversation and uses Pi's supported levels for that effective model.
If neither model can be resolved, the picker invents no levels and the command says that the branch's effective effort cannot be determined.
An absent, unreadable, or unrecognized file means no effort pin, and the branch then follows main's own current effort, applied explicitly and live whenever main changes effort mid-session.
A valid pin wins over main and remains unaffected by main's effort changes.
Picking "Follow main" removes the file, and the command writes an effort pin at mode `0600` and replaces it atomically, exactly as it writes a model pin.
The effort file's current state decides the branch effort on every branch build, on the same create-and-reopen contract as the model pin and for the same reason: a reopened branch conversation records the effort it last ran under, so only an explicit override keeps "Follow main" honest.
Only when main's own effort cannot be read either does an unpinned build fall back to passing no effort override at all, which is the behavior from before this file existed.
Pi owns the clamp, so a pinned level the branch's model cannot run becomes that model's nearest supported level rather than a refusal; the branch is never refused over effort, the captain's raw pick is kept so it applies again on a model that supports it, and the command reports the level the branch will really run at rather than the raw pin.
An effort token Pi would not recognize at all is treated as no pin rather than passed to that clamp, which would otherwise collapse a typo into the model's lowest level.

Cancelling the model picker cancels the whole command and changes neither choice.
Cancelling only the effort picker keeps the standing effort choice and still applies the model pick made in the same run, and the command's one closing message reports both choices as they will actually take effect.
Both choices are local to each Firstmate home and are not part of secondmate inherited configuration, the same as the Pi Calm preference; a secondmate home pins its own supervision model and effort with its own `/supervision-model`.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs bypass that routine-backend choice: `fm-backlog-handoff.sh` keeps only its own fleet-level validation, delegates the item move to `tasks-axi mv` (the single owner of the tasks-axi backlog format), and requires a verified receiver wake after a new move becomes durable.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Automated cross-home handoff into a beads-backed secondmate is deliberately deferred (beads-authority migration Stage 7), not merely unimplemented: a home's beads are scoped by the shared `fleet:firstmate` label, which is identical across every home, so no per-home owning key exists to re-own a moved bead without a cross-cutting change to the Stage 1/2 listing queries.
This does not restrict running the main home on beads: main-home-on-beads with secondmates on tasks-axi or manual is fully supported, and only the automated cross-home backlog transfer is unavailable when a beads home is the handoff destination; route such work directly instead.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `beads` to use the beads federated `task` store as the queue source instead of `data/backlog.md`.
Session-start's digest mirrors `data/backlog.md`'s `## In flight`/`## Queued` split with two beads-sourced sections, both scoped by the firstmate-fleet label below: **In flight** is `task list --label <label> --status in_progress,blocked`, and **Queued** is `task ready --label <label>` (bd's dependency-derived, blocker-aware readiness with no manual tagging, priority-ordered by `bd ready`'s default `--sort priority` so the highest-priority claimable work leads).
If either read fails, the whole listing falls back to the title-line rendering of `data/backlog.md` rather than printing a partial digest.
Beads requires the `task` CLI on `PATH` and access to the active beads store.
Bootstrap validates the beads backend and reports a `MISSING:` line if the CLI is absent or the store is unreachable and no fresh local mirror covers the gap, or a `DEGRADED:` line naming the mirror's timestamp when one does; see "Beads resilience layer" below.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in tasks-axi and manual modes; both produce the same `## In flight`, `## Queued`, and `## Done` sections in `data/backlog.md`.
The beads backend does not use `data/backlog.md`; all backlog state lives in the beads store and is queried dynamically at session start.
A home with an existing `data/backlog.md` queue migrates it once with [`bin/fm-backlog-import-beads.sh`](../bin/fm-backlog-import-beads.sh) (beads-authority migration Stage 6) before flipping the backend, so the live queue is not lost; that script's `--help` is the single owner of its mapping and flags.
The operator sequence is: (1) run `bin/fm-backlog-import-beads.sh` for a dry-run preview; (2) run `bin/fm-backlog-import-beads.sh --apply` to create one bead per `## In flight` (status `in_progress`) and `## Queued` (status `open`) item, carrying titles, full bodies, and priorities, mapping captain-held threads to beads-native human gates, and skipping `## Done`; then (3) set `config/backlog-backend` to `beads`.
The importer is idempotent and fails closed if the store is unreachable, so a re-run after a partial failure converges without duplicates; it never flips the backend for you.
Under the beads backend, firstmate's own dispatched-work beads carry a firstmate-fleet label, `fleet:firstmate` by default (overridable only for test fixtures via `FM_BEADS_FLEET_LABEL`), so a `task list --label <that label>` call scopes to firstmate's fleet instead of surfacing the shared federated store's full cross-project set; `bin/fm-decision-hold.sh`'s beads-native captain-hold anchor (see [`decision-hold-lifecycle.md`](decision-hold-lifecycle.md)) also creates a bead with that label, alongside `captain-hold`, `human`, and its `hold:<id>` identity labels.
`bin/fm-tasks-axi-lib.sh`'s `fm_beads_fleet_label` is the single owner of that label; read it from there rather than hardcoding it.
As of Stage 3 (beads-authority migration), `fm-spawn.sh` mints or resolves that labeled bead for every non-secondmate spawn via `fm_beads_fleet_label`'s sibling helper `fm_beads_resolve_or_create`, so bead-linking under this backend is automatic rather than requiring an explicit `--beads` flag; see AGENTS.md section 7.
The idempotency label those helpers use is home-scoped, `task:<home-scope>:<task_id>`, because the store is shared machine-wide while task slugs are minted per home: `bin/fm-tasks-axi-lib.sh`'s `fm_beads_home_scope` owns the scope derivation (a short SHA-256 hash of `FM_HOME`, stable across restarts and distinct per home), and `fm_beads_task_label` owns the resulting label, so two homes reusing the same slug resolve to different beads instead of one adopting the other's.
The hash is taken over the home's normalized physical path, so a trailing slash, a relative spelling, and a symlinked spelling of one home all produce the same scope rather than stranding that home's bead behind a second scope; a home path that cannot be resolved falls back to the lexically stripped string so the scope stays deterministic.
Resolution itself asks only that one question, so a brief scaffold or a spawn costs exactly one store lookup and never writes to the store to migrate anything.
Beads minted before the scheme changed carry the old unscoped `task:<task_id>` label, and they are rescued by a separate one-shot migration rather than by a compatibility read on the dispatch path: the unscoped label records no home, and the only home-local ownership record (`state/<task_id>.meta`'s `beads_id=`) does not exist yet at either point a bead is minted, so a read gated on it could never fire for the in-flight beads it would exist to rescue while an ungated one would re-adopt other homes' beads and reinstate the cross-home bug.
`fm_beads_migrate_legacy_task_labels` in [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) owns that migration, and `bin/fm-bootstrap.sh` runs it in its local phase only, as a mutating sweep under this backend, guarded by the session lock and by its own `state/.beads-label-migration.lock` so two processes in one home can never sweep the store at once.
It re-tags an open bead onto `task:<home-scope>:<task_id>` only when this home's own records claim that exact bead for that task id, which means either `state/<id>.meta` records `beads_id=` naming it, or `data/<id>/brief.md` exists and no meta names any bead for that id.
A `data/backlog.md` item id is deliberately not ownership evidence: every home that ever queued a slug carries that line, including a home that never dispatched it, so accepting it would let one home claim a bead a different home had already minted and recorded, which is the shared-bead failure the home-scoped label exists to prevent.
It leaves a bead alone when this home's own record names a different bead for that id, when no record here claims it at all, when another home has already stamped its own `task:<scope>:<task_id>` label on it, or when the bead's labels cannot be read at all, since an unreachable store is not evidence that nobody else has claimed it.
It never removes a label, never closes a bead, and never touches a closed one, so a finished task's surviving label and every other home's beads are left exactly as they were.
The only write it makes to a bead is adding one label, and the only other writes it can make at all are minting this home a replacement bead and rewriting this home's own `state/<id>.meta` `beads_id=` line, both described below.
When two homes both hold a claiming record for one slug and only one pre-migration bead exists, the label cannot say which home minted it, so the first home to sweep keeps that bead and the second ends up on a bead of its own.
How the losing home gets there depends on whether it had already dispatched that task.
A task it had not dispatched simply mints its own bead on its next resolve, because nothing points at the shared bead.
A task it had already dispatched is pinned to the shared bead by its own `state/<id>.meta` `beads_id=`, which `bin/fm-crew-state.sh` and `bin/fm-teardown.sh` read directly and never re-resolve, so leaving it alone would keep both homes acting on one bead; for that case the sweep mints the losing home a bead of its own and rewrites only that home's own `beads_id=` line to name it, never rewriting, re-tagging, or closing the other home's bead.
The rewrite is deferred when the task's endpoint is still alive: the live worker holds the old bead ID in its brief, and repointing the meta record under a running worker would give it a stale reference; the sweep counts that task as a candidate failure and retries the rewrite in the next session once the endpoint has gone.
What genuinely remains after that is that the surviving bead's history stays with the winning home while the losing home's replacement starts empty, and that the separation happens only when the losing home actually runs its sweep, so a home that never starts a session, or whose sweep keeps failing against an unreachable store, stays pinned to the shared bead until it does.
The whole sweep runs under one budget, `FM_BEADS_LABEL_MIGRATION_BUDGET` seconds (60 by default), and every store call within it under whatever of that budget is left, capped at the same per-read bound the heartbeat status read uses, so a Dolt server that accepts the connection and then never answers cannot hold the bootstrap phase open on an unbounded probe and a home with many candidates cannot hold it open on their sum.
A spent budget leaves the marker unwritten, so the remaining candidates are picked up next session rather than being declared migrated.
The sweep is idempotent and safe to re-run: a durable `state/.beads-label-migration-v1` marker records a completed pass so later sessions cost nothing, the marker is written only when no candidate failed so a transient store failure retries next session, and a bead already carrying this home's scoped label is skipped on its own evidence even with the marker removed.
A per-candidate lookup that fails or times out counts as a candidate failure rather than as a candidate with nothing to migrate, so a store failure can never let the permanent marker be written over a bead the sweep never actually read.
The whole-store label list that decides whether there is anything to migrate at all is held to the same rule, and an answer that is not a JSON array is treated as an unreadable store rather than as an empty one, because reading it as empty would write the permanent marker on the one pass that learned nothing.
A failed mint, a failed record rewrite, or a failed lookup of the replacement bead on the repointing path counts as a candidate failure the same way, so a task is never left silently pinned to another home's bead and a read that fails can never be mistaken for evidence that no replacement exists yet.
Its outcomes are reported through `BEADS_LABEL_MIGRATION:` bootstrap diagnostic lines; the `bootstrap-diagnostics` skill owns what each line means.
Bead capture now happens at intake rather than only at dispatch: `fm-brief.sh` opens that same labeled bead (via the same idempotent helper) the moment a task's brief is scaffolded, so a task known but not yet spawned already has an open bead, and the spawn-time resolve above returns it rather than minting a second one.
On the completion side, under the beads backend a task whose linked bead is closed is reconciled as complete by `bin/fm-crew-state.sh` (and therefore by the heartbeat/fleet review that reads it), authoritative over a stale status-event tail, while a still-open bead with a live endpoint stays governed by the existing pane/run-step logic so live work is never marked done prematurely.
Because `fm-ledger.sh`'s drop-recovery can close a claimed bead that went quiet WITHOUT landing, a closed bead is treated as completion only when the task also has no open decision, has a clean worktree, and has committed work that actually landed; otherwise the read falls through to the existing logic rather than reporting done.
Landing is judged by the same predicate teardown uses, `fm_work_is_landed` in `bin/fm-landed-lib.sh`: the task's PR is merged and contains the local work, or the content is already present in the up-to-date default branch.
A clean, fully-pushed worktree whose PR is still open therefore reads as unlanded, and a `local-only` task with no remote is judged against its own local default branch rather than being inert.
Every leg of that check fails closed, so a PR lookup, fetch, content comparison, or worktree read that cannot answer counts as unlanded and the task simply keeps its prior pane/run-step reading.
The check asks the remote, which makes it the one part of this otherwise side-effect-free read that fetches, and `bin/fm-crew-state.sh` bounds all of its remote work with a single shared `FM_CREW_STATE_LANDED_TIMEOUT` deadline so an unreachable remote or a blocking credential helper cannot stall a supervision poll.
The `fm-crew-state.sh` header owns the exact gate, the `bin/fm-landed-lib.sh` header owns the landing predicate's mechanics and its bounded/never-prompt opt-in, and `fm_beads_is_closed` in `bin/fm-tasks-axi-lib.sh` owns the closed-status check.
The structured fleet snapshot (`bin/fm-fleet-snapshot.sh --json`), Bearings (`bin/fm-bearings-snapshot.sh`), and session-start's compact digest above all read this fleet's in-flight/queued beads, scoped by that label, when the beads backend is selected; with any other backend their output is unchanged.
That beads-sourced view covers only status open/in_progress/blocked beads mapped to `records[]` state `queued`/`in_flight`; per-bead dependency graphs and correlation with local `state/*.meta` remain unwired, so `blocked_by_ids` is always empty and `requires_child_metadata` is always false for a beads-sourced record. A record carrying the `captain-hold` label is the exception: its `hold_kind`, `hold_reason`, `current_role`, and `captain_actionable` are populated from the anchor's own labels and `metadata.hold_reason` (see [`decision-hold-lifecycle.md`](decision-hold-lifecycle.md)); every other beads-sourced record leaves those fields null/false.

### Beads store provisioning and sync (state/.beads-sync-last)

Store resolution is the `task` CLI's job, not firstmate's: the federation wrapper pins `BEADS_DIR` before executing `bd`, so every home on one machine shares one store and a home with no local `.beads/` directory is not evidence of a missing store.
Provisioning is therefore per-machine, and local secondmate homes need none of it.
The gap is a machine that has never run beads, typically a remote secondmate host, where the wrapper or the store itself is absent and every read fails with "no beads database found"; [`docs/remote-secondmates.md`](remote-secondmates.md) owns that operator sequence and [`bin/fm-remote-doctor.sh`](../bin/fm-remote-doctor.sh)'s `beads-store` check owns the repair.

Provisioning uses `bd bootstrap`, the non-destructive verb, and never `bd init --force`.
`bin/fm-tasks-axi-lib.sh`'s `fm_beads_bootstrap_store` additionally refuses to bootstrap whenever the store already answers a read, because bootstrap's own detection inspects the `.beads/` directory and reports a healthy Dolt server-mode store as absent, which would otherwise create a fresh empty database beside the live one.

Routine sync is a mutating sweep in bootstrap's deferred network phase (beads backend only, real runs only), so it never sits on the blocking path of session start and a slow remote cannot delay a session.
It runs `task dolt commit`, then `task dolt push`, then `task dolt pull`, in that order: commit first because bd's `--dolt-auto-commit` policy defaults to `off` and leaves writes in the Dolt working set, and push before pull because getting this home's own commits off the machine is the gap being closed.
Each step is bounded by `FM_BEADS_SYNC_TIMEOUT` (default 45 seconds) and the whole sweep by `FM_BEADS_SYNC_BUDGET`, which the sweep sets to a third of the network stage's own `FM_STARTUP_NETWORK_TIMEOUT`; a step with no budget left is reported skipped rather than started.
That budget starts before the sweep's first command, and the store-reachability read and the Dolt remote listing that precede the three steps run under it too, so a Dolt server that accepts a connection and never answers cannot spend more than the budget without a single bounded step having run.
That sweep-wide bound is why the per-step bounds cannot sum past the stage budget and starve the other network sweeps, and it is also why beads sync runs last among them.
The sweep runs at most once per `FM_BEADS_SYNC_MIN_INTERVAL` (default 900 seconds), stamped at `state/.beads-sync-last` when the sweep is attempted rather than when it succeeds, so a broken remote backs off instead of being retried by every session that starts.
A store that does not answer skips the sweep entirely without stamping, because that outage is already reported by the local phase and syncing against it can accomplish nothing; sync then resumes on the first session after the store recovers.
Sync is best-effort throughout: a failing step is reported as a `BEADS_SYNC:` line, the remaining steps still run, and bootstrap itself still succeeds, because an unreachable remote must never block dispatch.
Best-effort never means silent, though. `task dolt commit` exits 0 whether it committed or found a clean working set, so any non-zero exit is reported as a commit failure on the exit status alone rather than on parsed vendor wording, and a push line can never announce success over writes that are still stranded uncommitted.
Likewise, a remote listing that cannot be read at all is reported as its own distinct skip rather than as the no-remote line below, since a home that is silently not syncing to a configured remote is the opposite of a home that has none.

Firstmate configures no Dolt remote, because adding one publishes the fleet's task store to that destination and the destination is the captain's decision; with none configured the sweep reports that the store is single-machine only and does nothing else.
[`docs/beads-sync-topology.md`](beads-sync-topology.md) is the owner of that recommendation, its trade-offs, and the one question the captain answers to enable off-machine durability.

### Beads resilience layer (state/.beads-mirror-*.json, state/.beads-write-queue)

`bin/fm-beads-resilience-lib.sh` keeps the beads backend from wedging firstmate during a Dolt/beads-store outage (beads-authority-migration Stage 5); its header comment is the single owner of the exact function contracts summarized here.
On the read side, a successful beads read that firstmate already performs for another reason - session-start's compact listing, `bin/fm-fleet-snapshot.sh` - opportunistically writes its raw output to a local mirror file (`state/.beads-mirror-<view>.json`, one per read shape) with a timestamp; no code path polls beads solely to refresh a mirror, the same discipline as `state/.last-watcher-beat`.
When a beads read then fails, the caller falls back to the mirror only if it is fresh (`FM_BEADS_MIRROR_MAX_AGE`, default 900 seconds / 15 minutes) and labels every line sourced from it as a stale mirror, naming the store-unreachable-since timestamp; stale mirror data is never presented as current.
Bootstrap applies the same freshness check across every known view (`fm_beads_mirror_freshest_iso`) to decide its own diagnostic: `DEGRADED:` when a fresh mirror exists, escalating to `MISSING:` only when both the live store and every mirror are unusable (`bootstrap-diagnostics` owns the captain-facing handling of both lines).
On the write side, a beads write that already tolerated failure by warning and continuing (`fm-bead-stamp.sh`'s dispatch stamp, `fm-teardown.sh`'s `close_linked_bead`) instead enqueues the failed write to a durable FIFO log (`state/.beads-write-queue`, lock-protected) on any write failure, not just an unreachable store; the queue is availability, not a second write authority, and replays each queued write strictly in order, reporting whatever `task` itself returns, with one narrow exception: a queued `close` whose replay fails is checked against the live store through `fm_beads_status` (`bin/fm-tasks-axi-lib.sh`, the single owner of that bounded single-bead status read), and a bead the store answered as already closed, or confirmed absent against a reachable store, is reconciled instead of re-queued forever.
Only a read that actually completed reconciles: a timeout, a missing tool, or a store that could not be reached to confirm the bead is gone leaves the close queued rather than dropping a pending write on no evidence.
Bootstrap's mutating sweep (beads backend only, real runs only) replays the queue on every session-start bootstrap, so an outage recovers without a new polling loop.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag that current authority for that exact task alone has authorized (a present captain instruction or the task's own accepted brief; never later-task precedent by analogy), then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.
The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
Task meta records `label=` only when `--label` was passed at spawn; an absent `label=` means the task ID was used as the default window label (window name is fm-<id> when --label is absent, fm-<label> when --label is passed).
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding, except legacy Herdr, Zellij, and cmux metadata lacking that binding, which self-repair by appending it once the live pane/tab/workspace is confirmed to still belong to the task (see [herdr-backend.md](herdr-backend.md#endpoint-metadata), [zellij-backend.md](zellij-backend.md#endpoint-metadata), and [cmux-backend.md](cmux-backend.md#endpoint-metadata)), and otherwise refuse without mutation.
Orca intentionally refuses unconditionally when the binding is absent, as it has no verified live-identity-check primitive to prove a recorded terminal or worktree still belongs to the task.
`FM_HOME` determines Herdr's home label: the primary home uses `1M-FIRSTMATE`, and a secondmate home marked by `.fm-secondmate-home` uses `2M-<SCOPE>`, uppercase and derived from its marker id.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior, and [Mate naming convention](herdr-backend.md#mate-naming-convention) owns the exact rank/scope derivation.
The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The setting is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Attended background triage (config/attended-triage / FM_ATTENDED_TRIAGE)

The sub-supervisor is normally the away-mode engine, active only while `state/.afk` is present.
The optional local, gitignored `config/attended-triage` flag also lets it run while the captain is present, as a background pass over the durable wake queue that drops the notifications it can prove nobody needs to act on.
The point is to keep the main session available to the captain instead of spending its turns on routine fleet events.

The flag holds one value on its first non-empty, non-comment line: `on` enables attended triage, and `off`, an absent file, or an unrecognised value leaves it disabled.
`FM_ATTENDED_TRIAGE` overrides the file with the same values.
**The default is off**, so a home that changes nothing keeps exactly today's supervision behavior; an unrecognised value is treated as off and noted in the triage log rather than silently enabling anything.
Start an attended daemon with `bin/fm-attended-start.sh`, which refuses while the flag is off or while away mode already owns the daemon, and keep it as a tracked background session exactly as `bin/fm-afk-start.sh` documents.

Presence changes exactly one thing - what happens to a notification that must reach the captain.
While `state/.afk` is present the daemon buffers it and injects the marked away-supervisor escalation, unchanged.
While the captain is present the daemon leaves it on `state/.wake-queue` so the main session surfaces it on its next turn, and never injects operational input.
A notification judged routine is removed from the queue and recorded in `state/.watch-triage.log` with its verdict and the tier that produced it.

The verdict is two-tier and only ever fails toward reaching the captain.
The shared verb classifier in `bin/fm-classify-lib.sh` runs first and can only force an escalation, which nothing else can override; a cheap model is asked only about what those rules did not already classify, and a notification is dropped only on that model's affirmative answer.
Every degraded path - no model binary, a non-zero exit, a timeout, an empty or unparseable answer, or the per-pass call cap - keeps the notification.
`bin/fm-attended-triage-lib.sh`'s header owns the exact rules, including the categories that are never dropped: any `done`, `needs-decision`, `blocked`, or `failed` report, any Relay mention, any merged pull request or green checks result, any staleness reclaim, any work with an open decision still recorded against it, and every fleet-wide review request.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.
When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.
The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Parlay claim prompt (config/spawn-claim-prompt / FM_SPAWN_CLAIM_PROBE_TIMEOUT)

The optional local, gitignored `config/spawn-claim-prompt` flag is **off unless it reads exactly `on`**, and an absent file is off.
With it on, a bead-linked crewmate or scout is launched against a short `parlay claim <bead>` prompt instead of its whole encoded brief, which is the launch shape `parlay claim` is built for.
The only thing that changes is which file the launch templates' `fm-operational-input.sh encode launch-brief < <file>` substitution reads; the operational-input encoding contract, every harness launch template, and every launch flag are untouched.
The prompt is written beside the brief at `data/<id>/claim-prompt.md`, and it names that brief and declares it authoritative, so a claim that fails at the agent's end still lands on the full contract rather than on a truncated one.
The claim it emits is `parlay claim <bead> --agent <task-id> --silent`: `--agent` keeps the one agent on the single Parlay identity `bin/fm-spawn.sh` already enrolled it under, instead of letting claim derive a second one from the ticket, and `--silent` suppresses the `parlay listen` arm-command claim would otherwise print for the agent to run, because that listener is already running and is already owned by teardown.

Any one of five conditions degrades a launch back to its brief: the flag is off, the spawn is a secondmate (a charter is not a bead-backed work item), the task has no `beads_id=`, the `parlay` binary is not installed, or a bounded `parlay subscribers` probe does not answer.
Degrading is not a second code path - it feeds the same brief the spawn always fed - so a home that has not turned this on produces a byte-identical launch command and `state/<id>.meta`.
`FM_SPAWN_CLAIM_PROBE_TIMEOUT` (default 10 seconds) bounds that probe; hitting the bound degrades the launch and can never block or fail the spawn, so this optional Parlay path stays as non-load-bearing as every other Parlay use in `bin/fm-spawn.sh`.
`state/<id>.meta` records `claim_prompt=on` only when the prompt was actually used, and a `--relaunch` re-decides the shape rather than inheriting it.
`bin/fm-claim-prompt-lib.sh`'s header owns the gate and the prompt text; `bin/fm-spawn.sh`'s header owns the substitution.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.
Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.
There is no shared learnings file by captain decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/fm-config-push.sh` propagates it to registered secondmates.
A secondmate does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
An inherited `data/captain-shared.md` counts in a secondmate's total but remains primary-owned and read-only there.
The internal [`/stow` skill](../.agents/skills/stow/SKILL.md) owns curation and its automatic secondmate cascade, which accounts every home against this same per-home allowance separately rather than against a fleet total.
The helper's header owns exact parsing, publication, and report output mechanics.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.
With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.
The flag is per home and is not inherited by secondmate homes, because stow cadence is a property of the home doing the stowing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.
The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
A remote route adds `host:` and `root:` before the existing fields and places the whole secondmate home on that SSH host; it does not make ordinary workers remotely placeable.
[`remote-secondmates.md`](remote-secondmates.md) owns current remote setup, operation, and safety behavior.
Use `fm-home-seed.sh validate` to check the complete operational registry contract documented by the command itself.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh local firstmate worktree for the secondmate home.
For remote provisioning, including supplied project origins, follow [Remote second mates](remote-secondmates.md#provision-a-route).
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it refuses In flight, Done, or non-secondmate homes, and a new move succeeds only after waking the recorded receiver.
If the wake is known to have failed, the moved item remains durable and rerunning the same handoff retries it idempotently; an unresolved delivery is reported and never blindly resent.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.fm-secondmate-home` identity marker at the home root, alongside a durable `.fm-secondmate-parent` record of the home's route to its parent (see "Provision a route" in [`docs/remote-secondmates.md`](remote-secondmates.md)).
The tracked root `.gitignore` ignores both markers, so validation can read them without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory against the caller's working directory, preserves absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated Relay poll shim; other transient consumers retain their existing shell-relative behavior.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Isolated launch (bin/fm-isolated-launch.sh)

`bin/fm-isolated-launch.sh` launches `claude` stripped of the operator's global `~/.claude/` PAI layer - no global CLAUDE.md @-imports, hooks, skills/agents, or auto-memory - while this repo's own project-level CLAUDE.md/AGENTS.md and `.agents/skills/` still load.
Redirecting `HOME` alone is not enough, so it does two things: it points `HOME` at a fresh `$FM_ROOT/.fm-isolated-home` (override with `FM_ISOLATED_HOME`) to strip the `$HOME/.claude/` global config, and, because Claude Code also walks cwd's ancestor directories for `.claude/CLAUDE.md` independent of `HOME`, it mirrors the repo's tracked files into a detached git worktree outside the real home tree at `/private/tmp/fm-isolated-worktree` (override with `FM_ISOLATED_CWD`) and launches `claude` from there so that ancestor walk never reaches `~/.claude/CLAUDE.md`.
The mirror is refreshed to the repo's current HEAD every launch, and the launch refuses rather than fall back to `$FM_ROOT` (nested under the real `$HOME`) if the mirror cannot be built.
`FM_ROOT_OVERRIDE` is exported into the session so every `bin/` script still resolves firstmate's real `data/`, `state/`, `config/`, and `projects/`, and the isolated home's `data/` is symlinked at the real one so the federated `bd` store wrappers keep resolving under the real `$HOME`.
The session runs in bypass-permissions (YOLO) autonomy - the same `claude --dangerously-skip-permissions` mode `fm-spawn.sh` uses for crewmates - re-applied every launch, so it does not stop for a tool-approval dialog.
On macOS the first launch seeds the isolated home's file-based credential by copying the existing OAuth token read-only out of the real, already-unlocked Keychain, so the session reuses the same logged-in account; only when that extraction is impossible (non-macOS, no `security`, or no stored credential) does first run fall back to a login prompt.
Later launches against the same isolated home reuse whatever credential file is already there.
The script header is the authoritative owner of the full rationale and mechanics.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, kimi, and cursor are empirically verified for crewmate and secondmate launches; [README requirements](../README.md#requirements) own the set supported for the primary session.
A cursor secondmate or primary runs the tracked project-scope `.cursor/hooks.json` in its own home and must be launched with `--trust`, or no project hook loads; [`docs/supervision-protocols/cursor.md`](supervision-protocols/cursor.md) owns its supervision protocol.
Cursor typed-submit confirmation is verified on tmux and Herdr only.
On Zellij, cmux, and Orca a typed-plane Cursor send (a harness-native invocation or an explicit backend target; ordinary text steers ride the durable inbox and exit 0 at enqueue) lands, but `fm-send` reports delivery unconfirmed and exits non-zero because their shared submit core does not consult the busy footer; [runtime backend verification](verification/runtime-backends.md#cursor-agent-cli) owns the evidence and transcript-state boundary.
muse is verified for crewmate and scout launches ONLY, and `fm-spawn.sh` refuses it for a secondmate, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](verification/muse.md) owns that evidence.
muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.
New harnesses get verified through a supervised trial task before joining the set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh), and [`docs/agent-control.md`](agent-control.md) owns their lifecycle-control architecture.
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Pi-family launches adapt the regular-TUI safeguard to the installed CLI's capabilities; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns executable resolution and launch mechanics.
Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
Changing this pin affects the next secondmate spawn or control-plane relaunch; the relaunch profile rules are owned by [`docs/agent-control.md`](agent-control.md#transactional-relaunch).
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
For Pi and pi-signed secondmate launches, `fm-spawn.sh` starts the selected executable with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

## Multi-account Claude Code (bin/claude-account.sh, --account)

A captain with more than one paid Claude subscription can have claude-harness crewmates draw from a second account's quota instead of competing with the primary session's own account.
[`bin/claude-account.sh <N> [args...]`](../bin/claude-account.sh) is a standalone launcher (it works with no firstmate checkout on `PATH`) that sets `CLAUDE_CONFIG_DIR` to `~/.claude-homes/account<N>/.claude`, symlinks shared config (`commands`, `hooks`, `skills`, `mcp-configs`, `settings.json`, `settings.local.json`, `rules`, `agents`) in from `~/.claude/` idempotently, authenticates the session with the account's long-lived setup token (below), and pre-accepts the onboarding, trust-dialog, and project-scoped MCP prompts so a session isn't dropped into a first-run or approval flow.
`.claude.json` is never symlinked - it stays a per-account real file, or project/session state leaks across accounts.
`bin/claude-1.sh` and `bin/claude-2.sh` are one-line direct launchers (`claude-1.sh <args>` == `claude-account.sh 1 <args>`) for a human or an orchestrator to call.

Two current-Claude-Code mechanics the launcher depends on:

- **Onboarding pre-seed location.** When `CLAUDE_CONFIG_DIR` is set, Claude Code reads its global config JSON from `$CLAUDE_CONFIG_DIR/.claude.json` (path = `join(CLAUDE_CONFIG_DIR ?? homedir, ".claude.json")`), *not* from a `.claude.json` in the parent of that dir. The onboarding gate is the single key `hasCompletedOnboarding: true`; once set, the whole welcome/theme/login first-run flow is skipped. The launcher writes its `hasCompletedOnboarding`, per-project `hasTrustDialogAccepted`, and `enableAllProjectMcpServers: true` pre-seed into `$CLAUDE_CONFIG_DIR/.claude.json` for exactly this reason (the last auto-approves project-scoped `.mcp.json` servers, which are never inherited across account homes).
- **Auth = per-account setup token, exported as `CLAUDE_CODE_OAUTH_TOKEN`.** The launcher resolves a long-lived `claude setup-token` (`sk-ant-oat01-…`) from the macOS keychain - service `ccjuggler-acc<N>`, account `ccjuggler`, the exact entry the `juggle`/ccjuggler switcher uses - validates the prefix, and exports it into the session env, where current Claude Code honors it for interactive sessions. Setup tokens are used on purpose over the `.credentials.json` / `claude /login` blob: they are ~1yr-lived and never silently log out mid-fleet-run (a cleared or expired `.credentials.json` does). The launcher refuses (rather than dropping into a login prompt) when the keychain token is absent or is not an `sk-ant-oat01-` value - a malformed value stored there is what once silently broke a second account.

Seed or rotate an account's setup token once before first use: run `claude setup-token` under the target account (browser flow), then store the printed token in the keychain (or use `juggle add`):

```
security add-generic-password -U -s "ccjuggler-acc<N>" -a "ccjuggler" -w "<sk-ant-oat01-… token>"
```

`fm-spawn.sh --account <N>` wires a ship or scout claude-harness spawn to a specific account: it records `account=N` in the task's `state/<id>.meta`, sets `CLAUDE_TRUST_DIR` to the task's worktree in the crewmate's launch environment so the correct directory gets pre-trusted, and launches through `bin/claude-account.sh N` instead of the plain `claude` binary.
`--account` requires the claude harness and is strictly optional; absent means current behavior (plain `claude`, no account isolation).

Full pattern, rationale, verification steps, and a capacity-aware routing reference: <https://gist.github.com/sjarmak/61e22d3625ecaac2279e8564d1b1b68f>.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.46.0 or newer, compatible gh-axi, chrome-devtools-axi, compatible lavish-axi, compatible tasks-axi per "Backlog backend" above, and compatible quota-axi.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When Relay is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)` unless `config/backlog-backend=beads` is set (use the beads store instead) or `config/backlog-backend=manual` (suppress the verbose fact); when compatible `tasks-axi` is on `PATH`, bootstrap stays silent and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent or incompatible `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)`.
An absent or incompatible `lavish-axi` reports `MISSING: lavish-axi (install: npm install -g lavish-axi && lavish-axi setup hooks)`.
An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; firstmate cannot resolve a profile array without a compatible binary.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`; [`fm-bootstrap.sh`'s header](../bin/fm-bootstrap.sh) owns the exact clone-refresh overlap, liveness-before-convergence, per-mate concurrency, ordered diagnostic replay, and sequential-fallback contract.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The same deferred network stage performs guarded tracked-file sync and propagates declared inherited local material into each validated live home under that sequencing contract.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a registered secondmate is skipped or its relaunch fails; already-live and successfully relaunched secondmates are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `backend`, `herdr-presentation-spaces`, `startup-memory-budget`, `trace-context`, and `data/captain-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running local home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
A changed remote home instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
The locked bootstrap inheritance pass uses the same placement-specific behavior; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Watched tool updates (config/watched-tools.json)

`config/watched-tools.json` is an optional local, gitignored list of the tools this home depends on.
When it is present and the check is armed, [`bin/fm-tool-update-check.sh`](../bin/fm-tool-update-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is already installed on this host, but `PATH` still resolves an older one.

The second condition is the reason the check exists.
An update can install correctly and stay inert because an earlier `PATH` entry still holds an older copy, and a check that only asks whether a newer version is published reports that host as up to date.
The script therefore runs every copy of a watched command found on `PATH` and asks it for its own version, rather than trusting one lookup or reading a version out of a directory name.
It only reports; it never installs, updates, fetches, or changes `PATH`, a version manager, or any installed tool.

This section is the single owner of the canonical schema.
`bin/fm-tool-update-check.sh` owns probe mechanics, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

Each entry needs a `name` and at least one of `command` or `git`; an entry may carry both.
A `command` entry gives the `PATH` comparison above, and adding `announce_pattern` also reports the tool's own update announcement, which is how a tool that already reports its own updates is read rather than reimplemented.
A tool does not always announce a new release on the command that prints its version: `no-mistakes --version` prints only the version, while its other commands carry the announcement.
`announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.
Both probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
See [`docs/examples/watched-tools.json`](examples/watched-tools.json) for a starting point to copy into local `config/watched-tools.json`.

Arm the check once per home with `bin/fm-tool-update-check.sh arm`.
That writes `state/tool-updates.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake; no separate schedule is involved.
The armed check runs whenever that home has a watcher running, and arming alone does not make watcher supervision required, so a home with no in-flight work and no other reason to watch does not start a watcher just for this check.
`bin/fm-tool-update-check.sh disarm` removes the shim, its trust binding, and the report record.
The check prints nothing when everything is current, and `state/.tool-updates` records the findings the last report was made from so the same pending update is reported once instead of on every poll.
A changed or returning condition is reported again.
Adding, removing, or changing a watched tool is an edit to this file and needs no code change or re-arming.
This file is not inherited by secondmate homes, so each home watches the tools it actually depends on.

`FM_TOOL_UPDATE_INTERVAL` (default 900 seconds, `0` to probe on every run) sets how often probes actually run, `FM_TOOL_UPDATE_PROBE_SECS` (default 5) bounds one probe, and `FM_TOOL_UPDATE_BUDGET_SECS` (default 20) bounds a whole sweep.
A sweep that runs out of budget says which tool it did not reach rather than reporting the rest as current.
The sweep must finish inside `FM_CHECK_TIMEOUT` (default 30), because a run the watcher kills prints nothing and records nothing and would then repeat that silence on every poll.
So a budget larger than that timeout allows is cut down to what fits instead of being refused, and the cut is reported in the report line.
A budget that is not a whole number from 1 to 120 is still refused outright.

## Relay (.env)

Relay lets a firstmate instance answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers both public surfaces the relay supports: `@myfirstmate` mentions on X, and mentions of the myfirstmate bot in a Discord server where it is installed.
Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the myfirstmate bot to a server you administer; the X surface needs no install step.
3. Copy the pairing token from the dashboard into this firstmate home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local firstmate home does with the token once it is in `.env`.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the Relay cadence contract: a Relay instance polls every 30 seconds instead of the default 300, only a Relay instance speeds up because a non-Relay home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While away mode is active the daemon owns the watcher and its default cadence applies; away-mode Relay cadence is a deferred follow-up.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
Relay remains additive to non-Relay lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The preserved object may also carry `in_reply_to_chain`, an optional oldest-first transcript of the surrounding conversation: entries shaped `{author_handle, text, unavailable, images}` plus an optional `kind` of `reply` (a reply ancestor), `thread_starter` (the message a thread grew from), or `history` (a recent nearby message), where an absent `kind` means a legacy reply-ancestor or thread-starter entry.
The chain is untrusted third-party public input and is often absent today (the relay currently sends it only for Discord reply chains and thread starters), so consumers treat it as strictly optional, tolerate unknown or missing fields, and read an entry with `unavailable: true` as a gap rather than content; the `fmx-respond` skill owns how firstmate reads it for referent resolution.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work. When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
The link is home-local by construction, because it lives in that home's own `state/<task-id>.meta`: work routed to a secondmate has no record here, so `bin/fm-x-link.sh` refuses it, names the registered secondmate home the task was found in when it can, and points at the promised-final path (`bin/fm-public-followup.sh register ... --work-home secondmate:<id>`), which is the only follow-up mechanism that binds work in another home.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation whose state machine is owned entirely by `tasks-axi public-followup` (requires `tasks-axi` 0.2.3 or newer; the shared bootstrap probe in `bin/fm-tasks-axi-lib.sh` gates at 0.2.2 for backlog-mutation verbs and does not cover this command), while the full private conversation context stays only in `state/x-context/`.
Firstmate's bounded registration retains the obligation's public-safe request binding so a delivered loop can be rechained without the original inbox.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, posts the final reply through `bin/fm-x-reply.sh --followup`, and explicitly rechains or retires the retained loop.
Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

Registration is what creates this home's private transport under `state/public-followup/` (mode 0700): `registry/` for the bounded private binding of each open public loop (the record survives delivery, stamped `state=delivered`, and is removed only by `retire`), `events/` for typed terminal results awaiting reconciliation, `consumed/` for the accepted-event ledger, `rejected/` for refusals kept with a one-line reason, `retired/` for the mode-0600 reason-and-time receipt written before removal, and `surfaced` for the poll's last-surfaced signature.
The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; that emitter refuses to write into a home with no registration for the named obligation.
A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.
A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.
Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.
The session-start digest separately prints a "Public commitments" subsection from disk when, and only when, this home is relay-active and still holds an open public loop (a reply still owed, or a delivered loop with nothing owed), so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind restart recovery, retained-loop disposition, and the relay-disabled zero-overhead guarantee.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; `bin/fm-procevent-lavish.sh` is the first adapter and wraps only the currently published `lavish-axi poll` interface.
That adapter, and only that adapter, retries the one exact transient response a cut-short listener returns while its marks remain available (`error: Lavish Editor poll response was interrupted` with `code: SERVER_ERROR`), up to 12 times at 5 second intervals, so an internal retry never reaches the runner as a captured result.
Real feedback, ended and missing sessions, any other `SERVER_ERROR`, and that same interruption still standing once the bound is spent are all captured and announced normally; `FM_LAVISH_POLL_RETRY_DELAY` is a bounded 0 to 60 second test override for the interval only, and the runner itself stays adapter-agnostic.
An already-armed Lavish source keeps its registered listener command until it is retired and armed again, so re-arm a live board once to adopt this retry policy.

The `when` adapter (`bin/fm-procevent-when.sh`) turns this channel into a condition->action primitive: it registers a deterministic condition and a deterministic action once, its blocking child polls the condition without waking firstmate, and a stable true fires the action at most once before one terminal outcome is durably captured and published as a wake that remains eligible for re-announcement until handled.
The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs.
Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

This section is the single owner of the runner's operating contract.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
The self-announcing adapter exception and its fail-safe ordering are defined below.
The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this home's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result is a routine no-op is adapter knowledge too, and the runner names no adapter-specific condition for it either.
Before publishing, the runner calls `bin/fm-procevent-<adapter>.sh silent <result-file>` and treats exit 0 as the only silence verdict: the result is recorded as durably handled and never announced, so it neither wakes a handler now nor returns on a later reconcile.
A missing command, an error, any other exit, or a silence the runner cannot durably record all publish the `check` wake exactly as before, so an adapter with no notion of a no-op needs no change and an unknown or degraded result always reaches its handler.
Silence is independent of the keyed-answer feed below, which still runs once per capture for every adapter: suppressing an announcement never suppresses the captain's own answer.
For Lavish that verdict covers exactly one shape - a session the adapter classifies `ended` that carries no queued content block at all, which is a review surface closed with nothing said.
Any recognized top-level `prompts` or `feedback` block counts as content regardless of its declared count, and a malformed header makes the result indeterminate rather than empty.
A `Send & End` close carrying the captain's answer arrives as `status: feedback` with `session_ended`, so it classifies `feedback` and is announced unchanged, as is any `ended` result that still carries content, and every `waiting`, `missing`, `unknown`, or unreadable result.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture - and after initial `check` publication for the default ordering - the runner calls `bin/fm-procevent-<adapter>.sh terminal <result-file>` and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.
For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

Applying a captured result is adapter knowledge too, and some results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the adapter apply and acknowledge its own result.
That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.
Announcement ordering is adapter-declared through `bin/fm-procevent-<adapter>.sh self-announcing`: an adapter that answers exit 0 declares that every result its autohandle fully applies is announced through a durable downstream channel of its own, so the runner applies first and publishes a `check` wake only for what remains unhandled afterwards; every other adapter keeps the strict publish-before-apply order, and its autohandle runs only when this capture's own wake was successfully appended to the durable queue.
The remote-secondmate reply adapter declares itself self-announcing: a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step, the mirrored status bytes are the single wake for one remote note through the same signal classification a local secondmate's append gets, a byte-identical replayed capture adds no bytes and stays quiet, and only a capture the adapter could not fully apply is published as a `check` wake, whose adapter handling remains idempotent.

Keyed captain answers use one more seam of the same kind, and the runner still decides nothing about them.
Some sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.
A source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
The adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future source needs nothing here beyond an `answers` command and a binding.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer is transcription while acting on it is firstmate's judgement.
An unbound source, an adapter with no `answers` command, and a failure on either side all leave the capture untouched and still announced.

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
Each claim binds its home and runner PID to a process identity, unique claim generation, and exact registration-file generation.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Retirement and orphan reconciliation signal a runner process group only while its recorded process identity still matches, or when the recorded leader is gone and only its own owned group survives.
A runner leads its own process group, so a claim counts as reclaimable only when that whole generation is gone: a crashed leader whose group still has members is not stale, and reconcile stops that surviving group and releases its generation before starting any replacement.
If identity cannot be established for a live PID, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is a reused PID, so it is treated as stale and its process group is never signalled.

Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims physically owned by that home through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Spoken interface and captain inbox (config/voice-*, config/inbox-*)

The spoken interface in [`docs/voice-relay.md`](voice-relay.md) and the model-backed subcommands of `bin/fm-inbox.sh` reach a paid API in a named account, so no region, model id or AWS profile is shipped as a tracked default.
Each is one line in a local, gitignored `config/` file, with an environment variable that overrides it for a single run, and a missing required value refuses with the path to write rather than falling back to a value that belongs to another home.
That configuration is the whole opt-in: an unconfigured home cannot start the relay and cannot run `fm-inbox.sh say` or `ask`, while `note`, `status`, `list` and `drain` need no configuration at all because they make no model call.
The voice handover depends on `note`, so it keeps working in a home that has configured nothing.

| File | Environment | Holds |
| --- | --- | --- |
| `config/voice-region` | `FM_VOICE_REGION` | Bedrock region for the relay's bidirectional session, required by `bin/fm-voice-relay.py`. |
| `config/voice-model` | `FM_VOICE_MODEL` | Speech-to-speech model id, required by `bin/fm-voice-relay.py`. |
| `config/voice-profile` | `FM_VOICE_PROFILE` | AWS profile the relay exports credentials from; absent, or an explicitly empty variable, means it uses only credentials already in its environment. |
| `config/voice-id` | `FM_VOICE_ID` | Output voice id, optional, `matthew` when unset. |
| `config/voice-read-scope` | none | `counts` (the default, and what an absent file means) or `full`; see [`docs/voice-relay.md`](voice-relay.md) for what each scope may say. |
| `config/voice-read-deny` | none | One plain case-insensitive substring per line; a matching open item is withheld from every list and reduced to a count. |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `fm-inbox.sh say` and `ask`. |
| `config/inbox-stt-model` | `FM_INBOX_STT_MODEL` | Speech-to-text model id, required by `fm-inbox.sh say`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model id, required by `fm-inbox.sh ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile for those two calls; absent, or an explicitly empty variable, means whatever credentials are already in the environment. |

Each account, model and voice file above is read as its first line that is not blank and not a `#` comment, so a comment above the value is fine.
The two read files are parsed differently: `config/voice-read-scope` must hold the bare word and nothing but blank space around it, so a comment header there refuses instead of being skipped, while every line of `config/voice-read-deny` that is not blank and not a `#` comment is one more substring.
`FM_VOICE_RELAY` and `FM_VOICE_PYTHON` belong to the laptop rather than to a home, so they have no config file: `bin/fm-voice-client.py` requires the relay path as a flag or that variable and carries no default path.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in fm-wake-lib.sh and fm-teardown.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/scout spawns, codex-app is not accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_BACKEND_HERDR_PRESENTATION_LOCK_POLLS=50  # herdr-only: polls a spawn, teardown, or task kill waits for the shared session presentation lock before degrading (spawn falls back flat, teardown/kill refuse); raise it for a loaded or instrumented run (docs/herdr-backend.md "Optional presentation spaces")
FM_BACKEND_HERDR_PRESENTATION_LOCK_INTERVAL=0.1  # herdr-only: seconds between those polls; 50 x 0.1 is the shipped 5s bound. Either knob falls back to its default when set to a non-numeric value, so a malformed override degrades to the shipped bound instead of skipping the wait or spinning it without delay
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_REMOTE_BRIDGE_URL=http://localhost:8787   # fm-remote-launch.sh-only: local herdr-web bridge base URL, proxied as /api/remote/<mini>/...
FM_REMOTE_LAUNCH_HTTP_TIMEOUT=10   # fm-remote-launch.sh-only: seconds allowed per bridge REST call
FM_REMOTE_LAUNCH_REACHABLE_TIMEOUT=5   # fm-remote-launch.sh-only: seconds allowed for the mini reachability snapshot probe
FM_REMOTE_LAUNCH_PROBE_TIMEOUT=25   # fm-remote-launch.sh-only: seconds allowed per terminal-websocket marker-based shell probe (project/gh-auth/dirty/landed checks)
FM_REMOTE_LAUNCH_CLONE_TIMEOUT=90   # fm-remote-launch.sh-only: seconds allowed for the remote `git clone` probe when the project is absent on the mini
FM_REMOTE_LAUNCH_FRAME_DELAY=2   # fm-remote-launch.sh-only: seconds between fire-and-forget input frames sent to start the agent and type its prompt
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the whole deferred network stage; hitting it prints an actionable NETWORK_CHECKS line
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_BEADS_SYNC_TIMEOUT=45   # beads backend only: seconds bounding each Dolt sync step, so an unreachable remote cannot stall the sweep
FM_BEADS_SYNC_BUDGET=40   # beads backend only: seconds bounding the WHOLE sync sweep, probes included, so the per-step bounds cannot sum past the caller's own budget; the bootstrap sweep overrides it to a third of FM_STARTUP_NETWORK_TIMEOUT
FM_BEADS_SYNC_MIN_INTERVAL=900   # beads backend only: seconds between store sync sweeps, stamped at state/.beads-sync-last on attempt
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_MD5_SBIN_OVERRIDE=/sbin/md5   # override for hash_pane()'s hardcoded /sbin/md5 fallback tier, mainly for tests; hash_pane also falls back through md5sum, openssl, shasum, and cksum before a pure-shell od+awk content digest last resort that cannot itself be absent, so a watcher's poll-to-poll pane hashing never hard-errors when PATH lacks md5/md5sum
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also scans immediately
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery on an idle pane; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_LANDED_TIMEOUT=10   # defaults to FM_CREW_STATE_NM_TIMEOUT; ONE shared deadline for all remote work in fm-crew-state.sh's closed-bead landing check, however many legs it runs; the only value that reaches the predicate there, so an exported FM_LANDED_NET_TIMEOUT never changes the supervision bound
FM_LANDED_NET_TIMEOUT=   # bin/fm-landed-lib.sh opt-in: seconds bounding the landing predicate's whole remote leg set and also forcing its fetches never to prompt; unset keeps the unbounded, may-prompt default fm-teardown.sh's interactive gate depends on
FM_BEADS_STATUS_TIMEOUT=4     # seconds allowed per single-bead status read (fm_beads_status) so a wedged store cannot stall the heartbeat; a non-numeric or non-positive value falls back to the default
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FM_TEARDOWN_BIN=bin/fm-teardown.sh   # test override for the reclaim call staleness auto-close makes against a stale ship task
FM_AGENT_AXI_TIMEOUT=10     # per-probe hard bound in seconds for fm-agent-axi.sh's herdr, git, and no-mistakes probes
FM_AGENT_AXI_AGENTS='claude|codex|opencode|grok|kimi|muse|pi'  # '|'-separated agent command basenames counted as live agents by fm-agent-axi.sh
FM_NM_LIVENESS_TIMEOUT=15   # seconds allowed per no-mistakes query inside fm-no-mistakes-liveness.sh and fm-nm-run-is-live.sh
FM_NM_LIVENESS_STALE=300    # seconds; a run is considered hung if its active step has not had activity for longer than this threshold
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, an open Stop auto-arm generation claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_AUTOARM_MAX_REARMS=20   # Claude Stop auto-arm re-arms per hook firing after a quiet arm close with no live watcher; exhausting the budget escalates to a continuity-lost rewake
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_IDLE_DISCOVERY_INTERVAL=60  # seconds between idle-task-discovery attempts (watcher autonomously dispatches ready tasks when fleet is idle)
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
FM_STALENESS_AUTOCLOSE_SECS=7200          # idle seconds before the watcher reclaims an ordinary ship task's live process via `fm-teardown.sh --staleness-autoclose`, ahead of ordinary stale surfacing; skipped for paused/captain-held or captain-relevant-gate status and for a pane crew_is_provably_working still finds working
FM_STALENESS_AUTOCLOSE_MAX_RETRIES=5      # consecutive failed reclaim attempts allowed for one stale pane hash before the watcher gives up until the hash next changes
FM_STALENESS_AUTOCLOSE_RETRY_BASE_SECS=300   # seconds before the first retry after a failed reclaim; doubles per additional failure
FM_STALENESS_AUTOCLOSE_RETRY_MAX_SECS=3600   # cap on the doubling reclaim-retry backoff
FM_STALENESS_FOCUS_GRACE_SECS=300        # herdr only: seconds a reap-candidate pane stays protected from the staleness auto-close reclaim after a human last focused it; a currently- or recently-focused pane blocks the reclaim without consuming the retry budget, and an unreadable focus also blocks but only until FM_STALENESS_AUTOCLOSE_MAX_RETRIES consecutive unreadable polls (any readable poll resets the count), after which the unreadable pane is held to the same within-grace recency check as an unfocused one so a dead pane with no fresh focus marker falls through to reap while a pane focused within this window stays blocked even at the bound
FM_BUSY_TURN_MAX_SECS=3600         # maximum age of a busy pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn completes, before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait or verified captain-held transfer takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_PAUSE_RESURFACE_SECS=3600       # seconds before the watcher re-surfaces a declared external wait or verified captain-held transfer for a recheck, including a live busy pane past FM_BUSY_TURN_MAX_SECS; the away-mode daemon uses the same setting for a declared external wait or verified captain-held transfer, ageing its window against the crew's own latest status line rather than pane busy state
FM_SECONDMATE_WAKE_STALL_SECS=60   # minimum age of the oldest valid foreign wake-queue row before an endpoint-recorded local secondmate produces one durable parent wake-loop-stall notification; zero or invalid values use 60
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_MAXDEPTH=6       # depth that same probe walks below the recorded worktree; it runs only at the moment a wedge escalation would otherwise fire, never on every poll; no probe knob applies to a secondmate, whose recorded worktree is a provisioned home the probe skips entirely
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_POOL_STALE_LEASE_SECS=7200             # age past which a process-free treehouse pool lease counts as abandoned and bin/fm-pool-reclaim.sh may return it; invalid values use 7200
FM_SPAWN_SKIP_POOL_RECLAIM=               # set to 1 to skip fm-spawn.sh's best-effort bin/fm-pool-reclaim.sh pre-flight before `treehouse get`
FM_SPAWN_POOL_RECLAIM_TIMEOUT=30          # seconds fm-spawn.sh allows that pre-flight sweep before abandoning it; a timeout is fail-open like every other reclaim failure
FM_SPAWN_FIRSTTURN=on                     # set to off to disable fm-spawn.sh's first-turn watchdog entirely; the launch then behaves exactly as it did before verification existed and state/.firstturn.log records detail=disabled
FM_SPAWN_FIRSTTURN_POLLS=120              # polls fm-spawn.sh waits for proof that the launch prompt started a turn; the wait returns the instant a turn is proven, so a healthy launch costs one read and only a dropped prompt spends the budget
FM_SPAWN_FIRSTTURN_INTERVAL=0.5           # seconds between those polls; 120 x 0.5 is the shipped 60s bound
FM_SPAWN_FIRSTTURN_RESUBMIT_POLLS=        # polls spent re-confirming after the brief pointer is resubmitted; unset uses FM_SPAWN_FIRSTTURN_POLLS
FM_SPAWN_FIRSTTURN_SUBMIT_RETRIES=3       # Enter retries for that single resubmission, passed straight to the backend's proof-carrying submit primitive
FM_SPAWN_FIRSTTURN_SUBMIT_SLEEP=          # seconds between those Enter retries; unset uses FM_SPAWN_FIRSTTURN_INTERVAL
FM_SPAWN_FIRSTTURN_SUBMIT_SETTLE=0        # seconds allowed for the typed pointer to settle before the first Enter
FM_SPAWN_CLAIM_PROBE_TIMEOUT=10           # seconds bounding the `parlay subscribers` reachability probe behind config/spawn-claim-prompt; hitting the bound degrades that launch to its brief and can never block or fail the spawn
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; tmux instead supplies its bounded visible pane, while the other adapters use this small window so stale scrollback banners stay out of the candidate set
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled tmux, herdr, and Zellij reads)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send typed-plane Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
FM_SEND_VERIFY_TRANSITION=0   # opt-in: after a successful submit, confirm the target actually transitioned idle->working before returning; non-zero enables. On a confirmed still-idle target (or a backend error) fm-send exits non-zero because the turn did not start
FM_SEND_VERIFY_TIMEOUT=0.6    # seconds fm-send polls the target's agent state for that idle->working transition
FM_SEND_VERBOSE=0             # non-zero prints a warning when the transition could not be verified (unknown result) instead of proceeding silently
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# attended background triage (bin/fm-attended-triage-lib.sh); active only while /afk is OFF
FM_ATTENDED_TRIAGE=                # on|off override for config/attended-triage; unset defers to the file, which defaults to off
FM_ATTENDED_TRIAGE_MODEL=haiku     # model passed to `claude -p --model` for the second-tier verdict
FM_ATTENDED_TRIAGE_TIMEOUT_SECS=8  # hard per-call watchdog; a timeout keeps the wake, never drops it
FM_ATTENDED_TRIAGE_MAX_CALLS=4     # model calls allowed per pass, so a wake storm cannot fan out; past the cap every remaining wake is kept
FM_ATTENDED_TRIAGE_EXEC=           # verdict seam: run this command instead of `claude`; unset in production
FM_ATTENDED_TRIAGE_STATUS_TAIL_LINES=8   # status lines shown to the model as context for one wake

# spoken interface and captain inbox; see "Spoken interface and captain inbox" above
FM_VOICE_REGION=        # overrides config/voice-region for one relay run
FM_VOICE_MODEL=         # overrides config/voice-model for one relay run
FM_VOICE_PROFILE=       # overrides config/voice-profile; explicitly empty forces ambient credentials
FM_VOICE_ID=            # overrides config/voice-id; matthew when neither is set
FM_VOICE_RELAY=         # laptop-side path to bin/fm-voice-relay.py on the desktop; required by fm-voice-client.py unless --relay is passed
FM_VOICE_PYTHON=python3 # laptop-side interpreter used to start the relay over ssh
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh say and ask
FM_INBOX_STT_MODEL=     # overrides config/inbox-stt-model for fm-inbox.sh say
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
`lsof` is resolved through `bin/fm-lock-lib.sh`'s `fm_lsof_bin()`, which checks PATH first, then falls back to standard system locations like `/usr/sbin/lsof` (crucial on macOS, where lsof is not in the PATH by default in many shells).
A live lock, an unavailable `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
