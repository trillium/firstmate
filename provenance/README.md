# Fork-feature provenance

This directory proves, end to end, a mechanism that guarantees the captain's fork-only firstmate features survive fast-moving upstream merges, or a check fails loudly.
It currently registers 16 fork-only features, not yet the full fork surface.
It converges the two research scouts under `data/prov-research/` and `data/prov-approvaltests/`: a fork-namespaced register that anchors each feature to its code, plus a golden-master behavioral proof per feature.

Everything lives under the fork-owned `provenance/` and `tests/provenance/` namespaces that upstream firstmate never writes, so an upstream merge can never silently clobber the register or the approved snapshots.

## The guarantee

For every registered fork feature, `provenance/check.sh`:

1. Verifies each anchor's `path` and optional `symbol` still exist.
   A vanished path or symbol is a FAIL: the deletion tripwire.
2. Recomputes each anchor's signature.
   A signature that no longer matches is a WARN, not a FAIL, because upstream edits legitimately shift code without deleting the feature.
3. Runs the feature's behavioral `test`, scrubs volatile tokens, and diffs the result against the approved golden-master snapshot.
   A mismatch, or a missing snapshot, is a FAIL: the feature's behavior changed or is gone.

The guard exits nonzero on any FAIL, so CI blocks the merge and a human re-verifies the named feature.
The behavioral proof is the load-bearing guarantee that a feature still works as approved; the anchor is the cheap locator and deletion tripwire that a behavioral test alone cannot provide.

## The register format

`provenance/register.toml` holds one `[[feature]]` block per fork feature:

- `id` is a stable slug that also names `tests/provenance/<id>/`.
- `story` is the user-story spec in human prose, reviewed in pull requests like any doc.
- `test` is a command whose scrubbed combined output plus exit code is the golden master.
- `[[feature.anchor]]` gives one or more locators, each with a `path`, an optional `symbol` (a bash function name), and a `sig` fingerprint of the anchored region.
  Omit `symbol` to anchor a whole file for existence only.

Adding a feature is one `[[feature]]` block plus one snapshot.
The snapshot and signatures are generated, never hand-written.

## Usage

```
provenance/check.sh          verify every feature; exit nonzero on any FAIL
provenance/check.sh --regen  re-bless: (re)write snapshots AND recompute sigs
provenance/check.sh --help   usage
```

Run `--regen` only after a human has reviewed the diff and confirmed each story still holds; it is the deliberate re-blessing step, never something CI runs.

## The scrubber and the fingerprint

`provenance/lib.sh` holds the two helpers the design turns on.

`scrub_volatile` replaces nondeterministic tokens (absolute paths under a throwaway home, tmpdirs, timestamps, long numeric and hex ids) with stable placeholders before the diff, so snapshots are deterministic and CI-safe.
It is the single most important helper for keeping golden masters from going flaky.

`provenance_fingerprint` is the anchor drift signature, and it is a deliberate one-function swap point.
Today it is a clearly-labeled PLACEHOLDER: it strips comments and blank lines, collapses whitespace, and hashes the result.
The research recommends a normalized `tree-sitter-bash` AST fingerprint (node kinds plus token text, with whitespace, position, and comments stripped) so reformatting and edits elsewhere in the file never trip the alarm.
That grammar is not wired in yet, so the placeholder stands in.
Swapping to the real fingerprint is a change to `provenance_fingerprint` alone; the register format, `check.sh`, and every snapshot stay put.
Because drift is a WARN rather than a FAIL, the placeholder's coarser sensitivity is safe for now.

## Deferred: scaling and CI wiring

The following are out of scope for the current register and are described here rather than built.

- Scaling from the current 16 features to the full fork surface is more register entries and more snapshots, no new machinery.
  A proper TOML parser should replace `provenance_parse_register` once the register grows past a handful of entries.
- Two-tier CI: the cheap deterministic tier here (help text, exit codes, scrubbed metadata shape) gates every pull request, while an expensive tier of real agent spawns runs nightly and never blocks a merge.
  firstmate's existing smoke-versus-e2e test split maps onto exactly this two-tier structure.
- A received-versus-approved reviewer surface, in the spirit of `cargo insta review`, would make re-blessing a snapshot a reviewed action rather than a raw `--regen`.

## Tests

`tests/provenance-check.test.sh` drives `check.sh` through its CLI against an isolated fixture tree, asserting green on an intact tree, red on a deleted anchor, red on a behavior change, and WARN-not-FAIL on signature drift.
It touches no real `bin/` script and no real snapshot, using the `FM_PROV_ROOT`, `FM_PROV_REGISTER`, and `FM_PROV_SNAP_DIR` overrides.

## Maintaining this file

Keep this file to the format, the guarantee, and the deferred plan.
Exact flags and mechanics belong in each script's header and `--help`, not here.
Prefer rewriting an entry over appending a new one, and keep one sentence per line.
