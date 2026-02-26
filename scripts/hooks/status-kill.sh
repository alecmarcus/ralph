#!/usr/bin/env bash
# ─── Loom Status Signal ────────────────────────────────────────
# PostToolUse hook on Write: when the agent writes status.md,
# sends a stderr nudge telling it to stop immediately.
# The stop-guard (Stop hook) will allow exit once status.md
# has been updated this iteration.
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom
[ "$LOOM_ACTIVE" != "1" ] && exit 0

# No enforcement in preview
[ "$LOOM_PREVIEW" = "1" ] && exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ "$FILE_PATH" == *"/.loom/status.md" ]]; then
  echo "status.md written — iteration complete. Stop immediately. Do not call any more tools or produce any more output." >&2
  exit 0
fi

exit 0
