#!/usr/bin/env bash
# ─── Loom Status Kill ───────────────────────────────────────────
# Terminates the Claude instance the moment status.md is written.
# Uses the universal "continue: false" hook field to force Claude
# to stop processing entirely. This is the hard guarantee that the
# loop actually loops — the agent cannot ignore this.
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — require live .pid and non-interactive session
_is_loom() { [ -f "$1/.pid" ] && kill -0 "$(cat "$1/.pid" 2>/dev/null)" 2>/dev/null; }
LOOM_DIR="${PWD}/.loom"
_is_loom "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
DEBUG_LOG="$LOOM_DIR/logs/debug.log"
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [status-kill] $1" >> "$DEBUG_LOG" 2>/dev/null || true; }

_dbg "fired. LOOM_DIR=$LOOM_DIR LOOM_PREVIEW=${LOOM_PREVIEW:-<unset>}"

if ! _is_loom "$LOOM_DIR" || [ -n "${CLAUDECODE:-}" ]; then
  _dbg "  → exit 0 (no live loom or interactive session)"
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
