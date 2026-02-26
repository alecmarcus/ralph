#!/usr/bin/env bash
# ─── Loom Status Kill ───────────────────────────────────────────
# Terminates the Claude instance the moment status.md is written.
# Uses the universal "continue: false" hook field to force Claude
# to stop processing entirely. This is the hard guarantee that the
# loop actually loops — the agent cannot ignore this.
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom
[ "$LOOM_ACTIVE" != "1" ] && exit 0

# No enforcement in preview
[ "$LOOM_PREVIEW" = "1" ] && exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ "$FILE_PATH" == *"/.loom/status.md" ]]; then
  jq -n '{
    continue: false,
    stopReason: "Iteration complete — status.md written. Restarting loop."
  }'
  exit 0
fi

exit 0
