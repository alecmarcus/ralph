#!/usr/bin/env bash
# ─── PRD Validation Hook ─────────────────────────────────────
# PostToolUse hook for Write: validates prd.json after writes.
# Only active during Loom loop mode (LOOM_ACTIVE=1).
# Exits 2 to block invalid writes.
# ──────────────────────────────────────────────────────────────

# Guard: only run during Loom loop mode
[ "${LOOM_ACTIVE:-}" = "1" ] || exit 0

# Guard: only trigger on prd.json writes
FILE_PATH="${TOOL_INPUT_FILE_PATH:-}"
[[ "$FILE_PATH" == */prd.json ]] || exit 0

# Validate JSON syntax
if ! jq empty "$FILE_PATH" 2>/dev/null; then
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
  echo "HOOK: prd.json missing required keys: $MISSING" >&2
  exit 2
fi

exit 0
