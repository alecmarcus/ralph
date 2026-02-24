# Loom

Loom is a Ralph Wiggum style autonomous development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) that is optimized for multi-threaded work with subagents.

Loom runs Claude Code in a continuous loop, reading tasks from a PRD (or ad-hoc directives), dispatching parallel subagents, running tests, committing passing code, and repeating — all inside a tmux session you can monitor.

You can loom from inside Claude Code, or with the bash script.

## Quick start

1. Install
  ```bash
  # Install into your project
  cd your-project
  curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash
  ```

2. (Optional) Have Claude generate a PRD with `/prd` from your specs. Pass any number of files of any format.
  ```bash
  # Use the slash command from inside Claude Code
  /prd spec.md design.md arch.md
  ```

3. Start the loom
  ```sh
  # Both the slash command and bash script default to work through the PRD until done
  /loom
  
  # You can skip the PRD and give it a task directly
  /loom Refactor all callbacks to async/await
  
  # Or pass queries to MCPs
  /loom github 42
  /loom linear TEAM-42
  /loom slack https://team.slack.com/archives/...
  ```

## How it works

```
┌─────────────────────────────────────────────────┐
│                  loom.sh (loop)                 │
│                                                 │
│  ┌───────────┐    ┌──────────┐    ┌──────────┐  │
│  │ Read PRD  │───▶│ Dispatch │───▶│  Tests   │  │
│  │ + status  │    │ subagents│    │ + commit │  │
│  └───────────┘    └──────────┘    └──────────┘  │
│        ▲                               │        │
│        └───────────────────────────────┘        │
│                 write status.md                 │
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
| `subagent-recall.sh` | Nudges subagents to check .docs, CLAUDE.md, and memory before starting |
| `subagent-stop-guard.sh` | Validates subagent output and nudges to update docs + memory |

## Prerequisites

- git
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) (`claude` in PATH)
- [jq](https://jqlang.github.io/jq/)
- [mdq](https://github.com/yshavit/mdq) (markdown query tool, used by `/prd` to extract sections from spec files)
- [tmux](https://github.com/tmux/tmux/wiki) (recommended — provides split-pane monitoring)

### Optional MCP servers

Loom subagents can use any MCP tools configured in the project. These are useful for stories with visual, browser, or mobile acceptance criteria.

| MCP | Install | Capability | What it provides |
|-----|---------|------------|------------------|
| [Playwright](https://github.com/microsoft/playwright-mcp) | `claude mcp add playwright -- npx @playwright/mcp@latest --headless` | `browser` | Browser automation, screenshots, DOM interaction. Use `--headless` for unattended Loom runs. |
| [Mobile MCP](https://github.com/mobile-next/mobile-mcp) | `claude mcp add mobile -- npx -y @mobilenext/mobile-mcp@latest` | `mobile` | iOS Simulator + Android Emulator screenshots, tap, swipe, app management. Requires a running simulator/emulator. |
| [Figma](https://developers.figma.com/docs/figma-mcp-server/) | `claude mcp add --transport http figma https://mcp.figma.com/mcp` | `design` | Full Figma integration (Code Connect, design system rules, bidirectional). Requires interactive OAuth on first use — better for interactive sessions than unattended Loom runs. |

To scope an MCP server to a single project, add it to your project's `.mcp.json` instead of global config. Loom copies `.mcp.json` into worktrees automatically.

## Installation

You can run the remote install script, which shallow-clones the necessary files from this repo into a temporary directory, installs brew deps, runs `setup.sh` in the cwd, and cleans itself up after.

```bash
curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash
```

Or specify a target project directory:

```bash
curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash -s -- /path/to/your-project
```

### Manual setup

If you don't have them, install `jq`, `mdq`, and `tmux`:

```bash
# Loom uses jq to pre-parse JSON before sending to claude, optimizing context
brew install jq

# mdq extracts sections from markdown spec files during PRD generation
brew install mdq

# tmux provides split-pane monitoring stream inside the terminal
brew install tmux
```

Clone the repo and run the setup script:

```bash
git clone https://github.com/alecmarcus/loom.git
cd loom
./setup.sh /path/to/your-project
```

The setup script:
- Copies `.loom/` (scripts, hooks, prompt templates)
- Installs the `/loom` and `/prd` [skills](https://code.claude.com/docs/en/skills) for Claude Code
- Configures Claude Code hooks in `.claude/settings.json`
- Updates `.gitignore`

## Usage

Everything in Loom can be run from the `/loom` slash command inside Claude Code or from the `.loom/loom.sh` bash script directly. Both support the same sources and options.

### Sources

Sources tell Loom where to get work. Without a source, Loom defaults to PRD mode (reads `.loom/prd.json`). Sources can be combined — e.g., `--github 42 --prompt "Also fix lint"`.

| Source | Bash flag | `/loom` subcommand | Accepts | MCP / tool required | Auth |
|--------|-----------|-------------------|---------|-------------------|------|
| PRD | *(default)* | `/loom` | — | — | — |
| Prompt | `--prompt` | `/loom <text>` | text, file path | — | — |
| Piped | `echo "..." \| .loom/loom.sh` | — | stdin | — | — |
| GitHub | `--github` | `/loom github` | issue #, URL, search query | `gh` CLI | `gh auth login` |
| Linear | `--linear` | `/loom linear` | ticket ID, URL, search query | Linear MCP | Linear API key |
| Slack | `--slack` | `/loom slack` | permalink URL | Slack MCP | Slack OAuth |
| Notion | `--notion` | `/loom notion` | page URL, search query | Notion MCP | Notion API key |
| Sentry | `--sentry` | `/loom sentry` | issue URL, search query | Sentry MCP | Sentry auth token |

Loom always runs in a git worktree — an isolated branch so your main tree stays clean. When the loop completes, the branch is pushed and a PR is created automatically.

#### Examples

```bash
# PRD mode — work through stories until done
/loom
.loom/loom.sh

# Directive — give it a task directly
/loom Refactor all callbacks to async/await
.loom/loom.sh --prompt "Fix all lint errors"

# GitHub — issue number, URL, or search
/loom github 42
.loom/loom.sh --github "https://github.com/org/repo/issues/42"

# Linear — ticket ID, URL, or natural language
/loom linear TEAM-42
/loom linear fix all tickets with less than 24h left in the SLA

# Slack — message permalink
/loom slack https://team.slack.com/archives/C.../p...

# Notion — page URL or search
/loom notion https://notion.so/team/My-Spec-Page-abc123
/loom notion "API redesign spec"

# Sentry — issue URL or search
/loom sentry https://sentry.io/organizations/org/issues/12345/
/loom sentry "TypeError in checkout flow"

# Combine sources
.loom/loom.sh --github 42 --prompt "Also fix the related lint warnings"
```

### Generating a PRD

```bash
# From Claude Code (recommended)
/prd spec.md planning-session.md sketch.md

# Standalone script
.loom/prd.sh spec.md planning-session.md

# Append to existing PRD
/prd additional-spec.md --append
```

The PRD generator decomposes your documents into atomic stories grouped into prioritized gates, with dependency tracking, acceptance criteria, and predicted file paths.

### Options

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--max-iterations` | `-m` | `500` | Maximum loop iterations |
| `--dry-run` | `-d` | off | Analyze one iteration without executing changes |
| `--timeout` | — | `3600` | Per-iteration timeout in seconds |
| `--max-failures` | — | `3` | Consecutive failures before halt |
| `--worktree` | — | on | Git worktree isolation |
| `--pr` | — | on | Push branch + create PR after loop |
| `--resume` | — | — | Resume an existing worktree by path or branch |

### Monitoring

Loom launches in a tmux session with three panes:

| Pane | Content |
|------|---------|
| Top | Live Claude Code output |
| Bottom-left | `status.md` (refreshes every 3s) |
| Bottom-right | `master.log` tail |

```bash
tmux attach -t loom-<project>   # attach to the session
/loom status                     # view status summary
```

### Stopping

```bash
touch .loom/.stop                        # graceful — finishes current iteration
tmux kill-session -t loom-<project>      # immediate
/loom stop                               # from Claude Code
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
      "tools": [],
      "details": {}
    }
  ]
}
```

**Required fields** on every story: `id`, `title`, `gate`, `priority`, `severity`, `status`, `files`, `description`, `acceptanceCriteria`, `actionItems`, `blockedBy`, `tools`, `details`.

- `severity`: `"critical"` | `"major"` | `"minor"`
- `actionItems`: concrete implementation steps (what to do)
- `acceptanceCriteria`: concrete verification steps (what to check)
- `tools`: array of capability categories the story requires (`"browser"`, `"mobile"`, `"design"`). Defaults to `[]`. Stories with tool requirements are skipped when the required MCP servers aren't installed. Auto-detected from acceptance criteria by `/prd`.
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
├── prd.sh          # Standalone PRD generator
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
│   ├── subagent-recall.sh
│   └── subagent-stop-guard.sh
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
