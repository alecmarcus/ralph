#!/usr/bin/env bash
# PostToolUse hook (Agent): After any subagent completes, remind the
# orchestrator of the mandatory review cycle protocol.
# Only active when the orchestrator is running (marker file exists).

HASH=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | shasum -a 256 | cut -c1-16)
MARKER="/tmp/loom-orchestrating-${HASH}"

if [ ! -f "$MARKER" ]; then
  exit 0
fi

cat <<'MSG'

================================================================
  REVIEW CYCLE — READ THIS BEFORE YOUR NEXT ACTION
================================================================

  A subagent just completed. What type was it?

  CODER completed    → dispatch REVIEWER with the diff. Not optional.
  REVIEWER completed → dispatch ARBITER with findings. Not optional.
  ARBITER completed  → check accepted findings count:
    accepted > 0 → dispatch CODER to fix → then REVIEWER again (THE LOOP)
    accepted = 0 → triage rejected findings → resolve PR comments → verify → ship

  NO SIZE EXEMPTIONS. A 1-line fix gets the full cycle. No "too small to review."
  YOU DO NOT CODE, REVIEW, OR ARBITRATE. Dispatch agents. Always.

  STATE MACHINE (every issue, no exceptions):
    coded → REVIEWER → reviewed → ARBITER → arbitrated
    arbitrated + findings > 0 → CODER fix → coded (LOOP BACK)
    arbitrated + findings = 0 → triage rejections → converged → VERIFY → SHIP

  MEMORY + FINDINGS + COMMENTS CHECK:
  - Did the arbiter just return? Triage ALL rejected findings.
    Actionable rejections → overrule or file GitHub issue. No drops.
  - Do any open PRs have unresolved comments? Each comment gets the
    full treatment: reviewer → arbiter loop, respond in-thread with
    references, then resolve/hide. No skipping to verification.
  - Have you written to Vestige since your last wave/review/verification?
    If not, write learnings NOW (smart_ingest).
  - Are you about to dispatch? Search Vestige for relevant context first.

================================================================

MSG
