## Run 2: declared glossary (prose list item, no Glossary heading), term missing
### data/captain.md
# Captain preferences

**Tools and stores.** This home's bead stores are plain CLIs at fixed paths:
1. Glossary store: `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/glossary search <word>` to look a name up; add a missing term with `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/glossary q "<Term>" "<body>"` (body: what it is, aliases, where it lives, related) then `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/glossary label add <id> term`.
2. Projects store: `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/projects search <word>`.

### Pane transcript
 ▐▛███▛█   Claude Code v2.1.309
▝▜██████▀  Opus 5.5 · Claude API
 ▝▝   ▝▝   ~/.no-mistakes/worktrees/0bf32a15afdb/01M6JQ285NG5NQMRD4ABQJN6SX
❯ Quillhaven stopped posting new episodes. Before anything else, just tell me what it is and where it lives, no fixes yet.
  Read 1 file, listed 3 directories, ran 1 shell command
⏺ Captain, I found Quillhaven in your projects list but not in your glossary, so I'm adding a glossary entry now.
  Ran 1 shell command
⏺ Captain, Quillhaven is your self-hosted service that turns RSS feeds into podcast feeds. People also call it "quill haven" or "QH".
  Where it lives:
  - Running service: your home NAS at nas.lan:8711.
  - Code: https://github.com/trillium/quillhaven
  - Related: your projects list links it to a "podcasts" entry, but that entry isn't in the list, so I don't know what it covers.
  There's no local copy of Quillhaven in this home yet. Your projects list is my only source for all of this. I haven't checked the NAS or the repo, so I can't yet confirm it's running at that
  address.
  Quillhaven wasn't in your glossary, so I added it there with the details above.
  As you asked, I haven't started any fix. When you want to look into why new episodes stopped, I'd start by finding out whether the service on the NAS is still up and still reading its feeds.
✻ Cooked for 1m 6s · done 11:34 PM
                                                                                                                                                       Update available! Run: brew upgrade claude-code
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ go ahead and investigate why episodes stopped
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)

### Glossary store invocation log
23:34:23 glossary search Quillhaven
23:34:23 glossary search QH
23:34:30 glossary q Quillhaven Self-hosted RSS-to-podcast bridge (Trillium's). Aliases: quill haven, QH. Lives on the home NAS at nas.lan:8711; repo github.com/trillium/quillhaven; projects-store id pr-17. Related: pr-9 podcasts.
23:34:30 glossary label add gl-002 term
23:34:30 glossary search Quillhaven

### Glossary store contents after
gl-002 Quillhaven Self-hosted RSS-to-podcast bridge (Trillium's). Aliases: quill haven, QH. Lives on the home NAS at nas.lan:8711; repo github.com/trillium/quillhaven; projects-store id pr-17. Related: pr-9 podcasts.
