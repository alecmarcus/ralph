#!/usr/bin/env bash
# ─── Loom Background Task Launcher ────────────────────────────
# Forces all Task tool calls to run in background during Loom
# loops. The orchestrator dispatches subagents and continues —
# results are delivered automatically on the next turn.
# Only active inside a Loom loop (LOOM_ACTIVE=1).
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — verify this Claude session is a child of a loom loop
_is_loom_child() {
  local pid_file="$1/.pid" p
  [ -f "$pid_file" ] || return 1
  local loom_pid; loom_pid=$(cat "$pid_file" 2>/dev/null) || return 1
  p=$PPID
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$p" != "0" ]; do
    [ "$p" = "$loom_pid" ] && return 0
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}
LOOM_DIR="${PWD}/.loom"
_is_loom_child "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
_is_loom_child "$LOOM_DIR" || exit 0
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
