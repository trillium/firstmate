---
name: herdr-navigation
description: Herdr workspace navigation for agents — how to find your own pane, open panes in a direction, and read or send to other panes.
user-invocable: false
metadata:
  internal: true
---

# herdr-navigation

You are running inside a herdr pane. Your pane ID is in the environment as `$HERDR_PANE_ID`. This skill covers how to navigate, open new panes, and interact with neighboring panes.

## Your own position

```bash
# Who am I?
herdr pane current --current

# Get full layout context (your position in the workspace grid)
herdr pane layout --current
```

Your pane ID is also available as `$HERDR_PANE_ID` (injected by fm-spawn). Use either.

## Open a pane and run a command in it

The common task: split a pane and launch a command in the new one.

```bash
# Split to the right without stealing focus; capture the new pane id
NEW=$(herdr pane split --current --direction right --ratio 0.5 --no-focus | jq -r '.result.pane.pane_id')
# Run a command in the newly created pane
herdr pane run "$NEW" tail -f /path/to/file
```

The JSON output shape is `{result: {pane: {pane_id, workspace_id, tab_id, ...}}}` — extract `.result.pane.pane_id`.

## Open a pane relative to yourself

```bash
# Split to the right (new pane appears to your right)
herdr pane split --current --direction right

# Split below (new pane appears below you)
herdr pane split --current --direction down

# Split with a specific cwd (the new pane is an empty shell; use herdr pane run to start a command)
herdr pane split --current --direction right --cwd "$PWD"

# Split with a custom split proportion
herdr pane split --current --direction right --ratio 0.6

# Split and focus the new pane
herdr pane split --current --direction right --focus

# Split without focus (new pane opens but stays in background)
herdr pane split --current --direction down --no-focus

# Split with environment variables set for the new shell
herdr pane split --current --direction right --env DEBUG=1 --env LOG_LEVEL=trace
```

## Run a command in an existing pane

```bash
# Launch a command in a specific pane (clean way vs send-text)
herdr pane run "$PANE_ID" echo hello
herdr pane run "$PANE_ID" tail -f /var/log/syslog
herdr pane run "$PANE_ID" bash -c "cd /tmp && ls -la"
```

`herdr pane run` is preferred for launching commands; `send-text` and `send-keys` type into whatever is already running.

## Find neighboring panes

```bash
# What's to my right?
herdr pane neighbor --direction right --current

# What's below me?
herdr pane neighbor --direction down --current

# What's to my left?
herdr pane neighbor --direction left --current
```

`neighbor` returns the neighbor's pane ID if one exists, or an error if the edge is empty.

## Read another pane's content

```bash
# Read the last 20 lines of a neighboring pane
NEIGHBOR=$(herdr pane neighbor --direction right --current --json | jq -r '.pane_id')
herdr pane read "$NEIGHBOR" --lines 20

# Read with different snapshot sources: visible|recent|recent-unwrapped|detection (default: recent)
herdr pane read "$NEIGHBOR" --lines 20 --source visible

# Read with ANSI color formatting (default: text)
herdr pane read "$NEIGHBOR" --lines 20 --format ansi
```

## Send text or keys to another pane

```bash
# Send a command to run in a neighboring pane
herdr pane send-text "$NEIGHBOR" "echo hello"

# Send a key sequence
herdr pane send-keys "$NEIGHBOR" Enter
```

## List all panes in your workspace

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

## Move yourself to a new tab

```bash
# Move this pane to a new tab (opens it as the only pane in a fresh tab)
herdr pane move "$HERDR_PANE_ID" --new-tab --label "my-work"
```

## Rules

- Always use `--current` (or `$HERDR_PANE_ID`) rather than hardcoding a pane ID — your ID is stable for your session but not across respawns.
- `herdr pane split` creates a NEW shell in the new pane; the new pane is empty until you send it commands or run it with `--cwd`.
- If `herdr` is not on PATH, check `~/.local/bin/herdr` or ask firstmate.
