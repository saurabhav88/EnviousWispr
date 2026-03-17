# Missing Skills and Recommended New Agents

> Author: Talent Team
> Date: 2026-03-06
> Basis: Gap analysis of 40 existing skills against 7 phases of WhisperKit highway plan

---

## Skills That Should Be Created Before Implementation

### 1. `wispr-scaffold-whisperkit-capture` (NEW SKILL)

**Why needed:** Phase 1 requires creating `WhisperKitAudioCapture`, a @MainActor capture coordinator. The existing `wispr-scaffold-asr-backend` skill covers ASRBackend actor conformance but NOT independent capture coordinators. The new skill should provide:
- Template for a @MainActor capture coordinator wrapping AudioCaptureManager
- Batch-only capture pattern (no onBufferCaptured, no streaming callbacks)
- PTT pre-warm integration pattern
- Emergency teardown wiring
- Two-phase start pattern (startEnginePhase + beginCapturePhase)

**Owner agent:** audio-pipeline
**Priority:** HIGH — blocks Phase 1

### 2. `wispr-scaffold-independent-pipeline` (NEW SKILL)

**Why needed:** Phase 2 requires creating `WhisperKitPipeline`, a completely independent pipeline class. No existing skill covers this. The `wispr-scaffold-asr-backend` covers backends, `wispr-trace-audio-pipeline` traces the existing pipeline, but neither scaffolds a new pipeline from scratch. The new skill should provide:
- Template for @MainActor @Observable pipeline class
- State machine enum (idle/recording/transcribing/polishing/complete/error)
- Standard method signatures (startRecording, stopAndTranscribe, cancelRecording, toggleRecording)
- AppState wiring pattern (property + hotkey routing)
- MenuBarIconAnimator callback wiring
- Text processing chain invocation (WordCorrectionStep + FillerRemovalStep + LLMPolishStep)
- PasteService integration
- isStopping reentrancy guard
- Polish LLM convergence contract

**Owner agent:** audio-pipeline (with feature-scaffolding review)
**Priority:** HIGH — blocks Phase 2

### 3. `wispr-configure-whisperkit-vad` (NEW SKILL)

**Why needed:** Phase 3 requires integrating WhisperKit's EnergyVAD. The existing `wispr-apply-vad-manager-patterns` skill is entirely Silero/FluidAudio-specific (VadManager, VadStreamState, VadSegmentationConfig). WhisperKit's EnergyVAD has a different API:
```swift
EnergyVAD(sampleRate: 16000, frameLength: 0.1, energyThreshold: 0.02)
```
The new skill should cover:
- EnergyVAD configuration for dictation
- Post-capture silence filtering (not real-time streaming)
- ChunkingStrategy selection (.none vs .vad) based on recording length
- Integration with WhisperKitAudioCapture.stopCapture()

**Owner agent:** audio-pipeline
**Priority:** MEDIUM — blocks Phase 3

### 4. `wispr-configure-whisperkit-streaming` (NEW SKILL)

**Why needed:** Phase 4 requires wrapping WhisperKit's `AudioStreamTranscriber` actor. This is fundamentally different from Parakeet's `StreamingAsrManager`:
- Parakeet: word-by-word via CTC/Transducer
- WhisperKit: chunked ~1s segments with confirmation
The new skill should cover:
- AudioStreamTranscriber lifecycle (startStreamTranscription, stopStreamTranscription)
- Segment confirmation model (confirmedSegments + unconfirmedSegments)
- Buffer feeding pattern with nonisolated(unsafe) AVAudioPCMBuffer
- Finalize timeout with batch fallback
- isStreaming guard for exactly-once finalization

**Owner agent:** audio-pipeline
**Priority:** MEDIUM — blocks Phase 4

### 5. `wispr-test-dual-pipeline` (NEW SKILL)

**Why needed:** From Phase 2 onward, every test must verify BOTH pipelines independently. No existing testing skill covers dual-pipeline verification patterns. The new skill should provide:
- Test matrix: each action x each pipeline
- Regression verification checklist (switch to Parakeet, verify no change)
- Smoke test extension for dual-pipeline build
- Wispr Eyes verification patterns for pipeline-specific behavior
- UAT scenarios covering backend switching mid-session

**Owner agent:** testing
**Priority:** MEDIUM — valuable from Phase 2 onward

---

## Agent Capabilities That Need Extending

### audio-pipeline agent

**Current gap:** The agent's domain knowledge is heavily Parakeet-centric. Its Actor Map, Error Handling table, and Gotchas all reference FluidAudio/Parakeet patterns. For WhisperKit highway work, the agent definition should be extended with:

1. **WhisperKit Actor Map entry:** `WhisperKitStreamingCoordinator` as `actor`, `WhisperKitAudioCapture` and `WhisperKitPipeline` as `@MainActor @Observable`
2. **Error Handling entries:** WhisperKit model download failure, EnergyVAD threshold too aggressive, AudioStreamTranscriber timeout, chunking artifacts on long recordings
3. **Gotchas entries:** WhisperKit model path (~/Documents/huggingface/), compute options must be explicit (Neural Engine), decode defaults are hardcoded (no user sliders), streaming is chunked not word-by-word

**When to extend:** After Phase 2 is complete and the WhisperKit highway architecture is proven.

### testing agent

**Current gap:** All test patterns assume a single pipeline. The testing agent needs:

1. **Dual-pipeline test matrix** in its Testing Requirements section
2. **WhisperKit-specific test scenarios:** long recording hallucination check, batch vs streaming WER comparison, model download/cache verification
3. **Benchmark extensions:** WhisperKit RTF measurement, streaming latency measurement

**When to extend:** Before Phase 2 begins.

### feature-scaffolding agent

**Current gap:** Scaffold skills assume wiring into existing AppState patterns. WhisperKit highway creates new infrastructure (WhisperKitPipeline, WhisperKitAudioCapture) that doesn't follow the standard "add case to enum, add property to AppState" pattern.

**Recommendation:** No change needed to the agent itself. The new skills (scaffold-whisperkit-capture, scaffold-independent-pipeline) fill this gap without modifying the generic scaffolding agent.

---

## Hooks and Automation That Would Help

### 1. Dual-Pipeline Regression Hook

A post-build hook that automatically verifies both backends still compile and the active pipeline routing is correct. Could be added to the `wispr-rebuild-and-relaunch` skill to check both pipelines exist in the binary.

### 2. WhisperKit Model Cache Validator

A diagnostic skill that verifies the WhisperKit model is cached at the correct path (`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`), reports model variant and size, and warns if the model is missing before tests run.

---

## Research Gaps That Need Filling

### 1. AudioStreamTranscriber API Stability

The `whisperkit-research.md` notes that `distil-large-v3` and `large-v3-turbo` are "unverified in WhisperKit 0.12 ModelVariant." Before Phase 4 begins, the team should verify the exact AudioStreamTranscriber API against the checked-out WhisperKit source at `.build/checkouts/WhisperKit/`.

### 2. Dual AudioCaptureManager Resource Contention

Phase 1 recommends creating a separate AudioCaptureManager instance for WhisperKit. The master plan acknowledges the risk of two AVAudioEngine instances but states "only one can be in isCapturing = true at a time." This assumption needs validation: does macOS allow two AVAudioEngine instances to coexist even when only one has an active tap? Test on real hardware before Phase 1 implementation.

### 3. WhisperKit Streaming vs Batch Quality Delta

Phase 4's exit criteria requires "streaming WER within +/-5% of batch." No baseline WER measurements exist for the current WhisperKit batch path. Run `wispr-run-benchmarks` with WhisperKit batch to establish baselines before Phase 4.
