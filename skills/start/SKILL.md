---
name: start
description: Start the Loom autonomous development loop. Launches a tmux session that continuously reads tasks from a PRD or directive, dispatches parallel subagents, runs tests, and commits passing code. Accepts a prompt, source flags, or no arguments for PRD mode.
argument-hint: "[<prompt>] [github|linear|slack|notion|sentry <query>] [resume <dir>] [wt|worktree <bool>] [pr <bool>]"
disable-model-invocation: true
allowed-tools: Bash, Read, Write
---

# /loom:start

Launch the Loom autonomous development loop. You must `unset CLAUDECODE` before running the script so nested `claude` invocations work.

## Current State
- Branch: !`git branch --show-current 2>/dev/null || echo "(detached)"`
- Worktrees: !`git worktree list 2>/dev/null | grep -c "\.claude-worktrees" || echo "0"` active
- Loom sessions: !`tmux list-sessions 2>/dev/null | grep -c "^loom-" || echo "0"` running
- Last log: !`tail -3 .loom/logs/master.log 2>/dev/null || echo "(no logs)"`

All scripts are located via the plugin root path stored in `.loom/.plugin_root`. Read it first:

```bash
LOOM="$(cat .loom/.plugin_root)"
```

## Routing

Look at `$ARGUMENTS` and determine which case applies:

### Case 1: No arguments (`$ARGUMENTS` is empty)

**PRD directory pre-emption:** Before launching, check if `.loom/config.json` exists and its `prd` key points to a directory. If that directory contains multiple `.json` files, list them and ask the user which one to use. Then pass the selection as `--prd <file>` to `start.sh`. If only one `.json` file exists in the directory, pass it automatically. This handles the interactive case before handing off to the non-interactive script.

Check if you're in a loom worktree or branch already, or if there are logs from recent iterations that are still fresh (happened in last several hours and relate to the most recent commits or uncommitted working changes). If so, resume in the current branch:

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --resume
```

Otherwise start the loop:

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh"
```

### Case 2: `linear <query_or_url>`

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --linear "$REST"
```

Where `$REST` is everything after the word `linear`.

### Case 3: `github <query_or_url>`

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --github "$REST"
```

### Case 4: `issue <number>`

Shorthand for GitHub issue mode:

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --github "$NUMBER"
```

### Case 5: `slack <url>`

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --slack "$URL"
```

### Case 6: `notion <query_or_url>`

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --notion "$REST"
```

### Case 7: `sentry <query_or_url>`

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --sentry "$REST"
```

### Case 8: `resume <directory>`

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --resume "$DIR"
```

### Case 9: Arguments start with `-` (raw flags passthrough)

Pass flags through directly to `start.sh`:

```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" $ARGUMENTS
```

Example: `/loom:start --prd .docs/prds/features.json` → runs with a custom PRD path.

### Case 10: Arguments are plain text (a prompt)

Write the text to a file and pass it via `--prompt`:

```bash
printf '%s' '$ARGUMENTS' > .loom/.directive && LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" --prompt .loom/.directive
```

Examples:
- `/loom:start Fix all lint errors` → writes "Fix all lint errors" to `.loom/.directive`, then runs with `--prompt .loom/.directive`
- `/loom:start Refactor all callbacks to async/await` → same pattern

### How to tell the difference

1. If `$ARGUMENTS` is empty → Case 1
2. If `$ARGUMENTS` starts with `linear ` → Case 2
3. If `$ARGUMENTS` starts with `github ` → Case 3
4. If `$ARGUMENTS` starts with `issue ` → Case 4
5. If `$ARGUMENTS` starts with `slack ` → Case 5
6. If `$ARGUMENTS` starts with `notion ` → Case 6
7. If `$ARGUMENTS` starts with `sentry ` → Case 7
8. If `$ARGUMENTS` starts with `resume ` → Case 8
9. If `$ARGUMENTS` starts with `--` or `-` → Case 9
10. Otherwise → Case 10

## After launching

Report back to the user (substitute the actual project directory name):
- Attach to monitor: `tmux attach -t loom-<project>`
- Kill the loop: `tmux kill-session -t loom-<project>`
