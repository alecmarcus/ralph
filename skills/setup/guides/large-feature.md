# Large Feature

Build an entire multi-story feature from spec documents using PRD mode — Loom's primary workflow.

## When to Use

- You have spec documents, design files, or planning notes describing a feature
- The work spans multiple files and will take more than one subagent iteration
- You want Loom to decompose the spec, plan dependencies, and execute stories in parallel

## Step 1: Prepare Your Specs

Gather your specification documents. Loom's `/loom:prd` generator accepts any file format but works best with structured markdown.

A good spec file includes:
- Clear sections with headings (h1-h6)
- Requirements as bullet lists (these become acceptance criteria 1:1)
- Implementation details and constraints
- Edge cases and error handling notes

```bash
# Verify your spec files exist
ls specs/feature-design.md specs/api-spec.md
```

If your specs are in other formats (Notion export, Google Doc, PDF), convert them to markdown first. The `/loom:prd` generator uses `mdq` to extract individual sections, so heading structure matters.

## Step 2: Generate the PRD

```bash
# From inside Claude Code (recommended)
/loom:prd specs/feature-design.md specs/api-spec.md

# With a custom story prefix
/loom:prd specs/feature-design.md prefix AUTH

# Limit story count for a first pass
/loom:prd specs/feature-design.md max 20
```

Or standalone:

```bash
/loom:prd specs/feature-design.md specs/api-spec.md
```

The generator will:
1. Index each file's heading structure without reading the full content
2. Extract sections on demand using `mdq`
3. Dispatch one subagent per section to transform it into story JSON
4. Group stories into prioritized gates (P0 → P1 → P2)
5. Set `blockedBy` dependencies between stories
6. Auto-detect `tools` requirements from acceptance criteria keywords
7. Verify nothing was lost in decomposition (coverage, verbatim, nuance, completeness checks)
8. Write `.loom/prd.json`

### Review the output

```bash
# Count stories and gates
jq '{stories: (.stories | length), gates: (.gates | length), root: [.stories[] | select(.blockedBy == [])] | length}' .loom/prd.json

# See the gate breakdown
jq '.gates[] | {name, priority, stories: (.stories | length)}' .loom/prd.json

# Check which stories can start immediately (no blockers)
jq '[.stories[] | select(.blockedBy == [] and .status == "pending")] | .[0:5] | .[] | {id, title, priority}' .loom/prd.json
```

### Refine if needed

```bash
# Add more stories from additional specs
/loom:prd specs/additional-requirements.md append

# Manually edit a story's acceptance criteria or dependencies
# Use jq for targeted edits — never rewrite the entire file
```

## Step 3: Preview (optional but recommended)

Preview what Loom will do on the first iteration without executing changes:

```bash
/loom:preview
```

Or from bash:

```bash
/loom:preview
```

This runs one iteration in read-only mode: recalls status, selects stories, shows which subagents would be dispatched and what they'd work on. Use this to verify the PRD decomposition looks right before committing to a full run.

## Step 4: Start the Loom

```bash
# From Claude Code
/loom:start

# From bash (via plugin scripts)
LOOM="$(cat .loom/.plugin_root)" && "$LOOM/scripts/start.sh"
```

Loom will:
1. Create a git worktree (isolated branch)
2. Launch a tmux session with monitoring panes
3. Begin iterating: recall → select → dispatch subagents → test → commit → report

### Monitor progress

```bash
# Attach to the tmux session
tmux attach -t loom-<project>

# Check status summary
/loom:status

# Watch the status file
cat .loom/status.md
```

The tmux session has four panes:
- **Top**: Session header (PID, mode, config, detected MCPs)
- **Middle**: Live Claude Code output
- **Bottom-left**: `status.md` (refreshes every 3s)
- **Bottom-right**: `iterations.log` tail

## Step 5: Let It Run

Loom handles everything autonomously:
- Selects parallelizable stories whose dependencies are resolved
- Dispatches one subagent per story, all in parallel
- Runs tests after subagents complete, fixes failures (up to 3 attempts)
- Commits only green code with conventional commit messages
- Updates `status.md` as short-term memory for the next iteration
- Stores patterns and decisions in Vestige for long-term memory
- Updates `.loom/prd.json` story statuses as work completes

### When stories have MCP tool requirements

Stories with `"tools": ["browser"]`, `"tools": ["mobile"]`, or `"tools": ["design"]` are automatically skipped if the required MCP servers aren't configured. They stay `pending` and will be picked up if you add the MCP later. See the [validation setup guides](validation/) or run `/loom:setup mobile`.

## Step 6: Completion

Loom stops automatically when:
- All stories are `done` or `cancelled` → emits `LOOM_RESULT:DONE`
- Or a circuit breaker trips (consecutive failures, max iterations, timeout)

When the loop completes with worktree mode (default):
1. The branch is pushed to the remote
2. A PR is created automatically
3. The worktree remains for inspection

### If it stops early

Check the status and logs:

```bash
/loom:status
cat .loom/status.md
tail -50 .loom/logs/iterations.log
```

Common reasons for early stops:
- **3 consecutive failures** — the circuit breaker tripped. Check what's failing in `status.md`
- **All remaining stories are tool-gated** — install the required MCP servers
- **Timeout** — a single iteration took longer than the timeout (default 3 hours)

### Resume after a stop

```bash
# Resume the existing worktree
/loom:start resume

# Resume a specific worktree
/loom:start resume /path/to/worktree
```

## Tuning

| Scenario | Flag | Example |
|----------|------|---------|
| Large PRD, let it run longer | `--max-iterations` | `/loom:start -m 1000` |
| Fragile tests, allow more retries | `--max-failures` | `/loom:start --max-failures 5` |
| Slow builds, increase timeout | `--timeout` | `/loom:start --timeout 7200` |
| Skip worktree (work in current branch) | `--worktree false` | `/loom:start --worktree false` |
| Skip PR creation | `--pr false` | `/loom:start --pr false` |

## Checklist

- [ ] Spec files are structured markdown with clear headings
- [ ] `/loom:prd` generated `.loom/prd.json` successfully
- [ ] Story count and gate structure look reasonable
- [ ] Root stories (no blockers) can start immediately
- [ ] Preview shows the expected first-iteration behavior
- [ ] `/loom:start` launched and tmux session is visible
