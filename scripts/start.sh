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
LOG_FILE="$LOOM_DIR/history.log"
TMUX_SESSION="loom-${PROJECT_NAME}"
MAX_ITERATIONS=1000
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
MAX_FAILURES=5
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

# ─── Debug Logging ───────────────────────────────────────────────
# Writes timestamped entries to .loom/logs/debug.log for full
# lifecycle traceability. Every decision point logs here.
# Initially buffers to a temp file so we don't pollute the source
# project's .loom/ before worktree setup repoints LOOM_DIR.
_DEBUG_BUFFER="$(mktemp)"
DEBUG_LOG="$_DEBUG_BUFFER"
debug() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S.%N' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$$] $1" >> "$DEBUG_LOG" 2>/dev/null || true
}
debug "─── START.SH LAUNCHED ─── pid=$$ args=$*"
debug "SCRIPT_DIR=$SCRIPT_DIR PLUGIN_ROOT=$PLUGIN_ROOT"
debug "PROJECT_DIR=$PROJECT_DIR LOOM_DIR=$LOOM_DIR"
debug "CLAUDECODE=${CLAUDECODE:-<unset>} TMUX=${TMUX:-<unset>} USE_TMUX=$USE_TMUX"
debug "bash_version=$BASH_VERSION"

# ─── Helpers ─────────────────────────────────────────────────────
die() { debug "FATAL: $1"; echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

is_url() { [[ "$1" == http://* ]] || [[ "$1" == https://* ]]; }

has_sources() {
  [ -n "$SOURCES_LINEAR" ] || [ -n "$SOURCES_GITHUB" ] || \
  [ -n "$SOURCES_SLACK" ] || [ -n "$SOURCES_NOTION" ] || \
  [ -n "$SOURCES_SENTRY" ] || [ -n "$SOURCES_PROMPT" ] || [ -n "$SOURCES_PIPED" ]
}

# Extract platform, type, and ID from a URL. Returns kebab-case slug or empty.
# Supports: GitHub, Linear, GitLab, Jira, Sentry, Slack, Notion, Bitbucket, Shortcut, Asana
parse_source_url() {
  local url="$1"
  # Strip trailing slashes and whitespace
  url="$(echo "$url" | sed 's|/*$||; s/^[[:space:]]*//; s/[[:space:]]*$//')"

  case "$url" in
    # GitHub: /issues/N, /pull/N, /discussions/N
    *github.com/*/issues/[0-9]*)
      echo "gh-issue-$(echo "$url" | grep -oE 'issues/[0-9]+' | grep -oE '[0-9]+')" ;;
    *github.com/*/pull/[0-9]*)
      echo "gh-pr-$(echo "$url" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+')" ;;
    *github.com/*/discussions/[0-9]*)
      echo "gh-disc-$(echo "$url" | grep -oE 'discussions/[0-9]+' | grep -oE '[0-9]+')" ;;

    # Linear: /issue/TEAM-123 or TEAM-123
    *linear.app/*/issue/*)
      echo "linear-$(echo "$url" | grep -oE 'issue/[A-Za-z]+-[0-9]+' | sed 's|issue/||' | tr '[:upper:]' '[:lower:]')" ;;

    # GitLab: /-/issues/N, /-/merge_requests/N
    *gitlab.com/*/-/issues/[0-9]*)
      echo "gl-issue-$(echo "$url" | grep -oE 'issues/[0-9]+' | grep -oE '[0-9]+')" ;;
    *gitlab.com/*/-/merge_requests/[0-9]*)
      echo "gl-mr-$(echo "$url" | grep -oE 'merge_requests/[0-9]+' | grep -oE '[0-9]+')" ;;

    # Jira: /browse/PROJ-123
    *atlassian.net/browse/*)
      echo "jira-$(echo "$url" | grep -oE 'browse/[A-Za-z]+-[0-9]+' | sed 's|browse/||' | tr '[:upper:]' '[:lower:]')" ;;

    # Sentry: /issues/N (org can be subdomain or path)
    *sentry.io/*/issues/[0-9]* | *sentry.io/issues/[0-9]*)
      echo "sentry-$(echo "$url" | grep -oE 'issues/[0-9]+' | grep -oE '[0-9]+')" ;;

    # Slack: /archives/CHANNEL_ID/pTIMESTAMP or just /archives/CHANNEL_ID
    *slack.com/archives/C[0-9A-Z]*/p[0-9]*)
      echo "slack-$(echo "$url" | grep -oE 'C[0-9A-Z]+' | head -1 | tr '[:upper:]' '[:lower:]')-$(echo "$url" | grep -oE 'p[0-9]+' | head -1 | tail -c 7)" ;;
    *slack.com/archives/C[0-9A-Z]*)
      echo "slack-$(echo "$url" | grep -oE 'C[0-9A-Z]+' | head -1 | tr '[:upper:]' '[:lower:]')" ;;

    # Notion: page ID (last 32 hex chars)
    *notion.so/*)
      local nid
      nid="$(echo "$url" | grep -oE '[0-9a-f]{32}' | tail -1 | head -c 8)"
      [ -n "$nid" ] && echo "notion-${nid}" ;;

    # Bitbucket: /issues/N, /pull-requests/N
    *bitbucket.org/*/issues/[0-9]*)
      echo "bb-issue-$(echo "$url" | grep -oE 'issues/[0-9]+' | grep -oE '[0-9]+')" ;;
    *bitbucket.org/*/pull-requests/[0-9]*)
      echo "bb-pr-$(echo "$url" | grep -oE 'pull-requests/[0-9]+' | grep -oE '[0-9]+')" ;;

    # Shortcut (formerly Clubhouse): /story/N
    *app.shortcut.com/*/story/[0-9]*)
      echo "sc-story-$(echo "$url" | grep -oE 'story/[0-9]+' | grep -oE '[0-9]+')" ;;

    # Asana: /0/N/N (task ID is last number)
    *app.asana.com/*/[0-9]*)
      echo "asana-$(echo "$url" | grep -oE '[0-9]+$')" ;;

    # Linear ticket ID without URL (e.g. "SCP-142")
    [A-Za-z]*-[0-9]*)
      echo "linear-$(echo "$url" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

# Fetch the title/summary of a source for richer branch slugs.
# Tier 1: direct CLI (gh for GitHub URLs/numbers, glab for GitLab)
#   → returns raw title string (needs separate slugify_title call)
# Tier 2: claude -p with MCP tools (Linear, Slack, Notion, Sentry, GH queries)
#   → returns pre-slugified 2-3 word kebab string (fetch+slugify in one LLM call)
# Sets TITLE_IS_SLUG=1 for tier 2 results (already slugified, skip slugify_title).
# Returns empty on failure. All calls wrapped in timeout 15.
TITLE_IS_SLUG=0
fetch_source_title() {
  local source_type="$1" source_value="$2"
  local title="" timeout_pfx=""
  TITLE_IS_SLUG=0

  # Resolve timeout binary (TIMEOUT_CMD may not be set yet at slug time)
  if command -v gtimeout &>/dev/null; then
    timeout_pfx="gtimeout 15"
  elif command -v timeout &>/dev/null; then
    timeout_pfx="timeout 15"
  fi

  local slug_instructions='Then compress that title into a 2-3 word kebab-case slug (lowercase, hyphens only). Output ONLY the slug — nothing else. No quotes, no explanation.'

  case "$source_type" in
    github)
      if is_url "$source_value" || [[ "$source_value" =~ ^[0-9]+$ ]]; then
        # Tier 1: gh CLI — fast, no LLM overhead
        if command -v gh &>/dev/null; then
          local num=""
          if [[ "$source_value" =~ ^[0-9]+$ ]]; then
            num="$source_value"
          else
            num="$(echo "$source_value" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' | head -1)"
          fi
          if [ -n "$num" ]; then
            # Try issue first, fall back to PR
            title="$($timeout_pfx gh issue view "$num" --json title -q .title 2>/dev/null)" || \
            title="$($timeout_pfx gh pr view "$num" --json title -q .title 2>/dev/null)" || true
          fi
        fi
      else
        # GitHub query (free-text search) — tier 2 (fetch + slugify combined)
        TITLE_IS_SLUG=1
        title="$($timeout_pfx claude -p --model haiku "Search GitHub issues for: ${source_value}. Find the single most relevant open issue. ${slug_instructions}" 2>/dev/null | head -1 | tr -d '[:space:]')" || true
      fi
      ;;
    linear)
      # Tier 2: fetch + slugify combined
      TITLE_IS_SLUG=1
      title="$($timeout_pfx claude -p --model haiku "Use Linear MCP tools to get the title of ticket or issue at: ${source_value}. ${slug_instructions}" 2>/dev/null | head -1 | tr -d '[:space:]')" || true
      ;;
    slack)
      # Tier 2: fetch + slugify combined
      TITLE_IS_SLUG=1
      title="$($timeout_pfx claude -p --model haiku "Use Slack MCP tools to fetch the message at: ${source_value}. Summarize the topic, then compress into a 2-3 word kebab-case slug. Output ONLY the slug — nothing else." 2>/dev/null | head -1 | tr -d '[:space:]')" || true
      ;;
    notion)
      # Tier 2: fetch + slugify combined
      TITLE_IS_SLUG=1
      title="$($timeout_pfx claude -p --model haiku "Use Notion MCP tools to get the page title at: ${source_value}. ${slug_instructions}" 2>/dev/null | head -1 | tr -d '[:space:]')" || true
      ;;
    sentry)
      # Tier 2: fetch + slugify combined
      TITLE_IS_SLUG=1
      title="$($timeout_pfx claude -p --model haiku "Use Sentry MCP tools to get the issue title at: ${source_value}. ${slug_instructions}" 2>/dev/null | head -1 | tr -d '[:space:]')" || true
      ;;
    gitlab)
      # Tier 1: glab CLI if available
      if command -v glab &>/dev/null; then
        local num=""
        num="$(echo "$source_value" | grep -oE '(issues|merge_requests)/[0-9]+' | grep -oE '[0-9]+' | head -1)"
        if [ -n "$num" ]; then
          if [[ "$source_value" == *merge_requests* ]]; then
            title="$($timeout_pfx glab mr view "$num" --output json 2>/dev/null | jq -r .title 2>/dev/null)" || true
          else
            title="$($timeout_pfx glab issue view "$num" --output json 2>/dev/null | jq -r .title 2>/dev/null)" || true
          fi
        fi
      fi
      ;;
  esac

  # Trim whitespace
  title="$(echo "$title" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  echo "$title"
}

# Compress a title into a 2-3 word kebab-case slug via Haiku.
# Returns validated slug or empty on failure.
slugify_title() {
  local title="$1"
  [ -z "$title" ] && return

  local raw
  raw=$(claude -p --model haiku "$(cat <<SLUGIFYEOF
Compress this title into a 2-3 word kebab-case slug. Output ONLY the slug — nothing else.

Rules:
- 2-3 lowercase words joined by hyphens
- Only lowercase letters, numbers, and hyphens
- No quotes, backticks, explanation, or punctuation

Examples:
"Fix watcher signal detection" → fix-watcher-signal
"Add dark mode support" → add-dark-mode
"Rate limiting for API endpoints" → rate-limiting

Title: ${title:0:200}
SLUGIFYEOF
)" 2>/dev/null | head -1 | tr -d '[:space:]')

  # Validate: 2-4 lowercase alphanumeric segments
  if echo "$raw" | grep -qE '^[a-z0-9]+(-[a-z0-9]+){1,3}$'; then
    echo "$raw"
  else
    echo "$raw" | grep -oE '[a-z0-9]+-[a-z0-9]+(-[a-z0-9]+){0,2}' | head -1
  fi
}

generate_branch_slug() {
  local ts slug raw
  ts="$(date '+%m%d-%H%M')"

  # PRD mode: deterministic — filename + timestamp
  if [ -n "$PRD_PATH" ] && [ -f "$PRD_PATH" ]; then
    slug="$(basename "$PRD_PATH" .json)"
    slug="$(echo "$slug" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"
    echo "${slug}-${ts}"
    return
  fi

  # Source URLs: parse platform + type + ID, then enrich with title
  local source_url="" source_type=""
  if [ -n "$SOURCES_LINEAR" ]; then
    source_url="$SOURCES_LINEAR"; source_type="linear"
  elif [ -n "$SOURCES_GITHUB" ]; then
    source_url="$SOURCES_GITHUB"; source_type="github"
  elif [ -n "$SOURCES_SLACK" ]; then
    source_url="$SOURCES_SLACK"; source_type="slack"
  elif [ -n "$SOURCES_NOTION" ]; then
    source_url="$SOURCES_NOTION"; source_type="notion"
  elif [ -n "$SOURCES_SENTRY" ]; then
    source_url="$SOURCES_SENTRY"; source_type="sentry"
  fi
  # Detect GitLab specifically
  if [ -n "$source_url" ] && [[ "$source_url" == *gitlab.com* ]]; then
    source_type="gitlab"
  fi

  if [ -n "$source_url" ]; then
    local parsed_slug title title_slug
    parsed_slug="$(parse_source_url "$source_url")"
    if [ -n "$parsed_slug" ]; then
      # Fetch title metadata and compress into slug
      title="$(fetch_source_title "$source_type" "$source_url")"
      if [ -n "$title" ]; then
        if [ "$TITLE_IS_SLUG" -eq 1 ]; then
          # Tier 2: already slugified by the LLM — validate only
          if echo "$title" | grep -qE '^[a-z0-9]+(-[a-z0-9]+){1,3}$'; then
            title_slug="$title"
          else
            title_slug="$(echo "$title" | grep -oE '[a-z0-9]+-[a-z0-9]+(-[a-z0-9]+){0,2}' | head -1)"
          fi
        else
          # Tier 1: raw title from CLI — slugify separately
          title_slug="$(slugify_title "$title")"
        fi
      fi

      if [ -n "${title_slug:-}" ]; then
        # Build enriched slug: prefix-ID-title
        # Extract prefix and numeric/ticket ID from parsed_slug
        local prefix="" id_part=""
        case "$parsed_slug" in
          gh-issue-*)  prefix="gh";     id_part="${parsed_slug#gh-issue-}" ;;
          gh-pr-*)     prefix="gh-pr";  id_part="${parsed_slug#gh-pr-}" ;;
          gh-disc-*)   prefix="gh-disc"; id_part="${parsed_slug#gh-disc-}" ;;
          linear-*)    prefix="linear"; id_part="${parsed_slug#linear-}" ;;
          gl-issue-*)  prefix="gl";     id_part="${parsed_slug#gl-issue-}" ;;
          gl-mr-*)     prefix="gl-mr";  id_part="${parsed_slug#gl-mr-}" ;;
          jira-*)      prefix="jira";   id_part="${parsed_slug#jira-}" ;;
          sentry-*)    prefix="sentry"; id_part="${parsed_slug#sentry-}" ;;
          slack-*)     prefix="slack";  id_part="${parsed_slug#slack-}" ;;
          notion-*)    prefix="notion"; id_part="${parsed_slug#notion-}" ;;
          bb-issue-*)  prefix="bb";     id_part="${parsed_slug#bb-issue-}" ;;
          bb-pr-*)     prefix="bb-pr";  id_part="${parsed_slug#bb-pr-}" ;;
          sc-story-*)  prefix="sc";     id_part="${parsed_slug#sc-story-}" ;;
          asana-*)     prefix="asana";  id_part="${parsed_slug#asana-}" ;;
          *)           prefix=""; id_part="" ;;
        esac
        if [ -n "$prefix" ] && [ -n "$id_part" ]; then
          slug="${prefix}-${id_part}-${title_slug}"
        else
          slug="${parsed_slug}-${title_slug}"
        fi
      else
        slug="$parsed_slug"
      fi
      echo "$slug"
      return
    fi
  fi

  # Free-form text (directive, prompt): ask Haiku for a topical slug
  local summary=""
  if [ -n "$SOURCES_PROMPT" ]; then
    if [ -f "$SOURCES_PROMPT" ]; then
      summary="$(head -c 200 "$SOURCES_PROMPT")"
    else
      summary="$(echo "$SOURCES_PROMPT" | head -c 200)"
    fi
  elif [ -n "$DIRECTIVE_FILE" ] && [ -f "$DIRECTIVE_FILE" ]; then
    summary="$(head -c 200 "$DIRECTIVE_FILE")"
  fi

  if [ -n "$summary" ]; then
    raw=$(claude -p --model haiku "$(cat <<SLUGEOF
You are a branch name generator. Output exactly one kebab-case slug — nothing else.

Rules:
- 2-3 lowercase words joined by hyphens
- Only lowercase letters, numbers, and hyphens
- Must describe the work
- No quotes, backticks, explanation, or punctuation

Examples:
"Migrate auth from cookies to JWT with refresh tokens" → auth-jwt-migration
"Refactor database connection pooling for read replicas" → db-pool-replicas
"Add dark mode support with theme persistence" → add-dark-mode

Work: ${summary:0:200}
SLUGEOF
)" 2>/dev/null | head -1 | tr -d '[:space:]')

    # Strict validation: 2-4 lowercase alphanumeric segments separated by hyphens
    if echo "$raw" | grep -qE '^[a-z0-9]+(-[a-z0-9]+){1,3}$'; then
      slug="$raw"
    else
      slug=$(echo "$raw" | grep -oE '[a-z0-9]+-[a-z0-9]+(-[a-z0-9]+){0,2}' | head -1)
    fi
  fi

  # Fallback: timestamp only
  [ -z "$slug" ] && slug="loom-${ts}"

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
      # Accept bare --worktree (= yes) or --worktree true/false
      if [[ $# -ge 2 ]] && [[ "$2" = "true" || "$2" = "false" ]]; then
        USE_WORKTREE=$([ "$2" = "true" ] && echo "yes" || echo "no")
        shift 2
      else
        USE_WORKTREE="yes"
        shift
      fi
      ;;
    --pr)
      # Accept bare --pr (= yes) or --pr true/false
      if [[ $# -ge 2 ]] && [[ "$2" = "true" || "$2" = "false" ]]; then
        CREATE_PR=$([ "$2" = "true" ] && echo "yes" || echo "no")
        shift 2
      else
        CREATE_PR="yes"
        shift
      fi
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
    [ -f "$f" ] && cp "$f" "$WORKTREE_DIR/" || true
  done

  # Copy secret/key files if present
  for pattern in ".secret*" "*.key" "*.pem"; do
    for f in "$PROJECT_DIR"/$pattern; do
      [ -f "$f" ] && cp "$f" "$WORKTREE_DIR/" || true
    done
  done

  # NOTE: don't log() here — LOG_FILE still points to source .loom/.
  # The caller logs after LOOM_DIR repoint.
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') | PR | $pr_url | $WORKTREE_BRANCH" >> "$LOOM_DIR/logs/iterations.log"
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
  # Append a structured line to iterations.log
  # Format: timestamp | #iteration | label | status | duration | reason [| subagents:N]
  local iteration="$1" label="$2" status="$3" duration="$4" reason="$5" subagents="${6:-}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local log_dir="$LOOM_DIR/logs"
  mkdir -p "$log_dir"
  local line="$ts | #$iteration | $label | $status | ${duration}s | $reason"
  [ -n "$subagents" ] && line="$line | subagents:$subagents"
  echo "$line" >> "$log_dir/iterations.log"
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

# ─── Source Reference Extraction ─────────────────────────────────
# Parses SOURCES_* variables into machine-readable type+ref for
# env export and tracking comment management.
extract_source_ref() {
  LOOM_SOURCE_TYPE=""
  LOOM_SOURCE_REF=""

  if [ -n "$SOURCES_GITHUB" ]; then
    LOOM_SOURCE_TYPE="github"
    if [[ "$SOURCES_GITHUB" =~ ^[0-9]+$ ]]; then
      LOOM_SOURCE_REF="$SOURCES_GITHUB"
    elif [[ "$SOURCES_GITHUB" =~ /issues/([0-9]+) ]]; then
      LOOM_SOURCE_REF="${BASH_REMATCH[1]}"
    elif [[ "$SOURCES_GITHUB" =~ /pull/([0-9]+) ]]; then
      LOOM_SOURCE_TYPE="github-pr"
      LOOM_SOURCE_REF="${BASH_REMATCH[1]}"
    else
      LOOM_SOURCE_REF="$SOURCES_GITHUB"
    fi
  elif [ -n "$SOURCES_LINEAR" ]; then
    LOOM_SOURCE_TYPE="linear"
    if [[ "$SOURCES_LINEAR" =~ ([A-Za-z]+-[0-9]+) ]]; then
      LOOM_SOURCE_REF="${BASH_REMATCH[1]}"
    else
      LOOM_SOURCE_REF="$SOURCES_LINEAR"
    fi
  fi

  export LOOM_SOURCE_TYPE LOOM_SOURCE_REF
  debug "extract_source_ref: type=$LOOM_SOURCE_TYPE ref=$LOOM_SOURCE_REF"
}

# ─── Source Tracking (GitHub issue/PR comment) ───────────────────
# Creates a single tracking comment on the source issue/PR, then
# updates it after each iteration with current status. Gives
# stakeholders live visibility into Loom progress.
LOOM_TRACKING_COMMENT_ID=""
LOOM_GH_REPO=""

# Resolve and cache the GitHub repo (owner/name) for API calls.
# Returns 1 if gh is unavailable or repo can't be resolved.
resolve_gh_repo() {
  [ -n "$LOOM_GH_REPO" ] && return 0
  command -v gh &>/dev/null || return 1
  LOOM_GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
  [ -n "$LOOM_GH_REPO" ] || return 1
  debug "resolve_gh_repo: $LOOM_GH_REPO"
  return 0
}

# Wrapper for gh api with timeout and error logging.
# Usage: gh_api [args...] — returns gh exit code.
gh_api() {
  local timeout_pfx=""
  if [ -n "$TIMEOUT_CMD" ]; then
    timeout_pfx="$TIMEOUT_CMD 30"
  fi
  local output exit_code
  output=$($timeout_pfx gh api "$@" 2>&1)
  exit_code=$?
  if [ $exit_code -ne 0 ]; then
    debug "gh_api FAILED (exit=$exit_code): gh api $*"
    debug "  output: $(echo "$output" | head -5)"
    echo "$output" >> "$LOG_FILE" 2>/dev/null || true
  else
    echo "$output"
  fi
  return $exit_code
}

# Truncate status.md for embedding in GitHub comments (max ~4000 chars
# to stay well under GitHub's 65536 char comment limit).
read_status_excerpt() {
  [ -f "$LOOM_DIR/status.md" ] || return
  head -c 4000 "$LOOM_DIR/status.md"
}

init_source_tracking() {
  [ -z "$LOOM_SOURCE_TYPE" ] && return 0

  # Resume: reuse existing tracking comment
  if [ -f "$LOOM_DIR/.tracking_comment_id" ]; then
    LOOM_TRACKING_COMMENT_ID=$(cat "$LOOM_DIR/.tracking_comment_id")
    debug "Reusing tracking comment ID: $LOOM_TRACKING_COMMENT_ID"
    return 0
  fi

  case "$LOOM_SOURCE_TYPE" in
    github|github-pr)
      [[ "$LOOM_SOURCE_REF" =~ ^[0-9]+$ ]] || return 0
      resolve_gh_repo || return 0

      local branch="${WORKTREE_BRANCH:-$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null)}"
      local body
      body="## Loom — Working

| | |
|---|---|
| **Branch** | \`${branch}\` |
| **Status** | Starting |
| **Iteration** | 0 / $MAX_ITERATIONS |
| **Mode** | $MODE_LABEL |
| **Started** | $(date -u '+%Y-%m-%dT%H:%M:%SZ') |

_Updated automatically by Loom. Last update: $(date -u '+%Y-%m-%dT%H:%M:%SZ')_"

      local comment_id
      comment_id=$(gh_api "repos/$LOOM_GH_REPO/issues/$LOOM_SOURCE_REF/comments" \
        -f body="$body" --jq '.id') || return 0

      if [ -n "$comment_id" ]; then
        LOOM_TRACKING_COMMENT_ID="$comment_id"
        echo "$comment_id" > "$LOOM_DIR/.tracking_comment_id"
        log "${CYAN}Tracking comment posted to #$LOOM_SOURCE_REF${NC}"
        debug "Tracking comment created: ID=$comment_id"
      fi
      ;;
  esac
}

update_source_tracking() {
  local iter="$1" signal="$2" duration="$3" subagents="$4"
  [ -z "$LOOM_SOURCE_TYPE" ] && return 0
  [ -z "$LOOM_TRACKING_COMMENT_ID" ] && return 0

  case "$LOOM_SOURCE_TYPE" in
    github|github-pr)
      resolve_gh_repo || return 0

      local status_icon="working"
      case "$signal" in
        SUCCESS) status_icon="Iteration passed" ;;
        DONE)    status_icon="Complete" ;;
        PARTIAL) status_icon="Partial progress" ;;
        FAILED)  status_icon="Iteration failed" ;;
      esac

      local mins=$((duration / 60))
      local secs=$((duration % 60))

      local summary
      summary=$(read_status_excerpt)

      local branch="${WORKTREE_BRANCH:-$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null)}"
      local body
      body="## Loom — Working

| | |
|---|---|
| **Branch** | \`${branch}\` |
| **Status** | $status_icon |
| **Iteration** | $iter / $MAX_ITERATIONS |
| **Last Duration** | ${mins}m ${secs}s |
| **Subagents** | $subagents |
| **Mode** | $MODE_LABEL |

<details>
<summary>Latest status</summary>

$summary
</details>

_Updated automatically by Loom. Last update: $(date -u '+%Y-%m-%dT%H:%M:%SZ')_"

      gh_api "repos/$LOOM_GH_REPO/issues/comments/$LOOM_TRACKING_COMMENT_ID" \
        -X PATCH -f body="$body" > /dev/null || true
      debug "Tracking comment updated: iter=$iter signal=$signal"
      ;;
  esac
}

finalize_source_tracking() {
  local total_iters="$1" final_status="$2"
  [ -z "$LOOM_SOURCE_TYPE" ] && return 0
  [ -z "$LOOM_TRACKING_COMMENT_ID" ] && return 0

  case "$LOOM_SOURCE_TYPE" in
    github|github-pr)
      resolve_gh_repo || return 0

      local summary
      summary=$(read_status_excerpt)

      local branch="${WORKTREE_BRANCH:-$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null)}"
      local body
      body="## Loom — Complete

| | |
|---|---|
| **Branch** | \`${branch}\` |
| **Status** | $final_status |
| **Iterations** | $total_iters |
| **Mode** | $MODE_LABEL |

<details>
<summary>Final status</summary>

$summary
</details>

_Completed $(date -u '+%Y-%m-%dT%H:%M:%SZ')_"

      gh_api "repos/$LOOM_GH_REPO/issues/comments/$LOOM_TRACKING_COMMENT_ID" \
        -X PATCH -f body="$body" > /dev/null || true

      rm -f "$LOOM_DIR/.tracking_comment_id"
      debug "Tracking comment finalized: iters=$total_iters status=$final_status"
      ;;
  esac
}

# ─── Cross-PRD File Locking ──────────────────────────────────────
# When multiple PRDs run concurrently on the same project, their
# stories may touch overlapping files. A shared lock directory under
# ~/.claude-worktrees/<project>/.file-locks/ tracks which files each
# session claims. The orchestrator skips stories that conflict with
# other active sessions.
FILE_LOCK_DIR=""
LOOM_LOCKED_FILES=""

init_file_lock_dir() {
  local base_dir="$HOME/.claude-worktrees/$PROJECT_NAME"
  FILE_LOCK_DIR="$base_dir/.file-locks"
  mkdir -p "$FILE_LOCK_DIR" 2>/dev/null || true
}

# Extract pending story files from a PRD.
extract_prd_files() {
  local prd="$1"
  [ -f "$prd" ] || return
  jq -r '[.stories[] | select(.status != "done" and .status != "cancelled") | .files[]?] | unique | .[]' "$prd" 2>/dev/null
}

# Register this session's file claims from the PRD.
# Called before the main loop and refreshed each iteration.
register_file_locks() {
  [ -z "$FILE_LOCK_DIR" ] && return 0
  [ -z "$PRD_PATH" ] || [ ! -f "$PRD_PATH" ] && return 0

  local slug="${WORKTREE_BRANCH:-$$}"
  slug="${slug//\//-}"

  local files_json
  files_json=$(extract_prd_files "$PRD_PATH" | jq -Rs 'split("\n") | map(select(. != ""))')
  [ -z "$files_json" ] || [ "$files_json" = "[]" ] && return 0

  jq -n \
    --arg pid "$$" \
    --arg branch "${WORKTREE_BRANCH:-}" \
    --arg prd "$PRD_PATH" \
    --arg started "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson files "$files_json" \
    '{pid: ($pid | tonumber), branch: $branch, prd: $prd, started: $started, files: $files}' \
    > "$FILE_LOCK_DIR/${slug}.json" 2>/dev/null

  debug "File locks registered: $(echo "$files_json" | jq 'length') files → $FILE_LOCK_DIR/${slug}.json"
}

# Check for file overlaps with other active Loom sessions.
# Sets LOOM_LOCKED_FILES (comma-separated) for the orchestrator.
check_file_conflicts() {
  [ -z "$FILE_LOCK_DIR" ] && return 0
  [ -z "$PRD_PATH" ] || [ ! -f "$PRD_PATH" ] && return 0

  local my_slug="${WORKTREE_BRANCH:-$$}"
  my_slug="${my_slug//\//-}"

  local my_files
  my_files=$(extract_prd_files "$PRD_PATH" | sort)
  [ -z "$my_files" ] && return 0

  local all_locked="" conflict_report=""

  for lock_file in "$FILE_LOCK_DIR"/*.json; do
    [ -f "$lock_file" ] || continue
    [ "$(basename "$lock_file" .json)" = "$my_slug" ] && continue

    local other_pid other_branch
    other_pid=$(jq -r '.pid' "$lock_file" 2>/dev/null)
    other_branch=$(jq -r '.branch' "$lock_file" 2>/dev/null)

    # Stale lock: PID dead → remove
    if [ -n "$other_pid" ] && ! kill -0 "$other_pid" 2>/dev/null; then
      debug "Removing stale file lock: $lock_file (pid $other_pid dead)"
      rm -f "$lock_file"
      continue
    fi

    local other_files
    other_files=$(jq -r '.files[]' "$lock_file" 2>/dev/null | sort)
    [ -z "$other_files" ] && continue

    local overlap
    overlap=$(comm -12 <(echo "$my_files") <(echo "$other_files"))
    if [ -n "$overlap" ]; then
      local overlap_count
      overlap_count=$(echo "$overlap" | wc -l | tr -d ' ')
      conflict_report="${conflict_report}  ${other_branch} (${overlap_count} files)\n"
      all_locked="${all_locked}${overlap}"$'\n'
    fi
  done

  if [ -n "$conflict_report" ]; then
    log "${YELLOW}File conflicts with other active sessions:${NC}"
    echo -e "$conflict_report" | while IFS= read -r line; do
      [ -n "$line" ] && log "$line" || true
    done
  fi

  LOOM_LOCKED_FILES=$(echo "$all_locked" | sort -u | grep -v '^$' | paste -sd, - || true)
  export LOOM_LOCKED_FILES
  debug "LOOM_LOCKED_FILES=${LOOM_LOCKED_FILES:-<none>}"
}

# Remove this session's lock file.
release_file_locks() {
  [ -z "$FILE_LOCK_DIR" ] && return 0
  local slug="${WORKTREE_BRANCH:-$$}"
  slug="${slug//\//-}"
  rm -f "$FILE_LOCK_DIR/${slug}.json" 2>/dev/null || true
  debug "File locks released: ${slug}"
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
debug "LOOM_ACTIVE=1 exported. LOOM_PREVIEW=${LOOM_PREVIEW:-<unset>}"

# ─── Cleanup ─────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  # Flush debug buffer if it was never finalized (early exit)
  if [ -f "${_DEBUG_BUFFER:-}" ]; then
    mkdir -p "$LOOM_DIR/logs" 2>/dev/null || true
    DEBUG_LOG="$LOOM_DIR/logs/debug.log"
    cat "$_DEBUG_BUFFER" >> "$DEBUG_LOG" 2>/dev/null || true
    rm -f "$_DEBUG_BUFFER"
  fi
  debug "─── CLEANUP TRAP FIRED ─── exit_code=$exit_code iteration=${ITERATION:-0}"
  debug "  LINENO=${BASH_LINENO[0]:-?} FUNCNAME=${FUNCNAME[1]:-main} BASH_COMMAND=${BASH_COMMAND:-?}"
  # Log exit for post-mortem diagnosis of silent deaths
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loop exiting (exit $exit_code, iteration ${ITERATION:-0})" >> "$LOG_FILE" 2>/dev/null || true
  # Only attempt PR creation if the loop actually ran iterations.
  # Prevents premature push on early exit (e.g. --resume with no work).
  if [ "${ITERATION:-0}" -gt 0 ]; then
    debug "  calling create_pr (ITERATION > 0)"
    create_pr 2>/dev/null || true
    debug "  create_pr done"
  else
    debug "  skipping create_pr (ITERATION=0)"
  fi
  debug "  releasing file locks"
  release_file_locks
  debug "  removing sentinels"
  rm -f "$LOOM_DIR/.directive" "$LOOM_DIR"/.directive-* "$LOOM_DIR/.piped_directive" "$LOOM_DIR"/.piped_directive-* "$LOOM_DIR/.iteration_marker" "$LOOM_DIR/.stop" "$LOOM_DIR/.pid" "$LOOM_DIR/.iter_state" "$LOOM_DIR/.header-pane.sh" "$LOOM_DIR/.steering" "$LOOM_DIR/.tracking_comment_id"
  # Kill the tmux session — helper panes are useless without the loop
  if [ -n "${TMUX_SESSION:-}" ]; then
    debug "  killing tmux session '$TMUX_SESSION'"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  fi
  debug "  calling cleanup_worktree"
  cleanup_worktree
  debug "─── CLEANUP COMPLETE ───"
}
trap cleanup EXIT
trap 'debug "ERR TRAP: line=${LINENO} cmd=${BASH_COMMAND} exit=$?"' ERR

debug "Concurrency guard. USE_WORKTREE=$USE_WORKTREE"
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

  SOURCE_PROJECT_DIR="$PROJECT_DIR"
  PROJECT_DIR="$WORKTREE_DIR"
  # Repoint all runtime state into the worktree so concurrent looms
  # don't clobber each other. Source .loom/ keeps only checked-in files.
  SOURCE_LOOM_DIR="$LOOM_DIR"
  LOOM_DIR="$PROJECT_DIR/.loom"
  mkdir -p "$LOOM_DIR"
  LOG_FILE="$LOOM_DIR/history.log"
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
  # Repoint PRD into worktree if it lives under the source project tree
  if [[ "$PRD_PATH" == "$SOURCE_PROJECT_DIR/"* ]]; then
    PRD_PATH="${WORKTREE_DIR}${PRD_PATH#"$SOURCE_PROJECT_DIR"}"
    export LOOM_PRD_PATH="$PRD_PATH"
  fi
  log "${CYAN}Worktree created:${NC} $WORKTREE_DIR (branch: $WORKTREE_BRANCH)"
else
  # Non-worktree runs: derive run slug from current branch
  RUN_SLUG="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "default")"
  RUN_SLUG="$(echo "$RUN_SLUG" | sed 's/[^a-zA-Z0-9-]/-/g')"
  TMUX_SESSION="loom-${PROJECT_NAME}-${RUN_SLUG}"
fi

# ─── Finalize debug log ──────────────────────────────────────
# LOOM_DIR is now final (repointed to worktree if applicable).
# Flush the temp buffer into the real debug log.
mkdir -p "$LOOM_DIR/logs" 2>/dev/null || true
DEBUG_LOG="$LOOM_DIR/logs/debug.log"
if [ -f "$_DEBUG_BUFFER" ]; then
  cat "$_DEBUG_BUFFER" >> "$DEBUG_LOG" 2>/dev/null || true
  rm -f "$_DEBUG_BUFFER"
fi
debug "LOOM_DIR finalized to $LOOM_DIR"

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

# ─── Source Reference Extraction ─────────────────────────────────
extract_source_ref

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
  [ "$USE_WORKTREE" = "no" ] && FORWARD_FLAGS="$FORWARD_FLAGS --worktree false"

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
  touch "$LOOM_DIR/logs/iterations.log"
  [ -f "$LOOM_DIR/status.md" ] || echo "# Loom Status" > "$LOOM_DIR/status.md"

  # Main pane: the loom loop (LOOM_TMUX_CHILD tells the child to
  # write its banner to .header instead of stdout)
  debug "Launching tmux session '$TMUX_SESSION' with: $0 $FORWARD_FLAGS"
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
    "exec tail -f \"$LOOM_DIR/logs/iterations.log\" 2>/dev/null || tail -f \"$LOG_FILE\""

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
  echo -e "  Session: ${BOLD}$TMUX_SESSION${NC}"
  echo -e "  Loom dir: ${BOLD}$LOOM_DIR${NC}"
  echo -e "  Attach:  ${BOLD}tmux attach -t $TMUX_SESSION${NC}"
  echo -e "  Kill:    ${BOLD}tmux kill-session -t $TMUX_SESSION${NC}"
  echo -e "  Stop:    ${BOLD}touch $LOOM_DIR/.stop${NC} (finishes current iteration)"

  # The tmux child owns all runtime state now — disable cleanup so the
  # parent doesn't delete files (.directive, .piped_directive) before
  # the async child reads them. The child handles its own cleanup.
  trap - EXIT

  # Auto-attach when running from a real interactive terminal.
  if [ -t 0 ] && [ -t 1 ]; then
    debug "auto-attaching to tmux (interactive terminal)"
    exec tmux attach -t "$TMUX_SESSION"
  fi

  # Non-interactive (Claude Code): parent exits, skill uses
  # iteration-watcher.sh relay for per-iteration notifications.
  debug "non-interactive launch — parent exiting (use iteration-watcher.sh for monitoring)"
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
  echo -e "  ${CYAN}Master log${NC}       tail -f $LOOM_DIR/logs/iterations.log"
  echo ""
fi

if $PREVIEW; then
  log "${YELLOW}${BOLD}PREVIEW${NC} — analysis only, no changes will be made"
fi

# ─── Ensure log directory exists ────────────────────────────────
mkdir -p "$LOOM_DIR/logs"

# ─── Clean stale sentinels ──────────────────────────────────────
rm -f "$LOOM_DIR/.iteration_marker"
debug "Stale sentinels cleaned. Entering main loop. MAX_ITERATIONS=$MAX_ITERATIONS"

# ─── Initialize file locks (cross-PRD conflict detection) ───────
init_file_lock_dir
register_file_locks
check_file_conflicts

# ─── Initialize source tracking ─────────────────────────────────
init_source_tracking

# ─── Main Loop ───────────────────────────────────────────────────
ITERATION=0

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  debug "─── LOOP TOP ─── iteration=$ITERATION max=$MAX_ITERATIONS failures=$CONSECUTIVE_FAILURES/$MAX_FAILURES"

  # ─── Graceful stop: check for .stop sentinel ──
  if [ -f "$LOOM_DIR/.stop" ]; then
    debug "BREAK: .stop sentinel found"
    log "${YELLOW}${BOLD}Graceful stop requested${NC} (.loom/.stop found). Halting after iteration $((ITERATION - 1))."
    rm -f "$LOOM_DIR/.stop"
    notify "Loom — Stopped" "Graceful stop after $((ITERATION - 1)) iterations."
    break
  fi

  # ─── Circuit breaker: consecutive failures ──
  if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
    debug "BREAK: circuit breaker tripped ($CONSECUTIVE_FAILURES >= $MAX_FAILURES)"
    log "${RED}${BOLD}Circuit breaker tripped:${NC} $CONSECUTIVE_FAILURES consecutive failures. Halting."
    master_log "$ITERATION" "$MODE_LABEL" "HALTED" "0" "Circuit breaker: $CONSECUTIVE_FAILURES consecutive failures" "0"
    notify "Loom ✗ Circuit Breaker" "$CONSECUTIVE_FAILURES consecutive failures. Halted."
    break
  fi

  echo ""
  log "${BOLD}Iteration $ITERATION${NC} (failures: $CONSECUTIVE_FAILURES/$MAX_FAILURES)"
  separator

  # ─── Steering: check for parent-injected instructions ──
  STEERING_CONTENT=""
  if [ -f "$LOOM_DIR/.steering" ]; then
    STEERING_CONTENT="$(cat "$LOOM_DIR/.steering")"
    mkdir -p "$LOOM_DIR/logs"
    mv "$LOOM_DIR/.steering" "$LOOM_DIR/logs/steering-iter${ITERATION}.md"
    log "${CYAN}Steering instructions received${NC} (${#STEERING_CONTENT} chars)"
    debug "Steering consumed: ${#STEERING_CONTENT} chars, archived to logs/steering-iter${ITERATION}.md"
  fi

  # ─── Refresh file locks (PRD statuses may have changed) ───
  register_file_locks
  check_file_conflicts

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

  # Inject current branch so the orchestrator knows where commits should land
  # NOTE: no `local` — this is in the main loop body, not a function.
  # bash 3.2 errors on `local` outside functions, fatal under set -e.
  current_branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "unknown")"
  PROMPT="${PROMPT//\{\{CURRENT_BRANCH\}\}/$current_branch}"

  # ─── Inject steering from parent context ──
  if [ -n "$STEERING_CONTENT" ]; then
    STEERING_BLOCK="---

## Operator Steering

The following instructions were injected by the operator between iterations. These take priority over default story selection and execution order:

$STEERING_CONTENT

"
    # Insert before Step 2 in both prompt.md and directive.md
    # NOTE: # must be escaped in bash parameter expansion patterns (# is a glob anchor)
    PROMPT="${PROMPT/\#\# Step 2/${STEERING_BLOCK}## Step 2}"
    debug "Steering injected into prompt (${#STEERING_CONTENT} chars)"
  fi

  # ─── Iteration marker for stop-guard hook ──
  touch "$LOOM_DIR/.iteration_marker"
  debug "Iteration marker touched. Prompt built (${#PROMPT} chars). PRD=$PRD_PATH"

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

  DISPATCH_LOG="$LOOM_DIR/logs/$(date '+%Y%m%d-%H%M%S')-${ITER_LABEL}-dispatches.jsonl"

  debug "Launching claude -p pipeline. CLAUDE_PREFIX='$CLAUDE_PREFIX' TIMEOUT=$TIMEOUT"
  debug "  ITER_LOG=$ITER_LOG DISPATCH_LOG=$DISPATCH_LOG"
  set +e
  # Pipeline: claude | tee (dispatch sidecar) | jq (text+tool names) | tee (log capture)
  # PIPESTATUS[0] = claude (or timeout wrapper)
  # PIPESTATUS[1] = tee (dispatch sidecar fork)
  # PIPESTATUS[2] = jq text/tool extraction
  # PIPESTATUS[3] = tee (log capture)
  # NOTE: --verbose is REQUIRED with --output-format stream-json --print;
  # removing it causes claude to exit 1 with "stream-json requires --verbose".
  $CLAUDE_PREFIX claude -p \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    "$PROMPT" 2>>"$LOG_FILE" | \
    tee >(jq --unbuffered -c '
      select(.type == "stream_event") |
      if (
        .event.type? == "content_block_start" and
        .event.content_block.type? == "tool_use" and
        .event.content_block.name? == "Task"
      ) then
        {ts: now | strftime("%Y-%m-%d %H:%M:%S"), event: "dispatch", index: .event.index}
      elif .event.type? == "content_block_stop" then
        {ts: now | strftime("%Y-%m-%d %H:%M:%S"), event: "stop", index: .event.index}
      else empty end
    ' >> "$DISPATCH_LOG" 2>/dev/null || true) | \
    jq --unbuffered -rj 'select(.type == "stream_event") |
      if .event.delta.type? == "text_delta" then .event.delta.text
      elif .event.type? == "content_block_start" and .event.content_block.type? == "text" and (.event.index // 0) > 0 then "\n"
      elif .event.type? == "content_block_start" and .event.content_block.type? == "tool_use" then
        "\n\u001b[2m[\(.event.content_block.name // "tool")]\u001b[0m "
      else empty end' 2>/dev/null | \
    tee >(strip_ansi | tee -a "$LOG_FILE" > "$ITER_LOG")
  CLAUDE_EXIT=${PIPESTATUS[0]}
  PIPE1=${PIPESTATUS[1]:-?}
  PIPE2=${PIPESTATUS[2]:-?}
  PIPE3=${PIPESTATUS[3]:-?}
  debug "Pipeline finished. PIPESTATUS=[$CLAUDE_EXIT,$PIPE1,$PIPE2,$PIPE3]"
  set -e

  ITER_END=$(date +%s)
  ITER_DURATION=$((ITER_END - ITER_START))
  debug "Duration: ${ITER_DURATION}s"

  # ─── Count subagent dispatches + orphans via dispatch log ──
  SUBAGENT_COUNT=0
  if [ -f "$DISPATCH_LOG" ] && [ -s "$DISPATCH_LOG" ]; then
    eval "$(jq -rs '
      ([.[] | select(.event == "dispatch")] | length) as $d |
      ([.[] | select(.event == "dispatch") | .index]) as $di |
      ([.[] | select(.event == "stop") | .index]) as $si |
      ($di | map(select(. as $i | $si | index($i))) | length) as $c |
      "SUBAGENT_COUNT=\($d) SUBAGENT_COMPLETED=\($c)"
    ' "$DISPATCH_LOG" 2>/dev/null || echo "SUBAGENT_COUNT=0 SUBAGENT_COMPLETED=0")"
    SUBAGENT_ORPHANED=$((SUBAGENT_COUNT - SUBAGENT_COMPLETED))
    if [ "$SUBAGENT_COUNT" -gt 0 ]; then
      if [ "$SUBAGENT_ORPHANED" -gt 0 ]; then
        log "${YELLOW}Subagents: $SUBAGENT_COMPLETED/$SUBAGENT_COUNT completed ($SUBAGENT_ORPHANED orphaned)${NC}"
      else
        log "${GREEN}Subagents: $SUBAGENT_COUNT/$SUBAGENT_COUNT completed${NC}"
      fi
    fi
  fi

  debug "Subagent count: $SUBAGENT_COUNT"

  # ─── Parse result signal from iteration output ──
  RESULT_SIGNAL=$(parse_result_signal "$ITER_LOG")
  debug "parse_result_signal from ITER_LOG: '$RESULT_SIGNAL'"

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
      debug "Inferred signal from status.md: '$RESULT_SIGNAL'"
    else
      debug "status.md fallback: file missing or not newer than marker"
    fi
  fi

  debug "Final RESULT_SIGNAL='$RESULT_SIGNAL' CLAUDE_EXIT=$CLAUDE_EXIT"

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

  debug "ITER_STATUS=$ITER_STATUS ITER_REASON=$ITER_REASON"
  master_log "$ITERATION" "$ITER_LABEL" "$ITER_STATUS" "$ITER_DURATION" "$ITER_REASON" "$SUBAGENT_COUNT"
  debug "master_log written"
  ITER_MINS=$((ITER_DURATION / 60))
  ITER_SECS=$((ITER_DURATION % 60))
  notify "Loom — Iter $ITERATION" "$RESULT_SIGNAL (${ITER_MINS}m ${ITER_SECS}s, $SUBAGENT_COUNT subagents)"
  debug "notify sent"

  # ─── Update source tracking comment ──
  update_source_tracking "$ITERATION" "$RESULT_SIGNAL" "$ITER_DURATION" "$SUBAGENT_COUNT"

  # ─── Done: no remaining work ──
  if [ "$RESULT_SIGNAL" = "DONE" ]; then
    debug "BREAK: RESULT_SIGNAL=DONE — all work complete"
    log "${GREEN}${BOLD}All work complete.${NC} Halting loop."
    notify "Loom ✓ Complete" "All work done after $ITERATION iterations."
    break
  fi

  # ─── Circuit breaker: check if status.md was updated ──
  if [ -f "$LOOM_DIR/.iteration_marker" ]; then
    if [ ! -f "$LOOM_DIR/status.md" ] || [ "$LOOM_DIR/status.md" -ot "$LOOM_DIR/.iteration_marker" ]; then
      # status.md not updated — count as failure
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      debug "Circuit breaker: status.md NOT updated. failures=$CONSECUTIVE_FAILURES/$MAX_FAILURES"
      log "${YELLOW}status.md not updated — failure $CONSECUTIVE_FAILURES/$MAX_FAILURES${NC}"
    else
      # Success — reset counter
      debug "Circuit breaker: status.md updated. Resetting failures to 0"
      CONSECUTIVE_FAILURES=0
    fi
  else
    debug "Circuit breaker: no .iteration_marker found (skipping check)"
  fi

  # ─── Commit status.md as iteration checkpoint ──
  if [ -f "$LOOM_DIR/status.md" ] && [ "$LOOM_DIR/status.md" -nt "$LOOM_DIR/.iteration_marker" ]; then
    debug "Committing status.md checkpoint"
    (
      cd "$PROJECT_DIR"
      git add "$LOOM_DIR/status.md" 2>>"$LOG_FILE"
      git commit --no-gpg-sign -m "chore(loom): iteration $ITERATION checkpoint [$RESULT_SIGNAL]" \
        -m "iteration: $ITERATION, status: $ITER_STATUS" 2>>"$LOG_FILE"
    ) && { debug "  status.md commit succeeded"; log "${DIM}Committed status.md checkpoint${NC}"; } \
      || { debug "  status.md commit failed"; log "${YELLOW}status.md checkpoint commit failed (see above)${NC}"; }
  else
    debug "Skipping status.md commit (file missing or not newer than marker)"
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
    debug "BREAK: preview mode — one iteration only"
    log "${GREEN}Preview analysis complete.${NC}"
    break
  fi

  debug "─── LOOP BOTTOM ─── iteration=$ITERATION — continuing to next iteration"

done
debug "─── LOOP EXITED ─── after $ITERATION iteration(s). PREVIEW=$PREVIEW MAX_ITERATIONS=$MAX_ITERATIONS"
log "${DIM}Loop exited after $ITERATION iteration(s)${NC}"

if ! $PREVIEW && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  log "${YELLOW}${BOLD}Loom completed $MAX_ITERATIONS iterations. Halting.${NC}"
  master_log "$ITERATION" "$MODE_LABEL" "MAX_ITER" "0" "Reached max iterations" "0"
  notify "Loom — Max Iterations" "Completed $MAX_ITERATIONS iterations."
fi

# ─── Finalize source tracking ────────────────────────────────────
finalize_source_tracking "$ITERATION" "${RESULT_SIGNAL:-UNKNOWN}"
