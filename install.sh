#!/usr/bin/env bash
set -euo pipefail

# ─── Loom Installer ─────────────────────────────────────────────
# curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash
#
# Alternative to the plugin marketplace install. Clones the repo
# and configures your shell so `claude` always loads Loom.
# ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${LOOM_INSTALL_DIR:-$HOME/.loom}"
REPO_URL="https://github.com/alecmarcus/loom.git"
SHELL_MARKER="# loom plugin"
SHELL_LINE="alias claude='claude --plugin-dir $INSTALL_DIR' $SHELL_MARKER"

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
echo ""

# ─── Check prerequisites ────────────────────────────────────────
MISSING=()
command -v git &>/dev/null    || MISSING+=("git")
command -v claude &>/dev/null || MISSING+=("claude (Claude Code CLI)")
command -v jq &>/dev/null     || MISSING+=("jq")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}Missing required dependencies:${NC}"
  for dep in "${MISSING[@]}"; do
    echo -e "  - $dep"
  done
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

# ─── Clone or update ────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  echo -e "  ${DIM}Updating existing install...${NC}"
  git -C "$INSTALL_DIR" pull --ff-only origin main 2>/dev/null || {
    echo -e "  ${YELLOW}Pull failed — re-cloning...${NC}"
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  }
  echo -e "  ${GREEN}✓${NC} Updated"
else
  if [ -d "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR already exists but is not a git repo. Remove it or set LOOM_INSTALL_DIR."
  fi
  echo -e "  ${DIM}Cloning to $INSTALL_DIR...${NC}"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  echo -e "  ${GREEN}✓${NC} Cloned"
fi

# ─── Make scripts executable ────────────────────────────────────
chmod +x "$INSTALL_DIR/scripts/"*.sh
chmod +x "$INSTALL_DIR/scripts/hooks/"*.sh 2>/dev/null || true

# ─── Configure shell ────────────────────────────────────────────
# Detect RC file
detect_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash)
      # macOS uses .bash_profile for login shells
      if [ -f "$HOME/.bash_profile" ]; then
        echo "$HOME/.bash_profile"
      else
        echo "$HOME/.bashrc"
      fi
      ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

RC_FILE="$(detect_rc)"
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"

if [ "$SHELL_NAME" = "fish" ]; then
  SHELL_LINE="alias claude 'claude --plugin-dir $INSTALL_DIR' $SHELL_MARKER"
fi

# Resolve symlinks so sed -i works on the real file
RC_FILE_REAL="$(readlink -f "$RC_FILE" 2>/dev/null || readlink "$RC_FILE" 2>/dev/null || echo "$RC_FILE")"

if grep -qF "$SHELL_MARKER" "$RC_FILE_REAL" 2>/dev/null; then
  # Already configured — update in case install dir changed
  if grep -qF "$SHELL_LINE" "$RC_FILE_REAL" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Shell already configured"
  else
    # Replace existing loom line (use temp file for portability)
    grep -vF "$SHELL_MARKER" "$RC_FILE_REAL" > "${RC_FILE_REAL}.loom-tmp"
    printf '%s\n' "$SHELL_LINE" >> "${RC_FILE_REAL}.loom-tmp"
    mv "${RC_FILE_REAL}.loom-tmp" "$RC_FILE_REAL"
    echo -e "  ${GREEN}✓${NC} Updated shell config in $RC_FILE"
  fi
else
  # Append
  printf '\n%s\n' "$SHELL_LINE" >> "$RC_FILE_REAL"
  echo -e "  ${GREEN}✓${NC} Added to $RC_FILE"
fi

# ─── Done ────────────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}${BOLD}Loom installed!${NC}"
echo ""
echo -e "  Restart your terminal, then in any project:"
echo ""
echo -e "    ${BOLD}claude${NC}          ${DIM}# loom is loaded automatically${NC}"
echo -e "    ${BOLD}/loom:init${NC}      ${DIM}# first-time project setup${NC}"
echo -e "    ${BOLD}/loom:start${NC}     ${DIM}# start the loop${NC}"
echo ""
echo -e "  ${DIM}Update: re-run this script or git -C $INSTALL_DIR pull${NC}"
echo -e "  ${DIM}Uninstall: rm -rf $INSTALL_DIR && remove the loom line from $RC_FILE${NC}"
echo ""
