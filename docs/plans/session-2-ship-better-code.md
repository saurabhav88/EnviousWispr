# Session 2 — "Ship Better Code"

You are running a software quality hardening cycle for the EnviousWispr project.
This session focuses on improving the actual application code.

## Pre-flight

Before starting, read these knowledge files (per CLAUDE.md rules):
- .claude/knowledge/architecture.md
- .claude/knowledge/gotchas.md
- .claude/knowledge/conventions.md
- .claude/knowledge/teamwork.md

Then run these checks:
1. `swift build` — establish a clean baseline. Note any existing warnings.
2. **Structure audit**: compare `Sources/EnviousWispr/` directory listing against
   architecture.md. Flag any mismatches in either direction (undocumented dirs,
   documented dirs that don't exist, files in wrong directories).
   Fix any documentation mismatches before proceeding.

## Cycle

Run this sequence TWO times.

### Step 1 — Identify Issues (`/feature-dev`)

Scan the codebase for architectural issues, incomplete implementations,
and design problems. Produce a prioritized list WITH dependency annotations:
- For each issue, note which source directories it touches
- Flag issues that span 2+ directories as "cross-domain"
- Pass 1: full scan
- Pass 2: re-scan focusing only on files modified in pass 1
Do NOT implement fixes — identify and document only.

### Step 2 — Agent Team: Fix Issues

Use `TeamCreate` (name: `quality-team`) with this composition:

| Name | Agent Type | Role |
|------|-----------|------|
| simplifier | code-simplifier | Simplify flagged files for clarity. Preserve all functionality. |
| auditor | quality-security | Scan for vulnerabilities, unsafe concurrency, credential leaks. Report only confirmed issues. |
| builder | build-compile | Compile validation after each teammate's changes. Gatekeeper. |

#### Workflow within the team

```
1. Coordinator creates tasks from Step 1 issue list
2. Assign non-cross-domain tasks to simplifier and auditor in parallel
3. After EACH task completion:
   a. Builder runs `swift build` — if it fails, the changing agent fixes before proceeding
   b. If the change touched files in another agent's domain, that agent is notified via SendMessage
4. Cross-domain tasks are handled sequentially:
   a. Primary agent makes the change
   b. Builder verifies build
   c. Affected-domain agent reviews the change via SendMessage and flags concerns
   d. Concerns are resolved before moving to next task
5. When all tasks complete, shutdown team
```

#### Cross-domain communication rules

When an agent modifies a file, it MUST check: does this file get imported or
called from another directory? If yes:
- SendMessage to the agent owning that directory with: what changed, what callers
  might be affected, and what to verify
- The receiving agent checks callers and confirms no breakage OR flags the issue
- Builder runs `swift build` as the final gate

**Domain ownership map** (from architecture.md):
- `App/` → macos-platform
- `ASR/` → audio-pipeline
- `Audio/` → audio-pipeline
- `LLM/` → quality-security (for key handling), feature-scaffolding (for connectors)
- `Models/` → any (shared types — changes here affect everyone)
- `Pipeline/` → audio-pipeline
- `PostProcessing/` → audio-pipeline
- `Services/` → macos-platform
- `Storage/` → any
- `Views/` → macos-platform, feature-scaffolding

**High-risk cross-domain files** (changes here ALWAYS need cross-agent review):
- `Models/*.swift` — shared types used everywhere
- `Pipeline/TranscriptionPipeline.swift` — orchestrator touching all domains
- `App/AppState.swift` — root DI container, every view depends on it
- `Services/PasteService.swift` — called from Pipeline and Views

### Step 3 — Deep Review (`/review-pr`)

After team completes, run pr-review-toolkit on ALL changes. Focus areas:
- Silent failures and swallowed errors
- Type design quality
- Test coverage gaps
- Regressions introduced by simplification
- Cross-domain breakage that the team might have missed

### Step 4 — Second Opinion (`/review`)

Independent coderabbit review. Specifically flag anything Step 3 didn't catch.
If both reviewers agree the code is clean, state that explicitly.

## Between Passes

After pass 1 completes:
1. Fix any issues flagged by Steps 3-4 BEFORE starting pass 2
2. Run `swift build` to confirm fixes compile
3. Pass 2 reviews the fixes, not the original problems

## Finish

After both passes:

1. Run `/wispr-run-smoke-test`
2. Run `swift build` — confirm zero errors
3. Print a change summary:
   - Files modified with one-line descriptions
   - `git diff --stat`
   - Count: N files changed, N insertions, N deletions
   - Cross-domain changes that were peer-reviewed (list them)
4. STOP and ask:
   "Quality cycle complete. N files changed. Ready to commit? [Y/n]"
   Do NOT commit until I confirm.

Commit message: `refactor: quality hardening — 2-pass review cycle`
