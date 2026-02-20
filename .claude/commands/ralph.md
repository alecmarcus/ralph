---
allowed-tools: Bash
description: "Start the Ralph autonomous development loop. Usage: /ralph [flags] or /ralph <directive text>"
---

# /ralph

Launch the Ralph autonomous development loop. You must `unset CLAUDECODE` before running the script so nested `claude` invocations work.

## Routing

Look at `$ARGUMENTS` and determine which case applies:

### Case 1: No arguments (`$ARGUMENTS` is empty)

Start the loop:

```bash
unset CLAUDECODE && .ralph/ralph.sh
```

### Case 2: `status`

Show run summary:

```bash
.ralph/ralph-status.sh
```

### Case 3: `stop`

Find and kill the ralph tmux session:

```bash
tmux kill-session -t "ralph-$(basename "$PWD")" 2>/dev/null && echo "Ralph stopped." || echo "Ralph is not running."
```

### Case 4: `linear <query_or_url>`

Linear mode — fetch from Linear, implement, update ticket:

```bash
unset CLAUDECODE && .ralph/ralph.sh --linear "$REST"
```

Where `$REST` is everything after the word `linear`.

### Case 5: `github <query_or_url>`

GitHub mode — fetch from GitHub, implement, close issues:

```bash
unset CLAUDECODE && .ralph/ralph.sh --github "$REST"
```

Where `$REST` is everything after the word `github`.

### Case 6: `issue <number>`

Shorthand for GitHub issue mode:

```bash
unset CLAUDECODE && .ralph/ralph.sh --github "$NUMBER"
```

### Case 7: `slack <url>`

Slack mode — fetch Slack message, implement:

```bash
unset CLAUDECODE && .ralph/ralph.sh --slack "$URL"
```

### Case 8: Arguments start with `-` (flags only)

Pass flags through directly:

```bash
unset CLAUDECODE && .ralph/ralph.sh $ARGUMENTS
```

Examples:
- `/ralph --dry-run` → `unset CLAUDECODE && .ralph/ralph.sh --dry-run`
- `/ralph -m 10` → `unset CLAUDECODE && .ralph/ralph.sh -m 10`
- `/ralph --dry-run --prompt path/to/file.md` → `unset CLAUDECODE && .ralph/ralph.sh --dry-run --prompt path/to/file.md`

### Case 9: Arguments are plain text (a prompt)

Write the text to a file and pass it via `--prompt`:

```bash
printf '%s' '$ARGUMENTS' > .ralph/.directive && unset CLAUDECODE && .ralph/ralph.sh --prompt .ralph/.directive
```

Examples:
- `/ralph Fix all lint errors` → writes "Fix all lint errors" to `.ralph/.directive`, then runs with `--prompt .ralph/.directive`
- `/ralph Refactor all callbacks to async/await` → same pattern

### How to tell the difference

1. If `$ARGUMENTS` is empty → Case 1
2. If `$ARGUMENTS` equals `status` → Case 2
3. If `$ARGUMENTS` equals `stop` → Case 3
4. If `$ARGUMENTS` starts with `linear ` → Case 4
5. If `$ARGUMENTS` starts with `github ` → Case 5
6. If `$ARGUMENTS` starts with `issue ` → Case 6
7. If `$ARGUMENTS` starts with `slack ` → Case 7
8. If `$ARGUMENTS` starts with `--` or `-` → Case 8
9. Otherwise → Case 9

## After launching

Report back to the user (substitute the actual project directory name):
- Attach to monitor: `tmux attach -t ralph-<project>`
- Kill the loop: `tmux kill-session -t ralph-<project>`
