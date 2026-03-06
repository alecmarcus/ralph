#!/usr/bin/env bash
# ─── Loom Subagent Stop Guard ───────────────────────────────────
# Validates that a subagent produced meaningful output before
# the orchestrator accepts its result. Only active in Loom loops.
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

# No enforcement in preview
[ "$LOOM_PREVIEW" = "1" ] && exit 0
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [subagent-stop] $1" >> "$LOOM_DIR/logs/debug.log" 2>/dev/null || true; }

INPUT=$(cat)

# Safety valve: if a stop hook already blocked this cycle, let it
# through to prevent infinite loops.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
[ "$STOP_ACTIVE" = "true" ] && exit 0

MESSAGE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')

# If the subagent produced no output at all, block so the
# orchestrator knows something went wrong.
if [ -z "$MESSAGE" ] || [ ${#MESSAGE} -lt 10 ]; then
  _dbg "blocked: no meaningful output (len=${#MESSAGE})"
  jq -n --arg reason "Subagent returned no meaningful output. Log this failure in status.md and continue with remaining work." '{
    decision: "block",
    reason: $reason
  }'
  exit 0
fi

# ─── Nudge: docs and memory ──────────────────────────────────────
# Always nudge. Advisory (block + continue), not a hard gate.

_dbg "nudge: docs/memory reminder (len=${#MESSAGE})"
jq -n '{
  decision: "block",
  reason: "Before finishing, check if your work warrants updates to:\n\nDocumentation:\n  - Root .docs/ and CLAUDE.md for project-wide knowledge (ADRs, specs, lessons, architecture)\n  - Feature-scoped .docs/ and CLAUDE.md (e.g. src/auth/.docs/) for feature-specific design notes, API decisions, and internal conventions\n  Create feature-scoped .docs/ directories when a feature area has design context worth preserving close to the code.\n\nMemory:\n  - If you discovered patterns, gotchas, or architectural decisions worth preserving, store them using available memory storage or tools so future iterations can benefit."
}'
