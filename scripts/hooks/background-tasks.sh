#!/usr/bin/env bash
# ─── Loom Background Task Launcher ────────────────────────────
# Forces all Task tool calls to run in background during Loom
# loops. The orchestrator dispatches subagents and continues —
# results are delivered automatically on the next turn.
# Only active inside a Loom loop (LOOM_ACTIVE=1).
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — require live .pid and non-interactive session
_is_loom() { [ -f "$1/.pid" ] && kill -0 "$(cat "$1/.pid" 2>/dev/null)" 2>/dev/null; }
LOOM_DIR="${PWD}/.loom"
_is_loom "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
_is_loom "$LOOM_DIR" || exit 0
[ -z "${CLAUDECODE:-}" ] || exit 0
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [bg-tasks] $1" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true; }

INPUT=$(cat)

# If already set to background, pass through
ALREADY_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
if [ "$ALREADY_BG" = "true" ]; then
  _dbg "already background, passthrough"
  exit 0
fi

_dbg "forcing Task to background"
# Inject run_in_background: true into the tool input
UPDATED=$(echo "$INPUT" | jq '.tool_input.run_in_background = true')

jq -n --argjson updated "$UPDATED" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: $updated.tool_input
  }
}'
