# Modular Architecture Plan — Heart & Limbs

**Date:** 2026-03-12
**Status:** Approved
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

### Phase 3: Break AppState God Object (Week 5-7)
**Goal:** AppState reduced from 857 lines / 5 responsibilities to thin coordinator.

- Extract view state → ViewState observable
- Extract DI container → ServiceContainer
- Extract callback wiring → separate setup methods
- Target: AppState < 300 lines, < 15 files depend on it

**Risk:** MEDIUM — touching the hub, but module boundaries from Phase 1 contain blast radius
**Win:** Views testable in isolation. Changes to settings don't recompile views.

### Phase 4: XPC Audio Service (Week 7-10)
**Goal:** CoreAudio crashes can't kill the app.

- New SPM executable target: EnviousWisprAudioService
- Move AVAudioEngine, device management, codec switch recovery to XPC service
- AudioCaptureManager becomes thin XPC proxy in main app
- Shared-memory ring buffer for audio samples (speed-critical, ~64KB/sec)
- Crash recovery: invalidationHandler → restart service, notify pipeline

**Risk:** HIGH — process boundary, IPC, microphone permissions
**Win:** BT crashes isolated. Hot-swap crashes survivable. Permanent fix for ew-8y3.

### Phase 5: XPC ASR Service (Week 10-12)
**Goal:** 500MB-2GB ASR models don't bloat main app memory.

- New SPM executable target: EnviousWisprASRService
- Move ParakeetBackend + WhisperKitBackend to XPC service
- ASRManager becomes XPC proxy
- Model load/unload frees memory to OS immediately

**Risk:** HIGH — latency-sensitive, model lifecycle complexity
**Win:** Memory isolation. Model crashes survivable. Foundation for iOS shared code.

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
