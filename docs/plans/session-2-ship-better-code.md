# Session 2 — "Ship Better Code"

You are running a software quality hardening cycle for the EnviousWispr project.
This session focuses on improving the actual application code.

## Pre-flight

Before starting, read these knowledge files (per CLAUDE.md rules):
- .claude/knowledge/architecture.md
- .claude/knowledge/gotchas.md
- .claude/knowledge/conventions.md
Confirm swift-lsp is active. Run `swift build` to establish a clean baseline.
Note any existing warnings — these are your starting inventory.

## Cycle

Run this 5-step sequence TWO times.

### Step 1 — feature-dev (`/feature-dev`)
Scan the codebase for architectural issues, incomplete implementations,
and design problems. Produce a prioritized list.
- Pass 1: full scan
- Pass 2: re-scan focusing only on files modified in pass 1
Do NOT implement fixes — identify and document only.

### Steps 2+3 — PARALLEL via Agent Team

Spawn a team. These run simultaneously on the issues from Step 1:

  **Teammate A — code-simplifier (subagent)**
  Simplify flagged files for clarity and maintainability.
  Preserve all functionality. Do not add features.

  **Teammate B — security-guidance (subagent)**
  Scan for vulnerabilities: credential leaks, injection risks,
  unsafe concurrency, missing validation at system boundaries.
  Report only confirmed issues, not theoretical ones.

Wait for both to complete before proceeding.

### Step 4 — pr-review-toolkit (`/review-pr`)
Deep review of ALL changes made this session. Focus areas:
- Silent failures and swallowed errors
- Type design quality
- Test coverage gaps
- Any regressions introduced by code-simplifier

### Step 5 — coderabbit (`/review`)
Independent second review of all changes. Specifically flag anything
Step 4 did not catch. If coderabbit agrees with pr-review-toolkit
that the code is clean, state that explicitly.

## Between Passes

After pass 1 completes, fix any issues flagged by Steps 4-5 BEFORE
starting pass 2. Pass 2 reviews the fixes, not the original problems.

## Finish

After both passes:

1. Run `/wispr-run-smoke-test`
2. Run `swift build` — confirm zero errors
3. Print a change summary:
   - Files modified with one-line descriptions
   - `git diff --stat`
   - Count: N files changed, N insertions, N deletions
4. STOP and ask:
   "Quality cycle complete. N files changed. Ready to commit? [Y/n]"
   Do NOT commit until I confirm.

Commit message: `refactor: quality hardening — 2-pass review cycle`
