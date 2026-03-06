#!/usr/bin/env bash
# ─── Loom Status Kill ───────────────────────────────────────────
# Terminates the Claude instance the moment status.md is written.
# Uses the universal "continue: false" hook field to force Claude
# to stop processing entirely. This is the hard guarantee that the
# loop actually loops — the agent cannot ignore this.
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
DEBUG_LOG="$LOOM_DIR/logs/debug.log"
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [status-kill] $1" >> "$DEBUG_LOG" 2>/dev/null || true; }

_dbg "fired. LOOM_DIR=$LOOM_DIR LOOM_PREVIEW=${LOOM_PREVIEW:-<unset>}"

if ! _is_loom_child "$LOOM_DIR"; then
  _dbg "  → exit 0 (not a loom child process)"
  exit 0
fi

# No enforcement in preview
if [ "$LOOM_PREVIEW" = "1" ]; then
  _dbg "  → exit 0 (preview mode)"
  exit 0
fi

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
_dbg "  file_path=$FILE_PATH"

if [[ "$FILE_PATH" == *"/.loom/status.md" ]]; then
  _dbg "  → MATCH! Emitting continue:false to kill claude instance"
  jq -n '{
    continue: false,
    stopReason: "Iteration complete — status.md written. Restarting loop."
  }'
  exit 0
fi

_dbg "  → no match, passthrough"
exit 0
