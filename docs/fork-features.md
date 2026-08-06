# Fork Features Register

This file enumerates every capability this fork has that upstream does not.
It is the authoritative record of what must survive any reconcile, rebase, or merge against upstream.
It is used by the automated test suite (`tests/fork-features.sh`) to prevent silent feature drops.

**Design principle:** omitting an entry from this list is obviously wrong to the next person because the entry name, files, and observable behavior are all concretely listed and verifiable.

## Multi-account Claude Code

**Capability:** Launch isolated Claude Code instances with per-account credential isolation using `--account N`.

**Files:**
- `bin/fm-spawn.sh` — accepts `--account <N>` flag, records in task meta, sets `CLAUDE_TRUST_DIR` and `CLAUDE_ACCOUNT_ID`
- `bin/claude-account.sh` — launcher that reads account setup token from macOS keychain (ccjuggler-acc<N>) and sets `CLAUDE_CONFIG_DIR` per account
- `docs/configuration.md` — documents multi-account setup and keychain integration

**Observable behavior:**
- `fm-spawn.sh --account 2 <task> <project>` succeeds (flag accepted)
- Task meta contains `account=2` line
- Crewmate environment exports `CLAUDE_ACCOUNT_ID=2` and `CLAUDE_TRUST_DIR=<worktree>`
- Claude Code reads account-isolated config from `~/.claude-homes/account2/.claude/`

**References:**
- Commits: 55bb1de, 956abb2, 368a5c2, 7ed2fab
- Brief: the `--account` flag is documented in `bin/fm-spawn.sh` and required for supporting multi-agent concurrent work on single desktop

## Remote Dispatch (SSH-based crewmate allocation)

**Capability:** Dispatch crewmate tasks to remote machines via SSH with automatic worktree allocation.

**Files:**
- `bin/fm-spawn.sh` — accepts `--remote <host>` flag, validates, and delegates to remote wrapper
- `bin/fm-remote-ssh.sh` — SSH transport, environment setup, and remote worktree allocation on target machine
- `docs/configuration.md` — documents SSH-based remote dispatch for crewmates
- `docs/remote-ssh.md` — detailed remote crewmate dispatch architecture and troubleshooting

**Observable behavior:**
- `fm-spawn.sh --remote <host> <task> <project>` succeeds (flag accepted)
- Task meta contains `remote_host=<host>` line
- Remote environment exports `FM_HERDR_REMOTE_HOST=<host>`
- Worktree is allocated on remote machine, not locally
- Recovery and steer commands work across SSH boundary

**References:**
- Commits: 55bb1de, 956abb2, 368a5c2, 7ed2fab, 0f1cc7b, 31c799b
- Brief: enables distributed crewmate dispatch without requiring all work to run on captain's machine

**Status in this test suite:** Currently failing (--remote flag absent in origin/main). Expected to clear when the remote-dispatch feature branch is reconciled and merged. A red result on this capability is not a blocker—it reflects expected divergence while the feature is being built on a parallel track.

## Beads Integration

**Capability:** Automatically link every crewmate spawn to a beads task, with Stage 4 (captain decision holds) and Stage 5 (resilience) support.

**Files:**
- `bin/fm-brief-hooks.d/beads.sh` — auto-link hook, validates bead id charset, creates or links to beads task
- `bin/fm-beads-resilience-lib.sh` — Stage 5 resilience layer for beads task-store backend (transactional safety)
- `bin/fm-bead-stamp.sh` — stamp each spawn with beads task correlation
- `bin/fm-spawn-hooks/beads` — hooks run before/after spawn to manage beads state
- `bin/fm-classify-lib.sh` — support for captain decision holds in beads (keyed open/resolved semantics)
- `docs/configuration.md` — beads backend configuration and backlog lifecycle
- `.tasks.toml` — tasks-axi markdown backend config for beads backlog

**Observable behavior:**
- Every spawn without `--beads <id>` auto-links to a new or matched beads task (no manual step)
- Captain decision holds in beads survive recovery and restart (`tasks-axi hold ... --kind captain`)
- Backlog queries work transparently (`bd ready`, `bd show`, `bd update`, `bd close`)
- Secondmate homes have isolated beads stores with inherited shared labels
- Open decisions are tracked durably in beads and recovered on startup

**References:**
- Commits: 613b284, 4b0e473, 6b093e2, 6bc3264, dcad2c6, e79cf63, 1245cdd, fe9c1c7, dc9f4b4
- Brief: makes firstmate's task tracking durable, enables captain-delegated decisions, and survives session restarts

## Fork-local Skills

**Capability:** Custom skills that extend firstmate's capabilities beyond upstream, installed in `.agents/skills/` and discoverable by firstmate's skill loader.

**Files:**
- `.agents/skills/` — fork-specific skills directory (not present in upstream)
- `.agents/skills/firstmate-orca/SKILL.md` — Orca backend integration
- `.agents/skills/herdr-navigation/SKILL.md` — Herdr lifecycle helpers
- `.agents/skills/night-ops-directive/SKILL.md` — away-mode supervision daemon
- `.agents/skills/coderabbit-pr-gate/SKILL.md` — PR review gate via CodeRabbit
- Other skills listed in `.agents/skills/` that are fork-specific

**Observable behavior:**
- `firstmate` can load skills from `.agents/skills/` (fork-local loader)
- Skills in `.agents/skills/*/SKILL.md` are discoverable and invocable
- Skill loader correctly routes fork skills and upstream skills
- `.claude/skills` symlink to `.agents/skills` works for IDE compatibility

**References:**
- Commits: various skill additions over fork history
- Brief: extends firstmate with capabilities not in upstream, all confined to `.agents/skills/` so they do not conflict with upstream

## Fork-origin Validation

**Capability:** Detect and flag when a clone is swapped (default branch is on upstream's line, not fork's) and refuse to proceed.

**Files:**
- `bin/fm-spawn.sh` — performs fork-origin check before dispatch
- `bin/fm-project-validate.sh` — validates fork vs upstream default branch

**Observable behavior:**
- Spawn refuses if project's default branch is on upstream/main (not trillium/firstmate)
- Error message clearly states the fork vs upstream issue
- Clone can be fixed by re-fetching and checking out fork's main

**References:**
- Commit: 57dc5d4
- Brief: prevents silent dispatch into upstream clones, catching config mistakes early

## Decision Hold Lifecycle (Beads-native)

**Capability:** Captain decision holds tracked natively in beads store with durable reconciliation on startup.

**Files:**
- `bin/fm-classify-lib.sh` — status_open_decisions_incremental for incremental decision scanning
- `bin/fm-session-start.sh` — displays OPEN DECISIONS section on every startup
- `.agents/skills/decision-hold-lifecycle/SKILL.md` — lifecycle and reconciliation procedure
- Beads store labels for decision state tracking

**Observable behavior:**
- `tasks-axi hold <id> --kind captain --reason "<reason>"` creates a captain hold (native beads)
- Holds appear in startup OPEN DECISIONS section
- Holds are marked resolved when captain responds (`tasks-axi close <id>`)
- Holds survive session restarts and secondmate transfers

**References:**
- Commits: 6bc3264, 6b093e2, dcad2c6
- Brief: enables captain to gate work with durable recorded decisions

## Beads Task-Store Backend

**Capability:** Use beads as the primary task/backlog store instead of markdown, with full Stage 4+5 resilience.

**Files:**
- `.tasks.toml` — tasks-axi configuration pointing to beads backend
- `bin/fm-backlog-handoff.sh` — safe backlog transfer between homes
- `bin/fm-backlog-receive.sh` — receive and integrate transferred backlog
- `bin/fm-beads-resilience-lib.sh` — Stage 5 transactional safety
- `docs/configuration.md` — backlog-backend configuration

**Observable behavior:**
- `task create "Title"` creates a bead in beads store, not markdown
- `task ready`, `task show <id>`, `task list` work transparently
- Backlog is durable and survives crashes within transaction boundaries
- Backlog transfers between homes work safely with Stage 5 resilience

**References:**
- Commits: 613b284, 4b0e473, 6b093e2
- Brief: replaces markdown backlog with durable transactional store

## Relay Integration

**Capability:** Respond to public mentions on X and Discord with dispatched work and durable public reply tracking.

**Files:**
- `.agents/skills/fmx-respond/SKILL.md` — mention classification, reply, and follow-up handling
- `bin/fm-x-lib.sh` — Relay mention parsing and reply context
- `bin/fmx-respond` — Relay mention handler (if present)
- `docs/configuration.md` — Relay activation and FMX_PAIRING_TOKEN

**Observable behavior:**
- Relay can be activated with `FMX_PAIRING_TOKEN` in `.env`
- Mentions wake the supervisor when Relay is active
- Replies and follow-ups are durable and tracked in state/
- Public commitment reconciliation before teardown

**References:**
- Various commits adding Relay support
- Brief: enables accepting work from X and Discord mentions with durable reply tracking

## Herdr Backend Support

**Capability:** Use Herdr as an alternative to tmux for crewmate lifecycle management.

**Files:**
- `bin/backends/herdr.sh` — Herdr backend adapter
- `bin/fm-spawn.sh` — `--backend herdr` support
- `.agents/skills/herdr-navigation/SKILL.md` — Herdr lifecycle helpers
- `docs/configuration.md` — Herdr backend configuration
- `docs/herdr-backend.md` — Herdr architecture and troubleshooting

**Observable behavior:**
- `fm-spawn.sh --backend herdr <task> <project>` succeeds
- Herdr lab is created for task isolation
- `bin/fm-crew-state.sh <id>` works with Herdr endpoints
- Recovery procedures work with Herdr-backed tasks

**References:**
- Various commits adding Herdr support
- Brief: provides alternative task isolation model beyond tmux

---

## Maintenance

When reconciling with upstream:

1. **Before merge:** run `tests/fork-features.sh` — it must fail if features are missing
2. **On conflict:** compare conflicted files against this manifest
3. **On silent drops:** this manifest shows which features are now broken
4. **After restore:** run `tests/fork-features.sh` again — it should pass

Every entry in this manifest is load-bearing.
Deleting an entry without removing the corresponding feature is a bug; removing a feature without updating this manifest is a regression that tests will catch.
