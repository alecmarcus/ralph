#!/usr/bin/env bash
# ─── Loom Subagent Stop Guard ───────────────────────────────────
# Validates that a subagent produced meaningful output before
# the orchestrator accepts its result. Only active in Loom loops.
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom
[ "$LOOM_ACTIVE" != "1" ] && exit 0

# No enforcement in dry-run
[ "$LOOM_DRY_RUN" = "1" ] && exit 0

INPUT=$(cat)

MESSAGE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')

# If the subagent produced no output at all, block so the
# orchestrator knows something went wrong.
if [ -z "$MESSAGE" ] || [ ${#MESSAGE} -lt 10 ]; then
  jq -n --arg reason "Subagent returned no meaningful output. Log this failure in status.md and continue with remaining work." '{
    decision: "block",
    reason: $reason
  }'
  exit 0
fi

# Nudge: remind about feature-scoped documentation.
# This is non-blocking — stderr is informational.
if ! echo "$MESSAGE" | grep -qiE '\.docs|CLAUDE\.md'; then
  cat >&2 <<'MSG'
Reminder: if this subagent added or changed a feature area, consider creating
or updating feature-scoped documentation (.docs/ directory and/or CLAUDE.md)
in the relevant directory with usage notes, constraints, and gotchas.
MSG
fi

exit 0
