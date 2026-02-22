---
name: wispr-implement-feature-request
description: Use when implementing a feature from its docs/feature-requests/ spec — reads the plan, identifies affected files, dispatches to domain agents, validates with build + smoke test, generates UAT scenarios, and runs behavioral tests before marking complete.
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
- `.claude/knowledge/conventions.md` — patterns to follow (includes Definition of Done)

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
swift build -c release 2>&1
```

Fix any build errors before proceeding to next step.

### 5. Run smoke test

Invoke `run-smoke-test` skill to verify:
- `swift build` passes
- `swift build --build-tests` passes
- App launches without crashing (5-second timeout)

### 6. Generate UAT test scenarios (MANDATORY)

Invoke `wispr-generate-uat-tests` skill to systematically enumerate test scenarios:

1. Read the feature spec's Testing Strategy section
2. Apply the 6 enumeration techniques:
   - Happy paths (golden path)
   - Equivalence partitioning (different trigger methods, states, settings)
   - Boundary value analysis (timing edges, min/max values)
   - State transition coverage (every pipeline state x feature action)
   - Negative tests (wrong state, missing permissions, invalid input)
   - Sequence tests (rapid actions, cancel-restart, feature interactions)
3. Write scenarios to `Tests/UITests/scenarios/NNN-feature-name.md`
4. Add test functions to `Tests/UITests/uat_runner.py` with `@uat_test` decorator

### 7. Run UAT behavioral tests (MANDATORY)

A feature is NOT complete until behavioral tests pass:

```bash
# Rebuild bundle and relaunch with fresh permissions
# (use wispr-rebuild-and-relaunch skill)

# Run ALL UAT tests (ensures no regressions)
python3 Tests/UITests/uat_runner.py run --verbose

# Run feature-specific suite
python3 Tests/UITests/uat_runner.py run --suite [feature_suite] --verbose
```

**If any test FAILS**: the feature has a bug. Fix the code, NOT the test. Then re-run.

### 8. Update tracker

ONLY after ALL UAT tests pass, edit `docs/feature-requests/TRACKER.md`:
- Change feature status from `[x]` (plan complete) to implemented
- Add implementation date

### 9. Commit

Use conventional commit format:
```
feat(<scope>): <feature title>
```

Where scope maps to the primary code area affected.

## Definition of Done

ALL must be true before marking a feature complete:

- [ ] Code implemented and compiles (`swift build -c release`)
- [ ] Test target compiles (`swift build --build-tests`)
- [ ] App bundle rebuilt and launches without crashing
- [ ] UAT scenarios generated and documented in `Tests/UITests/scenarios/`
- [ ] UAT behavioral tests added to `uat_runner.py`
- [ ] **All UAT tests pass** (`python3 Tests/UITests/uat_runner.py run --verbose`)
- [ ] TRACKER.md updated
- [ ] Committed with conventional commit format
