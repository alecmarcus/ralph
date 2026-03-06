#!/usr/bin/env bash
# ─── Loom Stop Guard ────────────────────────────────────────────
# Blocks the agent from exiting until status.md has been updated
# this iteration. Also nudges about docs and memory.
# Only active inside a Loom loop (LOOM_ACTIVE=1).
# ─────────────────────────────────────────────────────────────────

# No-op outside Loom — require live .pid and non-interactive session
_is_loom() { [ -f "$1/.pid" ] && kill -0 "$(cat "$1/.pid" 2>/dev/null)" 2>/dev/null; }
LOOM_DIR="${PWD}/.loom"
_is_loom "$LOOM_DIR" || LOOM_DIR="${CLAUDE_PROJECT_DIR:-.}/.loom"
DEBUG_LOG="$LOOM_DIR/logs/debug.log"
_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [stop-guard] $1" >> "$DEBUG_LOG" 2>/dev/null || true; }

_dbg "fired. LOOM_DIR=$LOOM_DIR LOOM_PREVIEW=${LOOM_PREVIEW:-<unset>}"

if ! _is_loom "$LOOM_DIR" || [ -n "${CLAUDECODE:-}" ]; then
  _dbg "  → exit 0 (no live loom or interactive session)"
  exit 0
fi

# No enforcement in preview
if [ "$LOOM_PREVIEW" = "1" ]; then
  _dbg "  → exit 0 (preview mode)"
  exit 0
fi

INPUT=$(cat)

# Safety valve: if a stop hook already blocked this cycle, let it
# through to prevent infinite loops.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  _dbg "  → exit 0 (stop_hook_active=true, safety valve)"
  exit 0
fi

# ─── Check: status.md updated this iteration ─────────────────────
# start.sh touches .iteration_marker at the start of each iteration.
# If status.md is older than the marker, the agent skipped the status update.

if [ -f "$LOOM_DIR/.iteration_marker" ]; then
  MARKER_TS=$(stat -f %m "$LOOM_DIR/.iteration_marker" 2>/dev/null || echo "?")
  if [ ! -f "$LOOM_DIR/status.md" ]; then
    _dbg "  status.md MISSING (marker=$MARKER_TS) → exit 2 (BLOCK)"
    cat >&2 <<'MSG'
You have not updated .loom/status.md this iteration.

You must write a fresh status report before exiting:
  - Failing Tests (every currently-failing test)
  - Uncommitted Changes (if tests failed and code was not committed)
  - Fixed This Iteration (previously-failing tests now passing)
  - Tests Added / Updated
  - Outcomes (story ID or directive summary, pass/fail for each)

Ensure all commits (if tests pass), documentation updates, and memory storage
are done before writing status.md — the write triggers an immediate kill.
MSG
    exit 2
  fi

  STATUS_TS=$(stat -f %m "$LOOM_DIR/status.md" 2>/dev/null || echo "?")
  if [ "$LOOM_DIR/status.md" -ot "$LOOM_DIR/.iteration_marker" ]; then
    _dbg "  status.md STALE (status=$STATUS_TS < marker=$MARKER_TS) → exit 2 (BLOCK)"
    cat >&2 <<'MSG'
You have not updated .loom/status.md this iteration.

You must write a fresh status report before exiting:
  - Failing Tests (every currently-failing test)
  - Uncommitted Changes (if tests failed and code was not committed)
  - Fixed This Iteration (previously-failing tests now passing)
  - Tests Added / Updated
  - Outcomes (story ID or directive summary, pass/fail for each)

Ensure all commits (if tests pass), documentation updates, and memory storage
are done before writing status.md — the write triggers an immediate kill.
MSG
    exit 2
  fi
  _dbg "  status.md OK (status=$STATUS_TS >= marker=$MARKER_TS) → allowing stop"
else
  _dbg "  no .iteration_marker found → allowing stop"
fi

# ─── Nudge: docs and memory ──────────────────────────────────────
# Advisory only — stderr feedback, does not block the stop.
# The agent should have already done docs (4d) and memory (4e) before reaching here.

cat >&2 <<'MSG'
Reminder: if you haven't already, check if this iteration warrants updates to:
  - Root .docs/ and CLAUDE.md for project-wide knowledge
  - Feature-scoped .docs/ and CLAUDE.md for feature-specific context
  - Memory (Vestige) for patterns, decisions, and gotchas
MSG
_dbg "  → exit 0 (stop allowed with nudge)"
exit 0
