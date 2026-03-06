#!/usr/bin/env bash
# ─── Loom Interactive Tool Blocker ─────────────────────────────
# Blocks EnterPlanMode and AskUserQuestion during autonomous Loom
# runs. No human is present — execute directly.
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
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [block-interactive] denied interactive tool" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "No human is present. Execute directly."
  }
}'
