---
name: start
description: Start the Loom autonomous development loop. Launches a tmux session that continuously reads tasks from a PRD or directive, dispatches parallel subagents, runs tests, and commits passing code. Accepts a prompt, source flags, or no arguments for PRD mode.
argument-hint: "[<prompt>] [prd <path>] [github|linear|slack|notion|sentry <query>] [resume <dir>] [wt|worktree <bool>] [pr <bool>]"
disable-model-invocation: true
allowed-tools: Bash, Read, Write
---

# /loom:start

## Current State
- Branch: !`git branch --show-current 2>/dev/null || echo "(detached)"`
- Worktrees: !`git worktree list 2>/dev/null | grep -c "\.claude-worktrees" || echo "0"` active
- Loom sessions: !`tmux list-sessions 2>/dev/null | grep -c "^loom-" || echo "0"` running
- Last log: !`tail -3 .loom/logs/iterations.log 2>/dev/null || echo "(no logs)"`

## start.sh

The launch script lives in the plugin. Before reading the path, ensure `.plugin_root` points to the current installed version:

```bash
REGISTRY="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$REGISTRY" ] && command -v jq &>/dev/null; then
  LOOM=$(jq -r '.plugins | to_entries[] | select(.key | startswith("loom@")) | .value[0].installPath // empty' "$REGISTRY" 2>/dev/null)
  [ -n "$LOOM" ] && [ -d "$LOOM" ] && echo "$LOOM" > .loom/.plugin_root
fi
LOOM="$(cat .loom/.plugin_root)"
```

Then invoke as: `unset CLAUDECODE && "$LOOM/scripts/start.sh" [FLAGS]`

`unset CLAUDECODE` is required so nested `claude` invocations work.

### Available script flags

| Flag | Value | Description |
| --- | --- | --- |
| `--prompt` | text or file path | Run with inline text or file as directive |
| `--prd` | file or directory | PRD path (overrides `.loom/config.json`) |
| `--linear` | query, ticket ID, or URL | Fetch from Linear, implement, update ticket |
| `--github` | query, issue number, or URL | Fetch from GitHub, implement, close issues |
| `--slack` | permalink URL | Fetch Slack message context, implement |
| `--notion` | URL or search query | Fetch Notion page, implement |
| `--sentry` | URL or search query | Fetch Sentry issue, fix the error |
| `--resume` | path or branch (optional) | Reuse existing worktree (default: current dir) |
| `--worktree` | `true`/`false` | Git worktree isolation (default: on) |
| `--pr` | `true`/`false` | Push + open PR after loop (default: on) |
| `--preview` | — | Analyze one iteration without executing |
| `--max-iterations` | N | Max loop iterations (default: 500) |
| `--timeout` | seconds | Per-iteration timeout (default: 10800) |
| `--max-failures` | N | Consecutive failures before halt (default: 3) |
| `--session-name` | name | Custom tmux session name |

Sources can be combined: `--linear PHN-42 --github 13 --prompt "Also fix lint"`.

Without any source flag, runs in **PRD mode** (reads `prd.json`).

## Argument → flag routing

**Parse `$ARGUMENTS`** to build the flag string for `start.sh`:

| Argument pattern | Maps to |
| --- | --- |
| `linear <rest>` | `--linear "$REST"` |
| `github <rest>` | `--github "$REST"` |
| `issue <number>` | `--github "$NUMBER"` |
| `slack <rest>` | `--slack "$REST"` |
| `notion <rest>` | `--notion "$REST"` |
| `sentry <rest>` | `--sentry "$REST"` |
| `prd <rest>` | `--prd "$REST"` |
| `resume <dir>` | `--resume "$DIR"` or `--resume` if $DIR was omitted (script will default to CWD) |
| starts with `-` | passthrough — pass `$ARGUMENTS` directly |
| any other text | write to `.loom/.directive`, pass `--prompt .loom/.directive` |
| empty | no flags (PRD mode) — but see **Decision logic** below |

**Source queries** are passed to the corresponding MCP, so they should be preserved as plain language. Users may mix directive-style instructions with a query. If this happens, semantically separate the query from the directive. Preserve the content of both. Pass the query to the source flag value, write the directive to `.loom/.directive`, then pass `--prompt .loom/.directive`.

Example:
- Input: `/start find all github issues about security, figure out if there are any blocking sequences, execute accordingly with maximum parallelization. one issue per agent`
- Query: `issues about security` → `--github "issues about security"`
- Directive: `read all issues, identify blocking sequences, execute in parallel with 1 agent per issue` → written to `.loom/.directive`, passed as `--prompt .loom/.directive`

**Modifiers** can appear anywhere in `$ARGUMENTS`. Extract them before applying the primary routing above.

| Modifier | Flag | Default (bare keyword) |
| --- | --- | --- |
| `wt [<bool>]` | `--worktree` | `true` |
| `worktree [<bool>]` | `--worktree` | `true` |
| `pr [<bool>]` | `--pr` | `true` |

## Decision logic

Before launching, apply these checks in order:

### 1. PRD directory disambiguation (no-args mode only)

When `$ARGUMENTS` is empty and no explicit `--prd` flag will be passed:

1. Check if `.loom/config.json` exists and use `jq` to read the `prd` key
2. If it points to a **file**, pass it as `--prd <file>`
3. If it points to a **directory** with one `.json` file, pass that file automatically
4. If the directory has **multiple** `.json` files, list them and ask the user which one to use
5. If `.loom/config.json` is invalid or the `prd` key points somewhere that's empty, non-existent, or doesn't have any readable files, let the user know and offer to read the default prd file.

This handles the interactive disambiguation before handing off to the non-interactive script.

### 2. Auto-resume detection

If **any** of these are true, add `--resume` to the flags:

- The current directory is inside a loom worktree or branch
- `.loom/logs/iterations.log` has entries from the last few hours that relate to recent commits or current uncommitted changes

This applies regardless of whether other source flags are present. The script handles `--resume` combined with other flags.

### 3. Auto-set PR

If:
- You're in a branch
- There's a PR open
- The user did not specify `pr`

Add `--pr false` to flags.

### 4. Launch

When `$FLAGS` includes `--prompt` with user text (standalone or from semantic separation), write the text to a file first to avoid shell quoting issues:

```bash
printf '%s' "$TEXT" > .loom/.directive
```

Then use `--prompt .loom/.directive` in `$FLAGS`.

**Launch the loop** (run in background with `run_in_background: true`):
```bash
LOOM="$(cat .loom/.plugin_root)" && unset CLAUDECODE && "$LOOM/scripts/start.sh" $FLAGS
```

The script launches the tmux session, prints session info, and exits. The output includes:
- **Session**: the tmux session name (e.g., `loom-myapp-fix-auth-bug`)
- **Loom dir**: the `.loom/` directory path (may be in a worktree, e.g., `/Users/.../.claude-worktrees/.../.loom`)

Parse both values from the output. Report the session name and control commands:
  - Attach to monitor: `tmux attach -t <session-name>`
  - Kill the loop: `tmux kill-session -t <session-name>`
  - Stop gracefully: `touch <loom-dir>/.stop`

Do **not** fabricate a session name or loom dir. Only use what the script actually outputs.

## Iteration watcher relay

After launching, start monitoring via the iteration watcher relay pattern. Each watcher invocation waits for the next iteration to complete, reports it, and exits — giving you one notification per iteration.

**Start the relay** immediately after the launch notification arrives:
```bash
LOOM="$(cat .loom/.plugin_root)" && "$LOOM/scripts/iteration-watcher.sh" "<session-name>" "<loom-dir>"
```
Run this with `run_in_background: true`. Both `<session-name>` and `<loom-dir>` must match what `start.sh` output. The loom dir is especially important with worktrees — it points to the worktree's `.loom/`, not the project root's.

**When the watcher notification arrives**, it will contain one of:
- **Iteration line(s)** (e.g., `2026-02-26 14:30:00 | #3 | prd | SUCCESS | 120s | ...`): Report the result to the user briefly, then **immediately launch another watcher** with the same command to continue monitoring.
- **`LOOP_TERMINATED`** (possibly followed by final log lines): The loop has ended. Report final status to the user. Do **not** relaunch the watcher.

**Critical**: Always relaunch the watcher after an iteration line. The relay must continue until you see `LOOP_TERMINATED`. Never skip relaunching — the user may not be at their computer and relies on you for status updates.
