#!/usr/bin/env bash
set -euo pipefail

# ─── Loom Setup ─────────────────────────────────────────────────
# Installs Loom into a project directory. Can be run from:
#   1. Inside the Loom repo:  ./setup.sh /path/to/my-project
#   2. After cloning into a project:  .loom/setup.sh (no args)
#   3. Via curl:  curl -fsSL <url>/setup.sh | bash -s -- /path/to/project
# ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

die() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

# ─── Resolve source and target ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine where Loom's source files live
if [ -d "$SCRIPT_DIR/.loom" ]; then
  # Running from Loom repo root (./setup.sh)
  LOOM_SOURCE="$SCRIPT_DIR/.loom"
  SKILLS_SOURCE="$SCRIPT_DIR/.claude/skills"
elif [ -d "$SCRIPT_DIR/../.loom" ]; then
  # setup.sh might be inside .loom/
  LOOM_SOURCE="$SCRIPT_DIR"
  SKILLS_SOURCE=""
else
  die "Cannot find Loom source files. Run this script from the Loom repository root."
fi

# Determine target project directory
if [ $# -ge 1 ]; then
  TARGET_DIR="$(cd "$1" 2>/dev/null && pwd)" || die "Target directory does not exist: $1"
else
  # No argument — install into current directory
  TARGET_DIR="$(pwd)"
fi

# Safety check: don't install Loom into the Loom repo itself
if [ "$TARGET_DIR" = "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.loom" ]; then
  echo -e "${GREEN}Loom is already set up in this directory.${NC}"
  echo -e "Run ${BOLD}.loom/loom.sh --help${NC} to get started."
  exit 0
fi

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║           L O O M   S E T U P             ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Source${NC}  $LOOM_SOURCE"
echo -e "  ${DIM}Target${NC}  $TARGET_DIR"
echo ""

# ─── Check prerequisites ────────────────────────────────────────
MISSING=()
command -v claude &>/dev/null || MISSING+=("claude (Claude Code CLI)")
command -v jq &>/dev/null     || MISSING+=("jq")
command -v git &>/dev/null    || MISSING+=("git")
command -v tmux &>/dev/null   || MISSING+=("tmux (recommended, not required)")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${YELLOW}Missing dependencies:${NC}"
  for dep in "${MISSING[@]}"; do
    echo -e "  - $dep"
  done
  # Only hard-fail on required deps
  if ! command -v claude &>/dev/null; then
    die "Claude Code CLI is required. Install it: https://docs.anthropic.com/en/docs/claude-code/overview"
  fi
  if ! command -v jq &>/dev/null; then
    die "jq is required. Install it: brew install jq (macOS) or apt install jq (Linux)"
  fi
  if ! command -v git &>/dev/null; then
    die "git is required."
  fi
  echo ""
fi

# ─── Check for existing installation ────────────────────────────
if [ -d "$TARGET_DIR/.loom" ]; then
  echo -e "${YELLOW}Loom is already installed in $TARGET_DIR${NC}"
  echo -e "  Overwrite? This will reset prd.json and status.md."
  read -r -p "  Continue? [y/N] " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# ─── Copy Loom files ───────────────────────────────────────────
echo -e "${CYAN}Installing Loom...${NC}"

# Core directory
mkdir -p "$TARGET_DIR/.loom/hooks"
mkdir -p "$TARGET_DIR/.loom/logs"

# Copy scripts
cp "$LOOM_SOURCE/loom.sh"        "$TARGET_DIR/.loom/loom.sh"
cp "$LOOM_SOURCE/loom-status.sh" "$TARGET_DIR/.loom/loom-status.sh"
cp "$LOOM_SOURCE/prd.sh"    "$TARGET_DIR/.loom/prd.sh"
cp "$LOOM_SOURCE/stop.sh"         "$TARGET_DIR/.loom/stop.sh"
cp "$LOOM_SOURCE/prompt.md"       "$TARGET_DIR/.loom/prompt.md"
cp "$LOOM_SOURCE/directive.md"    "$TARGET_DIR/.loom/directive.md"

# Copy hooks
for hook in "$LOOM_SOURCE/hooks/"*.sh; do
  [ -f "$hook" ] && cp "$hook" "$TARGET_DIR/.loom/hooks/"
done

# Copy template files (don't overwrite existing project files)
if [ ! -f "$TARGET_DIR/.loom/prd.json" ] || [ -s "$TARGET_DIR/.loom/prd.json" ] && grep -q "EXAMPLE-001" "$TARGET_DIR/.loom/prd.json" 2>/dev/null; then
  cp "$LOOM_SOURCE/prd.json" "$TARGET_DIR/.loom/prd.json"
fi

if [ ! -f "$TARGET_DIR/.loom/status.md" ] || grep -q "No iterations run yet" "$TARGET_DIR/.loom/status.md" 2>/dev/null; then
  cp "$LOOM_SOURCE/status.md" "$TARGET_DIR/.loom/status.md"
fi

# Make scripts executable
chmod +x "$TARGET_DIR/.loom/loom.sh"
chmod +x "$TARGET_DIR/.loom/loom-status.sh"
chmod +x "$TARGET_DIR/.loom/prd.sh"
chmod +x "$TARGET_DIR/.loom/stop.sh"
chmod +x "$TARGET_DIR/.loom/hooks/"*.sh

echo -e "  ${GREEN}✓${NC} Copied .loom/ directory"

# ─── Install Claude Code skills ──────────────────────────────────
mkdir -p "$TARGET_DIR/.claude/skills/loom"
mkdir -p "$TARGET_DIR/.claude/skills/prd"

if [ -n "$SKILLS_SOURCE" ] && [ -d "$SKILLS_SOURCE" ]; then
  cp "$SKILLS_SOURCE/loom/SKILL.md" "$TARGET_DIR/.claude/skills/loom/SKILL.md"
  cp "$SKILLS_SOURCE/prd/SKILL.md"   "$TARGET_DIR/.claude/skills/prd/SKILL.md"
else
  if [ ! -f "$TARGET_DIR/.claude/skills/loom/SKILL.md" ]; then
    die "Could not find skill sources. Copy them manually from the Loom repo."
  fi
fi

# Remove old commands if migrating from a previous install
rm -f "$TARGET_DIR/.claude/commands/loom.md" "$TARGET_DIR/.claude/commands/prd.md"
rmdir "$TARGET_DIR/.claude/commands" 2>/dev/null || true

echo -e "  ${GREEN}✓${NC} Installed /loom and /prd skills"

# ─── Configure Claude Code hooks ────────────────────────────────
SETTINGS_FILE="$TARGET_DIR/.claude/settings.json"

# Build the hooks configuration
HOOKS_JSON='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/background-tasks.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/bash-guard.sh"
          }
        ]
      },
      {
        "matcher": "EnterPlanMode",
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/block-interactive.sh"
          }
        ]
      },
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/block-interactive.sh"
          }
        ]
      },
      {
        "matcher": "TaskOutput",
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/block-task-output.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/status-kill.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/stop-guard.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".loom/hooks/subagent-stop-guard.sh"
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
  # Merge hooks into existing settings
  EXISTING=$(cat "$SETTINGS_FILE")
  # Check if hooks already exist
  if echo "$EXISTING" | jq -e '.hooks' &>/dev/null; then
    echo -e "  ${YELLOW}!${NC} Hooks already configured in settings.json — merging"
    MERGED=$(echo "$EXISTING" | jq --argjson new "$HOOKS_JSON" '.hooks = ($new.hooks * .hooks)')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
  else
    MERGED=$(echo "$EXISTING" | jq --argjson new "$HOOKS_JSON" '. + $new')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
  fi
else
  echo "$HOOKS_JSON" | jq '.' > "$SETTINGS_FILE"
fi

echo -e "  ${GREEN}✓${NC} Configured Claude Code hooks"

# ─── Update .gitignore ───────────────────────────────────────────
GITIGNORE="$TARGET_DIR/.gitignore"
LOOM_IGNORES=(
  "# Loom autonomous loop"
  ".loom/logs/"
  ".loom/.stop"
  ".loom/.pid"
  ".loom/.directive"
  ".loom/.piped_directive"
  ".loom/.iteration_marker"
  ".loom/loom.log"
)

if [ -f "$GITIGNORE" ]; then
  NEEDS_NEWLINE=true
  for entry in "${LOOM_IGNORES[@]}"; do
    if ! grep -qF "$entry" "$GITIGNORE" 2>/dev/null; then
      if $NEEDS_NEWLINE; then
        echo "" >> "$GITIGNORE"
        NEEDS_NEWLINE=false
      fi
      echo "$entry" >> "$GITIGNORE"
    fi
  done
else
  printf '%s\n' "${LOOM_IGNORES[@]}" > "$GITIGNORE"
fi

echo -e "  ${GREEN}✓${NC} Updated .gitignore"

# ─── Update CLAUDE.md ───────────────────────────────────────────
CLAUDEMD="$TARGET_DIR/CLAUDE.md"
LOOM_SECTION_MARKER="<!-- loom:begin -->"
LOOM_SECTION_END="<!-- loom:end -->"

LOOM_SECTION="$LOOM_SECTION_MARKER
## Loom — Autonomous Development Loop

Loom runs Claude Code in a continuous loop: read tasks from a PRD, dispatch parallel subagents, run tests, commit green code, repeat.

\`\`\`
.loom/               # Autonomous dev loop — dispatches parallel subagents from a PRD
├── prd.json         # Structured stories with gates (P0/P1/P2), deps, acceptance criteria
├── prompt.md        # Autonomous iteration instructions (story selection, execution, commit)
├── directive.md     # Single-task mode instructions (execute one directive, signal result)
├── status.md        # Current iteration state (read at start, written at end of each cycle)
├── prd.sh           # Standalone PRD generator (wraps claude -p)
└── hooks/           # Guard rails: stop signals, interactive blocking, subagent limits
\`\`\`

### Rules for success

**Stories must be atomic.** Each story is executed by a single subagent in one iteration (~15-30 min). If it can't be done in one shot, split it. Coupled work (model + migration + route) stays together; unrelated work does not.

**Acceptance criteria must be machine-verifiable.** Not \"it works\" but \"POST /api/x returns 200 with a JWT\". If you can't write a test for it, Loom can't verify it.

**Parallelism requires file isolation.** Stories that touch the same files cannot run in the same batch. Set \`blockedBy\` for true data dependencies; leave it empty otherwise to maximize parallelism.

**Green tests are a hard gate.** Loom never commits failing code. Test failures are recorded in status.md and become top priority for the next iteration. After 3 failed fix attempts within one iteration, Loom stops and records the state.

**Context is the scarcest resource.** Read prd.json in jq waves of 10. Never cat entire files. Use dedicated tools (Read, Grep, Glob) instead of shell commands. status.md is the only continuity across loop restarts — write it thoroughly.

**Search before building.** Subagents must search the codebase before assuming something is missing. Reimplementing existing code is a common failure mode.

**Scope is sacred.** Implement only the assigned story. Do not \"fix\" adjacent code, add unrequested features, or refactor code that seems inconsistent with other specs.
$LOOM_SECTION_END"

if [ -f "$CLAUDEMD" ]; then
  if grep -qF "$LOOM_SECTION_MARKER" "$CLAUDEMD" 2>/dev/null; then
    # Replace existing Loom section
    # Use awk to replace content between markers
    awk -v replacement="$LOOM_SECTION" '
      /<!-- loom:begin -->/ { print replacement; skip=1; next }
      /<!-- loom:end -->/ { skip=0; next }
      !skip { print }
    ' "$CLAUDEMD" > "${CLAUDEMD}.tmp" && mv "${CLAUDEMD}.tmp" "$CLAUDEMD"
    echo -e "  ${GREEN}✓${NC} Updated Loom section in CLAUDE.md"
  else
    # Append Loom section
    printf '\n%s\n' "$LOOM_SECTION" >> "$CLAUDEMD"
    echo -e "  ${GREEN}✓${NC} Added Loom section to CLAUDE.md"
  fi
else
  # Create new CLAUDE.md
  printf '%s\n' "$LOOM_SECTION" > "$CLAUDEMD"
  echo -e "  ${GREEN}✓${NC} Created CLAUDE.md with Loom section"
fi

# ─── Done ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Loom installed successfully!${NC}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo ""
echo -e "  1. ${BOLD}Edit your PRD${NC}"
echo -e "     Open ${DIM}.loom/prd.json${NC} and replace the example story with your own."
echo -e "     Each story needs: id, title, description, acceptanceCriteria, files, status."
echo ""
echo -e "  2. ${BOLD}Start the loop${NC}"
echo -e "     ${DIM}\$.loom/loom.sh${NC}"
echo -e "     Or from Claude Code: ${DIM}/loom${NC}"
echo ""
echo -e "  3. ${BOLD}Quick directive${NC} (skip the PRD)"
echo -e "     ${DIM}\$.loom/loom.sh --prompt \"Fix all lint errors\"${NC}"
echo -e "     ${DIM}echo 'Add auth middleware' | .loom/loom.sh${NC}"
echo ""
echo -e "  4. ${BOLD}Monitor${NC}"
echo -e "     ${DIM}tmux attach -t loom-$(basename "$TARGET_DIR")${NC}"
echo -e "     ${DIM}.loom/loom-status.sh${NC}"
echo ""
echo -e "  5. ${BOLD}Stop${NC}"
echo -e "     ${DIM}touch .loom/.stop${NC}  (finishes current iteration)"
echo -e "     ${DIM}tmux kill-session -t loom-$(basename "$TARGET_DIR")${NC}  (immediate)"
echo ""
echo -e "  Run ${BOLD}.loom/loom.sh --help${NC} for all options."
