# Session 1 — "Polish the Brain"

You are running an internal systems polish cycle for the EnviousWispr project.
Do NOT write or modify application source code. This session is strictly about
improving Claude's own instructions, guardrails, knowledge, and skills.

## Pre-flight

Before starting, read these knowledge files (per CLAUDE.md rules):
- .claude/knowledge/conventions.md
- .claude/knowledge/architecture.md
- .claude/knowledge/gotchas.md
Then run `git status` to confirm a clean working tree.

## Cycle

Run this 4-step sequence TWO times. Each pass builds on the previous.

### Step 1 — claude-md-management (`/claude-md-improver`)
Audit all CLAUDE.md files across the project. Fix stale references, missing
agents/skills, incorrect paths, outdated conventions.
- Pass 2: verify pass 1 changes are internally consistent and didn't
  introduce contradictions with knowledge files.

### Step 2 — hookify (`/hookify`)
Analyze THIS session's transcript for mistakes, bad patterns, or near-misses.
Create hooks ONLY when backed by observed evidence from the transcript.
- Do NOT create speculative or hypothetical hooks
- Pass 2: review ALL existing hooks (including pass 1 hooks) for conflicts,
  redundancy, or over-broad patterns. Remove any that would block legitimate
  work. Tighten, don't accumulate.

### Step 3 — context7
Fetch current documentation for project dependencies, scoped per pass:
  - Pass 1: FluidAudio, WhisperKit (ASR core)
  - Pass 2: Sparkle, Swift Concurrency (distribution + platform)
After each fetch, cross-reference against `.claude/knowledge/` files.
If any knowledge file contains outdated API info, update it.
If the docs match what we have, state "knowledge is current" and move on.

### Step 4 — skill-creator (`/skill-creator`)
Audit skill inventory against agent capabilities and knowledge files.
- If a real, actionable gap exists → create the skill
- If no gap exists → state "no new skills needed" and move on
- Do NOT create skills for hypothetical future needs
- Pass 2: also verify skills created in pass 1 follow the conventions
  in .claude/knowledge/conventions.md

## Completion Rules

- Complete each step fully before starting the next
- After each full cycle (steps 1-4), write a brief summary:
  PASS N SUMMARY: [what changed, what was already clean]
- EARLY EXIT: if pass 2 produces zero changes across all 4 steps, skip
  any remaining work — the system is already clean
- Show `git diff --stat` when done
- Commit with: `chore(claude): polish internal systems — 2-pass brain cycle`
- Print: SESSION 1 COMPLETE — ready for quality pass
