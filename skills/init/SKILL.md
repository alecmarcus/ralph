---
name: init
description: Initialize a project for Loom. Creates the .loom/ directory with template files and injects the Loom section into CLAUDE.md.
argument-hint: ""
context: fork
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Glob
---

# /loom:init

First-time project setup for Loom. Creates the `.loom/` directory structure, writes template files, and injects the Loom rules section into `CLAUDE.md`.

## Prerequisites

Check that:
1. The current directory is a git repository (`git rev-parse --git-dir`)
2. `.loom/` does not already exist (if it does, tell the user the project is already initialized and exit)

## Step 1: Create directory structure

```bash
mkdir -p .loom/logs
```

## Step 2: Write template files

Write these files only if they don't already exist.

### `.loom/.gitignore`

```
logs/
.stop
.pid
.directive
.piped_directive
.iteration_marker
.header
.header-pane.sh
.iter_state
.plugin_root
*.log

# Make prd.json local by default. Can be checked in if you choose.
prd.json
```

### `.loom/prd.json`

```json
{
  "project": "my-project",
  "description": "Replace this with your project description.",
  "gates": [
    {
      "id": "gate-1",
      "name": "Example Gate — replace with your own",
      "priority": "P0",
      "status": "pending",
      "stories": ["EXAMPLE-001"]
    }
  ],
  "stories": [
    {
      "id": "EXAMPLE-001",
      "title": "Example story — delete this and add your own",
      "gate": "gate-1",
      "priority": "P0",
      "severity": "major",
      "status": "pending",
      "files": ["src/example.ts"],
      "description": "Describe what needs to be built or changed.",
      "acceptanceCriteria": [
        "First acceptance criterion",
        "Second acceptance criterion"
      ],
      "actionItems": [
        "First implementation step",
        "Second implementation step"
      ],
      "blockedBy": [],
      "details": {}
    }
  ]
}
```

### `.loom/status.md`

```markdown
# Loom Status

No iterations run yet.
```

## Step 3: Inject CLAUDE.md section

If `CLAUDE.md` exists in the project root, check if it already contains the `<!-- loom:begin -->` marker. If not, append the Loom section. If `CLAUDE.md` doesn't exist, create it with the section.

If the markers already exist, replace the content between `<!-- loom:begin -->` and `<!-- loom:end -->` with the updated section.

### Loom section content

```markdown
<!-- loom:begin -->
## Loom — Autonomous Development Loop

Loom runs Claude Code in a continuous loop: read tasks from a PRD, dispatch parallel subagents, run tests, commit green code, repeat.

```
.loom/               # Autonomous dev loop — dispatches parallel subagents from a PRD
├── prd.json         # Structured stories with gates (P0/P1/P2), deps, acceptance criteria
├── status.md        # Current iteration state (read at start, written at end of each cycle)
└── logs/            # Per-iteration logs + master.log
```

### Rules for success

**Stories must be atomic.** Each story is executed by a single subagent in one iteration (~15-30 min). If it can't be done in one shot, split it. Coupled work (model + migration + route) stays together; unrelated work does not.

**Acceptance criteria must be machine-verifiable.** Not "it works" but "POST /api/x returns 200 with a JWT". If you can't write a test for it, Loom can't verify it.

**Parallelism requires file isolation.** Stories that touch the same files cannot run in the same batch. Set `blockedBy` for true data dependencies; leave it empty otherwise to maximize parallelism.

**Green tests are a hard gate.** Loom never commits failing code. Test failures are recorded in status.md and become top priority for the next iteration. After 3 failed fix attempts within one iteration, Loom stops and records the state.

**Context is the scarcest resource.** Read prd.json in jq waves of 10. Never cat entire files. Use dedicated tools (Read, Grep, Glob) instead of shell commands. status.md is the only continuity across loop restarts — write it thoroughly.

**Search before building.** Subagents must search the codebase before assuming something is missing. Reimplementing existing code is a common failure mode.

**Scope is sacred.** Implement only the assigned story. Do not "fix" adjacent code, add unrequested features, or refactor code that seems inconsistent with other specs.
<!-- loom:end -->
```

## Step 4: Report

Tell the user:

```
Loom initialized.

Created:
  .loom/prd.json       Template PRD (edit or generate with /loom:prd)
  .loom/status.md      Initial status
  .loom/.gitignore     Keeps logs and temp files out of git
  CLAUDE.md            Loom rules section injected

Next steps:
  1. Generate a PRD:     /loom:prd spec.md
  2. Or give it a task:  /loom:start Fix all lint errors
  3. Or start the loop:  /loom:start
```

Note: The plugin root path (`.loom/.plugin_root`) will be written automatically when you restart Claude Code in this project. This is handled by the SessionStart hook.
