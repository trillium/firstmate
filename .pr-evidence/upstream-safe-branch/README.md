# Evidence: upstream-safe-branch

```mermaid
flowchart LR
  subgraph before[Fork main: 142 commits ahead, 231 files differ]
    A[fork edits to existing files] -->|conflict risk on every upstream sync| U[upstream/main]
  end
  subgraph after[This branch]
    B[upstream/main] --> C[+ new files only]
    B --> D[+ edits to files upstream has not touched since 4a67799d]
  end
```

Verification transcript (summary):

```
$ git merge --no-commit --no-ff upstream/main
Already up to date.
$ git diff upstream/main --stat | tail -1
 95 files changed (adds + clean edits only)
test run: 293 scripts; remaining failures also fail on a pristine upstream/main copy
          (macOS md5/-q and /tmp path noise) or pass on re-run (load-sensitive timing).
```
