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
