# Claude setup-token worker pin: before and after

## Before

```mermaid
flowchart LR
  A[config/claude-account<br/>ordinary or config dir] --> B[pinned launch:<br/>env -u CLAUDE_CODE_OAUTH_TOKEN ...]
  B --> C[claude worker<br/>stored login only]
  D[raw launch with<br/>CLAUDE_CODE_OAUTH_TOKEN=...] -->|refused under a pin| X[no token worker]
  D -->|unpinned: no adapter wiring| E[bare claude]
```

## After

```mermaid
flowchart LR
  A[config/claude-account<br/>token:/abs/path 0600 file] --> V{validate file<br/>missing / empty / non-0600 refuse}
  V --> S{claude auth status<br/>reports oauth_token}
  S -->|yes| B[pinned launch:<br/>env -u shed vars -u CLAUDE_CONFIG_DIR<br/>fm-claude-token-exec.sh FILE claude ...]
  B --> H[helper reads file,<br/>exports CLAUDE_CODE_OAUTH_TOKEN<br/>for that process only]
  H --> C[claude worker<br/>normal adapter wiring, hooks, signals]
  B -. argv / launch file / meta / status / digest .-> N[path and account=token:basename only,<br/>never the token]
  R[relaunch, secondmate account file, raw command] --> A
```

## Test evidence

`tests/fm-worker-account.test.sh`: `# all fm-worker-account tests passed`, including the five new `test_token_pin_*` and relaunch/helper cases, each scanning every record for the token sentinel.
