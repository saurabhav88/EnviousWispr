# Roadmap & Feature Requests

## Feature Request Location

```text
docs/feature-requests/
  TRACKER.md              # Master checklist — source of truth for status
  001-cancel-hotkey.md    # One file per feature, zero-padded ID
  002-transcribe-with-llm-hotkey.md
  ...
  020-wav-recording-history.md
```

## Feature Request Doc Format

Each `.md` follows this template:

```markdown
# Feature: <Title>

**ID:** NNN
**Category:** <Hotkeys & Input | Clipboard & Output | AI & Post-Processing | Audio & Models | Localization & i18n | Platform & Distribution | Developer Experience>
**Priority:** <High | Medium | Low>
**Inspired by:** <source>
**Status:** <Planning | In Progress | Complete>

## Problem
What user pain does this solve?

## Proposed Solution
High-level approach (1-2 paragraphs).

## Files to Modify
List of source files to create or change.

## Implementation Plan
Step-by-step with code snippets.

## Testing Strategy
How to verify (smoke test, UI test, manual).

## Risks & Considerations
Edge cases, compatibility, performance.
```

## Tracker Status Legend

| Marker | Meaning |
|--------|---------|
| `[ ]` | Not started — skeleton only |
| `[~]` | In progress — implementation plan being written |
| `[x]` | Complete — full implementation plan ready |

## Priority Categories

- **High** — Core UX gaps, frequently requested (cancel hotkey, clipboard restore, model unload)
- **Medium** — Power-user features, nice-to-have (CLI control, auto-submit, debug mode)
- **Low** — Niche or large-scope (cross-platform, i18n, always-on mic)

## Feature Categories

| Category | Feature IDs |
|----------|-------------|
| Hotkeys & Input | 001-004 |
| Clipboard & Output | 005-007 |
| AI & Post-Processing | 008-010 |
| Audio & Models | 011-014 |
| Localization & i18n | 015-016 |
| Platform & Distribution | 017-018 |
| Developer Experience | 019-020 |

## Implementation Workflow

1. Read the feature request doc (`docs/feature-requests/NNN-*.md`)
2. Read relevant knowledge files (architecture, gotchas, conventions)
3. Identify which existing agents own the affected code areas
4. Write implementation plan in the feature doc
5. Update TRACKER.md status to `[x]`
6. When implementing: dispatch to owning agents, chain build-compile + testing

## Agent Mapping for Features

| Feature Area | Primary Agent | Supporting Agents |
|-------------|---------------|-------------------|
| Hotkeys | macos-platform | audio-pipeline |
| Clipboard/Paste | macos-platform | — |
| LLM/AI features | feature-scaffolding | quality-security |
| Audio/Models | audio-pipeline | build-compile |
| UI/Settings | feature-scaffolding | macos-platform |
| Distribution | release-maintenance | build-compile |
| Concurrency | quality-security | — |
