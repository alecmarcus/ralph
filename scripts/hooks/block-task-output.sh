#!/usr/bin/env bash
# ─── Loom TaskOutput Blocker ───────────────────────────────────
# Prevents polling for subagent results during Loom loops.
# Background subagent results are delivered automatically by
# Claude Code — polling via TaskOutput causes JSONL transcript
# leaks that pollute the orchestrator's context window.
# Only active inside a Loom loop (LOOM_ACTIVE=1).
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — detect via .loom marker file instead of env var
LOOM_DIR="${PWD}/.loom"
[ -f "$LOOM_DIR/.pid" ] || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
[ -f "$LOOM_DIR/.pid" ] || exit 0
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [block-task-output] denied TaskOutput polling" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "BLOCKED: Do not poll for subagent results. Do not try to check on subagent progress via Bash either. Do not read subagent worktrees. Stop making tool calls entirely and wait — subagent results are delivered to you automatically when each one completes. Do nothing until all subagents have reported back."
  }
}'
