## Run 5: declaration only in inherited data/captain-shared.md (secondmate layout, prime's 'Tools and stores' item-2 shape), term missing
### data/captain-shared.md
# Shared captain preferences (inherited by every secondmate)

**Tools and stores - know them, keep current (every home).** Each store is its own CLI at a fixed path.
1. `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/projects search <word>` lists projects.
2. **Glossary first, every time.** Before asking the captain what an unfamiliar name means, run `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/glossary search <word>`. Not there: find it in projects, then add it (`/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/glossary q "<Term>" "<body>"`, then `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/glossary label add <id> term`).
### Pane transcript
 ▐▛███▛█   Claude Code v2.1.309
▝▜██████▀  Opus 5.5 · Claude API
 ▝▝   ▝▝   ~/.no-mistakes/worktrees/0bf32a15afdb/01M6JQ285NG5NQMRD4ABQJN6SX
❯ Do your normal session start for this home (FM_HOME) first, and use only this home's stores. Then: Tessellate is acting up after the update - what is it and where does it live? One line, no fixes.
  Read 1 file, ran 2 shell commands
⏺ Glossary missed, projects found it; adding the entry as the home's preferences require.
  Ran 2 shell commands
⏺ Captain, Tessellate ("tess") is your tile-layout window manager config for the MacBook, and it lives at github.com/trillium/tessellate (it's related to your dotfiles; I've added it to the glossary,
  which didn't have it yet).
✻ Baked for 33s · done 11:46 PM
                                                                                                                                                       Update available! Run: brew upgrade claude-code
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ scout why Tessellate broke after the update
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
### Store invocation log
23:46:14 glossary search Tessellate
23:46:14 projects search Tessellate
23:46:19 glossary q Tessellate Tile-layout window manager config for the MacBook. Lives at github.com/trillium/tessellate. Aliases: tess. Related: dotfiles (projects pr-4); projects entry pr-23.
23:46:24 glossary label add gl-002 term
23:46:24 glossary search Tessellate
### Glossary store after
gl-002 Quillhaven Self-hosted RSS-to-podcast bridge (Trillium's). Aliases: quill haven, QH. Lives on the home NAS at nas.lan:8711; repo github.com/trillium/quillhaven; projects-store id pr-17. Related: pr-9 podcasts.
gl-002 Tessellate Tile-layout window manager config for the MacBook. Lives at github.com/trillium/tessellate. Aliases: tess. Related: dotfiles (projects pr-4); projects entry pr-23.
