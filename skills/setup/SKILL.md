---
name: setup
description: Set up Loom integrations by reading and executing setup guides. Covers Playwright, mobile testing, GitHub issues, Linear, and more.
argument-hint: "<topic>"
context: fork
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task
---

# /loom:setup

Set up Loom integrations. Guides are bundled with the skill — read the index, match the user's query, read the matched guide, and execute it step by step.

## Arguments

The query is everything the user typed after `setup` (available as `$ARGUMENTS`). Examples:

- `/loom:setup playwright`
- `/loom:setup mobile testing`
- `/loom:setup github issues`
- `/loom:setup how do I run loom on a large feature`
- `/loom:setup from my product specs`
- `/loom:setup sentry`

If the query is empty or `help`, show the available guides (from Step 1) and exit.

## Step 1: Read the index

Read the guide index from the skill directory. Find the skill root by reading `.loom/.plugin_root`:

```
$(cat .loom/.plugin_root)/skills/setup/guides/index.md
```

For local installs (no `.plugin_root`), try:

```
.claude/skills/loom-setup/guides/index.md
```

This file contains two tables listing all available guides, their file paths, and descriptions.

## Step 2: Match the request

Parse the index and match the query to the most applicable guide. Match on:

1. **Exact file name** — e.g., `playwright` matches `validation/playwright.md`
2. **Keyword in description** — e.g., `mobile testing` matches `validation/mobile-mcp.md` or `validation/mobile-agent-device.md`
3. **Semantic match** — e.g., `how do I work from github issues` matches `github-issues.md`

### If multiple guides match

Present the matches and ask which one to use. For example, `mobile` could match both `validation/mobile-mcp.md` and `validation/mobile-agent-device.md`. If there are differences, explain them.

### If nothing matches

Show the full index and suggest the closest match.

### If the query is empty or `help`

Show the full index and exit.

## Step 3: Read the guide

Read the matched guide file from the same `guides/` directory:

```
$(cat .loom/.plugin_root)/skills/setup/guides/<relative-path>
```

Or for local installs:

```
.claude/skills/loom-setup/guides/<relative-path>
```

## Step 4: Execute the guide

Read the guide content and execute it step by step. The guide contains imperative instructions — follow them in order:

- Run prerequisite checks
- Install packages and configure MCP servers
- Modify project files (`.mcp.json`, `CLAUDE.md`, etc.)
- Run verification steps
- Report results

Adapt to the current project context. For example, if the guide says to add a test script to `package.json` but the project uses `pyproject.toml`, adapt accordingly.

## Rules

- **Execute, don't just display.** The user wants the setup done, not a summary of what to do.
- **Verify each step.** Run verification commands from the guide and report pass/fail.
- **Stop on failure.** If a prerequisite check fails or an install command errors, stop and report the issue rather than continuing blindly.
- **Be specific about what changed.** After setup, summarize what was installed, configured, or modified.
