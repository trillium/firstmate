# Dropped fork features (upstream-wins reconcile)
This file lists every fork-side path fully overwritten by upstream/main in this reconcile.
Reconcile base is fork main 9c1b17b6 merged with upstream/main 3eb5b633 using merge strategy `-X theirs`.
Merge-base is 53ecbc79 with 202 fork commits and 297 upstream commits.
Fork-only paths with no upstream change are kept automatically and are not listed here.
Blended paths where the merge result differs from upstream are kept partially and are not listed here.
Only paths where the merge result equals upstream/main (fork change fully dropped) are listed below.
Prior attempt branch fm/upstream-merge-branch at 0ff1ab03 was inventoried before this merge.
That branch is 108 commits behind current upstream/main and diverges by 502 paths, so it was not rebased directly.
Its strategy (upstream merge plus fork restores) informed the upstream-wins approach used here.
- `.agents/skills/afk/SKILL.md` - fork staleness auto-close wording from feat(watch): add staleness auto-close for idle ship tasks (#27) dropped because upstream supervision wording wins.
- `.agents/skills/decision-hold-lifecycle/SKILL.md` - fork beads-native captain holds from feat(decision-hold): add beads-native captain decision holds (Stage 4) (#36) dropped because upstream collapsed-tasks model wins.
- `.agents/skills/harness-adapters/SKILL.md` - fork old-structure adapter edits carried by Reconcile: merge upstream kunchenguid/firstmate into trillium fork dropped because upstream router plus references layout wins.
- `.agents/skills/quota-array-dispatch/SKILL.md` - fork completion-aware selection carried by Merge origin/main: reconcile diverged main (Option A) dropped because upstream spendPriority procedure wins.
- `.github/workflows/no-mistakes-required.yml` - fork self-gate removal from chore(gate): drop firstmate's own no-mistakes plus external-reviewer self-gate (#115) dropped because upstream attestation-bound gate wins.
- `.no-mistakes.yaml` - fork self-gate config removal from chore(gate): drop firstmate's own no-mistakes plus external-reviewer self-gate (#115) dropped because upstream intent-targeted validation config wins.
- `bin/fm-landed-lib.sh` - fork closed-bead landing predicate from fix(bin): gate closed-bead done on the real landing predicate (#134) dropped because upstream landing helper wins.
- `bin/fm-pr-check-migrate.sh` - fork watcher lock work from ci(pr-flow): improve watcher lock settlement and decouple merge from poll arming (#77) dropped because upstream deleted this helper.
- `bin/fm-pr-merge.sh` - fork CodeRabbit review gating from Gate merges on CodeRabbit's reviews API, not its status check (#125) dropped because upstream merge helper wins.
- `bin/fm-remote-entrypoint.sh` - fork beads store provisioning from feat(beads): provision and routinely sync the beads store (#121) dropped because upstream entrypoint hash wins.
- `bin/fm-x-lib.sh` - fork stat comment fix from docs(fm-stat-lib): correct inverted GNU stat -f failure-mode comments (#132) dropped because upstream Relay library wins.
- `docs/decision-hold-lifecycle.md` - fork beads hold doc from feat(decision-hold): add beads-native captain decision holds (Stage 4) (#36) dropped because upstream deleted this doc in the collapsed-tasks refactor.
- `docs/turnend-guard.md` - fork guard wording carried by Reconcile: merge upstream kunchenguid/firstmate into trillium fork dropped because upstream quiet supervision wording wins.
- `tests/fm-busy-adapter-wiring.test.sh` - fork explicit-model spawn assertion from fm-spawn.sh: require an explicit --model on every spawn (#141) dropped because upstream helper-plus-model layout wins.
- `tests/fm-calm-pi-extension.test.sh` - fork calm test change carried by Merge origin/main into local main (town-result superset) dropped because upstream calm test wins.
- `tests/fm-cmux-claude-composer-live-e2e.test.sh` - fork clobber-restore from fix(fm): restore fork behavior clobbered by upstream reconcile merge (#113) dropped because upstream live-harness guard layout wins.
- `tests/fm-gate-refuse.test.sh` - fork explicit-model assertion from fm-spawn.sh: require an explicit --model on every spawn (#141) dropped because upstream helper-plus-model layout wins.
- `tests/fm-grok-harness.test.sh` - fork explicit-model assertion from fm-spawn.sh: require an explicit --model on every spawn (#141) dropped because upstream helper-plus-model layout wins.
- `tests/fm-harness-liveness-drift-live-e2e.test.sh` - fork parlay-bypass guard from fix(tests): stop test spawns enrolling with the live parlay relay (#robots-4nkn) (#84) dropped because upstream live-harness guard layout wins.
- `tests/fm-remote-job-orphan-reap.test.sh` - fork clobber-restore from fix(fm): restore fork behavior clobbered by upstream reconcile merge (#113) dropped because upstream remote-job worker wins.
- `tests/fm-teardown-endpoint-safety.test.sh` - fork endpoint safety test carried by Reconcile: merge upstream kunchenguid/firstmate into trillium fork dropped because upstream teardown test wins.
