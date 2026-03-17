# Onboarding QA Re-run — Brainstorm Session

**Date**: 2026-03-02
**Buddy**: Gemini 2.5 Pro
**Session**: `onboarding-qa-review`

## Problem

Running the onboarding flow end-to-end for QA currently requires wiping UserDefaults or the entire build directory. Need a one-click way to restart onboarding from the dev app.

## Architecture Context Shared

- `OnboardingState` enum: `.needsMicPermission` → `.needsModelDownload` → `.needsCompletion` → `.completed`
- Stored in UserDefaults via `SettingsManager.onboardingState` (also syncs legacy `hasCompletedOnboarding` Bool)
- `AppDelegate.openOnboardingWindow()` guards on `onboardingState != .completed`
- `EnviousWisprApp` has `@State var isOnboardingPresented` computed once at init from UserDefaults
- `ActionWirer.task` checks `onboardingState != .completed` to auto-open on launch
- `OnboardingView.onAppear` checks `onboardingState == .needsCompletion` to skip to Step 3

## Proposed Plan

Add a "Restart Onboarding" button in DiagnosticsSettingsView (Debug Mode section):
1. Reset `onboardingState` to `.needsMicPermission`
2. Call `appDelegate.openOnboardingWindow()`
3. Existing state (TCC, models, API keys) preserved — steps auto-advance

## Buddy Review — Key Findings

### Validated as Safe
- **`dismissWindow` mid-session**: Works correctly regardless of when window was opened
- **ActionWirer.task**: One-shot initializer, won't re-trigger mid-session — no race condition
- **isOnboardingPresented stale state**: Irrelevant for opening (uses `openWindow(id:)`) and dismissal (uses `dismissWindow(id:)`)
- **Fast-forwarding through completed steps**: Acceptable and preferable — tests conditional logic in each step

### Critical Issue Found
- **Recording during restart**: Triggering onboarding while recording could crash the audio engine or cause data loss. **Fix**: `.disabled(appState.pipelineState != .idle)` on the button.

### Flagged but Dismissed (with justification)
- **Settings window hidden on restart**: This IS the real onboarding UX we want to test. Acceptable for a debug-only feature gated behind Debug Mode.
- **Refactoring `isOnboardingPresented` to derived state**: Over-engineering for a debug feature. Current approach works.
- **Step picker (start at specific step)**: YAGNI for now. Can add later if clicking through Steps 1-2 becomes a time sink.

## Final Consensus

Minimal implementation: ~8 lines in one file (`DiagnosticsSettingsView.swift`), with recording guard as the only addition from the original plan.
