# Loom

Loom is a Ralph Wiggum style autonomous development loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) that is optimized for multi-threaded work with subagents.

Loom runs Claude Code in a continuous loop, reading tasks from a source(s) of your choosing, dispatching parallel subagents, testing & validating, committing passing code, and repeating — all inside a tmux session you can monitor.

## Quick start

1. Install the plugin
   ```bash
   /plugin marketplace add alecmarcus/claude-plugins
   /plugin install loom@alecmarcus
   ```

2. Initialize your project
   ```bash
   /loom:init
   ```

3. Loom
   ```bash
   # Give it a task
   /loom:start Refactor all callbacks to async/await

   # Work from a GitHub issue
   /loom:start github 42

   # Work from a Linear ticket
   /loom:start linear TEAM-42

   # Build a feature from specs
   /loom:prd spec.md design.md
   /loom:start

   # Set up integrations
   /loom:setup playwright
   /loom:setup github issues
   ```

## How it works

```
┌─────────────────────────────────────────────────┐
│                  start.sh (loop)                │
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

## Installation

### Prerequisites

- git
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) (`claude` in PATH)
- [jq](https://jqlang.github.io/jq/)
- [mdq](https://github.com/yshavit/mdq) (markdown query tool, used by `/loom:prd` to extract sections from spec files)
- [tmux](https://github.com/tmux/tmux/wiki) (recommended — provides split-pane monitoring)

### Plugin marketplace (recommended)

```bash
/plugin marketplace add alecmarcus/claude-plugins
/plugin install loom@alecmarcus
```

Or install directly:

```bash
claude plugin install loom
```

Update:

```bash
claude plugin update loom
```

### Local install

Self-contained, per-project install. No plugins — everything is checked into your repo for complete control:

```bash
curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash
```

**What it does:**
- Copies scripts, templates, and setup guides into `.loom/`
- Installs skills in `.claude/skills/` (`/loom:start`, `/loom:stop`, etc.)
- Configures hooks in `.claude/settings.json`
- Creates `prd.json`, `status.md`, `.gitignore`, and a `CLAUDE.md` section
- Re-running updates scripts and hooks without overwriting project files

Same `/loom:*` skill names as the plugin install. Everything is tracked in your repo — portable and self-contained.

**Update:** Re-run the install script in your project directory.

**Uninstall:** Remove `.loom/`, `.claude/skills/loom:*/`, and the hooks from `.claude/settings.json`.

### Initialize your project

**⚠️ Important, don't skip this!**

After installing via **either** method:

```bash
/loom:init
```

This creates the `.loom/` directory with template files and injects the Loom section into your `CLAUDE.md`.

## Skills

Loom provides 8 skills, all prefixed with `/loom:`:

| Skill | Description |
|-------|-------------|
| `/loom:start` | Start the autonomous loop — PRD mode, directive, or external source |
| `/loom:init` | First-time project setup — creates `.loom/` and configures `CLAUDE.md` |
| `/loom:setup` | Fetch and execute integration setup guides |
| `/loom:prd` | Generate a structured PRD from spec files |
| `/loom:status` | Show run summary |
| `/loom:stop` | Graceful stop (finishes current iteration) |
| `/loom:kill` | Immediate kill (terminates tmux session) |
| `/loom:preview` | Analyze one iteration without executing changes |

## Usage

### Sources

Sources tell Loom where to get work. Without a source, Loom defaults to PRD mode (reads `.loom/prd.json`).

| Source | Command | Accepts | MCP / tool required | Auth |
|--------|---------|---------|---------------------|------|
| PRD | `/loom:start` | — | — | — |
| Prompt | `/loom:start <text>` | text, file path | — | — |
| GitHub | `/loom:start github` | issue #, URL, search query | `gh` CLI | `gh auth login` |
| Linear | `/loom:start linear` | ticket ID, URL, search query | [Linear MCP](https://mcp.linear.app) | OAuth |
| Slack | `/loom:start slack` | permalink URL | [Slack MCP](https://mcp.slack.com) | OAuth |
| Notion | `/loom:start notion` | page URL, search query | [Notion MCP](https://mcp.notion.com) | OAuth |
| Sentry | `/loom:start sentry` | issue URL, search query | [Sentry MCP](https://mcp.sentry.dev) | OAuth |

Loom always runs in a git worktree — an isolated branch so your main tree stays clean. When the loop completes, the branch is pushed and a PR is created automatically.

#### Examples

```bash
# PRD mode — work through stories until done
/loom:start

# Directive — give it a task directly
/loom:start Refactor all callbacks to async/await

# GitHub — issue number, URL, or search
/loom:start github 42

# Linear — ticket ID, URL, or natural language
/loom:start linear TEAM-42
/loom:start linear fix all tickets with less than 24h left in the SLA

# Slack — message permalink
/loom:start slack https://team.slack.com/archives/C.../p...

# Notion — page URL or search
/loom:start notion https://notion.so/team/My-Spec-Page-abc123
/loom:start notion "API redesign spec"

# Sentry — issue URL or search
/loom:start sentry https://sentry.io/organizations/org/issues/12345/
/loom:start sentry "TypeError in checkout flow"
```

### Generating a PRD

```bash
# From Claude Code (recommended)
/loom:prd spec.md planning-session.md sketch.md

# Append to existing PRD
/loom:prd additional-spec.md append
```

The PRD generator decomposes your documents into atomic stories grouped into prioritized gates, with dependency tracking, acceptance criteria, and predicted file paths.

### Start options

Flags can be passed to `/loom:start` via raw flag passthrough (e.g., `/loom:start --worktree false`):

| Flag | Default | Description |
|------|---------|-------------|
| `resume <dir>` | — | Resume an existing worktree |
| `wt/worktree <bool>` | on | Git worktree isolation |
| `pr <bool>` | on | Push branch + create PR after loop |

## MCP integrations

Loom subagents can use any MCP tools configured in the project. These are especially useful for stories with visual, browser, or mobile acceptance criteria.

### Supported servers

| MCP | Install | Capability | What it provides |
|-----|---------|------------|------------------|
| [Playwright](https://github.com/microsoft/playwright-mcp) | `claude mcp add playwright -- npx @playwright/mcp@latest --headless` | `browser` | Browser automation, screenshots, DOM interaction. Use `--headless` for unattended Loom runs. |
| [Mobile MCP](https://github.com/mobile-next/mobile-mcp) | `claude mcp add mobile -- npx -y @mobilenext/mobile-mcp@latest` | `mobile` | iOS Simulator + Android Emulator screenshots, tap, swipe, app management. Requires a running simulator/emulator. |
| [Figma](https://developers.figma.com/docs/figma-mcp-server/) | `claude mcp add --transport http figma https://mcp.figma.com/mcp` | `design` | Full Figma integration (Code Connect, design system rules, bidirectional). Requires interactive OAuth on first use — better for interactive sessions than unattended Loom runs. |

To scope an MCP server to a single project, add it to your project's `.mcp.json` instead of global config. Loom copies `.mcp.json` into worktrees automatically.

### Capability auto-detection

Loom automatically detects MCP capabilities at startup by scanning `.mcp.json`. Known server names map to capability categories:

| Server names | Capability |
|-------------|-----------|
| `playwright`, `chrome`, `puppeteer`, `browserbase` | `browser` |
| `mobile`, `mobile-mcp`, `appium` | `mobile` |
| `figma` | `design` |

Servers not in this list are exposed by their own name as a capability (e.g., a server named `supabase` becomes the `supabase` capability).

The resolved capabilities are exported as `LOOM_CAPABILITIES` and displayed in the tmux header. During story selection, Loom checks each story's `tools` array against the available capabilities — stories requiring missing capabilities stay `pending` and are skipped. The `/loom:prd` generator auto-detects `tools` from acceptance criteria keywords (e.g., "screenshot" → `["browser"]`, "simulator" → `["mobile"]`, "design tokens" → `["design"]`).

## Setup guides

Step-by-step guides for common scenarios — written as agent-executable instructions. Use `/loom:setup` to have an agent fetch and execute any guide for your project:

```bash
/loom:setup playwright
/loom:setup mobile testing
/loom:setup github issues
/loom:setup how do I run loom on a large feature
```

Or browse all [setup guides](setup/) directly.

**Usage patterns:**

| Guide | When to use |
|-------|-------------|
| [Large Feature](setup/large-feature.md) | Build a multi-story feature from specs using PRD mode |
| [Quick Task](setup/quick-task.md) | Run a focused directive without PRD overhead |
| [PRD Creation](setup/prd-creation.md) | Generate, review, and refine PRDs from spec files |
| [GitHub Issues](setup/github-issues.md) | Implement GitHub issues — fetch, build, close |
| [Linear Tickets](setup/linear-tickets.md) | Implement Linear tickets — fetch, build, update |
| [External Sources](setup/external-sources.md) | Pull work from Slack, Notion, or Sentry |
| [Testing](setup/testing.md) | Configure test suites for any language/framework |
| [Worktrees & PRs](setup/worktrees-and-prs.md) | Control isolation, branching, and PR creation |

**Validation:**

| Guide | Capability | What it sets up |
|-------|-----------|-----------------|
| [Playwright](setup/validation/playwright.md) | `browser` | Browser testing, screenshots, DOM verification |
| [Mobile MCP](setup/validation/mobile-mcp.md) | `mobile` | iOS Simulator & Android Emulator via MCP |
| [agent-device](setup/validation/mobile-agent-device.md) | — | iOS & Android via CLI skill (token-efficient) |
| [Figma](setup/validation/figma.md) | `design` | Design token extraction & visual fidelity |
| [Custom MCP](setup/validation/custom-mcp.md) | any | Extend Loom with any MCP server |

## Monitoring & control

Loom launches in a tmux session with four panes:

| Pane | Content |
|------|---------|
| Top (fixed) | Session header — PID, mode, config (always visible) |
| Middle | Live Claude Code output |
| Bottom-left | `status.md` (refreshes every 3s) |
| Bottom-right | `iterations.log` tail |

```bash
tmux attach -t loom-<project>   # attach to the session
/loom:status                     # view status summary
```

### Notifications

Loom provides two independent notification systems:

**macOS notifications** — Each iteration sends a native notification via `osascript` with the iteration number, result signal, and duration. Automatic, no setup needed.

**Claude Code relay** — The `/loom:start` skill monitors the loop via `iteration-watcher.sh`. After each iteration, the watcher reports back to Claude Code and exits; the skill relaunches it for the next iteration. This lets Claude Code track progress and report to you even when you're away from the computer (SSH, remote sessions, etc.).

### Stopping

```bash
/loom:stop                               # graceful — finishes current iteration
/loom:kill                               # immediate kill
touch .loom/.stop                        # graceful via file signal
tmux kill-session -t loom-<project>      # immediate via tmux
```

## Safety

Loom enforces safety through Claude Code hooks and automatic circuit breakers — not just prompt instructions.

### Hooks

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

### Circuit breakers

Loom won't run forever. It stops when:

- **All stories done** — emits `LOOM_RESULT:DONE`
- **Consecutive failures** — 3 failures in a row trips the circuit breaker (configurable with `--max-failures`)
- **Max iterations** — hard cap at 500 (configurable with `--max-iterations`)
- **Graceful stop** — `touch .loom/.stop`
- **Timeout** — per-iteration timeout kills stuck runs (configurable with `--timeout`)

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
- `tools`: array of capability categories the story requires (`"browser"`, `"mobile"`, `"design"`). Defaults to `[]`. Stories with tool requirements are skipped when the required MCP servers aren't installed. Auto-detected from acceptance criteria by `/loom:prd`.
- `details`: object for arbitrary project-specific metadata (always present, `{}` when empty)

Loom uses `jq` to read stories in waves of 10 (never loading the full file), selects stories whose `blockedBy` dependencies are resolved, and dispatches them as parallel subagents.

Statuses: `pending` → `in_progress` → `done` | `blocked` | `cancelled`

## File structure

```
loom/                              # Plugin root
├── .claude-plugin/
│   └── plugin.json                # Plugin manifest
├── skills/
│   ├── start/
│   │   └── SKILL.md              # /loom:start — launch the loop
│   ├── init/
│   │   └── SKILL.md              # /loom:init — first-time project setup
│   ├── setup/
│   │   └── SKILL.md              # /loom:setup — integration guides
│   ├── prd/
│   │   └── SKILL.md              # /loom:prd — PRD generation
│   ├── status/
│   │   └── SKILL.md              # /loom:status — show run summary
│   ├── stop/
│   │   └── SKILL.md              # /loom:stop — graceful stop
│   ├── kill/
│   │   └── SKILL.md              # /loom:kill — immediate kill
│   └── preview/
│       └── SKILL.md              # /loom:preview — analysis without changes
├── hooks/
│   └── hooks.json                 # Hook configuration
├── scripts/
│   ├── start.sh                   # Main loop controller
│   ├── prd.sh                     # Standalone PRD generator
│   ├── loom-status.sh             # Status reporter
│   ├── stop.sh                    # Graceful stop
│   ├── kill.sh                    # Immediate kill
│   ├── iteration-watcher.sh       # Per-iteration completion watcher (relay pattern)
│   ├── session-init.sh            # SessionStart hook — writes .loom/.plugin_root
│   └── hooks/                     # Hook handler scripts
│       ├── bash-guard.sh
│       ├── background-tasks.sh
│       ├── block-interactive.sh
│       ├── block-task-output.sh
│       ├── status-kill.sh
│       ├── stop-guard.sh
│       ├── subagent-recall.sh
│       └── subagent-stop-guard.sh
├── templates/                     # Default per-project files
│   ├── prompt.md                  # PRD mode prompt template
│   ├── directive.md               # Directive mode prompt template
│   ├── prd.json                   # Empty PRD template
│   ├── status.md                  # Initial status
│   ├── gitignore                  # .loom/.gitignore content
│   └── claude-md-section.md       # CLAUDE.md loom section content
├── setup/                         # Setup guides
└── README.md
```

### Per-project files (created by `/loom:init`)

```
your-project/
├── .loom/
│   ├── prd.json                   # Your project stories
│   ├── status.md                  # Inter-iteration state (auto-managed)
│   ├── .gitignore
│   ├── .plugin_root               # Path to plugin (written by SessionStart hook)
│   └── logs/                      # Per-iteration logs + iterations.log
└── CLAUDE.md                      # Contains Loom rules section
```

## License

MIT
