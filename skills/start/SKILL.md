---
name: start
description: Launch the Loom orchestrator. Reads open GitHub issues, validates them, dispatches coding agents, runs review cycles, and ships PRs. Optionally scope with a query.
argument-hint: "[<query>] — e.g., 'all auth issues', 'issue #42', or blank for everything"
allowed-tools: Read, Agent, Bash, Grep, Glob, Skill
---

# /loom:start

## Launch

Activate orchestrator mode and load the template.

```
1. Create the orchestrator marker (enables enforcement hooks):
   echo "$PWD" | shasum -a 256 | cut -c1-16 | xargs -I{} touch /tmp/loom-orchestrating-{}
2. Start the protocol enforcement loop — invoke the /loop skill:
   /loop 10 PROTOCOL ENFORCEMENT — MANDATORY CHECKPOINT. Do ALL three checks: [1] STATE MACHINE: For every in-flight issue, state where it is in the state machine (coded / reviewed / arbitrated / converged / verified / shipped) and what your NEXT action must be. If an issue is past coder and has not been through reviewer → arbiter → [fix loop], you are behind. Do not push or create PRs until the full cycle completes. [2] REJECTED FINDINGS: Have any arbiter verdicts produced rejected findings since the last checkpoint? If yes, have you triaged ALL of them? Every actionable rejected finding must be either overruled (accepted and sent to coder) or filed as a new GitHub issue. List any pending un-triaged rejections. No actionable finding goes unaddressed. [3] PR COMMENTS: Do any open PRs have unresolved comments? If yes, each comment must get the full treatment: reviewer → arbiter loop on the comment, respond in-thread with references, then resolve/hide. Do NOT skip to verification or shipping with unresolved comments. [4] LOCAL CI: Have you pushed anything since the last checkpoint? Did local CI pass BEFORE every push? This is a hard requirement — no code is ever pushed without local CI passing first. If you are about to push, run CI now. If you pushed without running CI, you have violated the protocol. [5] CONTEXT INTEGRITY: Have you been compacted since the last checkpoint? If you cannot recall the full state machine or your in-flight issue states feel fuzzy, re-read ${CLAUDE_PLUGIN_ROOT}/templates/orchestrator.md NOW. [6] MEMORY: When did you last read from Vestige? When did you last write to Vestige? If you have completed a wave, review cycle, or verification since your last write, you are behind — write learnings NOW via smart_ingest. If you are about to dispatch and haven't searched Vestige for relevant context, search NOW.
3. Read `${CLAUDE_PLUGIN_ROOT}/templates/orchestrator.md`
4. The contents ARE your instructions. Execute them.
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
