---
name: implement-feature-request
description: Use when implementing a feature from its docs/feature-requests/ spec — reads the plan, identifies affected files, dispatches to domain agents, and validates with build + smoke test.
---

# Implement Feature Request

## Prerequisites

- Feature doc must have a completed implementation plan (status `[x]` in TRACKER.md)
- If plan is missing, dispatch to **feature-planning** agent first

## Steps

### 1. Read the feature spec

```bash
cat /Users/m4pro_sv/Desktop/EnviousWispr/docs/feature-requests/NNN-*.md
```

Confirm "Implementation Plan" and "Files to Modify" sections are filled in.

### 2. Read knowledge files

Before any code changes, read:
- `.claude/knowledge/architecture.md` — affected types and structure
- `.claude/knowledge/gotchas.md` — known pitfalls for the domain
- `.claude/knowledge/conventions.md` — patterns to follow

### 3. Map steps to agents

For each implementation step, identify the owning agent:

| Code Area | Agent |
|-----------|-------|
| Hotkeys, permissions, NSEvent, paste | macos-platform |
| Audio capture, VAD, ASR backends | audio-pipeline |
| New views, settings tabs, backends | feature-scaffolding |
| Concurrency, Sendable, secrets | quality-security |
| Build failures, dependency updates | build-compile |

### 4. Dispatch agents in order

Execute implementation steps by dispatching to agents in dependency order. After each agent completes, run:

```bash
swift build 2>&1
```

Fix any build errors before proceeding to next step.

### 5. Run smoke test

Invoke `run-smoke-test` skill to verify:
- `swift build` passes
- `swift build --build-tests` passes
- App launches without crashing (5-second timeout)

### 6. Update tracker

Edit `docs/feature-requests/TRACKER.md`:
- Change feature status from `[x]` (plan complete) to implemented
- Add implementation date

### 7. Commit

Use conventional commit format:
```
feat(<scope>): <feature title>
```

Where scope maps to the primary code area affected.
