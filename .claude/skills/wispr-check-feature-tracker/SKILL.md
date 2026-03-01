---
name: wispr-check-feature-tracker
description: Use when checking feature request status, reviewing what's planned vs done, or getting a quick overview of the roadmap backlog in docs/feature-requests/TRACKER.md.
---

# Check Feature Tracker

## Steps

### 1. Read the tracker

```bash
cat /Users/m4pro_sv/Desktop/EnviousWispr/docs/feature-requests/TRACKER.md
```

### 2. Count statuses

Parse the tracker tables and count:
- `[ ]` = Not started
- `[~]` = In progress
- `[x]` = Complete

#### TRACKER.md checkbox format examples

```markdown
| #   | Feature                     | Status |
|-----|-----------------------------|--------|
| 001 | Cancel Hotkey               | [x]    |
| 005 | Clipboard Save/Restore      | [x]    |
| 008 | Custom Word Correction      | [~]    |
| 013 | Multi-language Switching    | [ ]    |
```

- `[x]` — feature is committed and build-clean (code merged, tests passed)
- `[~]` — implementation plan exists OR code is in progress but not yet merged
- `[ ]` — not started (plan may or may not exist)

### 3. Report summary

Output a table like:

```
Feature Tracker Status (YYYY-MM-DD)
────────────────────────────────────
  Not started:  NN
  In progress:  NN
  Complete:     NN
  Total:        20

High priority incomplete:
  - NNN: <title>
  - NNN: <title>
```

### 4. If a specific feature is requested

Read `docs/feature-requests/NNN-*.md` and report:
- Status (Planning / In Progress / Complete)
- Whether implementation plan is written
- Whether testing strategy is defined
- Priority level

## Definition of Done — when to mark `[x]`

A feature is `[x]` (Complete) only when ALL of the following pass (from `conventions.md`):

1. `swift build -c release` exits 0
2. `swift build --build-tests` exits 0
3. `.app` bundle rebuilt and relaunched (`wispr-rebuild-and-relaunch`)
4. Smart UAT tests pass (`wispr-run-smart-uat` — scope-driven, generates targeted tests for the feature)
5. All UAT execution used `run_in_background: true`

Mark `[~]` (In Progress) when code is merged but UAT has not yet passed, or when the implementation plan exists but code is not yet started.
