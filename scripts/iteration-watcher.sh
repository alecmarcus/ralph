#!/usr/bin/env bash
# ─── Loom Iteration Watcher ──────────────────────────────────────
# Watches iterations.log for the next new entry or loop termination.
# Designed to run as a background Task in the interactive Claude
# session. Exits when:
#   1. A new iteration completes (outputs the new log line(s))
#   2. The loop dies (outputs LOOP_TERMINATED + final lines)
#
# Usage: iteration-watcher.sh <session-name> [loom-dir]
# ─────────────────────────────────────────────────────────────────

SESSION="${1:?Usage: iteration-watcher.sh <session-name> [loom-dir]}"
LOOM_DIR="${2:-.loom}"
LOGFILE="$LOOM_DIR/logs/iterations.log"
DEBUG_LOG="$LOOM_DIR/logs/debug.log"
PID_FILE="$LOOM_DIR/.pid"

_dbg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [iter-watcher] $1" >> "$DEBUG_LOG" 2>/dev/null || true; }

# Wait for iterations.log to exist (loop may still be initializing)
WAIT=0
while [ ! -f "$LOGFILE" ] && [ "$WAIT" -lt 30 ]; do
  WAIT=$((WAIT + 1))
  sleep 1
done

# Baseline: current line count at launch
BASELINE=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
_dbg "started. session=$SESSION logfile=$LOGFILE baseline=$BASELINE pid_file=$PID_FILE"

# Determine liveness check mode: tmux session or PID file
is_loop_alive() {
  # Try tmux first
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0
  fi
  # Fallback: check PID file (inline/nohup mode)
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

POLL=0
while true; do
  POLL=$((POLL + 1))

  # Check for new iteration entries
  CURRENT=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$CURRENT" -gt "$BASELINE" ]; then
    NEW_LINES=$((CURRENT - BASELINE))
    _dbg "poll=$POLL: NEW LINES detected ($BASELINE→$CURRENT, +$NEW_LINES). Exiting with iteration data."
    tail -n "$NEW_LINES" "$LOGFILE"
    exit 0
  fi

  # Check if loop is still running
  if ! is_loop_alive; then
    _dbg "poll=$POLL: loop is GONE (no tmux '$SESSION', no live PID). Outputting LOOP_TERMINATED."
    echo "LOOP_TERMINATED"
    [ -f "$LOGFILE" ] && tail -3 "$LOGFILE"
    exit 0
  fi

  # Log every 20th poll (~60s) to avoid flooding
  if [ $((POLL % 20)) -eq 0 ]; then
    _dbg "poll=$POLL: still waiting (baseline=$BASELINE current=$CURRENT session=$SESSION)"
  fi

  sleep 3
done
