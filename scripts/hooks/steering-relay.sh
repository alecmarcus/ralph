#!/usr/bin/env bash
# ─── Loom Steering Relay ──────────────────────────────────────────
# PostToolUse hook that checks for .loom/.steering on every tool call.
# If found, reads the content, archives it, and injects it as feedback
# to the running agent via stderr. This gives near-real-time steering
# from the parent Claude context — the agent sees it on its very next
# tool call after the file appears.
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom
[ "$LOOM_ACTIVE" != "1" ] && exit 0

LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
STEERING_FILE="$LOOM_DIR/.steering"

# Fast path: no steering file → exit immediately (single stat syscall)
[ -f "$STEERING_FILE" ] || exit 0

# Read and consume the steering file atomically
CONTENT=$(cat "$STEERING_FILE" 2>/dev/null) || exit 0
[ -z "$CONTENT" ] && exit 0

# Archive with timestamp to prevent re-consumption
ARCHIVE="$LOOM_DIR/logs/steering-$(date '+%Y%m%d-%H%M%S').md"
mkdir -p "$LOOM_DIR/logs"
mv "$STEERING_FILE" "$ARCHIVE" 2>/dev/null || exit 0

# Inject steering as feedback via stdout — PostToolUse hook stdout is
# appended to the tool result, which the agent sees immediately.
cat <<EOF

OPERATOR STEERING (injected mid-iteration):

$CONTENT

Apply these instructions immediately. They take priority over your current plan.
Acknowledge receipt by briefly noting the steering in your next output.

EOF

# Debug log
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [steering-relay] Delivered ${#CONTENT} chars, archived to $ARCHIVE" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true

exit 0
