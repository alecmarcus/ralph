# Ralph

Autonomous development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview).

Ralph runs Claude Code in a continuous loop, reading tasks from a PRD (or ad-hoc directives), dispatching parallel subagents, running tests, committing passing code, and repeating — all inside a tmux session you can monitor.

## How it works

```
┌─────────────────────────────────────────────────┐
│                  ralph.sh (loop)                │
│                                                 │
│  ┌───────────┐    ┌──────────┐    ┌──────────┐ │
│  │ Read PRD  │───▶│ Dispatch │───▶│  Tests   │ │
│  │ + status  │    │ subagents│    │ + commit │ │
│  └───────────┘    └──────────┘    └──────────┘ │
│        ▲                               │        │
│        └───────────────────────────────┘        │
│                 write status.md                  │
└─────────────────────────────────────────────────┘
```

Each iteration:

1. **Recall** — reads `status.md` (short-term memory) and queries Vestige (long-term memory)
2. **Select** — picks parallelizable stories from `prd.json` using `jq`
3. **Execute** — launches one subagent per story, all in parallel
4. **Verify** — runs tests, fixes failures (up to 3 attempts)
5. **Commit** — commits only green code using conventional commits
6. **Report** — writes `status.md`, which triggers a hard kill and loop restart

Safety is enforced by Claude Code hooks — not just prompt instructions:

| Hook | Purpose |
|------|---------|
| `bash-guard.sh` | Blocks destructive commands (`rm -rf /`, `git push --force`, etc.) |
| `block-interactive.sh` | Prevents `EnterPlanMode` and `AskUserQuestion` (no human present) |
| `block-task-output.sh` | Prevents `TaskOutput` polling (results auto-deliver) |
| `background-tasks.sh` | Forces all subagents to run in background |
| `status-kill.sh` | Hard-kills the agent when `status.md` is written |
| `stop-guard.sh` | Blocks exit until `status.md` has been updated |
| `subagent-stop-guard.sh` | Validates subagent output is non-empty |

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) (`claude` in PATH)
- [jq](https://jqlang.github.io/jq/)
- git
- tmux (recommended — provides split-pane monitoring)

## Installation

```bash
git clone https://github.com/alecmarcus/ralph.git
cd ralph
./setup.sh /path/to/your-project
```

Or install into the current directory:

```bash
cd your-project
/path/to/ralph/setup.sh
```

The setup script:
- Copies `.ralph/` (scripts, hooks, prompt templates)
- Installs the `/ralph` slash command for Claude Code
- Configures Claude Code hooks in `.claude/settings.local.json`
- Updates `.gitignore`

## Usage

### PRD mode (default)

Edit `.ralph/prd.json` with your stories, then:

```bash
.ralph/ralph.sh
```

Or from inside Claude Code:

```
/ralph
```

Ralph reads the PRD, selects pending stories with clear dependencies, dispatches parallel subagents, and loops until everything is done.

### Directive mode

Skip the PRD and give Ralph a specific task:

```bash
# Inline prompt
.ralph/ralph.sh --prompt "Refactor all callbacks to async/await"

# From a file
.ralph/ralph.sh --prompt path/to/directive.md

# Piped
echo "Fix all lint errors" | .ralph/ralph.sh
```

### Source integrations

Ralph can fetch work from external tools:

```bash
# GitHub issue
.ralph/ralph.sh --github 42
.ralph/ralph.sh --github "https://github.com/org/repo/issues/42"

# Linear ticket
.ralph/ralph.sh --linear "PHN-42"
.ralph/ralph.sh --linear "https://linear.app/team/issue/PHN-42"

# Slack message
.ralph/ralph.sh --slack "https://team.slack.com/archives/C.../p..."

# Combine sources
.ralph/ralph.sh --github 42 --prompt "Also fix the related lint warnings"
```

GitHub and Linear sources automatically enable git worktree mode — Ralph works on an isolated branch.

### Options

```
-m, --max-iterations N   Maximum loop iterations (default: 500)
-d, --dry-run            Analyze one iteration without executing changes
--timeout SECONDS        Per-iteration timeout (default: 3600)
--max-failures N         Consecutive failures before halt (default: 3)
--worktree               Force git worktree mode
--no-worktree            Disable git worktree mode
--resume PATH_OR_BRANCH  Resume an existing worktree
```

### Monitoring

Ralph launches in a tmux session with three panes:

| Pane | Content |
|------|---------|
| Top | Live Claude Code output |
| Bottom-left | `status.md` (refreshes every 3s) |
| Bottom-right | `master.log` tail |

```bash
# Attach to the session
tmux attach -t ralph-<project-name>

# View status summary
.ralph/ralph-status.sh

# Or from Claude Code
/ralph status
```

### Stopping

```bash
# Graceful (finishes current iteration)
touch .ralph/.stop

# Immediate
tmux kill-session -t ralph-<project-name>

# From Claude Code
/ralph stop
```

## PRD format

`.ralph/prd.json` is a flat array of stories:

```json
{
  "project": "my-app",
  "description": "A brief project description.",
  "stories": [
    {
      "id": "APP-001",
      "title": "Add user authentication",
      "description": "Implement JWT-based auth with login/signup endpoints.",
      "acceptanceCriteria": [
        "POST /auth/login returns a JWT",
        "POST /auth/signup creates a user and returns a JWT",
        "Protected routes return 401 without a valid token"
      ],
      "files": ["src/auth/router.ts", "src/auth/middleware.ts"],
      "status": "pending",
      "blockedBy": []
    },
    {
      "id": "APP-002",
      "title": "Add user profile endpoint",
      "description": "GET /users/me returns the authenticated user's profile.",
      "acceptanceCriteria": [
        "Returns 200 with user data when authenticated",
        "Returns 401 when not authenticated"
      ],
      "files": ["src/users/router.ts"],
      "status": "pending",
      "blockedBy": ["APP-001"]
    }
  ]
}
```

Ralph uses `jq` to read stories in waves of 10 (never loading the full file), selects stories whose `blockedBy` dependencies are resolved, and dispatches them as parallel subagents.

Statuses: `pending` → `in_progress` → `done` | `blocked` | `cancelled`

## File structure

```
.ralph/
├── ralph.sh              # Main loop controller
├── ralph-status.sh       # Status reporter
├── stop.sh               # Graceful stop helper
├── prompt.md             # PRD mode prompt template
├── directive.md          # Directive mode prompt template
├── prd.json              # Your project stories
├── status.md             # Inter-iteration state (auto-managed)
├── hooks/
│   ├── background-tasks.sh
│   ├── bash-guard.sh
│   ├── block-interactive.sh
│   ├── block-task-output.sh
│   ├── status-kill.sh
│   ├── stop-guard.sh
│   └── subagent-stop-guard.sh
├── specs/
│   └── TICKETS.md        # Your reference notes
└── logs/                 # Per-iteration logs + master.log
```

## Circuit breakers

Ralph won't run forever. It stops when:

- **All stories done** — emits `RALPH_RESULT:DONE`
- **Consecutive failures** — 3 failures in a row trips the circuit breaker (configurable with `--max-failures`)
- **Max iterations** — hard cap at 500 (configurable with `--max-iterations`)
- **Graceful stop** — `touch .ralph/.stop`
- **Timeout** — per-iteration timeout kills stuck runs (configurable with `--timeout`)

## License

MIT
