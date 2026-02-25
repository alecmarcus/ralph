---
name: status
description: Show the current Loom run summary — iteration count, story progress, active subagents, and recent activity.
argument-hint: ""
disable-model-invocation: true
allowed-tools: Bash, Read
---

# /loom:status

Show the current Loom run summary.

## Current State
- Sessions: !`tmux list-sessions 2>/dev/null | grep "^loom-" || echo "(none)"`
- PID: !`cat .loom/.pid 2>/dev/null || echo "(none)"`

All scripts are located via the plugin root path stored in `.loom/.plugin_root`. Read it first:

```bash
LOOM="$(cat .loom/.plugin_root)"
```

Then run the status reporter:

```bash
LOOM="$(cat .loom/.plugin_root)" && "$LOOM/scripts/loom-status.sh"
```

Display the output to the user as-is.
