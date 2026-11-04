## Run 4 (control): captain.md declares no glossary store - no glossary lookup
### data/captain.md
# Captain preferences

**Tools and stores.** This home's project store is a plain CLI: `/var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/projects search <word>`.
Keep replies short.
### Pane transcript
 ▐▛███▛█   Claude Code v2.1.309
▝▜██████▀  Opus 5.5 · Claude API
 ▝▝   ▝▝   ~/.no-mistakes/worktrees/0bf32a15afdb/01M6JQ285NG5NQMRD4ABQJN6SX
❯ Do your normal session start for this home (FM_HOME) first, and use only this home's stores. Then: is Brindlemoor something we run? One line, no fixes.
  Ran 2 shell commands
⏺ Captain, no: Brindlemoor isn't in this home's project store, and this home has no project list on file.
✻ Brewed for 21s · done 11:42 PM
                                                                                                                                                       Update available! Run: brew upgrade claude-code
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
### Primary's tool calls
TOOL {"command": "echo \"FM_HOME=$FM_HOME\"; bin/fm-session-start.sh 2>&1 | head -c 20000", "description": "Run session start for this home"}
TOOL {"command": "\"$FM_HOME/fakebin/projects\" search Brindlemoor; echo \"exit=$?\"", "description": "Search this home's project store for Brindlemoor"}
### Store invocation log
23:42:54 projects search Brindlemoor
