#!/usr/bin/env bash
set -euo pipefail

# ─── Loom Local Installer ───────────────────────────────────────
# curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash
#
# Installs Loom directly into the current project — scripts, hooks,
# skills, and templates. Self-contained: no external dependencies,
# no plugin system, everything tracked in your repo.
# ─────────────────────────────────────────────────────────────────

TARGET_DIR="${1:-$(pwd)}"
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || { echo "Error: directory does not exist: $1" >&2; exit 1; }
REPO_URL="https://github.com/alecmarcus/loom.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

die() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

echo ""
echo -e "  ${BOLD}${CYAN}Loom Installer${NC}"
echo -e "  ${DIM}Target: $TARGET_DIR${NC}"
echo ""

# ─── Check prerequisites ────────────────────────────────────────
MISSING=()
command -v git &>/dev/null    || MISSING+=("git")
command -v claude &>/dev/null || MISSING+=("claude (Claude Code CLI)")
command -v jq &>/dev/null     || MISSING+=("jq")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}Missing required dependencies:${NC}"
  for dep in "${MISSING[@]}"; do echo -e "  - $dep"; done
  echo ""
  command -v claude &>/dev/null || echo -e "  Install Claude Code: ${DIM}https://docs.anthropic.com/en/docs/claude-code/overview${NC}"
  command -v jq &>/dev/null     || echo -e "  Install jq: ${DIM}brew install jq${NC} or ${DIM}apt install jq${NC}"
  die "Install missing dependencies and try again."
fi

if ! command -v tmux &>/dev/null; then
  echo -e "  ${YELLOW}Warning:${NC} tmux not found. Loom uses tmux for its monitoring UI."
  echo -e "  Install: ${DIM}brew install tmux${NC} or ${DIM}apt install tmux${NC}"
  echo ""
fi

# ─── Clone source to temp dir ───────────────────────────────────
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo -e "  ${DIM}Fetching Loom...${NC}"
git clone --depth 1 "$REPO_URL" "$TMPDIR" 2>/dev/null
echo -e "  ${GREEN}✓${NC} Fetched"

SRC="$TMPDIR"

# ─── Copy scripts ───────────────────────────────────────────────
echo -e "  ${DIM}Installing scripts...${NC}"
mkdir -p "$TARGET_DIR/.loom/scripts/hooks"

cp "$SRC/scripts/start.sh"        "$TARGET_DIR/.loom/scripts/"
cp "$SRC/scripts/stop.sh"         "$TARGET_DIR/.loom/scripts/"
cp "$SRC/scripts/kill.sh"         "$TARGET_DIR/.loom/scripts/"
cp "$SRC/scripts/loom-status.sh"  "$TARGET_DIR/.loom/scripts/"
cp "$SRC/scripts/prd.sh"          "$TARGET_DIR/.loom/scripts/"
cp "$SRC/scripts/session-init.sh" "$TARGET_DIR/.loom/scripts/"
cp "$SRC/scripts/hooks/"*.sh      "$TARGET_DIR/.loom/scripts/hooks/"

chmod +x "$TARGET_DIR/.loom/scripts/"*.sh
chmod +x "$TARGET_DIR/.loom/scripts/hooks/"*.sh

echo -e "  ${GREEN}✓${NC} Scripts"

# ─── Copy templates ─────────────────────────────────────────────
mkdir -p "$TARGET_DIR/.loom/templates"
cp "$SRC/templates/prompt.md"           "$TARGET_DIR/.loom/templates/"
cp "$SRC/templates/directive.md"        "$TARGET_DIR/.loom/templates/"
cp "$SRC/templates/claude-md-section.md" "$TARGET_DIR/.loom/templates/"

echo -e "  ${GREEN}✓${NC} Templates"

# ─── Write version file ──────────────────────────────────────────
VERSION=$(jq -r '.version' "$SRC/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")
echo "$VERSION" > "$TARGET_DIR/.loom/.version"
echo -e "  ${GREEN}✓${NC} Version $VERSION"

# ─── Install skills ─────────────────────────────────────────────
echo -e "  ${DIM}Installing skills...${NC}"

SKILL_MAP=(
  "start:loom:start"
  "stop:loom:stop"
  "kill:loom:kill"
  "status:loom:status"
  "preview:loom:preview"
  "prd:loom:prd"
  "setup:loom:setup"
  "init:loom:init"
)

for mapping in "${SKILL_MAP[@]}"; do
  src_name="${mapping%%:*}"
  dest_name="${mapping#*:}"
  src_dir="$SRC/skills/$src_name"
  dest_dir="$TARGET_DIR/.claude/skills/$dest_name"

  if [ -f "$src_dir/SKILL.md" ]; then
    mkdir -p "$dest_dir"
    # Copy and update the name field in frontmatter
    sed "s/^name: $src_name$/name: $dest_name/" "$src_dir/SKILL.md" > "$dest_dir/SKILL.md"
    # Copy companion files and directories (guides, etc.)
    for item in "$src_dir"/*; do
      [ "$(basename "$item")" = "SKILL.md" ] && continue
      [ -e "$item" ] || continue
      cp -r "$item" "$dest_dir/"
    done
  fi
done

echo -e "  ${GREEN}✓${NC} Skills (/loom:start, /loom:stop, etc.)"

# ─── Configure hooks ────────────────────────────────────────────
echo -e "  ${DIM}Configuring hooks...${NC}"
SETTINGS_FILE="$TARGET_DIR/.claude/settings.json"

HOOKS_JSON='{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{ "type": "command", "command": ".loom/scripts/session-init.sh" }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/background-tasks.sh" }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/bash-guard.sh" }]
      },
      {
        "matcher": "EnterPlanMode",
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/block-interactive.sh" }]
      },
      {
        "matcher": "AskUserQuestion",
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/block-interactive.sh" }]
      },
      {
        "matcher": "TaskOutput",
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/block-task-output.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/status-kill.sh" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/stop-guard.sh" }]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/subagent-recall.sh" }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{ "type": "command", "command": ".loom/scripts/hooks/subagent-stop-guard.sh" }]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
  EXISTING=$(cat "$SETTINGS_FILE")
  if echo "$EXISTING" | jq -e '.hooks' &>/dev/null; then
    # Merge: plugin hooks into existing hooks config
    MERGED=$(echo "$EXISTING" | jq --argjson new "$HOOKS_JSON" '.hooks = ($new.hooks * .hooks)')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
    echo -e "  ${GREEN}✓${NC} Hooks merged into existing settings.json"
  else
    MERGED=$(echo "$EXISTING" | jq --argjson new "$HOOKS_JSON" '. + $new')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
    echo -e "  ${GREEN}✓${NC} Hooks added to settings.json"
  fi
else
  mkdir -p "$TARGET_DIR/.claude"
  echo "$HOOKS_JSON" | jq '.' > "$SETTINGS_FILE"
  echo -e "  ${GREEN}✓${NC} Created settings.json with hooks"
fi

# ─── Project files (don't overwrite existing) ───────────────────
echo -e "  ${DIM}Setting up project files...${NC}"
mkdir -p "$TARGET_DIR/.loom/logs"

# .gitignore
if [ ! -f "$TARGET_DIR/.loom/.gitignore" ]; then
  cp "$SRC/templates/gitignore" "$TARGET_DIR/.loom/.gitignore"
  echo -e "  ${GREEN}✓${NC} .loom/.gitignore"
fi

# prd.json
if [ ! -f "$TARGET_DIR/.loom/prd.json" ]; then
  cp "$SRC/templates/prd.json" "$TARGET_DIR/.loom/prd.json"
  echo -e "  ${GREEN}✓${NC} .loom/prd.json (template)"
fi

# status.md
if [ ! -f "$TARGET_DIR/.loom/status.md" ]; then
  cp "$SRC/templates/status.md" "$TARGET_DIR/.loom/status.md"
  echo -e "  ${GREEN}✓${NC} .loom/status.md"
fi

# .plugin_root — points to .loom/ itself for local installs.
# The session-init.sh hook will overwrite this on each session start,
# but we seed it here so skills work immediately.
echo "$TARGET_DIR/.loom" > "$TARGET_DIR/.loom/.plugin_root"

# ─── CLAUDE.md ──────────────────────────────────────────────────
CLAUDEMD="$TARGET_DIR/CLAUDE.md"
SECTION_MARKER="<!-- loom:begin -->"
SECTION_CONTENT=$(cat "$SRC/templates/claude-md-section.md")

if [ -f "$CLAUDEMD" ]; then
  if grep -qF "$SECTION_MARKER" "$CLAUDEMD" 2>/dev/null; then
    echo -e "  ${DIM}CLAUDE.md already has Loom section — skipping${NC}"
  else
    printf '\n%s\n' "$SECTION_CONTENT" >> "$CLAUDEMD"
    echo -e "  ${GREEN}✓${NC} Appended Loom section to CLAUDE.md"
  fi
else
  printf '%s\n' "$SECTION_CONTENT" > "$CLAUDEMD"
  echo -e "  ${GREEN}✓${NC} Created CLAUDE.md with Loom section"
fi

# ─── Done ────────────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}${BOLD}Loom installed!${NC}"
echo ""
echo -e "  Installed to:        ${BOLD}$TARGET_DIR/.loom/${NC}"
echo -e "  Skills:              ${BOLD}$TARGET_DIR/.claude/skills/loom:*${NC}"
echo -e "  Hooks:               ${BOLD}$TARGET_DIR/.claude/settings.json${NC}"
echo ""
echo -e "  ${CYAN}Next steps:${NC}"
echo -e "    1. ${BOLD}/loom:prd spec.md${NC}                  Generate a PRD"
echo -e "    2. ${BOLD}/loom:start${NC}                        Start the loop"
echo -e "    3. ${BOLD}/loom:start Fix all lint errors${NC}    Or give it a task"
echo ""
echo -e "  ${DIM}Update: re-run this script in the project directory${NC}"
echo ""
