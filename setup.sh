#!/usr/bin/env bash
set -euo pipefail

# ─── Ralph Setup ─────────────────────────────────────────────────
# Installs Ralph into a project directory. Can be run from:
#   1. Inside the Ralph repo:  ./setup.sh /path/to/my-project
#   2. After cloning into a project:  .ralph/setup.sh (no args)
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

# Determine where Ralph's source files live
if [ -d "$SCRIPT_DIR/.ralph" ]; then
  # Running from Ralph repo root (./setup.sh)
  RALPH_SOURCE="$SCRIPT_DIR/.ralph"
  COMMAND_SOURCE="$SCRIPT_DIR/.claude/commands/ralph.md"
elif [ -d "$SCRIPT_DIR/../.ralph" ]; then
  # setup.sh might be inside .ralph/
  RALPH_SOURCE="$SCRIPT_DIR"
  COMMAND_SOURCE=""
else
  die "Cannot find Ralph source files. Run this script from the Ralph repository root."
fi

# Determine target project directory
if [ $# -ge 1 ]; then
  TARGET_DIR="$(cd "$1" 2>/dev/null && pwd)" || die "Target directory does not exist: $1"
else
  # No argument — install into current directory
  TARGET_DIR="$(pwd)"
fi

# Safety check: don't install Ralph into the Ralph repo itself
if [ "$TARGET_DIR" = "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.ralph" ]; then
  echo -e "${GREEN}Ralph is already set up in this directory.${NC}"
  echo -e "Run ${BOLD}.ralph/ralph.sh --help${NC} to get started."
  exit 0
fi

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║          R A L P H   S E T U P            ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Source${NC}  $RALPH_SOURCE"
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
if [ -d "$TARGET_DIR/.ralph" ]; then
  echo -e "${YELLOW}Ralph is already installed in $TARGET_DIR${NC}"
  echo -e "  Overwrite? This will reset prd.json and status.md."
  read -r -p "  Continue? [y/N] " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# ─── Copy Ralph files ───────────────────────────────────────────
echo -e "${CYAN}Installing Ralph...${NC}"

# Core directory
mkdir -p "$TARGET_DIR/.ralph/hooks"
mkdir -p "$TARGET_DIR/.ralph/specs"
mkdir -p "$TARGET_DIR/.ralph/logs"

# Copy scripts
cp "$RALPH_SOURCE/ralph.sh"        "$TARGET_DIR/.ralph/ralph.sh"
cp "$RALPH_SOURCE/ralph-status.sh" "$TARGET_DIR/.ralph/ralph-status.sh"
cp "$RALPH_SOURCE/stop.sh"         "$TARGET_DIR/.ralph/stop.sh"
cp "$RALPH_SOURCE/prompt.md"       "$TARGET_DIR/.ralph/prompt.md"
cp "$RALPH_SOURCE/directive.md"    "$TARGET_DIR/.ralph/directive.md"

# Copy hooks
for hook in "$RALPH_SOURCE/hooks/"*.sh; do
  [ -f "$hook" ] && cp "$hook" "$TARGET_DIR/.ralph/hooks/"
done

# Copy template files (don't overwrite existing project files)
if [ ! -f "$TARGET_DIR/.ralph/prd.json" ] || [ -s "$TARGET_DIR/.ralph/prd.json" ] && grep -q "EXAMPLE-001" "$TARGET_DIR/.ralph/prd.json" 2>/dev/null; then
  cp "$RALPH_SOURCE/prd.json" "$TARGET_DIR/.ralph/prd.json"
fi

if [ ! -f "$TARGET_DIR/.ralph/status.md" ] || grep -q "No iterations run yet" "$TARGET_DIR/.ralph/status.md" 2>/dev/null; then
  cp "$RALPH_SOURCE/status.md" "$TARGET_DIR/.ralph/status.md"
fi

if [ ! -f "$TARGET_DIR/.ralph/specs/TICKETS.md" ]; then
  cp "$RALPH_SOURCE/specs/TICKETS.md" "$TARGET_DIR/.ralph/specs/TICKETS.md"
fi

# Make scripts executable
chmod +x "$TARGET_DIR/.ralph/ralph.sh"
chmod +x "$TARGET_DIR/.ralph/ralph-status.sh"
chmod +x "$TARGET_DIR/.ralph/stop.sh"
chmod +x "$TARGET_DIR/.ralph/hooks/"*.sh

echo -e "  ${GREEN}✓${NC} Copied .ralph/ directory"

# ─── Install Claude Code slash command ───────────────────────────
mkdir -p "$TARGET_DIR/.claude/commands"

if [ -n "$COMMAND_SOURCE" ] && [ -f "$COMMAND_SOURCE" ]; then
  cp "$COMMAND_SOURCE" "$TARGET_DIR/.claude/commands/ralph.md"
else
  # Generate the command file inline if source isn't available
  if [ ! -f "$TARGET_DIR/.claude/commands/ralph.md" ]; then
    die "Could not find ralph.md command source. Copy it manually from the Ralph repo."
  fi
fi

echo -e "  ${GREEN}✓${NC} Installed /ralph slash command"

# ─── Configure Claude Code hooks ────────────────────────────────
SETTINGS_FILE="$TARGET_DIR/.claude/settings.local.json"

# Build the hooks configuration
HOOKS_JSON='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/background-tasks.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/bash-guard.sh"
          }
        ]
      },
      {
        "matcher": "EnterPlanMode",
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/block-interactive.sh"
          }
        ]
      },
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/block-interactive.sh"
          }
        ]
      },
      {
        "matcher": "TaskOutput",
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/block-task-output.sh"
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
            "command": ".ralph/hooks/status-kill.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/stop-guard.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".ralph/hooks/subagent-stop-guard.sh"
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
    echo -e "  ${YELLOW}!${NC} Hooks already configured in settings.local.json — merging"
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
RALPH_IGNORES=(
  "# Ralph autonomous loop"
  ".ralph/logs/"
  ".ralph/.stop"
  ".ralph/.pid"
  ".ralph/.directive"
  ".ralph/.piped_directive"
  ".ralph/.iteration_marker"
  ".ralph/ralph.log"
)

if [ -f "$GITIGNORE" ]; then
  NEEDS_NEWLINE=true
  for entry in "${RALPH_IGNORES[@]}"; do
    if ! grep -qF "$entry" "$GITIGNORE" 2>/dev/null; then
      if $NEEDS_NEWLINE; then
        echo "" >> "$GITIGNORE"
        NEEDS_NEWLINE=false
      fi
      echo "$entry" >> "$GITIGNORE"
    fi
  done
else
  printf '%s\n' "${RALPH_IGNORES[@]}" > "$GITIGNORE"
fi

echo -e "  ${GREEN}✓${NC} Updated .gitignore"

# ─── Done ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Ralph installed successfully!${NC}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo ""
echo -e "  1. ${BOLD}Edit your PRD${NC}"
echo -e "     Open ${DIM}.ralph/prd.json${NC} and replace the example story with your own."
echo -e "     Each story needs: id, title, description, acceptanceCriteria, files, status."
echo ""
echo -e "  2. ${BOLD}Start the loop${NC}"
echo -e "     ${DIM}\$.ralph/ralph.sh${NC}"
echo -e "     Or from Claude Code: ${DIM}/ralph${NC}"
echo ""
echo -e "  3. ${BOLD}Quick directive${NC} (skip the PRD)"
echo -e "     ${DIM}\$.ralph/ralph.sh --prompt \"Fix all lint errors\"${NC}"
echo -e "     ${DIM}echo 'Add auth middleware' | .ralph/ralph.sh${NC}"
echo ""
echo -e "  4. ${BOLD}Monitor${NC}"
echo -e "     ${DIM}tmux attach -t ralph-$(basename "$TARGET_DIR")${NC}"
echo -e "     ${DIM}.ralph/ralph-status.sh${NC}"
echo ""
echo -e "  5. ${BOLD}Stop${NC}"
echo -e "     ${DIM}touch .ralph/.stop${NC}  (finishes current iteration)"
echo -e "     ${DIM}tmux kill-session -t ralph-$(basename "$TARGET_DIR")${NC}  (immediate)"
echo ""
echo -e "  Run ${BOLD}.ralph/ralph.sh --help${NC} for all options."
