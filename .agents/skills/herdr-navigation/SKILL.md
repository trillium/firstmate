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

## Open a pane relative to yourself

```bash
# Split to the right (new pane appears to your right)
herdr pane split --current --direction right

# Split below (new pane appears below you)
herdr pane split --current --direction down

# Split with a specific command running in the new pane
herdr pane split --current --direction right --cwd "$PWD"

# Split and focus the new pane
herdr pane split --current --direction right --focus
```

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
