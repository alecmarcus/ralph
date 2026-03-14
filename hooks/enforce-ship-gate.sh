#!/usr/bin/env bash
# PreToolUse hook (Bash): Block merge commands unconditionally.
# Only active when the orchestrator is running (marker file exists).

HASH=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | shasum -a 256 | cut -c1-16)
MARKER="/tmp/loom-orchestrating-${HASH}"

if [ ! -f "$MARKER" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if echo "$COMMAND" | grep -qE '(gh pr merge|--auto-merge|--auto[^-]|git merge)'; then
  echo '{"decision":"block","reason":"BLOCKED: Never merge PRs directly. PRs are created for human review. The human decides when to merge."}'
  exit 0
fi

echo '{"decision":"allow"}'
