#!/usr/bin/env bash
# ─── Loom Bash Guard ────────────────────────────────────────────
# Blocks destructive shell commands during autonomous Loom runs.
# Only active inside a Loom loop (LOOM_ACTIVE=1).
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — require live .pid and non-interactive session
_is_loom() { [ -f "$1/.pid" ] && kill -0 "$(cat "$1/.pid" 2>/dev/null)" 2>/dev/null; }
LOOM_DIR="${PWD}/.loom"
_is_loom "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
_is_loom "$LOOM_DIR" || exit 0
[ -z "${CLAUDECODE:-}" ] || exit 0
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [bash-guard] $1" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true; }

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

# ─── Blocked patterns ────────────────────────────────────────────
# Each pattern is an extended regex checked against the full command.

BLOCKED=(
  'rm\s+-rf\s+/'
  'rm\s+-rf\s+~'
  'rm\s+-rf\s+\.\s*$'
  'git\s+push\s+.*--force'
  'git\s+push\s+-f\b'
  'git\s+reset\s+--hard'
  'git\s+clean\s+-f'
  'git\s+checkout\s+\.\s*$'
  'git\s+restore\s+\.\s*$'
  'git\s+branch\s+-D'
  'git\s+add\s+(--all|-A)\b'
  'git\s+add\s+\.(\s|$)'
  'chmod\s+-R\s+777'
  'mkfs\.'
  '>\s*/dev/sd'
  'dd\s+if=.*of=/dev'
)

# ─── Subagent polling patterns ──────────────────────────────────
# Detect attempts to poll subagent progress via Bash workarounds.
# These trigger a deny with strong "stop and wait" messaging.

POLLING=(
  '\.claude/worktrees'
  'tail.*\.claude'
  'cat.*\.claude.*output'
  'sleep.*&&'
  'while.*sleep'
  'watch\s'
)

POLLING_RE=$(IFS='|'; echo "${POLLING[*]}")
if echo "$COMMAND" | grep -qE "$POLLING_RE"; then
  _dbg "DENY polling: $COMMAND"
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "BLOCKED: Do not poll for subagent progress. Do not read subagent worktrees. Do not use sleep loops or watch commands. Stop making tool calls entirely and wait — subagent results are delivered to you automatically when each one completes. Do nothing until all subagents have reported back."
    }
  }'
  exit 0
fi

# Fast path: single combined regex check avoids 14 forks on every Bash call
BLOCKED_RE=$(IFS='|'; echo "${BLOCKED[*]}")
if echo "$COMMAND" | grep -qE "$BLOCKED_RE"; then
  # Match found — identify which pattern for the deny reason
  for pattern in "${BLOCKED[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
      _dbg "DENY destructive: pattern='$pattern' cmd=$COMMAND"
      jq -n --arg reason "Destructive command blocked by Loom safety guard: matched pattern '$pattern'" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $reason
        }
      }'
      exit 0
    fi
  done
fi

exit 0
