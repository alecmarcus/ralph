#!/usr/bin/env bash
# ─── PRD Validation Hook ─────────────────────────────────────
# PostToolUse hook for Write: validates prd.json after writes.
# Only active during Loom loop mode (LOOM_ACTIVE=1).
# Exits 2 to block invalid writes.
# ──────────────────────────────────────────────────────────────

# No-op outside Loom — require live .pid and non-interactive session
_is_loom() { [ -f "$1/.pid" ] && kill -0 "$(cat "$1/.pid" 2>/dev/null)" 2>/dev/null; }
LOOM_DIR="${PWD}/.loom"
_is_loom "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
_is_loom "$LOOM_DIR" || exit 0
[ -z "${CLAUDECODE:-}" ] || exit 0
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [validate-prd] $1" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true; }

# Guard: only trigger on prd.json writes
FILE_PATH="${TOOL_INPUT_FILE_PATH:-}"
[[ "$FILE_PATH" == */prd.json ]] || exit 0
_dbg "validating $FILE_PATH"

# Validate JSON syntax
if ! jq empty "$FILE_PATH" 2>/dev/null; then
  _dbg "  INVALID JSON → exit 2"
  echo "HOOK: prd.json has invalid JSON syntax" >&2
  exit 2
fi

# Validate required top-level keys
MISSING=$(jq -r '
  ["project", "description", "gates", "stories"] as $required |
  [$required[] | select(. as $k | keys | index($k) | not)] |
  if length > 0 then join(", ") else empty end
' "$FILE_PATH" 2>/dev/null)

if [ -n "$MISSING" ]; then
  _dbg "  MISSING KEYS: $MISSING → exit 2"
  echo "HOOK: prd.json missing required keys: $MISSING" >&2
  exit 2
fi

_dbg "  valid"
exit 0
