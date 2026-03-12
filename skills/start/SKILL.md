---
name: start
description: Launch the Loom orchestrator. Reads open GitHub issues, validates them, dispatches coding agents, runs review cycles, and ships PRs. Optionally scope with a query.
argument-hint: "[<query>] — e.g., 'all auth issues', 'issue #42', or blank for everything"
disable-model-invocation: true
allowed-tools: Read, Agent, Bash, Grep, Glob
---

# /loom:start

## Launch

Activate orchestrator mode and load the template.

```
1. Create the orchestrator marker (enables enforcement hooks):
   echo "$PWD" | shasum -a 256 | cut -c1-16 | xargs -I{} touch /tmp/loom-orchestrating-{}
2. Read `${CLAUDE_PLUGIN_ROOT}/templates/orchestrator.md`
3. The contents ARE your instructions. Execute them.
```

### Scoping

If `$ARGUMENTS` is provided, it's a natural-language query to scope which issues the orchestrator works on:
- `"all open issues about auth"` → filter polled issues to auth-related ones
- `"issue #42 and its dependencies"` → work on #42 and anything it depends on
- `"everything"` or empty → work on all open issues

Pass the query to the orchestrator as a scoping directive alongside the template.

### Template Loading

The orchestrator template references other templates (`coder.md`, `reviewer.md`, `arbiter.md`, `validator.md`). Read each from `${CLAUDE_PLUGIN_ROOT}/templates/` when the orchestrator instructions tell you to.

### Memory

Before starting, initialize memory context:

```
Search Vestige for: "<project-name> orchestrator patterns conventions"
Include any relevant results in your working context.
```

### No tmux, No Background Script

The orchestrator IS the current Claude session. There is no tmux, no background loop, no iteration watcher. You execute the orchestrator protocol directly in this session.
