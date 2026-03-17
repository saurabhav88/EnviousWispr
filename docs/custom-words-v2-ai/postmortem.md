# Custom Words v2 AI Integration — Project Postmortem

**Date**: 2026-03-12
**Status**: FAILED — Reverted to `checkpoint/pre-custom-words-v2-ai`
**Duration**: ~1 session (2026-03-11 evening → 2026-03-12 early morning)

## Summary

Attempted to integrate Apple Foundation Models (`FoundationModels` framework, `@Generable` macro) into the Custom Words pipeline for:
1. AI-powered word suggestion (auto-categorize + phonetic alias generation)
2. FM-based transcript correction (context-aware word fixing)
3. Custom word injection into LLM polish prompts

**Result**: App crashed consistently within seconds of every hotkey press. 7+ crashes across multiple rebuild attempts. Initially blamed on `@Generable` macro metadata corrupting the Swift concurrency runtime. **Actual root cause discovered later: Bluetooth audio headphones (Bose) connected for the first time caused memory corruption in macOS 26.4 beta's audio routing, which manifested as `MainActor.assumeIsolated` executor crashes.** The Custom Words v2 changes were innocent.

## Beads Trail

| Bead | Title | Status |
|------|-------|--------|
| ew-ceh | Custom Words Phase 1: Auto-open edit sheet + AI auto-categorize/suggest aliases | open (unstarted) |
| ew-2zt | Custom Words Phase 2: Foundation Models as primary word correction layer | open (unstarted) |
| ew-awj | Custom Words Phase 3: Cloud LLM polish must-have for own-API-key users | open (unstarted) |
| ew-d6y | [bug] Fix Custom Words v2 review findings (8 issues) | open — review found 8 issues before crash was discovered |
| ew-uxr | Custom Words v2: Post-review fixes + FM suggestion debugging | open — fixes compiled but crash discovered during UAT |
| ew-8a4 | Custom Words v2: Redesign around offline-first, engine-aware architecture | open (parent epic) |

## The Crash

### Signature (identical across all 7 reports)
```
EXC_BAD_ACCESS (SIGSEGV)
KERN_INVALID_ADDRESS at 0x0000000000000000 / 0x000000000000001e

Thread 0 (com.apple.main-thread):
  objc_msgSend / objc_opt_class
  swift_getObjectType
  swift_task_isMainExecutorImpl
  swift::SerialExecutorRef::isMainExecutor() const
  swift_task_isCurrentExecutorWithFlagsImpl
  specialized static MainActor.assumeIsolated<A>(_:file:line:)
```

### Crash Sites (all previously stable code)
1. **MenuBarIconAnimator.swift:88** — `Timer.scheduledTimer` callback calling `MainActor.assumeIsolated` (5 of 7 crashes)
2. **HotkeyService.swift:579** — Carbon `EventHandlerCallRef` callback calling `MainActor.assumeIsolated` (1 of 7)
3. **RainbowLipsIcon (SwiftUI Canvas)** — SwiftUI body getter internally checking main actor (1 of 7)

### Key Observation
The crash was NOT in the new code. It corrupted the Swift concurrency runtime's main executor reference, causing `MainActor.assumeIsolated` to dereference a null/garbage pointer (0x0 or 0x1e) when checking the executor type via `objc_msgSend`/`objc_opt_class`. This affected code that had been stable for months.

## What Changed (Unstaged Diff)

### New Files
- `Sources/EnviousWispr/PostProcessing/WordSuggestionService.swift` — 143 lines
  - `@Generable struct WordSuggestionsResult` (macro-expanded at compile time)
  - `Task.detached { await self.suggestWithFoundationModels() }` — hops from detached task to @MainActor
  - `withCheckedContinuation` + dual `Task.detached` for timeout race
  - `SuggestionOnce` (OSAllocatedUnfairLock) for single-delivery guard
- `Sources/EnviousWispr/Models/CustomWord+PromptRendering.swift` — 50 lines
  - `Task { @MainActor in await AppLogger.shared.log() }` fire-and-forget from static method

### Modified Files
- `WordCorrectionStep.swift` — grew from 28 to 217 lines
  - Added `#if canImport(FoundationModels)` + `@Generable struct CorrectedText`
  - `withCheckedContinuation` + `nonisolated(unsafe)` + `ManagedOnce` timeout race
  - `Task { @MainActor in }` for FM correction
  - Dynamic schema fallback for CLT builds without `@Generable`
- `LLMPolishStep.swift` — +15 lines: inject custom words into polish prompt
- `AppState.swift` — +17 lines: wire `fmCorrectionEnabled`, `wordSuggestionService`, sync custom words to LLM polish
- `SettingsManager.swift` — +9 lines: `fmCorrectionEnabled` property + UserDefaults
- `WordFixSettingsView.swift` — +79 lines: auto-open edit sheet, `.onAppear` triggers AI suggestion, loading state, cancel

## Root Cause Analysis

### CORRECTION (2026-03-12, later in same session)

**The original analysis below was WRONG.** After extensive debugging:

1. Reverted ALL Custom Words v2 changes to checkpoint → **still crashed**
2. Replaced all `MainActor.assumeIsolated` with `Task { @MainActor in }` → **still crashed**
3. Nuked `.build/`, `swift package clean`, full clean rebuild → **still crashed**
4. Built minimal reproducers (Timer + assumeIsolated, SwiftUI TimelineView) → **all passed fine**
5. Ran app with `MallocScribble=1` → **survived** (timing-dependent memory corruption)
6. User noticed they were using **Bose Bluetooth headphones for the first time**
7. Disconnected BT headphones → **crash stopped immediately, app fully stable**

**Actual root cause**: Bluetooth audio device routing on macOS 26.4 beta (25E5233c) corrupts memory. The app's smart device selection detects "BT output with active media" and routes to built-in mic. This AVAudioEngine reconfiguration corrupts a pointer that the Swift runtime later dereferences during `MainActor.assumeIsolated` executor checks (`swift_getObjectType` → `objc_msgSend` on garbage isa pointer).

The Custom Words v2 changes, `@Generable` macro, and `Task.detached` patterns were **completely innocent**. The crash timing coincided with the user's first BT headphone session.

### Original analysis (INCORRECT — kept for reference)

#### What we knew at the time
1. `FoundationModels` was already imported by `AppleIntelligenceConnector.swift` and `LLMModelDiscovery.swift` before these changes — framework loading is NOT new
2. `fmCorrectionEnabled` defaults to `false` — the FM correction code path in `WordCorrectionStep` never executes at runtime
3. The crash happens on hotkey press → processing animation, BEFORE any word correction or suggestion code runs
4. Removing FM code from `WordCorrectionStep.swift` (but keeping `WordSuggestionService.swift`) did NOT fix the crash (crash #7 at 00:07:49)

#### Original suspects (all exonerated)
1. ~~**`@Generable` macro metadata**~~ — INNOCENT. Clean build from checkpoint without any @Generable code still crashed.
2. ~~**`Task.detached` + MainActor hop pattern**~~ — INNOCENT. Reverted code had none of these patterns.
3. **macOS 26.4 beta bug** — PARTIALLY CORRECT, but specifically in Bluetooth audio routing, not in the Swift concurrency runtime itself.

## Debug Attempts (Chronological)

| Time | Action | Result |
|------|--------|--------|
| 23:50 | First build with all Custom Words v2 changes | Crash #1 at 23:53 (RainbowLipsIcon SwiftUI Canvas) |
| 23:54 | Relaunch | Crash #2 at 23:54 (MenuBarIconAnimator Timer) |
| 23:54 | Relaunch | Crash #3 at 23:54 (MenuBarIconAnimator Timer) |
| 23:55 | Relaunch | Crash #4 at 23:55 (MenuBarIconAnimator Timer) |
| 23:57 | Relaunch | Crash #5 at 23:57 (Carbon HotkeyService) |
| 00:01 | Claude wrapped Carbon callback in `DispatchQueue.main.async` | Crash #6 at 00:01 (MenuBarIconAnimator Timer — different site, same root cause) |
| 00:07 | Claude removed FM code from WordCorrectionStep, reverted HotkeyService | Crash #7 at 00:07 (MenuBarIconAnimator Timer — WordSuggestionService still compiled) |

## Review Findings (Pre-Crash)

Three parallel code reviews (GPT-5.4, Claude Code reviewer, Claude PR reviewer) found 8 issues before the crash was even discovered:

### Critical
1. **Priority sort inverted** — `renderForPrompt()` sorts by priority ascending, but lower int = higher priority. Truncation keeps wrong items.
2. **FM timeout not enforced** — `fmTask.cancel()` is cooperative only; FM model can ignore cancellation and block past timeout.
3. **Prompt injection** — Custom words interpolated raw into system prompts with no sanitization. Malicious word names could inject instructions.

### High
4. **Dynamic schema fallback broken** — CLT builds without `@Generable` use `DynamicGenerationSchema` which silently returns empty aliases.

### Medium
5. **isAvailable logic gap** — Checks 3 specific unavailable reasons but `suggest()` requires `.available` — edge cases fall through.
6. **Case-sensitive duplicate check** — `addWord()` lookup uses `==` but `CustomWordsManager.add()` uses case-insensitive compare.
7. **Race condition in suggestions** — `.onAppear` async suggestion can overwrite user edits if FM response arrives after user starts typing.

### Low
8. **Missing error feedback** — `newWord` field cleared on silent duplicate rejection with no user-visible error.

## Learnings

### For the developer
1. **Check your hardware/environment before blaming code.** The crash coincided with Custom Words v2 changes AND first-time BT headphone use. Correlation ≠ causation. Hours were wasted reverting innocent code.

2. **Bluetooth audio + macOS beta = volatile.** BT audio device routing on macOS 26.4 beta corrupts memory in ways that manifest far from the actual bug site. The crash appeared in Timer callbacks and SwiftUI views, nowhere near the audio code.

3. **MallocScribble is a powerful diagnostic.** Running with `MallocScribble=1` changed timing enough that the crash didn't reproduce, confirming it was a timing-dependent memory corruption — not a logic bug.

4. **Minimal reproducers eliminate runtime-level hypotheses.** A 10-line Swift script proved `MainActor.assumeIsolated` works fine. The runtime wasn't broken — something in our process was corrupting memory.

### For Claude (the AI assistant)
1. **UAT is not optional.** After every rebuild, MUST verify the app stays alive under real usage (hotkey press → record → process → paste). "Build succeeded + process count > 0" is NOT sufficient.

2. **Don't assume the code change is the cause.** Ask the user about environmental changes: new hardware, OS updates, different usage patterns. The crash report showed audio-related threads, and the app log showed BT device detection — these were clues that were overlooked.

3. **Call council BEFORE making fixes.** The first session burned through context with blind fix attempts. The second session called GPT + Gemini council first, which correctly identified "clean build + verify" as the first step, saving time.

4. **Bisect properly.** Should have immediately asked: "What else changed besides the code?" instead of spending hours reverting code changes.

## Files to Revert

All changes revert to `checkpoint/pre-custom-words-v2-ai` tag (or `git checkout HEAD -- Sources/`):

```
Sources/EnviousWispr/App/AppState.swift
Sources/EnviousWispr/Pipeline/Steps/LLMPolishStep.swift
Sources/EnviousWispr/Pipeline/Steps/WordCorrectionStep.swift
Sources/EnviousWispr/Services/SettingsManager.swift
Sources/EnviousWispr/Views/Settings/WordFixSettingsView.swift
```

Delete (new, untracked):
```
Sources/EnviousWispr/Models/CustomWord+PromptRendering.swift
Sources/EnviousWispr/PostProcessing/WordSuggestionService.swift
```

## Path Forward

### Immediate
1. **Fix BT audio crash** — Investigate audio device selection/routing code for threading issues that cause memory corruption when BT headphones are connected. File Apple Feedback for macOS 26.4 beta.

### Custom Words v2 (can resume)
The Custom Words v2 AI features (ew-ceh, ew-2zt, ew-awj) are **not blocked by this crash** — they were innocent. They can be re-attempted once the BT audio fix is in place. The 8 review findings (see above) should be addressed in the re-implementation.

The non-AI Custom Words improvements (LLM polish prompt injection, auto-open edit sheet) can be re-implemented immediately without `FoundationModels` dependency.
