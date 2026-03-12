#!/usr/bin/env bash
# PreToolUse hook: Block the orchestrator from writing code directly.
# Only active when the orchestrator is running (marker file exists).
# Normal coding sessions are unaffected.

HASH=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | shasum -a 256 | cut -c1-16)
MARKER="/tmp/loom-orchestrating-${HASH}"

if [ -f "$MARKER" ]; then
  echo '{"decision":"block","reason":"BLOCKED: The orchestrator must NEVER write code directly. Dispatch a coder subagent instead. See orchestrator.md Rules."}'
else
  echo '{"decision":"allow"}'
fi
