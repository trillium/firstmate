# Fork catches up with upstream

The fork's main was 86 upstream commits behind.
This merge makes upstream's main an ancestor of the fork again.

```mermaid
flowchart LR
  subgraph before["Before: fork main is behind"]
    direction LR
    B0["shared base 4a67799d"] --> BF["fork main<br/>191 fork-only commits"]
    B0 --> BU["upstream main<br/>86 commits the fork lacks"]
  end
  subgraph after["After: one merge commit"]
    direction LR
    A0["shared base 4a67799d"] --> AF["fork main"]
    A0 --> AU["upstream main 37e9a365"]
    AF --> AM(["merge commit<br/>behind upstream: 0"])
    AU --> AM
  end
  before --> after
```

## What the check shows

| Check | Result |
| --- | --- |
| Commits upstream has that this branch lacks (`git rev-list --count HEAD..upstream/main`) | 0 |
| Files that conflicted | 47 |
| Conflict markers left in the tree | none |
| `bin/fm-lint.sh` | clean |
| `bin/fm-doc-audience-check.sh` | ok |
| `bin/fm-test-run.sh --check-coverage` | ok, 12 serial shards |
