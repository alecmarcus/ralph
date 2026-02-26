#!/usr/bin/env bash
set -euo pipefail

# ─── Loom: Autonomous Development Loop ──────────────────────────
# Runs Claude Code in a loop, reading instructions from prompt.md
# each iteration. Designed for tmux-based monitoring.
# ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOM_DIR="$PROJECT_DIR/.loom"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
LOG_FILE="$LOOM_DIR/loom.log"
TMUX_SESSION="loom-${PROJECT_NAME}"
MAX_ITERATIONS=500
# Default to tmux when running from a terminal (not inside Claude Code
# or already inside a tmux session from re-execution), but only if
# tmux is actually installed.
if [ -n "${CLAUDECODE:-}" ] || [ -n "${TMUX:-}" ] || ! command -v tmux &>/dev/null; then
  USE_TMUX=false
else
  USE_TMUX=true
fi
PREVIEW=false
DIRECTIVE_FILE=""
TIMEOUT=10800
MAX_FAILURES=3
CONSECUTIVE_FAILURES=0
PRD_PATH=""

# ─── Sources (composable — multiple can be combined) ─────────────
SOURCES_LINEAR=""       # Linear query/URL
SOURCES_GITHUB=""       # GitHub query/URL/number
SOURCES_SLACK=""        # Slack permalink URL
SOURCES_NOTION=""       # Notion page URL or search query
SOURCES_SENTRY=""       # Sentry issue URL or search query
SOURCES_PROMPT=""       # Inline text or file path
SOURCES_PIPED=""        # Piped stdin content

# ─── Worktree ────────────────────────────────────────────────────
USE_WORKTREE=""         # "" = auto, "yes", "no"
WORKTREE_DIR=""
WORKTREE_BRANCH=""
RESUME_WORKTREE=""
CREATE_PR="yes"         # "yes" = push + PR after loop, "no" = skip
WAIT_MODE=false         # --wait: block until tmux session ends (for background watcher)

# ─── Colors (terminal only — stripped from log file) ─────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
TERM_WIDTH=$(tput cols 2>/dev/null || echo 120)

# ─── Helpers ─────────────────────────────────────────────────────
die() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

is_url() { [[ "$1" == http://* ]] || [[ "$1" == https://* ]]; }

has_sources() {
  [ -n "$SOURCES_LINEAR" ] || [ -n "$SOURCES_GITHUB" ] || \
  [ -n "$SOURCES_SLACK" ] || [ -n "$SOURCES_NOTION" ] || \
  [ -n "$SOURCES_SENTRY" ] || [ -n "$SOURCES_PROMPT" ] || [ -n "$SOURCES_PIPED" ]
}

generate_branch_slug() {
  # Build a short summary (not the full content) for slug generation
  local summary=""
  if [ -n "$PRD_PATH" ] && [ -f "$PRD_PATH" ]; then
    summary="$(jq -r '.project + ": " + .description' "$PRD_PATH" 2>/dev/null)"
  fi
  if [ -n "$SOURCES_LINEAR" ]; then
    summary="${summary:+$summary; }linear: $SOURCES_LINEAR"
  fi
  if [ -n "$SOURCES_GITHUB" ]; then
    summary="${summary:+$summary; }github: $SOURCES_GITHUB"
  fi
  if [ -n "$SOURCES_SLACK" ]; then
    summary="${summary:+$summary; }slack context"
  fi
  if [ -n "$SOURCES_NOTION" ]; then
    summary="${summary:+$summary; }notion: $SOURCES_NOTION"
  fi
  if [ -n "$SOURCES_SENTRY" ]; then
    summary="${summary:+$summary; }sentry: $SOURCES_SENTRY"
  fi
  if [ -z "$summary" ] && [ -n "$SOURCES_PROMPT" ]; then
    if [ -f "$SOURCES_PROMPT" ]; then
      summary="$(head -c 200 "$SOURCES_PROMPT")"
    else
      summary="$(echo "$SOURCES_PROMPT" | head -c 200)"
    fi
  fi
  if [ -z "$summary" ] && [ -n "$DIRECTIVE_FILE" ] && [ -f "$DIRECTIVE_FILE" ]; then
    summary="$(head -c 200 "$DIRECTIVE_FILE")"
  fi

  local prompt
  if [ -n "$summary" ]; then
    prompt="three-word kebab-case git branch slug for: ${summary:0:200}"
  else
    prompt="three-word kebab-case git branch slug, random evocative words"
  fi

  local raw slug
  raw=$(claude -p --model haiku "Output ONLY a slug like fix-auth-bug. No quotes, no explanation. $prompt" 2>/dev/null | head -1)

  # Try to extract a kebab-case slug (e.g., "fix-auth-bug") from the response
  slug=$(echo "$raw" | grep -oE '[a-z][a-z0-9]*(-[a-z0-9]+)+' | head -1)

  # Fallback: take first 3 words, sanitize to kebab-case
  if [ -z "$slug" ]; then
    slug=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]/ /g; s/  */ /g; s/^ //; s/ $//' | awk '{for(i=1;i<=3&&i<=NF;i++) printf "%s%s",$i,(i<3&&i<NF?"-":"")}')
  fi

  # Enforce max length
  slug=$(echo "$slug" | head -c 40 | sed 's/-$//')

  # Ultimate fallback if claude call failed entirely
  [ -z "$slug" ] && slug="loom-$(date '+%Y%m%d-%H%M%S')"

  echo "$slug"
}

# ─── Template Resolution ────────────────────────────────────────
# Local override (per-project) > plugin default
resolve_template() {
  local name="$1"
  if [[ -f "$LOOM_DIR/$name" ]]; then
    echo "$LOOM_DIR/$name"
  elif [[ -f "$PLUGIN_ROOT/templates/$name" ]]; then
    echo "$PLUGIN_ROOT/templates/$name"
  else
    die "Template $name not found"
  fi
}

# ─── PRD Resolution ─────────────────────────────────────────────
# Resolution order: --prd flag > .loom/config.json > .loom/prd.json
resolve_prd() {
  # 1. --prd flag (already in PRD_PATH)
  if [ -n "$PRD_PATH" ]; then
    if [ -d "$PRD_PATH" ]; then
      local jsons=()
      while IFS= read -r -d '' f; do
        jsons+=("$f")
      done < <(find "$PRD_PATH" -maxdepth 1 -name '*.json' -print0 2>/dev/null | sort -z)
      case ${#jsons[@]} in
        0) die "No PRD files found in directory: $PRD_PATH" ;;
        1) PRD_PATH="${jsons[0]}" ;;
        *) echo -e "${YELLOW}Multiple PRD files in $PRD_PATH:${NC}" >&2
           for f in "${jsons[@]}"; do echo "  $(basename "$f")" >&2; done
           die "Specify which PRD to use with --prd <file>" ;;
      esac
    fi
    [ -f "$PRD_PATH" ] || die "PRD file not found: $PRD_PATH"
    return
  fi

  # 2. .loom/config.json
  if [ -f "$LOOM_DIR/config.json" ]; then
    local cfg_prd
    cfg_prd=$(jq -r '.prd // empty' "$LOOM_DIR/config.json" 2>/dev/null)
    if [ -n "$cfg_prd" ]; then
      # Resolve relative paths against project dir
      [[ "$cfg_prd" != /* ]] && cfg_prd="$PROJECT_DIR/$cfg_prd"
      if [ -d "$cfg_prd" ]; then
        local jsons=()
        while IFS= read -r -d '' f; do
          jsons+=("$f")
        done < <(find "$cfg_prd" -maxdepth 1 -name '*.json' -print0 2>/dev/null | sort -z)
        case ${#jsons[@]} in
          0) die "No PRD files found in directory: $cfg_prd" ;;
          1) PRD_PATH="${jsons[0]}" ;;
          *) echo -e "${YELLOW}Multiple PRD files in $cfg_prd:${NC}" >&2
             for f in "${jsons[@]}"; do echo "  $(basename "$f")" >&2; done
             die "Specify which PRD to use with --prd <file>" ;;
        esac
      elif [ -f "$cfg_prd" ]; then
        PRD_PATH="$cfg_prd"
      else
        die "PRD path from config.json not found: $cfg_prd"
      fi
      return
    fi
  fi

  # 3. Default
  PRD_PATH="$LOOM_DIR/prd.json"
}

# ─── Parse Arguments ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-iterations|-m)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      MAX_ITERATIONS="$2"
      [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || die "--max-iterations must be a positive integer, got '$MAX_ITERATIONS'"
      shift 2
      ;;
    --preview|-d)
      PREVIEW=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "$1 requires a value in seconds"
      TIMEOUT="$2"
      [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer, got '$TIMEOUT'"
      shift 2
      ;;
    --max-failures)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      MAX_FAILURES="$2"
      [[ "$MAX_FAILURES" =~ ^[0-9]+$ ]] || die "--max-failures must be a positive integer, got '$MAX_FAILURES'"
      shift 2
      ;;
    --prompt)
      [[ $# -ge 2 ]] || die "$1 requires text or a file path"
      SOURCES_PROMPT="$2"
      shift 2
      ;;
    --directive)
      # Legacy alias for --prompt
      [[ $# -ge 2 ]] || die "$1 requires text or a file path"
      SOURCES_PROMPT="$2"
      shift 2
      ;;
    --linear)
      [[ $# -ge 2 ]] || die "$1 requires a query, ticket ID, or URL"
      SOURCES_LINEAR="$2"
      shift 2
      ;;
    --github)
      [[ $# -ge 2 ]] || die "$1 requires a query, issue number, or URL"
      SOURCES_GITHUB="$2"
      shift 2
      ;;
    --slack)
      [[ $# -ge 2 ]] || die "$1 requires a Slack message permalink URL"
      SOURCES_SLACK="$2"
      shift 2
      ;;
    --notion)
      [[ $# -ge 2 ]] || die "$1 requires a page URL or search query"
      SOURCES_NOTION="$2"
      shift 2
      ;;
    --sentry)
      [[ $# -ge 2 ]] || die "$1 requires an issue URL or search query"
      SOURCES_SENTRY="$2"
      shift 2
      ;;
    --worktree)
      [[ $# -ge 2 ]] || die "$1 requires true or false"
      USE_WORKTREE=$([ "$2" = "true" ] && echo "yes" || echo "no")
      shift 2
      ;;
    --pr)
      [[ $# -ge 2 ]] || die "$1 requires true or false"
      CREATE_PR=$([ "$2" = "true" ] && echo "yes" || echo "no")
      shift 2
      ;;
    --prd)
      [[ $# -ge 2 ]] || die "$1 requires a path to a PRD file or directory"
      PRD_PATH="$2"
      shift 2
      ;;
    --session-name)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TMUX_SESSION="$2"
      shift 2
      ;;
    --wait)
      WAIT_MODE=true
      shift 1
      ;;
    --resume)
      if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
        RESUME_WORKTREE="$2"
        shift 2
      else
        # Default to current directory
        RESUME_WORKTREE="."
        shift 1
      fi
      ;;
    -h|--help)
      cat <<'HELPEOF'
Usage: start.sh [OPTIONS]

Options:
  -m, --max-iterations N   Maximum loop iterations (default: 500)
  -d, --preview            Analyze one iteration without executing changes
  --timeout SECONDS        Per-iteration timeout (default: 10800)
  --max-failures N         Consecutive failures before halt (default: 3)
  -h, --help               Show this help

Sources (can be combined):
  --prompt TEXT_OR_PATH    Run with inline text or file as directive
  --linear QUERY_OR_URL   Fetch from Linear MCP, implement, update ticket
  --github QUERY_OR_URL   Fetch from GitHub via gh, implement, close issues
  --slack URL             Fetch Slack message context, implement
  --notion URL_OR_QUERY   Fetch Notion page via MCP, implement
  --sentry URL_OR_QUERY   Fetch Sentry issue via MCP, fix the error

  Multiple sources can be combined:
    start.sh --linear PHN-42 --github 13 --prompt "Also fix lint"

  Without a source flag, runs in PRD mode (reads prd.json).
  A directive can also be piped via stdin:
    echo 'Fix all lint errors' | start.sh
    echo 'Only work on AC-001' | start.sh --preview

PRD:
  --prd PATH              PRD file or directory (overrides .loom/config.json)

Worktree:
  --worktree              Git worktree isolation (default: on)
  --pr                    Push + PR after loop (default: on)
  --resume [PATH_OR_BRANCH] Reuse existing worktree (default: current dir)

Graceful stop:
  touch .loom/.stop      Stop after the current iteration finishes
HELPEOF
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# ─── Wait-only mode ──────────────────────────────────────────────
# When --wait is set, skip all initialization and just watch the
# tmux session. This is invoked by the start skill as a background
# task so the parent Claude session gets notified when the loop ends.
if $WAIT_MODE; then
  # Wait for session to appear (race: watcher may start before foreground creates it)
  for _ in $(seq 1 30); do
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null && break
    sleep 1
  done
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "Timed out waiting for tmux session '$TMUX_SESSION' to appear"
    exit 1
  fi
  # Block until the session ends
  while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do sleep 5; done
  echo ""
  echo "── Loom session '$TMUX_SESSION' ended ──"
  tail -20 "$LOOM_DIR/logs/master.log" 2>/dev/null
  exit 0
fi

# ─── Piped stdin ─────────────────────────────────────────────────
if [ ! -t 0 ]; then
  # detect_timeout_cmd runs later, so resolve timeout binary inline here
  _tc=""; command -v gtimeout &>/dev/null && _tc=gtimeout || command -v timeout &>/dev/null && _tc=timeout
  if [ -n "$_tc" ]; then
    PIPED="$("$_tc" 1 cat 2>/dev/null || true)"
  else
    PIPED="$(cat 2>/dev/null || true)"
  fi
  if [ -n "$PIPED" ]; then
    SOURCES_PIPED="$PIPED"
  fi
  unset _tc
fi

# ─── Build Directive Content ─────────────────────────────────────
# Sources are composable. Each active source appends a section to
# the directive. If only --prompt points to an existing file and
# no other sources are active, use that file directly.

build_directive() {
  local parts=()

  # Linear
  if [ -n "$SOURCES_LINEAR" ]; then
    if is_url "$SOURCES_LINEAR"; then
      parts+=("## Linear Issue

Fetch the Linear issue at this URL using the Linear MCP tools:

$SOURCES_LINEAR

Read the issue details (title, description, acceptance criteria, comments). Implement everything described in the issue. After successful implementation, update the ticket status in Linear to reflect completion.")
    else
      parts+=("## Linear Issue

Search Linear using the Linear MCP tools for issues matching:

$SOURCES_LINEAR

Fetch the matching issue(s) and read their details (title, description, acceptance criteria, comments). Implement what's described. After successful implementation, update the ticket status in Linear to reflect completion.")
    fi
  fi

  # GitHub
  if [ -n "$SOURCES_GITHUB" ]; then
    if is_url "$SOURCES_GITHUB"; then
      parts+=("## GitHub Issue

Fetch the GitHub issue at this URL using \`gh\`:

\`\`\`bash
gh issue view \"$SOURCES_GITHUB\" --json title,body,comments,labels,state
\`\`\`

Read the issue details. Implement everything described. After successful implementation, comment on the issue with a summary of changes and close it:

\`\`\`bash
gh issue comment <number> --body \"Implemented in this iteration. <summary>\"
gh issue close <number>
\`\`\`")
    elif [[ "$SOURCES_GITHUB" =~ ^[0-9]+$ ]]; then
      parts+=("## GitHub Issue

Fetch GitHub issue #$SOURCES_GITHUB using \`gh\`:

\`\`\`bash
gh issue view $SOURCES_GITHUB --json title,body,comments,labels,state
\`\`\`

Read the issue details. Implement everything described. After successful implementation, comment on the issue with a summary of changes and close it:

\`\`\`bash
gh issue comment $SOURCES_GITHUB --body \"Implemented in this iteration. <summary>\"
gh issue close $SOURCES_GITHUB
\`\`\`")
    else
      parts+=("## GitHub Issues

Search GitHub issues matching this query using \`gh\`:

\`\`\`bash
gh issue list --search \"$SOURCES_GITHUB\" --json number,title,body,state --limit 10
\`\`\`

Review the matching issues. Implement what's described in the most relevant open issue(s). After successful implementation, comment on each resolved issue with a summary of changes and close it.")
    fi
  fi

  # Slack
  if [ -n "$SOURCES_SLACK" ]; then
    is_url "$SOURCES_SLACK" || die "--slack requires a Slack message permalink URL"
    parts+=("## Slack Context

Fetch the Slack message at this permalink:

$SOURCES_SLACK

Use any available Slack MCP tools or web fetch to read the message and its thread context. Understand what's being described or requested. Implement it.")
  fi

  # Notion
  if [ -n "$SOURCES_NOTION" ]; then
    if is_url "$SOURCES_NOTION"; then
      parts+=("## Notion Page

Fetch the Notion page at this URL using the Notion MCP tools:

$SOURCES_NOTION

Read the page content, including any sub-pages, databases, or linked references. Understand the requirements or spec described. Implement everything specified.")
    else
      parts+=("## Notion Page

Search Notion using the Notion MCP tools for pages matching:

$SOURCES_NOTION

Read the matching page(s) and their content, including sub-pages and linked references. Understand the requirements or spec described. Implement everything specified.")
    fi
  fi

  # Sentry
  if [ -n "$SOURCES_SENTRY" ]; then
    if is_url "$SOURCES_SENTRY"; then
      parts+=("## Sentry Issue

Fetch the Sentry issue at this URL using the Sentry MCP tools:

$SOURCES_SENTRY

Read the error details: exception type, stack trace, breadcrumbs, tags, and any linked issues. Identify the root cause from the stack trace. Fix the bug. Add a regression test that reproduces the error and verifies the fix.")
    else
      parts+=("## Sentry Issue

Search Sentry using the Sentry MCP tools for issues matching:

$SOURCES_SENTRY

Read the matching issue(s) and their error details: exception type, stack trace, breadcrumbs, tags. Identify the root cause from the stack trace. Fix the bug(s). Add regression tests that reproduce each error and verify the fix.")
    fi
  fi

  # Prompt (inline text or file contents)
  if [ -n "$SOURCES_PROMPT" ]; then
    if [ -f "$SOURCES_PROMPT" ] && [ ${#parts[@]} -eq 0 ] && [ -z "$SOURCES_PIPED" ]; then
      # Only source is a file — use directly, skip composing
      DIRECTIVE_FILE="$SOURCES_PROMPT"
      return
    elif [ -f "$SOURCES_PROMPT" ]; then
      parts+=("## Additional Instructions

$(cat "$SOURCES_PROMPT")")
    else
      parts+=("## Additional Instructions

$SOURCES_PROMPT")
    fi
  fi

  # Piped stdin
  if [ -n "$SOURCES_PIPED" ]; then
    parts+=("## Additional Instructions

$SOURCES_PIPED")
  fi

  # Compose all parts into a single directive file
  if [ ${#parts[@]} -gt 0 ]; then
    local result="${parts[0]}"
    for ((i=1; i<${#parts[@]}; i++)); do
      result+=$'\n\n---\n\n'"${parts[$i]}"
    done
    printf '%s' "$result" > "$LOOM_DIR/.directive"
    DIRECTIVE_FILE="$LOOM_DIR/.directive"
  fi
}

if has_sources; then
  build_directive
fi

# ─── Resolve PRD path ──────────────────────────────────────────
resolve_prd
export LOOM_PRD_PATH="$PRD_PATH"

# ─── Worktree Auto-Detection ────────────────────────────────────
resolve_worktree() {
  # Previews don't modify anything — skip worktree creation
  if $PREVIEW && [ -z "$RESUME_WORKTREE" ]; then
    USE_WORKTREE="no"
    return
  fi
  if [ -z "$USE_WORKTREE" ]; then
    USE_WORKTREE="yes"
  fi
}

setup_worktree() {
  local base_dir="$HOME/.claude-worktrees/$PROJECT_NAME"
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"

  if [ -n "$RESUME_WORKTREE" ]; then
    # Resume existing worktree
    if [ -d "$RESUME_WORKTREE" ]; then
      WORKTREE_DIR="$(cd "$RESUME_WORKTREE" && pwd)"
    elif [ -d "$base_dir/$RESUME_WORKTREE" ]; then
      WORKTREE_DIR="$base_dir/$RESUME_WORKTREE"
    else
      die "Cannot find worktree: $RESUME_WORKTREE"
    fi
    WORKTREE_BRANCH="$(git -C "$WORKTREE_DIR" branch --show-current 2>/dev/null)" || die "Failed to detect branch in worktree"
    log "${CYAN}Resuming worktree:${NC} $WORKTREE_DIR (branch: $WORKTREE_BRANCH)"
    return
  fi

  WORKTREE_BRANCH="loom/$(generate_branch_slug)"
  WORKTREE_DIR="$base_dir/$WORKTREE_BRANCH"

  mkdir -p "$base_dir"

  # Create branch and worktree
  git -C "$PROJECT_DIR" branch "$WORKTREE_BRANCH" HEAD
  git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" "$WORKTREE_BRANCH"

  # Copy dotfiles that are typically gitignored but needed at runtime
  local dotfiles=(
    ".claude/settings.json"
    ".mcp.json"
    ".env"
  )

  for f in "${dotfiles[@]}"; do
    if [ -f "$PROJECT_DIR/$f" ]; then
      mkdir -p "$WORKTREE_DIR/$(dirname "$f")"
      cp "$PROJECT_DIR/$f" "$WORKTREE_DIR/$f"
    fi
  done

  # Copy .env.* variants
  for f in "$PROJECT_DIR"/.env.*; do
    [ -f "$f" ] && cp "$f" "$WORKTREE_DIR/"
  done

  # Copy secret/key files if present
  for pattern in ".secret*" "*.key" "*.pem"; do
    for f in "$PROJECT_DIR"/$pattern; do
      [ -f "$f" ] && cp "$f" "$WORKTREE_DIR/"
    done
  done

  log "${CYAN}Worktree created:${NC} $WORKTREE_DIR (branch: $WORKTREE_BRANCH)"
}

cleanup_worktree() {
  if [ -n "$WORKTREE_DIR" ] && [ -z "$RESUME_WORKTREE" ]; then
    # Only remove worktree if we created it (not resumed)
    # and there are no uncommitted changes
    if git -C "$WORKTREE_DIR" diff --quiet 2>/dev/null && \
       git -C "$WORKTREE_DIR" diff --cached --quiet 2>/dev/null; then
      git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" 2>/dev/null || true
      # Only delete branch locally if it hasn't been pushed to a remote
      if ! git -C "$PROJECT_DIR" ls-remote --heads origin "$WORKTREE_BRANCH" 2>/dev/null | grep -q .; then
        git -C "$PROJECT_DIR" branch -d "$WORKTREE_BRANCH" 2>/dev/null || true
      fi
      log "${DIM}Worktree cleaned up: $WORKTREE_DIR${NC}"
    else
      log "${YELLOW}Worktree has uncommitted changes, keeping: $WORKTREE_DIR${NC}"
    fi
  fi
}

PR_CREATED=false

# ─── PR Creation ──────────────────────────────────────────────────
create_pr() {
  # Idempotent — only run once per loop
  if $PR_CREATED; then return 0; fi

  # Guard: only create PR if worktree mode and PR creation are both enabled
  if [ "$USE_WORKTREE" != "yes" ] || [ "$CREATE_PR" != "yes" ]; then
    return 0
  fi

  # Guard: need a branch name
  if [ -z "$WORKTREE_BRANCH" ]; then
    return 0
  fi

  # Guard: skip if no commits ahead of main
  local main_branch
  main_branch=$(git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
  local commits_ahead
  commits_ahead=$(git -C "$PROJECT_DIR" rev-list --count "${main_branch}..${WORKTREE_BRANCH}" 2>/dev/null || echo "0")
  if [ "$commits_ahead" -eq 0 ]; then
    log "${DIM}No commits on $WORKTREE_BRANCH — skipping PR creation${NC}"
    return 0
  fi

  # Push branch to origin
  log "${CYAN}Pushing branch $WORKTREE_BRANCH to origin...${NC}"
  if ! git -C "$PROJECT_DIR" push -u origin "$WORKTREE_BRANCH" 2>>"$LOG_FILE"; then
    log "${YELLOW}Failed to push branch — skipping PR creation${NC}"
    return 0
  fi

  # Build PR title and body based on mode
  local pr_title pr_body pr_labels="loom"

  case "$MODE_LABEL" in
    *github*)
      # Extract issue number from URL if present, otherwise use as-is
      if [[ "$SOURCES_GITHUB" =~ /issues/([0-9]+) ]]; then
        local issue_num="${BASH_REMATCH[1]}"
      else
        local issue_num="$SOURCES_GITHUB"
      fi
      pr_title="fix(loom): resolve #${issue_num}"
      pr_body="## Summary
Automated implementation for issue #${issue_num}.

Closes #${issue_num}

## Loom Run
- Branch: \`${WORKTREE_BRANCH}\`
- Mode: ${MODE_LABEL}
- Commits: ${commits_ahead}"
      ;;
    *linear*)
      local ticket_id="$SOURCES_LINEAR"
      pr_title="feat(loom): implement ${ticket_id}"
      pr_body="## Summary
Automated implementation for Linear ticket ${ticket_id}.

## Loom Run
- Branch: \`${WORKTREE_BRANCH}\`
- Mode: ${MODE_LABEL}
- Commits: ${commits_ahead}"
      ;;
    *prompt*)
      local short_prompt
      if [ -f "$SOURCES_PROMPT" ]; then
        short_prompt=$(head -c 50 "$SOURCES_PROMPT" | tr '\n' ' ')
      else
        short_prompt=$(echo "$SOURCES_PROMPT" | head -c 50 | tr '\n' ' ')
      fi
      pr_title="feat(loom): ${short_prompt}"
      pr_body="## Summary
Automated implementation from prompt directive.

## Loom Run
- Branch: \`${WORKTREE_BRANCH}\`
- Mode: ${MODE_LABEL}
- Commits: ${commits_ahead}"
      ;;
    prd)
      local story_ids
      story_ids=$(git -C "$PROJECT_DIR" log "${main_branch}..${WORKTREE_BRANCH}" --format="%s" 2>/dev/null | \
        grep -oE '[A-Z]+-[0-9]+' | sort -u | tr '\n' ' ' || true)
      if [ -n "$story_ids" ]; then
        pr_title="feat(loom): complete stories ${story_ids}"
      else
        pr_title="feat(loom): PRD iteration work"
      fi
      pr_body="## Summary
Automated PRD implementation by Loom.

## Loom Run
- Branch: \`${WORKTREE_BRANCH}\`
- Mode: ${MODE_LABEL}
- Commits: ${commits_ahead}
- Stories: ${story_ids:-none detected}"
      ;;
    *)
      pr_title="feat(loom): automated changes (${MODE_LABEL})"
      pr_body="## Summary
Automated changes by Loom.

## Loom Run
- Branch: \`${WORKTREE_BRANCH}\`
- Mode: ${MODE_LABEL}
- Commits: ${commits_ahead}"
      ;;
  esac

  # Ensure the label exists (create it if missing)
  gh label create "$pr_labels" --description "Automated by Loom" --color "6A0DAD" 2>/dev/null || true

  # Create the PR
  log "${CYAN}Creating PR...${NC}"
  local pr_url
  pr_url=$(gh pr create \
    --head "$WORKTREE_BRANCH" \
    --base "$main_branch" \
    --title "$pr_title" \
    --body "$pr_body" \
    --label "$pr_labels" \
    2>>"$LOG_FILE") || true

  if [ -n "$pr_url" ]; then
    PR_CREATED=true
    log "${GREEN}${BOLD}PR created:${NC} $pr_url"
    mkdir -p "$LOOM_DIR/logs"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | PR | $pr_url | $WORKTREE_BRANCH" >> "$LOOM_DIR/logs/master.log"
  else
    log "${YELLOW}PR creation failed — branch pushed but PR not created${NC}"
  fi
}

# ─── Logging ─────────────────────────────────────────────────────
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="${DIM}[$ts]${NC} $1"
  echo -e "$line"
  echo -e "$line" | strip_ansi >> "$LOG_FILE"
}

separator() {
  printf "${DIM}──────────────────────────────────────────────────────${NC}\n"
}

master_log() {
  # Append a structured line to master.log
  # Format: timestamp | #iteration | label | status | duration | reason [| subagents:N]
  local iteration="$1" label="$2" status="$3" duration="$4" reason="$5" subagents="${6:-}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local log_dir="$LOOM_DIR/logs"
  mkdir -p "$log_dir"
  local line="$ts | #$iteration | $label | $status | ${duration}s | $reason"
  [ -n "$subagents" ] && line="$line | subagents:$subagents"
  echo "$line" >> "$log_dir/master.log"
}

# ─── Timeout Detection ──────────────────────────────────────────
TIMEOUT_CMD=""
detect_timeout_cmd() {
  if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
  elif command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
  fi
}

# ─── Result Signal Parsing ───────────────────────────────────────
parse_result_signal() {
  local log_file="$1"
  # Look for LOOM_RESULT:{SUCCESS,FAILED,PARTIAL,DONE}
  # in the last 50 lines of the iteration log
  local signal
  signal=$(tail -50 "$log_file" | grep -oE 'LOOM_RESULT:(SUCCESS|FAILED|PARTIAL|DONE)' | tail -1 || true)
  if [ -n "$signal" ]; then
    echo "${signal#LOOM_RESULT:}"
  else
    echo "UNKNOWN"
  fi
}

notify() {
  # Send a system notification (macOS only for now)
  local title="$1" body="$2"
  if [[ "$OSTYPE" == darwin* ]] && command -v osascript &>/dev/null; then
    osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null &
  fi
}

# ─── Preflight ───────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  die "claude CLI not found in PATH"
fi

PROMPT_TEMPLATE="$(resolve_template "prompt.md")"

if [ -n "$DIRECTIVE_FILE" ]; then
  if [[ ! -f "$DIRECTIVE_FILE" ]]; then
    die "directive file not found: $DIRECTIVE_FILE"
  fi
  DIRECTIVE_TEMPLATE="$(resolve_template "directive.md")"
fi

# PRD mode requires prd.json
if ! has_sources; then
  if [[ ! -f "$PRD_PATH" ]]; then
    die "PRD file not found: $PRD_PATH"
  fi
fi

detect_timeout_cmd
resolve_worktree

# ─── Environment ─────────────────────────────────────────────────
# Allow nested claude invocations (e.g. when loom is started from
# within a Claude session via a /loom skill).
unset CLAUDECODE

# Signal to hooks that we're inside a Loom loop. Hooks check this
# variable and no-op when it's absent, so they don't affect normal
# Claude Code sessions.
export LOOM_ACTIVE=1

# ─── Cleanup ─────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  # Log exit for post-mortem diagnosis of silent deaths
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loop exiting (exit $exit_code, iteration ${ITERATION:-0})" >> "$LOG_FILE" 2>/dev/null || true
  # Only attempt PR creation if the loop actually ran iterations.
  # Prevents premature push on early exit (e.g. --resume with no work).
  if [ "${ITERATION:-0}" -gt 0 ]; then
    create_pr 2>/dev/null || true
  fi
  rm -f "$LOOM_DIR/.directive" "$LOOM_DIR"/.directive-* "$LOOM_DIR/.piped_directive" "$LOOM_DIR"/.piped_directive-* "$LOOM_DIR/.iteration_marker" "$LOOM_DIR/.stop" "$LOOM_DIR/.pid" "$LOOM_DIR/.iter_state" "$LOOM_DIR/.header-pane.sh"
  cleanup_worktree
}
trap cleanup EXIT

# ─── Concurrency Guard ──────────────────────────────────────────
# Only guard non-worktree runs (they share state, can't be concurrent).
# Worktree runs get their own .loom/.pid after worktree setup.
if [ "$USE_WORKTREE" != "yes" ]; then
  PID_FILE="$LOOM_DIR/.pid"
  if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE")
    if kill -0 "$EXISTING_PID" 2>/dev/null; then
      die "Loom is already running (PID $EXISTING_PID). Use worktrees for concurrent runs."
    else
      rm -f "$PID_FILE"
    fi
  fi
  echo $$ > "$PID_FILE"
fi

# ─── Worktree Setup ─────────────────────────────────────────────
if [ "$USE_WORKTREE" = "yes" ]; then
  setup_worktree

  # Derive run slug from worktree branch and update tmux session name
  RUN_SLUG="${WORKTREE_BRANCH#loom/}"
  TMUX_SESSION="loom-${PROJECT_NAME}-${RUN_SLUG}"

  # Rename source directive to run-scoped name to prevent races
  # between concurrent Looms writing to the same .directive file.
  if [ -n "$DIRECTIVE_FILE" ] && [ "$DIRECTIVE_FILE" = "$LOOM_DIR/.directive" ]; then
    mv "$DIRECTIVE_FILE" "${LOOM_DIR}/.directive-${RUN_SLUG}"
    DIRECTIVE_FILE="${LOOM_DIR}/.directive-${RUN_SLUG}"
  fi

  PROJECT_DIR="$WORKTREE_DIR"
  # Repoint all runtime state into the worktree so concurrent looms
  # don't clobber each other. Source .loom/ keeps only checked-in files.
  SOURCE_LOOM_DIR="$LOOM_DIR"
  LOOM_DIR="$PROJECT_DIR/.loom"
  LOG_FILE="$LOOM_DIR/loom.log"
  PID_FILE="$LOOM_DIR/.pid"
  echo $$ > "$PID_FILE"
  # Relocate composed directive into the worktree so concurrent looms
  # don't overwrite each other's directives.
  if [ -n "$DIRECTIVE_FILE" ] && [[ "$DIRECTIVE_FILE" == "$SOURCE_LOOM_DIR/"* ]]; then
    cp "$DIRECTIVE_FILE" "$LOOM_DIR/.directive"
    rm -f "$DIRECTIVE_FILE"
    DIRECTIVE_FILE="$LOOM_DIR/.directive"
  fi
  rm -f "$SOURCE_LOOM_DIR/.piped_directive"
else
  # Non-worktree runs: derive run slug from current branch
  RUN_SLUG="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "default")"
  RUN_SLUG="$(echo "$RUN_SLUG" | sed 's/[^a-zA-Z0-9-]/-/g')"
  TMUX_SESSION="loom-${PROJECT_NAME}-${RUN_SLUG}"
fi

# ─── MCP Capability Detection ────────────────────────────────
CAPABILITY_MAP=(
  # browser
  "playwright:browser"
  "chrome:browser"
  "puppeteer:browser"
  "browserbase:browser"
  # mobile
  "mobile:mobile"
  "mobile-mcp:mobile"
  "appium:mobile"
  # design
  "figma:design"
)

detect_mcp_capabilities() {
  local mcp_file="$PROJECT_DIR/.mcp.json"
  local caps=""
  if [ -f "$mcp_file" ]; then
    local servers
    servers=$(jq -r '.mcpServers // {} | keys[]' "$mcp_file" 2>/dev/null)
    LOOM_MCP_SERVERS=$(echo "$servers" | paste -sd, -)
    for server in $servers; do
      for mapping in "${CAPABILITY_MAP[@]}"; do
        if [ "$server" = "${mapping%%:*}" ]; then
          local cap="${mapping#*:}"
          [[ ",$caps," != *",$cap,"* ]] && caps="${caps:+$caps,}$cap"
        fi
      done
      # Unknown servers: expose by name as a capability
      local matched=false
      for mapping in "${CAPABILITY_MAP[@]}"; do
        [ "$server" = "${mapping%%:*}" ] && matched=true && break
      done
      $matched || caps="${caps:+$caps,}$server"
    done
  fi
  export LOOM_MCP_SERVERS="${LOOM_MCP_SERVERS:-}"
  export LOOM_CAPABILITIES="${caps:-}"
}

detect_mcp_capabilities

# ─── Mode label for logging ───────────────────────────────────────
MODE_LABEL=""
[ -n "$SOURCES_LINEAR" ] && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}linear"
[ -n "$SOURCES_GITHUB" ] && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}github"
[ -n "$SOURCES_SLACK" ]  && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}slack"
[ -n "$SOURCES_NOTION" ] && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}notion"
[ -n "$SOURCES_SENTRY" ] && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}sentry"
[ -n "$SOURCES_PROMPT" ] && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}prompt"
[ -n "$SOURCES_PIPED" ]  && MODE_LABEL="${MODE_LABEL:+$MODE_LABEL+}prompt"
MODE_LABEL="${MODE_LABEL:-prd}"

# ─── Tmux Launch ─────────────────────────────────────────────────
if $USE_TMUX; then
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "${YELLOW}Loom is already running in tmux session '$TMUX_SESSION'${NC}"
    echo -e "Attach: ${BOLD}tmux attach -t $TMUX_SESSION${NC}"
    echo -e "Kill:   ${BOLD}tmux kill-session -t $TMUX_SESSION${NC}"
    exit 1
  fi

  touch "$LOG_FILE"

  # Build flags to forward
  FORWARD_FLAGS="--max-iterations $MAX_ITERATIONS --timeout $TIMEOUT --max-failures $MAX_FAILURES"
  if $PREVIEW; then FORWARD_FLAGS="$FORWARD_FLAGS --preview"; fi
  [ -n "$PRD_PATH" ] && [ "$PRD_PATH" != "$LOOM_DIR/prd.json" ] && FORWARD_FLAGS="$FORWARD_FLAGS --prd $(printf '%q' "$PRD_PATH")"

  # Forward sources (each independently)
  [ -n "$SOURCES_LINEAR" ] && FORWARD_FLAGS="$FORWARD_FLAGS --linear $(printf '%q' "$SOURCES_LINEAR")"
  [ -n "$SOURCES_GITHUB" ] && FORWARD_FLAGS="$FORWARD_FLAGS --github $(printf '%q' "$SOURCES_GITHUB")"
  [ -n "$SOURCES_SLACK" ]  && FORWARD_FLAGS="$FORWARD_FLAGS --slack $(printf '%q' "$SOURCES_SLACK")"
  [ -n "$SOURCES_NOTION" ] && FORWARD_FLAGS="$FORWARD_FLAGS --notion $(printf '%q' "$SOURCES_NOTION")"
  [ -n "$SOURCES_SENTRY" ] && FORWARD_FLAGS="$FORWARD_FLAGS --sentry $(printf '%q' "$SOURCES_SENTRY")"
  if [ -n "$SOURCES_PIPED" ]; then
    if [ -n "$SOURCES_PROMPT" ]; then
      printf '%s\n\n%s' "$SOURCES_PROMPT" "$SOURCES_PIPED" > "$LOOM_DIR/.piped_directive"
    else
      printf '%s' "$SOURCES_PIPED" > "$LOOM_DIR/.piped_directive"
    fi
    FORWARD_FLAGS="$FORWARD_FLAGS --prompt $(printf '%q' "$LOOM_DIR/.piped_directive")"
  elif [ -n "$SOURCES_PROMPT" ]; then
    FORWARD_FLAGS="$FORWARD_FLAGS --prompt $(printf '%q' "$SOURCES_PROMPT")"
  fi

  # Forward worktree and PR overrides — always resume the already-created
  # worktree so the tmux child doesn't create a second orphaned one.
  if [ "$USE_WORKTREE" = "yes" ]; then
    FORWARD_FLAGS="$FORWARD_FLAGS --resume $(printf '%q' "$WORKTREE_DIR")"
  fi
  # Pass session name so the tmux child uses the same scoped name
  FORWARD_FLAGS="$FORWARD_FLAGS --session-name $(printf '%q' "$TMUX_SESSION")"
  [ "$CREATE_PR" = "no" ] && FORWARD_FLAGS="$FORWARD_FLAGS --pr false"

  # Clear PID file so re-executed instance doesn't hit the concurrency guard
  # (this process is still alive when the tmux instance starts)
  rm -f "$PID_FILE"

  # Compute header height to match content exactly
  # Base: 1 (title) + 1 (PID/Mode) + 1 (Dir) + 1 (Stop) + 1 (Iter/timer) = 5
  HEADER_HEIGHT=5
  [ -n "$PRD_PATH" ] && HEADER_HEIGHT=$((HEADER_HEIGHT + 1))
  [ -n "$DIRECTIVE_FILE" ] && HEADER_HEIGHT=$((HEADER_HEIGHT + 1))
  # Tree line only shown when different from Dir
  [ "$USE_WORKTREE" = "yes" ] && [ "$WORKTREE_DIR" != "$PROJECT_DIR" ] && HEADER_HEIGHT=$((HEADER_HEIGHT + 1))
  [ -n "${LOOM_CAPABILITIES:-}" ] && HEADER_HEIGHT=$((HEADER_HEIGHT + 1))

  # Use real terminal size so pane proportions are correct on attach
  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  TERM_LINES=$(tput lines 2>/dev/null || echo 50)

  # Write .header before creating tmux so the header pane has content
  # immediately. The child will overwrite with its own PID on start.
  {
    echo -e "  ${BOLD}${CYAN}Loom ∞${NC}"
    echo -e "  ${DIM}PID${NC} ${BOLD}…${NC}  ${DIM}|${NC}  ${DIM}Mode${NC} ${BOLD}$MODE_LABEL${NC}  ${DIM}|${NC}  ${DIM}Iter${NC} ${BOLD}$MAX_ITERATIONS${NC}  ${DIM}|${NC}  ${DIM}Timeout${NC} ${BOLD}${TIMEOUT}s${NC}"
    echo -e "  ${DIM}Dir${NC}   $PROJECT_DIR"
    [ -n "$PRD_PATH" ] && echo -e "  ${DIM}PRD${NC}   $PRD_PATH"
    [ -n "$DIRECTIVE_FILE" ] && echo -e "  ${DIM}Src${NC}   $DIRECTIVE_FILE"
    [ "${USE_WORKTREE:-}" = "yes" ] && [ "${WORKTREE_DIR:-}" != "$PROJECT_DIR" ] && echo -e "  ${DIM}Tree${NC}  $WORKTREE_DIR"
    [ -n "${LOOM_CAPABILITIES:-}" ] && echo -e "  ${DIM}MCPs${NC}  ${GREEN}$LOOM_CAPABILITIES${NC}"
    echo -e "  ${DIM}Stop${NC}  ${CYAN}touch $LOOM_DIR/.stop${NC}"
  } > "$LOOM_DIR/.header"

  # Generate header pane script (reads .header + .iter_state, computes elapsed timer)
  cat > "$LOOM_DIR/.header-pane.sh" <<'HEADEREOF'
#!/bin/sh
LOOM_DIR="$1"
while true; do
  # Compose full output, then clear+draw in one atomic printf (no flash, no wrap artifacts)
  buf=$(cat "$LOOM_DIR/.header" 2>/dev/null || printf '  Starting…\n')

  # Check if the loop process is still alive
  LOOP_ALIVE=false
  if [ -f "$LOOM_DIR/.pid" ]; then
    _pid=$(cat "$LOOM_DIR/.pid" 2>/dev/null)
    [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && LOOP_ALIVE=true
  fi

  if ! $LOOP_ALIVE; then
    buf="${buf}
$(printf '  \033[1;31mSTOPPED\033[0m')"
    printf '\033[2J\033[H%s' "$buf"
    sleep 5
    continue
  fi

  if [ -f "$LOOM_DIR/.iter_state" ]; then
    read -r iter start < "$LOOM_DIR/.iter_state"
    now=$(date +%s)
    elapsed=$((now - start))
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    buf="${buf}
$(printf '  \033[2mIter\033[0m  \033[1m#%s\033[0m  \033[2m|\033[0m  \033[2m%dm %02ds\033[0m' "$iter" "$mins" "$secs")"
  else
    buf="${buf}
$(printf '  \033[2mIter\033[0m  \033[2mwaiting…\033[0m')"
  fi
  printf '\033[2J\033[H%s' "$buf"
  sleep 1
done
HEADEREOF

  # Pre-create log dir/files so bottom panes don't die on missing paths
  mkdir -p "$LOOM_DIR/logs"
  touch "$LOOM_DIR/logs/master.log"
  [ -f "$LOOM_DIR/status.md" ] || echo "# Loom Status" > "$LOOM_DIR/status.md"

  # Main pane: the loom loop (LOOM_TMUX_CHILD tells the child to
  # write its banner to .header instead of stdout)
  tmux new-session -d -s "$TMUX_SESSION" -x "$TERM_COLS" -y "$TERM_LINES" \
    "CLAUDE_PROJECT_DIR=$(printf '%q' "$PROJECT_DIR") LOOM_TMUX_CHILD=1 exec $0 $FORWARD_FLAGS"

  # Top: fixed header pane (always visible, sized to content, 1s refresh for timer)
  tmux split-window -v -b -t "$TMUX_SESSION:0.0" -l "$HEADER_HEIGHT" \
    "exec sh \"$LOOM_DIR/.header-pane.sh\" \"$LOOM_DIR\""

  # Bottom-left: live status.md (compact, 10 lines)
  tmux split-window -v -t "$TMUX_SESSION:0.1" -l 10 \
    "exec watch -n 3 -t sh -c 'printf \"\\033[1;36m── status.md ──\\033[0m\\n\"; cat \"$LOOM_DIR/status.md\" 2>/dev/null || echo \"(empty)\"'"

  # Bottom-right: log tail
  tmux split-window -h -t "$TMUX_SESSION:0.2" \
    "exec tail -f \"$LOOM_DIR/logs/master.log\" 2>/dev/null || tail -f \"$LOG_FILE\""

  # Pin pane sizes: header at top, bottom panes at 10 lines
  tmux resize-pane -t "$TMUX_SESSION:0.0" -y "$HEADER_HEIGHT" 2>/dev/null || true
  tmux resize-pane -t "$TMUX_SESSION:0.2" -y 10 2>/dev/null || true
  tmux resize-pane -t "$TMUX_SESSION:0.3" -y 10 2>/dev/null || true
  tmux select-pane -t "$TMUX_SESSION:0.1"
  # Hook fires on terminal resize — re-pin header and bottom panes.
  # run-shell wraps in sh so errors don't propagate to tmux.
  tmux set-hook -t "$TMUX_SESSION" client-resized \
    "run-shell 'tmux resize-pane -t 0.0 -y $HEADER_HEIGHT 2>/dev/null; tmux resize-pane -t 0.2 -y 10 2>/dev/null; tmux resize-pane -t 0.3 -y 10 2>/dev/null; true'"

  echo -e "${GREEN}Loom launched in tmux session '${TMUX_SESSION}'${NC}"
  echo -e "  Attach:  ${BOLD}tmux attach -t $TMUX_SESSION${NC}"
  echo -e "  Kill:    ${BOLD}tmux kill-session -t $TMUX_SESSION${NC}"
  echo -e "  Stop:    ${BOLD}touch .loom/.stop${NC} (finishes current iteration)"

  # Auto-attach when running from an interactive terminal
  if [ -t 0 ]; then
    exec tmux attach -t "$TMUX_SESSION"
  fi
  # The tmux child owns all runtime state now — disable cleanup so the
  # parent doesn't delete files (.directive, .piped_directive) before
  # the async child reads them. The child handles its own cleanup.
  trap - EXIT
  exit 0
fi

# ─── Banner ──────────────────────────────────────────────────────
if [ "${LOOM_TMUX_CHILD:-}" = "1" ]; then
  # Compact banner for the fixed tmux header pane
  {
    echo -e "  ${BOLD}${CYAN}Loom ∞${NC}"
    echo -e "  ${DIM}PID${NC} ${BOLD}$$${NC}  ${DIM}|${NC}  ${DIM}Mode${NC} ${BOLD}$MODE_LABEL${NC}  ${DIM}|${NC}  ${DIM}Iter${NC} ${BOLD}$MAX_ITERATIONS${NC}  ${DIM}|${NC}  ${DIM}Timeout${NC} ${BOLD}${TIMEOUT}s${NC}"
    echo -e "  ${DIM}Dir${NC}   $PROJECT_DIR"
    [ -n "$PRD_PATH" ] && echo -e "  ${DIM}PRD${NC}   $PRD_PATH"
    [ -n "$DIRECTIVE_FILE" ] && echo -e "  ${DIM}Src${NC}   $DIRECTIVE_FILE"
    [ "${USE_WORKTREE:-}" = "yes" ] && [ "${WORKTREE_DIR:-}" != "$PROJECT_DIR" ] && echo -e "  ${DIM}Tree${NC}  $WORKTREE_DIR"
    [ -n "${LOOM_CAPABILITIES:-}" ] && echo -e "  ${DIM}MCPs${NC}  ${GREEN}$LOOM_CAPABILITIES${NC}"
    echo -e "  ${DIM}Stop${NC}  ${CYAN}touch $LOOM_DIR/.stop${NC}"
  } > "$LOOM_DIR/.header"
else
  echo ""
  echo -e "  ${BOLD}${CYAN}Loom ∞${NC}"
  echo ""
  echo -e "  ${DIM}PID${NC}   ${BOLD}$$${NC}"
  echo -e "  ${DIM}Mode${NC}  ${BOLD}$MODE_LABEL${NC}  ${DIM}|${NC}  ${DIM}Iter${NC} ${BOLD}$MAX_ITERATIONS${NC}  ${DIM}|${NC}  ${DIM}Timeout${NC} ${BOLD}${TIMEOUT}s${NC}"
  echo -e "  ${DIM}Dir${NC}   $PROJECT_DIR"
  if [ -n "$PRD_PATH" ]; then
    echo -e "  ${DIM}PRD${NC}   $PRD_PATH"
  fi
  if [ -n "$DIRECTIVE_FILE" ]; then
    echo -e "  ${DIM}Src${NC}   $DIRECTIVE_FILE"
  fi
  if [ "$USE_WORKTREE" = "yes" ] && [ "${WORKTREE_DIR:-}" != "$PROJECT_DIR" ]; then
    echo -e "  ${DIM}Tree${NC}  $WORKTREE_DIR"
  fi
  if [ -n "$LOOM_CAPABILITIES" ]; then
    echo -e "  ${DIM}MCPs${NC}  ${GREEN}$LOOM_CAPABILITIES${NC}"
  fi
  echo ""
  echo -e "  ${CYAN}Graceful stop${NC}    touch $LOOM_DIR/.stop"
  echo -e "  ${CYAN}Kill${NC}             kill -TERM -$$"
  echo -e "  ${CYAN}Tail log${NC}         tail -f $LOG_FILE"
  echo -e "  ${CYAN}Status${NC}           cat $LOOM_DIR/status.md"
  echo -e "  ${CYAN}Master log${NC}       tail -f $LOOM_DIR/logs/master.log"
  echo ""
fi

if $PREVIEW; then
  log "${YELLOW}${BOLD}PREVIEW${NC} — analysis only, no changes will be made"
fi

# ─── Ensure log directory exists ────────────────────────────────
mkdir -p "$LOOM_DIR/logs"

# ─── Clean stale sentinels ──────────────────────────────────────
rm -f "$LOOM_DIR/.iteration_marker"

# ─── Main Loop ───────────────────────────────────────────────────
ITERATION=0

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))

  # ─── Graceful stop: check for .stop sentinel ──
  if [ -f "$LOOM_DIR/.stop" ]; then
    log "${YELLOW}${BOLD}Graceful stop requested${NC} (.loom/.stop found). Halting after iteration $((ITERATION - 1))."
    rm -f "$LOOM_DIR/.stop"
    notify "Loom — Stopped" "Graceful stop after $((ITERATION - 1)) iterations."
    break
  fi

  # ─── Circuit breaker: consecutive failures ──
  if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
    log "${RED}${BOLD}Circuit breaker tripped:${NC} $CONSECUTIVE_FAILURES consecutive failures. Halting."
    master_log "$ITERATION" "$MODE_LABEL" "HALTED" "0" "Circuit breaker: $CONSECUTIVE_FAILURES consecutive failures" "0"
    notify "Loom ✗ Circuit Breaker" "$CONSECUTIVE_FAILURES consecutive failures. Halted."
    break
  fi

  echo ""
  log "${BOLD}Iteration $ITERATION${NC} (failures: $CONSECUTIVE_FAILURES/$MAX_FAILURES)"
  separator

  # ─── Build prompt ───────────────────────────────────────────
  if [ -n "$DIRECTIVE_FILE" ]; then
    # Directive mode: read template, split on {{DIRECTIVE}} marker,
    # insert user's directive content between the halves.
    DIRECTIVE_CONTENT="$(cat "$DIRECTIVE_FILE")"
    PROMPT_TOP="$(sed '/^{{DIRECTIVE}}$/,$d' "$DIRECTIVE_TEMPLATE")"
    PROMPT_BOTTOM="$(sed '1,/^{{DIRECTIVE}}$/d' "$DIRECTIVE_TEMPLATE")"
    PROMPT="${PROMPT_TOP}${DIRECTIVE_CONTENT}"$'\n'"${PROMPT_BOTTOM}"
  else
    # Normal loop mode: full prompt.md orchestration with PRD
    PROMPT="$(cat "$PROMPT_TEMPLATE")"
  fi

  # Substitute PRD path placeholder
  PROMPT="${PROMPT//\{\{PRD_FILE\}\}/$PRD_PATH}"

  # ─── Iteration marker for stop-guard hook ──
  touch "$LOOM_DIR/.iteration_marker"

  # ─── Preview: append analysis-only override ──
  if $PREVIEW; then
    export LOOM_PREVIEW=1

    if [ -n "$DIRECTIVE_FILE" ]; then
      read -r -d '' PREVIEW_ADDENDUM <<'PREVIEWEOF' || true

---

## !! PREVIEW — DO NOT EXECUTE !!

This is a **preview**. Read status.md (Step 1), then analyze the directive (Step 2), but **stop there**.

**DO NOT** execute anything. Do not launch subagents. Do not create, modify, or delete any files.

Instead, output a structured analysis:

### 1. Status Assessment
Summarize what you found in status.md. Any failing tests relevant to the directive.

### 2. Directive Breakdown
How you would decompose this directive into parallelizable units of work.

### 3. Subagent Plan
One line per subagent you would launch and what it would do.

### 4. Estimated File Impact
Which files would likely be created or modified.

After outputting this report, exit immediately.
PREVIEWEOF
    else
      read -r -d '' PREVIEW_ADDENDUM <<'PREVIEWEOF' || true

---

## !! PREVIEW — DO NOT EXECUTE !!

This is a **preview**. Perform Steps 1 and 2 exactly as written (read status.md, read prd.json with jq waves), but **stop there**.

**DO NOT** execute Steps 3–4. Do not launch subagents. Do not create, modify, or delete any files.

Instead, output a structured analysis:

### 1. Status Assessment
Summarize what you found in status.md. List any failing tests that would be prioritized as fixes.

### 2. Story Selection
Which stories you would select for this iteration: story ID, title, and why each was chosen. Explain your parallelization rationale — why these stories can safely run concurrently.

### 3. Subagent Plan
One line per subagent you would launch: the story ID and a brief description of the assignment.

### 4. Estimated File Impact
Which files would likely be created or modified across all subagents.

After outputting this report, exit immediately.
PREVIEWEOF
    fi

    PROMPT="$PROMPT"$'\n'"$PREVIEW_ADDENDUM"
  fi

  cd "$PROJECT_DIR"

  export LOOM_TIMEOUT="$TIMEOUT"

  # ─── Per-iteration log file ──
  ITER_LABEL="${MODE_LABEL}"
  ITER_LOG="$LOOM_DIR/logs/$(date '+%Y%m%d-%H%M%S')-${ITER_LABEL}.log"
  ITER_START=$(date +%s)
  echo "$ITERATION $ITER_START" > "$LOOM_DIR/.iter_state"

  # ─── Execute Claude with streaming output ──
  CLAUDE_PREFIX=""
  if [ -n "$TIMEOUT_CMD" ] && [ "$TIMEOUT" -gt 0 ]; then
    CLAUDE_PREFIX="$TIMEOUT_CMD --foreground $TIMEOUT"
  fi

  set +e
  # Pipeline: claude | jq (text+tool names) | tee (log capture)
  # PIPESTATUS[0] = claude (or timeout wrapper)
  # PIPESTATUS[1] = jq text/tool extraction
  # PIPESTATUS[2] = tee (log capture)
  $CLAUDE_PREFIX claude -p \
    --dangerously-skip-permissions \
    --verbose \
    --output-format stream-json \
    --include-partial-messages \
    "$PROMPT" 2>>"$LOG_FILE" | \
    jq --unbuffered -rj 'select(.type == "stream_event") |
      if .event.delta.type? == "text_delta" then .event.delta.text
      elif .event.type? == "content_block_start" and .event.content_block.type? == "text" and (.event.index // 0) > 0 then "\n"
      elif .event.type? == "content_block_start" and .event.content_block.type? == "tool_use" then
        "\n\u001b[2m[\(.event.content_block.name // "tool")]\u001b[0m "
      else empty end' 2>/dev/null | \
    tee >(strip_ansi | tee -a "$LOG_FILE" > "$ITER_LOG")
  CLAUDE_EXIT=${PIPESTATUS[0]}
  set -e

  ITER_END=$(date +%s)
  ITER_DURATION=$((ITER_END - ITER_START))

  # ─── Count Task dispatches from iter log ──
  SUBAGENT_COUNT=0
  if [ -f "$ITER_LOG" ] && [ -s "$ITER_LOG" ]; then
    SUBAGENT_COUNT=$(grep -c '^\[Task\]' "$ITER_LOG" 2>/dev/null || echo 0)
    if [ "$SUBAGENT_COUNT" -gt 0 ]; then
      log "${GREEN}Subagents: $SUBAGENT_COUNT dispatched${NC}"
    fi
  fi

  # ─── Parse result signal from iteration output ──
  RESULT_SIGNAL=$(parse_result_signal "$ITER_LOG")

  # Fallback: if agent didn't emit a signal, infer from status.md.
  # The stop-guard hook allows exit once status.md is written, and
  # the status-kill hook (PostToolUse on Write) nudges the agent to stop.
  if [ "$RESULT_SIGNAL" = "UNKNOWN" ]; then
    if [ -f "$LOOM_DIR/status.md" ] && [ "$LOOM_DIR/status.md" -nt "$LOOM_DIR/.iteration_marker" ]; then
      if grep -qiE 'LOOM_RESULT:DONE|no (actionable |remaining )?stories remain' "$LOOM_DIR/status.md" 2>/dev/null; then
        RESULT_SIGNAL="DONE"
      elif grep -qiE 'LOOM_RESULT:SUCCESS|all.*complete|all.*done' "$LOOM_DIR/status.md" 2>/dev/null; then
        RESULT_SIGNAL="SUCCESS"
      elif grep -qiE 'LOOM_RESULT:PARTIAL|partial|some.*failed' "$LOOM_DIR/status.md" 2>/dev/null; then
        RESULT_SIGNAL="PARTIAL"
      else
        RESULT_SIGNAL="SUCCESS"
      fi
      log "${DIM}(inferred signal from status.md: $RESULT_SIGNAL)${NC}"
    fi
  fi

  # ─── Determine iteration status ──
  ITER_STATUS="unknown"
  ITER_REASON=""

  if [ "$CLAUDE_EXIT" -eq 124 ]; then
    ITER_STATUS="timeout"
    ITER_REASON="Timed out after ${TIMEOUT}s"
    log "${RED}Iteration $ITERATION timed out after ${TIMEOUT}s${NC}"
  elif [ "$RESULT_SIGNAL" = "SUCCESS" ] || [ "$RESULT_SIGNAL" = "DONE" ]; then
    ITER_STATUS="ok"
    ITER_REASON="$RESULT_SIGNAL"
    log "${GREEN}Iteration $ITERATION completed ($RESULT_SIGNAL)${NC}"
  elif [ "$RESULT_SIGNAL" = "PARTIAL" ]; then
    ITER_STATUS="partial"
    ITER_REASON="$RESULT_SIGNAL"
    log "${YELLOW}Iteration $ITERATION partial — some work failed${NC}"
  elif [ "$CLAUDE_EXIT" -eq 0 ]; then
    ITER_STATUS="ok"
    ITER_REASON="$RESULT_SIGNAL"
    log "${GREEN}Iteration $ITERATION completed${NC}"
  else
    ITER_STATUS="exit-$CLAUDE_EXIT"
    ITER_REASON="$RESULT_SIGNAL"
    log "${YELLOW}Iteration $ITERATION finished (exit $CLAUDE_EXIT, signal: $RESULT_SIGNAL)${NC}"
  fi

  master_log "$ITERATION" "$ITER_LABEL" "$ITER_STATUS" "$ITER_DURATION" "$ITER_REASON" "$SUBAGENT_COUNT"
  notify "Loom — Iter $ITERATION" "$RESULT_SIGNAL (${mins}m ${secs}s, $SUBAGENT_COUNT subagents)"

  # ─── Done: no remaining work ──
  if [ "$RESULT_SIGNAL" = "DONE" ]; then
    log "${GREEN}${BOLD}All work complete.${NC} Halting loop."
    notify "Loom ✓ Complete" "All work done after $ITERATION iterations."
    break
  fi

  # ─── Circuit breaker: check if status.md was updated ──
  if [ -f "$LOOM_DIR/.iteration_marker" ]; then
    if [ ! -f "$LOOM_DIR/status.md" ] || [ "$LOOM_DIR/status.md" -ot "$LOOM_DIR/.iteration_marker" ]; then
      # status.md not updated — count as failure
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      log "${YELLOW}status.md not updated — failure $CONSECUTIVE_FAILURES/$MAX_FAILURES${NC}"
    else
      # Success — reset counter
      CONSECUTIVE_FAILURES=0
    fi
  fi

  # ─── Commit status.md as iteration checkpoint ──
  if [ -f "$LOOM_DIR/status.md" ] && [ "$LOOM_DIR/status.md" -nt "$LOOM_DIR/.iteration_marker" ]; then
    (
      cd "$PROJECT_DIR"
      git add "$LOOM_DIR/status.md" 2>>"$LOG_FILE"
      git commit --no-gpg-sign -m "chore(loom): iteration $ITERATION checkpoint [$RESULT_SIGNAL]" \
        -m "iteration: $ITERATION, status: $ITER_STATUS" 2>>"$LOG_FILE"
    ) && log "${DIM}Committed status.md checkpoint${NC}" \
      || log "${YELLOW}status.md checkpoint commit failed (see above)${NC}"
  fi

  # ─── Clean up Claude Code temp task output ──
  # Subagent task output files accumulate in /private/tmp and can fill
  # the disk across iterations. Delete stale output files (>30min old)
  # after each iteration — active sessions keep their files fresh.
  CLAUDE_TEMP="/private/tmp/claude-$(id -u)"
  if [ -d "$CLAUDE_TEMP" ]; then
    find "$CLAUDE_TEMP" -path "*/tasks/*.output" -mmin +30 -delete 2>/dev/null || true
    find "$CLAUDE_TEMP" -type d -name "tasks" -empty -delete 2>/dev/null || true
  fi

  # ─── Preview: one iteration only, no cooldown ──
  if $PREVIEW; then
    log "${GREEN}Preview analysis complete.${NC}"
    break
  fi

done
log "${DIM}Loop exited after $ITERATION iteration(s)${NC}"

if ! $PREVIEW && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  log "${YELLOW}${BOLD}Loom completed $MAX_ITERATIONS iterations. Halting.${NC}"
  master_log "$ITERATION" "$MODE_LABEL" "MAX_ITER" "0" "Reached max iterations" "0"
  notify "Loom — Max Iterations" "Completed $MAX_ITERATIONS iterations."
fi

# ─── Kill tmux session on organic completion ──────────────────────
# When the loop ends naturally (DONE, graceful stop, max iterations,
# circuit breaker), kill the enclosing tmux session so it doesn't
# leave dead panes. The cleanup trap runs first (PR creation, file
# removal), then this fires as the last act of the script.
if [ -n "${TMUX:-}" ] && [ -n "$TMUX_SESSION" ]; then
  # Small delay so final log output is visible
  sleep 1
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi
