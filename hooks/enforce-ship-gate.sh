#!/usr/bin/env bash
# PreToolUse hook (Bash): Block auto-merge. Allow explicit merge after convergence.
# Only active when the orchestrator is running (marker file exists).

HASH=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | shasum -a 256 | cut -c1-16)
MARKER="/tmp/loom-orchestrating-${HASH}"

if [ ! -f "$MARKER" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Block auto-merge flags — explicit merge is allowed after full convergence (§7.4)
if echo "$COMMAND" | grep -qE '(--auto-merge|--auto[^-]|gh pr merge.*--auto)'; then
  echo '{"decision":"block","reason":"BLOCKED: Never use auto-merge. Merge explicitly after verifying all six conditions in §7.4: review converged, PR comments addressed, rejected findings triaged, local CI green, remote CI green, branch rebased."}'
  exit 0
fi

echo '{"decision":"allow"}'
