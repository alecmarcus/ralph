#!/usr/bin/env bash
# ─── Loom Interactive Tool Blocker ─────────────────────────────
# Blocks EnterPlanMode and AskUserQuestion during autonomous Loom
# runs. No human is present — execute directly.
# Only active inside a Loom loop (LOOM_ACTIVE=1).
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — require live .pid and non-interactive session
_is_loom() { [ -f "$1/.pid" ] && kill -0 "$(cat "$1/.pid" 2>/dev/null)" 2>/dev/null; }
LOOM_DIR="${PWD}/.loom"
_is_loom "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
_is_loom "$LOOM_DIR" || exit 0
[ -z "${CLAUDECODE:-}" ] || exit 0
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [block-interactive] denied interactive tool" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "No human is present. Execute directly."
  }
}'
