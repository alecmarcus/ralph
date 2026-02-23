#!/usr/bin/env bash
set -euo pipefail

# ─── Loom Installer ─────────────────────────────────────────────
# curl -fsSL https://raw.githubusercontent.com/alecmarcus/loom/main/install.sh | bash
# ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

die() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

# ─── Install dependencies ───────────────────────────────────────
install_pkg() {
  local cmd="$1"
  if command -v "$cmd" &>/dev/null; then return 0; fi

  echo -e "${CYAN}Installing $cmd...${NC}"
  if command -v brew &>/dev/null; then
    brew install "$cmd"
  elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq "$cmd"
  elif command -v yum &>/dev/null; then
    sudo yum install -y "$cmd"
  elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm "$cmd"
  else
    die "Cannot install $cmd automatically. Please install it manually."
  fi
  echo -e "  ${GREEN}✓${NC} Installed $cmd"
}

install_pkg jq
install_pkg tmux

if ! command -v claude &>/dev/null; then
  die "Claude Code CLI is required. Install it first: https://docs.anthropic.com/en/docs/claude-code/overview"
fi

# ─── Clone and run setup ────────────────────────────────────────
TARGET_DIR="${1:-$(pwd)}"
TMPDIR=$(mktemp -d)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Cloning Loom..."
git clone --depth 1 https://github.com/alecmarcus/loom.git "$TMPDIR" 2>/dev/null

"$TMPDIR/setup.sh" "$TARGET_DIR"
