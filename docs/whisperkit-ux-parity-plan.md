# WhisperKit UX Parity Plan

## Problem Statement

WhisperKit has two bugs that Parakeet doesn't, both caused by the `.transcribing` state being overloaded to mean both "loading model" and "running ASR."

### Bug 1: Wrong Overlay During Model Load
- **Expected**: PTT down → lips+timer overlay (same as Parakeet)
- **Actual**: PTT down → spinner overlay ("Polishing...") because `state = .transcribing` triggers during model load
- **Impact**: User thinks app is processing, not recording

### Bug 2: "Recording Too Short" Silent Discard
- **Expected**: PTT held through model load → recording starts → PTT release → transcribe
- **Actual**: If PTT released during model load → `stopRequested=true` → fires immediately after `recordingStartTime` set → elapsed ~0.00s → silently discarded
- **Impact**: User dictates, releases PTT, nothing happens. No error shown.

## Root Cause

`PipelineState.transcribing` is used for two distinct purposes:
1. **Model loading** (line 134 of TranscriptionPipeline.swift): `state = .transcribing` before `await asrManager.loadModel()`
2. **Actual ASR processing** (line 338): `state = .transcribing` after recording stops, during batch transcription

The overlay handler in AppState treats both identically → spinner shown during model load.

The `stopRequested` flag was designed for "stop recording when it starts" but fires before meaningful audio capture → 0.00s elapsed → minimum duration check fails.

## Why Parakeet Doesn't Have This Bug

- Parakeet pre-loads model on app launch via FluidAudio
- `asrManager.isModelLoaded` check at line 133 returns `true` → skips Phase 1 entirely
- `startRecording()` runs to completion without suspension at the model load point
- `recordingStartTime` is set well before PTT release can race it

WhisperKit also pre-loads via WhisperKitSetupService, but the model can get unloaded (idle timer, memory pressure). When user hits PTT with model unloaded → bug triggers.

## Solution: Add `.loadingModel` State + `cancelStartRequest()` Command

### 1. Add `PipelineState.loadingModel`

```swift
enum PipelineState: Equatable, Sendable {
    case idle
    case loadingModel    // NEW: Model is loading/downloading
    case recording
    case transcribing    // NOW: Only actual ASR processing
    case polishing
    case complete
    case error(String)
}
```

### 2. New Pipeline Command: `cancelStartRequest()`

```swift
// TranscriptionPipeline.swift
private var startRequestCancelled = false

func cancelStartRequest() {
    guard state == .loadingModel else { return }
    startRequestCancelled = true
}
```

### 3. Update `startRecording()` Model Load Path

```swift
// Line 133-141, currently:
if !asrManager.isModelLoaded {
    state = .transcribing  // WRONG: overloaded
    try await asrManager.loadModel()
}

// Fixed:
if !asrManager.isModelLoaded {
    startRequestCancelled = false
    state = .loadingModel  // EXPLICIT: model loading
    try await asrManager.loadModel()

    // Check if user released PTT during model load
    if startRequestCancelled {
        startRequestCancelled = false
        state = .idle
        return
    }
}
```

### 4. Update `requestStop()` to Handle `.loadingModel`

```swift
func requestStop() async {
    if state == .recording {
        await stopAndTranscribe()
    } else if state == .loadingModel {
        cancelStartRequest()  // Abort pending start
    } else {
        stopRequested = true
    }
}
```

### 5. Update AppState Overlay Handler

```swift
case .loadingModel:
    self.hotkeyService.unregisterCancelHotkey()
    self.recordingOverlay.showProcessing(label: "Loading model...")
```

### 6. Update All Switch Statements on PipelineState

Files that switch on PipelineState (compiler will enforce exhaustiveness):
- `Sources/EnviousWispr/Models/AppSettings.swift` — `isActive`, `statusText`
- `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` — `toggleRecording()`, `requestStop()`
- `Sources/EnviousWispr/App/AppState.swift` — overlay handler, status text
- `Sources/EnviousWispr/App/AppDelegate.swift` — menu bar icon state
- `Sources/EnviousWispr/Views/Main/MainWindowView.swift` — two switch statements

## Behavioral Changes

| Scenario | Before | After |
|----------|--------|-------|
| PTT down, model loaded | `.recording` → lips+timer | `.recording` → lips+timer (no change) |
| PTT down, model unloaded | `.transcribing` → spinner | `.loadingModel` → "Loading model..." spinner |
| PTT up during model load | `stopRequested=true` → race → "too short" | `cancelStartRequest()` → `.idle` cleanly |
| PTT held through model load | Works (if no race) | Works (guaranteed) |
| Parakeet flow | Unchanged | Unchanged (never hits `.loadingModel`) |

## Flow Diagrams

### Parakeet (unchanged)
```
PTT down → .recording → lips+timer
PTT up   → .transcribing → spinner → .polishing → spinner → .complete → paste
```

### WhisperKit (model loaded — typical)
```
PTT down → .recording → lips+timer
PTT up   → .transcribing → "Transcribing..." → .polishing → "Polishing..." → .complete → paste
```

### WhisperKit (model unloaded — edge case)
```
PTT down → .loadingModel → "Loading model..." spinner
           [model loads]
         → .recording → lips+timer
PTT up   → .transcribing → "Transcribing..." → .polishing → "Polishing..." → .complete → paste
```

### WhisperKit (PTT released during model load — edge case)
```
PTT down → .loadingModel → "Loading model..." spinner
PTT up   → cancelStartRequest() → .idle → overlay hidden
```

## Open Question: Transcribing vs Polishing Overlay Labels

Once `.loadingModel` is separated, we can safely split the `.transcribing` and `.polishing` cases in AppState to show different labels:
- `.transcribing` → "Transcribing..." (during batch ASR)
- `.polishing` → "Polishing..." (during LLM cleanup)

This was the original intent of the overlay fix that broke things — it will work correctly once `.loadingModel` stops contaminating the `.transcribing` state.

## Research Sources
- Codebase deep-dive by Explore agent (TranscriptionPipeline.swift full analysis)
- Buddies session: `whisperkit-ux-parity` (Gemini consultation on state machine design)
- App logs from 2026-03-06 showing both bugs in action
