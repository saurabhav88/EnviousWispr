# Custom Words v2 — Apple Intelligence Integration

**Status**: FAILED — Reverted 2026-03-12
**Checkpoint**: `checkpoint/pre-custom-words-v2-ai`

Attempted to integrate Apple Foundation Models (`@Generable`, `LanguageModelSession`) into the Custom Words pipeline. Caused systematic `MainActor.assumeIsolated` crashes on macOS 26.4 beta — corrupted Swift concurrency runtime executor, affecting all timer/callback/SwiftUI code.

## Contents

| File | Description |
|------|-------------|
| `postmortem.md` | Full postmortem: crash analysis, root cause, debug timeline, learnings |
| `implementation-plan.md` | Original 3-phase plan (Phase 1: suggestions, Phase 2: FM correction, Phase 3: cloud LLM) |
| `research-foundation-models.md` | Apple Foundation Models API research (LanguageModelSession, @Generable, token limits) |
| `research-speechanalyzer.md` | Apple SpeechAnalyzer research (verdict: SKIP — contextualStrings not viable) |
| `failed-implementation.patch` | Full git diff of all source changes (apply with `git apply` to reproduce) |
| `snapshot-WordSuggestionService.swift` | New file: AI suggestion service with @Generable + Task.detached timeout race |
| `snapshot-CustomWordPromptRendering.swift` | New file: Custom word list rendering for LLM/FM prompt injection |
| `crash-reports-summary.txt` | All 7 crash signatures with timestamps and addresses |

## Beads

- `ew-d6y` — Review findings (8 issues) — closed as failed
- `ew-uxr` — Post-review fixes — closed as failed
- `ew-ceh` — Phase 1: AI suggestions — open, blocked on macOS beta
- `ew-2zt` — Phase 2: FM correction — open, blocked on macOS beta
- `ew-awj` — Phase 3: Cloud LLM polish — open, can proceed without FM

## What can be salvaged (no FoundationModels dependency)

1. Auto-open edit sheet on word add (pure SwiftUI, from `WordFixSettingsView` changes)
2. Custom word injection into LLM polish prompt (from `LLMPolishStep` changes)
3. `CustomWord+PromptRendering` helper (pure Swift, no FM imports)
4. `fmCorrectionEnabled` settings plumbing (for future use)
