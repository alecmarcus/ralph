# Loom

Autonomous development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview).

Loom runs Claude Code in a continuous loop, reading tasks from a PRD (or ad-hoc directives), dispatching parallel subagents, running tests, committing passing code, and repeating — all inside a tmux session you can monitor.

## How it works

```
┌─────────────────────────────────────────────────┐
│                  loom.sh (loop)                │
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
git clone https://github.com/alecmarcus/loom.git
cd loom
./setup.sh /path/to/your-project
```

Or install into the current directory:

```bash
cd your-project
/path/to/loom/setup.sh
```

The setup script:
- Copies `.loom/` (scripts, hooks, prompt templates)
- Installs the `/loom` and `/prd` [skills](https://code.claude.com/docs/en/skills) for Claude Code
- Configures Claude Code hooks in `.claude/settings.local.json`
- Updates `.gitignore`

## Usage

### Generating a PRD

Loom includes tools to convert your specs, planning docs, and design sketches into a structured PRD:

```bash
# From Claude Code (recommended — uses Claude's full tool suite)
/prd spec.md planning-session.md sketch.md

# Standalone script (wraps claude -p)
.loom/loom-prd.sh spec.md planning-session.md

# Append more stories to an existing PRD
/prd additional-spec.md --append

# Custom ID prefix and story limit
.loom/loom-prd.sh --prefix SCP --max 60 spec.md
```

The PRD generator decomposes your documents into atomic stories grouped into prioritized gates, with dependency tracking, acceptance criteria, and predicted file paths.

### PRD mode (default)

Once you have a PRD (generated or hand-written), start the loop:

```bash
.loom/loom.sh
```

Or from inside Claude Code:

```
/loom
```

Loom reads the PRD, selects pending stories with clear dependencies, dispatches parallel subagents, and loops until everything is done.

### Directive mode

Skip the PRD and give Loom a specific task:

```bash
# Inline prompt
.loom/loom.sh --prompt "Refactor all callbacks to async/await"

# From a file
.loom/loom.sh --prompt path/to/directive.md

# Piped
echo "Fix all lint errors" | .loom/loom.sh
```

### Source integrations

Loom can fetch work from external tools:

```bash
# GitHub issue
.loom/loom.sh --github 42
.loom/loom.sh --github "https://github.com/org/repo/issues/42"

# Linear ticket
.loom/loom.sh --linear "PHN-42"
.loom/loom.sh --linear "https://linear.app/team/issue/PHN-42"

# Slack message
.loom/loom.sh --slack "https://team.slack.com/archives/C.../p..."

# Combine sources
.loom/loom.sh --github 42 --prompt "Also fix the related lint warnings"
```

GitHub and Linear sources automatically enable git worktree mode — Loom works on an isolated branch.

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

Loom launches in a tmux session with three panes:

| Pane | Content |
|------|---------|
| Top | Live Claude Code output |
| Bottom-left | `status.md` (refreshes every 3s) |
| Bottom-right | `master.log` tail |

```bash
# Attach to the session
tmux attach -t loom-<project-name>

# View status summary
.loom/loom-status.sh

# Or from Claude Code
/loom status
```

### Stopping

```bash
# Graceful (finishes current iteration)
touch .loom/.stop

# Immediate
tmux kill-session -t loom-<project-name>

# From Claude Code
/loom stop
```

## PRD format

`.loom/prd.json` contains gates (priority-ordered story groups) and stories:

```json
{
  "project": "my-app",
  "description": "A brief project description.",
  "gates": [
    {
      "id": "gate-1",
      "name": "Core Infrastructure",
      "priority": "P0",
      "status": "pending",
      "stories": ["APP-001", "APP-002"]
    },
    {
      "id": "gate-2",
      "name": "Features",
      "priority": "P1",
      "status": "pending",
      "stories": ["APP-003", "APP-004"]
    }
  ],
  "stories": [
    {
      "id": "APP-001",
      "title": "Add user authentication",
      "gate": "gate-1",
      "priority": "P0",
      "severity": "critical",
      "status": "pending",
      "files": ["src/auth/router.ts", "src/auth/middleware.ts"],
      "description": "Implement JWT-based auth with login/signup endpoints.",
      "acceptanceCriteria": [
        "POST /auth/login returns a JWT",
        "POST /auth/signup creates a user and returns a JWT",
        "Protected routes return 401 without a valid token"
      ],
      "actionItems": [
        "Create auth middleware that validates JWT from Authorization header",
        "Add login route with bcrypt password comparison",
        "Add signup route with input validation"
      ],
      "blockedBy": [],
      "details": {}
    }
  ]
}
```

**Required fields** on every story: `id`, `title`, `gate`, `priority`, `severity`, `status`, `files`, `description`, `acceptanceCriteria`, `actionItems`, `blockedBy`, `details`.

- `severity`: `"critical"` | `"major"` | `"minor"`
- `actionItems`: concrete implementation steps (what to do)
- `acceptanceCriteria`: concrete verification steps (what to check)
- `details`: object for arbitrary project-specific metadata (always present, `{}` when empty)

Loom uses `jq` to read stories in waves of 10 (never loading the full file), selects stories whose `blockedBy` dependencies are resolved, and dispatches them as parallel subagents.

Statuses: `pending` → `in_progress` → `done` | `blocked` | `cancelled`

## File structure

```
.claude/skills/
├── loom/SKILL.md        # /loom skill
└── prd/SKILL.md          # /prd skill (PRD generator)

.loom/
├── loom.sh              # Main loop controller
├── loom-status.sh       # Status reporter
├── loom-prd.sh          # Standalone PRD generator
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

Loom won't run forever. It stops when:

- **All stories done** — emits `LOOM_RESULT:DONE`
- **Consecutive failures** — 3 failures in a row trips the circuit breaker (configurable with `--max-failures`)
- **Max iterations** — hard cap at 500 (configurable with `--max-iterations`)
- **Graceful stop** — `touch .loom/.stop`
- **Timeout** — per-iteration timeout kills stuck runs (configurable with `--timeout`)

## License

MIT
