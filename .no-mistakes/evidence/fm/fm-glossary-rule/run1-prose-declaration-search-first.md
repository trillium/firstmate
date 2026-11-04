## Run 1: prose 'Tools and stores' declaration (bare 'glossary' command), first prompt 'is Quillhaven something we own?'
Primary's tool calls, from its transcript:
TOOL {"command": "cat /Users/mini0/.claude/projects/-Users-mini0--no-mistakes-worktrees-0bf32a15afdb-01M6JQ285NG5NQMRD4ABQJN6SX/efc8df2d-f525-499b-a28f-ce97f21b8777/tool-results/hook-f23cf1dd-1298-4c46-a36d-457824d7cc2a-stdout.txt | tail -n +15", "description": "Read the rest of the persisted startup output"}
TOOL {"command": "bin/fm-session-start.sh 2>&1 | head -c 60000", "description": "Run the one-time session start digest", "timeout": 180000}
TOOL {"command": "glossary search Quillhaven 2>&1; echo \"---\"; projects search Quillhaven 2>&1", "description": "Look up Quillhaven in the glossary and projects stores"}
TOOL {"command": "glossary search quill 2>&1 | grep -v auto-backup; projects search quill 2>&1 | grep -v auto-backup; echo \"--- grep\"; grep -rli quillhaven ~/fm_home ~/code ~/projects \"$FM_HOME\" . 2>/dev/null | head -20; ls ~ | head -50", "description": "Broaden the search for Quillhaven across stores and local files", "timeout": 60000}
TOOL {"command": "which glossary projects; grep -n -i -C3 quillhaven /var/folders/d9/2d5w27z5775c_r1qcw57vzzr0000gn/T//fm-lab.OZELRS/fakebin/projects", "description": "Check which store CLIs are used and the Quillhaven match"}

Note: Claude's Bash tool reloaded the login profile, so the bare 'glossary' resolved to the host's real ~/.local/bin/glossary. It ran read-only searches only and added nothing, because the agent judged the fixture data unconfirmed. Runs 2-5 use absolute fixture paths.
