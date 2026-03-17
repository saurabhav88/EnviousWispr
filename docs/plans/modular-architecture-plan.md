# Modular Architecture Plan — Heart & Limbs

**Date:** 2026-03-12
**Status:** Phases 1-5 Complete (2026-03-16)
**Motivation:** Build WisprFlow-level feature completeness at better speed. Protect the working core while making it safe to add features without regression — one step forward, zero steps back.

## Principles

1. **Full functionality at maximum speed.** EnviousWispr is a 1-2 minute max dictation tool. The bar is WisprFlow — match or beat their feature set at better speed. Sub-second pipeline latency is the goal. Every architecture decision optimizes for fast start, fast transcribe, fast paste — without sacrificing capability.
2. **Heart never fails.** The critical path (audio → ASR → paste) must always deliver text to the clipboard. Every feature ships and works — but if a limb hiccups, the heart keeps beating.
3. **Limbs fail gracefully.** Each feature (Custom Words, filler removal, LLM polish, future features) runs with a timeout and catch boundary. If it fails, the heart continues.
4. **Pipelines stay separate.** TranscriptionPipeline (Parakeet) and WhisperKitPipeline (WhisperKit) are intentionally independent. We tried unifying them — 4 hours of crashes, reverted. The DictationPipeline protocol is the shared contract. The duplication is the cost of independence, and it's worth it.
5. **One step forward, zero steps back.** Every change must be shippable. No multi-week rewrites. Migrate module by module, test at each step.

## Current State

- ~16K lines, 74 Swift files, 1 SPM target (monolith)
- AppState: 857 lines, 5 responsibilities, 23 files depend on it (31%)
- No module boundaries — any file change recompiles everything
- Features run inline in critical path with no timeouts or graceful fallback
- BT audio crashes mitigated (4774ad1) but not architecturally solved
- Health score: 6.5/10 — bones are good, coupling is the disease

## Target Architecture

```
Main App (Heart — thin shell)
├── EnviousWisprCore        — Models, Utilities, Storage, Constants
├── EnviousWisprAudio       — AudioCaptureManager, SilenceDetector, DeviceEnumerator
├── EnviousWisprASR         — ASRBackend protocol, ParakeetBackend, WhisperKitBackend
├── EnviousWisprLLM         — Connectors (OpenAI/Gemini/Ollama/Apple), Keychain, NetworkSession
├── EnviousWisprFeatures    — TextProcessingStep conformances (each a "limb")
│   ├── CustomWords         — WordCorrector, CustomWordStore
│   ├── FillerRemoval       — FillerRemovalStep
│   └── LLMPolish           — LLMPolishStep (wraps EnviousWisprLLM)
├── EnviousWisprPipeline    — TranscriptionPipeline, WhisperKitPipeline (STAY SEPARATE)
├── XPC: AudioService       — AVAudioEngine, CoreAudio device mgmt (process isolated)
└── XPC: ASRService         — CoreML model inference (process isolated, memory isolated)
```

### Heart (critical path)
```
Hotkey → Audio Capture → ASR → [try each limb with timeout] → Clipboard/Paste
```

If ALL limbs fail, user still gets raw ASR text pasted. Always.

### Limb Contract
```swift
protocol FeatureStep {
    var name: String { get }
    var isEnabled: Bool { get }
    var maxDuration: Duration { get }  // timeout per step
    func process(_ text: String) async throws -> String
}
```

Pipeline calls each enabled limb in sequence:
```swift
for step in enabledSteps {
    do {
        text = try await withTimeout(step.maxDuration) {
            try await step.process(text)
        }
    } catch {
        log("\(step.name) failed/timed out — skipping")
        // text unchanged, continue to next step
    }
}
```

### Timeout Budgets (speed-optimized for 1-2 min dictation)
| Step | Max Duration | Fallback |
|------|-------------|----------|
| Custom Words | 100ms | Skip corrections |
| Filler Removal | 50ms | Skip removal |
| LLM Polish | 1.0s | Paste raw ASR text |
| Future features | 200ms default | Skip |

## Phases

### Phase 1: SPM Multi-Package Skeleton (Week 1-2)
**Goal:** Module boundaries exist. App compiles and ships identically.

- Create Package.swift targets for Core, Audio, ASR, LLM, Features, Pipeline
- Move files into correct targets (no code changes, just file organization)
- Fix import visibility (public/internal boundaries)
- Verify: `swift build` succeeds, app behavior unchanged

**Risk:** LOW — purely structural, no logic changes
**Win:** 50-60% faster incremental builds, clean dependency graph

### Phase 2: Limb Architecture + Custom Words v2 (Week 3-5)
**Goal:** Features degrade gracefully. Custom Words v2 ships as first proper limb.

- Add timeout + catch wrapper to pipeline's step execution
- Build Custom Words v2 (Foundation Models / @Generable auto-categorize) as a FeatureStep
- If Custom Words v2 fails or times out → raw text pastes fine
- Add per-step latency telemetry

**Risk:** LOW-MEDIUM — new feature behind graceful fallback
**Win:** Custom Words v2 ships safely. Pattern established for all future features.

### Phase 3: Break AppState God Object — DONE (2026-03-14)
**Result:** AppState reduced from 870 → 437 lines (50% reduction). 6 extraction steps, 6 commits.

**Actual extractions (differed from original plan — coordinators instead of ViewState/ServiceContainer):**
1. `AudioDeviceList` — device enumeration + hardware monitoring
2. `PermissionsService` extended — accessibility monitoring moved from AppState
3. `LLMModelDiscoveryCoordinator` — model discovery, API key validation, caching
4. `CustomWordsCoordinator` — custom word CRUD, persistence, suggestion service
5. `PipelineSettingsSync` — settings forwarding to pipelines/subsystems (30+ keys)
6. `TranscriptCoordinator` — transcript history state, search, persistence

**What remains in AppState (437 lines, accepted):** pipeline init + wiring, hotkey closures (~100 lines), pipeline state change handlers (~40 lines), `toggleRecording`, `cancelRecording`, computed display properties, WhisperKit preload observation.

**437 > 300 target:** Remaining code is legitimate coordination, not unfinished extraction. Hotkey closures could theoretically move but would add indirection without benefit.

### Phase 4: XPC Audio Service — COMPLETE (2026-03-16)
**Result:** Audio capture runs in XPC service process (default path). BT audio degradation solved via dual-backend architecture.

**Steps completed:** 1 (service skeleton) → 2 (mic permission) → 3 (service-side capture) → 4 (crash recovery) → 5 (service-side VAD) → 6 (BT chaos testing, 3 isolation bugs fixed) → 6b (AVCaptureSession capture backend) → 7 (XPC default ON).

**Architecture shipped:**
- `AudioCaptureProxy` — XPC bridge (default audio path, crash-isolated)
- `CaptureRouteResolver` — picks capture source per recording based on BT state
- `AVCaptureSessionSource` — built-in mic via AVCaptureSession (BT output active, no A2DP→SCO)
- `AVAudioEngineSource` — AVAudioEngine tap + VP + codec switch recovery (non-BT)
- `AudioCaptureManager` — thin coordinator (~300 lines, down from 843)
- Escape hatch: `defaults write ... useXPCAudioService -bool false`

**Key finding:** `setInputDevice(built-in-mic)` while BT output active creates corrupted `CADefaultDeviceAggregate` — permanently abandoned in favor of AVCaptureSession which bypasses CoreAudio device routing entirely.

### Phase 5: XPC ASR Service — COMPLETE (2026-03-16)
**Result:** ASR inference runs in dedicated XPC service process (default path). Both backends validated.

**Architecture shipped:**
- `ASRServiceProtocol` — @objc XPC protocol (load/unload/transcribe/streaming stubs)
- `ASRManagerProxy` — XPC bridge in main app (mirrors AudioCaptureProxy pattern)
- `ASRManagerInterface` — protocol extracted from ASRManager
- `ASRServiceHandler` — service-side handler wrapping ParakeetBackend + WhisperKitBackend
- Crash recovery: interruptionHandler/invalidationHandler, auto-relaunch on next call
- Escape hatch: `defaults write ... useXPCASRService -bool false`

**Validated:** Parakeet batch 83ms, WhisperKit batch 792ms across XPC. Crash recovery proven (kill -9 → app survives, next recording succeeds).
**Known gap:** ew-3wxc (silent failure on mid-recording crash — no user-visible error).
**Deferred:** Incremental worker (Phase 5b), streaming through XPC (batch fallback works).

## What We're NOT Doing

- **NOT unifying pipelines.** TranscriptionPipeline and WhisperKitPipeline stay separate. Tried it, it crashed. DictationPipeline protocol is the right abstraction.
- **NOT rewriting from scratch.** The paste cascade, BT crash recovery, codec switch handling, PTT spam resilience — these are battle-tested. We scavenge, not restart.
- **NOT optimizing for long-form recording.** Max 1-2 minutes. Full functionality at maximum speed — not speed at the cost of features.
- **NOT adding Xcode.** SPM + CLI stays. All automation (agents, skills, hooks) already speaks `swift build`.

## Success Criteria

- [ ] Any single feature failure → user still gets text pasted
- [ ] BT headphone crash → app stays alive, recording restarts
- [ ] New feature addition → new module, no changes to heart
- [ ] Incremental build for view-only change → < 30 seconds
- [ ] Custom Words v2 shipped and working
