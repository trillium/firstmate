```mermaid
flowchart LR
  subgraph Before
    A[pi worker spawned in project with .mcp.json] --> B[Allow project MCP server dialog x N]
    B --> C[idles at 0 percent until Enter]
  end
  subgraph After
    D[pi worker spawned in project with .mcp.json] --> E[launched with --no-approve]
    E --> F[adapter blocks project servers, no dialog]
    F --> G[worker processes brief]
  end
```

Verified in a throwaway project with `pi --tui-mode regular`: without the flag the dialog appears; with `--no-approve` the pane shows "MCP: 1 server enabled (1 blocked by project trust)" and the server never started.
