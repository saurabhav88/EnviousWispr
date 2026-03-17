# Historical Lessons from WhisperKit Integration Attempts

**Compiled by:** Oracle
**Date:** 2026-03-06
**Sources:** Git history, beads memories, buddies sessions (whisperkit-architecture-debate, whisperkit-tuning-research, whisperkit-ux-parity), architecture docs, source code

---

## Timeline of WhisperKit Work

### Milestone 0 (M0) — Initial Scaffold
- **Commit:** `511b175` — "feat: VibeWhisper M0 — repo scaffold and running skeleton"
- WhisperKit was a dependency from day one alongside Parakeet

### Milestone 1 (M1) — MVP
- **Commit:** `4d38473` — "feat: VibeWhisper M1 — MVP dictation with Parakeet v3 + WhisperKit"
- Both backends existed but the entire pipeline, state machine, overlay, and UX were designed around Parakeet's streaming model
- WhisperKit worked for basic batch transcription but was never stress-tested against the pipeline

### Settings UI Enhancement
- **Commit:** `656dfbc` — "feat: 9 settings UI enhancements — AI polish, Ollama, shortcuts, WhisperKit, audio input, noise suppression"
- WhisperKit settings added to SpeechEngineSettingsView
- User-facing sliders for temperature, compression threshold, log prob threshold, no-speech threshold
- These were later removed as unnecessary complexity (commit `7aa2caa`)

### Modularity Refactor (Checkpoint 1 — KEPT)
- **Commit:** `9057484` — "refactor(asr): modular WhisperKit/Parakeet backend separation + fix model cache path"
- Created `WhisperKitDecodingConfig` struct (Sendable, Equatable) for WK-specific params
- Stripped 6 WhisperKit fields from shared `TranscriptionOptions` — now holds only `language` + `enableTimestamps`
- **CRITICAL FIX:** Model cache path was `~/Library/Caches/huggingface/` but WhisperKit 0.12+ stores at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`
- Created `WhisperKitSetupService` with download, progress tracking, and state detection
- **12 files changed, +403 lines, -33 lines**

### Decode Defaults Optimization (Checkpoint 2 — KEPT)
- **Commit:** `7aa2caa` — "feat(asr): hardcode WhisperKit decode defaults + Neural Engine compute"
- Hardcoded dictation-optimized `DecodingOptions`: temperature=0, fallback, skipSpecialTokens, suppressBlank, prefill
- Added `ModelComputeOptions`: encoder/decoder on Neural Engine, mel on GPU, prefill on CPU
- Removed user-facing accuracy/speech filter sliders (unnecessary for dictation use case)
- Removed `syncWhisperKitDecodingConfig` from AppState
- **5 files changed, +33 lines, -111 lines** (net code reduction)

### UX Parity Attempt (Checkpoint 3 — REVERTED)
- **Commit:** `ef1becb` — "docs: WhisperKit UX parity research and pipeline split architecture decision"
- Attempted to fix two bugs in the monolithic pipeline
- Patches included: `.loadingModel` state, `startRequestCancelled` flag, `transitionToRecording()` method
- Each patch revealed another edge case
- After 3+ hours of patching, consulted GPT-4o and Gemini 2.5 Flash
- **Unanimous decision: revert patches, split pipelines**
- Only the research documents were committed; all code patches were reverted

---

## Key Lessons

### Lesson 1: The Pipeline Was Built for Streaming — Batch Is a Different Animal
The entire `TranscriptionPipeline` (758 lines) assumes Parakeet's streaming model:
- ASR happens *during* recording, invisible to the user
- Model is always loaded (FluidAudio pre-loads on launch)
- Only 2 overlay states needed: recording (lips) and processing (polish)
- `recordingStartTime` is set immediately — no suspension between PTT press and recording start

WhisperKit violates every one of these assumptions:
- ASR happens *after* recording — a visible 1-5s batch phase
- Model may need on-demand loading (cold start after idle unload)
- Needs up to 4 overlay states: loading model, recording, transcribing, polishing
- An `await` suspension between PTT press and recording start creates a race window

### Lesson 2: Overloaded State Enums Are a Bug Factory
The `.transcribing` state was used for two completely different purposes:
1. Model loading (line 134 of TranscriptionPipeline.swift): `state = .transcribing` before `await asrManager.loadModel()`
2. Actual ASR processing (line 338): `state = .transcribing` after recording, during batch transcription

This single overload caused two bugs:
- **Bug 1:** Spinner overlay during model load instead of "Loading model..." or recording lips
- **Bug 2:** `stopRequested` race where PTT release during model load causes `recordingStartTime` to fire at ~0.00s elapsed, silently discarding the recording

### Lesson 3: Flag Gymnastics Compound Complexity
Each fix to the shared pipeline required adding a new flag:
- `stopRequested` — set by key-up when `startRecording()` is in-flight
- `startRequestCancelled` — cancel pending start during model load
- `streamingASRActive` — gate buffer forwarding
- `isStopping` — prevent concurrent `stopAndTranscribe()` calls
- `isPreWarmed` — track pre-warm state

Each flag interacts with every other flag. The combinatorial explosion of states (5 flags = 32 combinations) makes reasoning about correctness nearly impossible.

### Lesson 4: Model Path Was Wrong From the Start
WhisperKit 0.12+ stores models at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`, NOT `~/Library/Caches/huggingface/`. This caused the model to appear "not downloaded" even when it was. Fixed in commit `9057484`.

### Lesson 5: User-Facing Tuning Knobs Were Premature
The initial implementation exposed temperature, compression threshold, log prob threshold, and no-speech threshold as settings sliders. These were confusing to users and unnecessary — dictation has well-known optimal defaults. The knobs were removed in commit `7aa2caa` in favor of hardcoded values.

### Lesson 6: Hardcoded Compute Options Are Non-Negotiable
Neural Engine allocation for encoder/decoder is the single biggest performance lever:
```swift
ModelComputeOptions(
    melCompute: .cpuAndGPU,
    audioEncoderCompute: .cpuAndNeuralEngine,
    textDecoderCompute: .cpuAndNeuralEngine,
    prefillCompute: .cpuOnly
)
```
This was discovered in the tuning research session (buddies: whisperkit-tuning-research). Without explicit compute options, WhisperKit defaults to CPU-only, which is 5-10x slower.

### Lesson 7: External Consensus Was Unanimous — Split Pipelines
Both GPT-4o and Gemini 2.5 Flash independently recommended splitting the pipeline when consulted. Key quotes:

- **GPT-4o:** "You've hit that classic point where iteratively adding features to a single pipeline creates more complexity and fragility than it's worth."
- **Gemini 2.5 Flash:** "Each ASR system demands a unique approach. Crafting distinct state machines will minimize the risk of state management bugs."
- **Gemini (ux-parity session):** "Reusing the stopRequested flag is exactly the kind of 'clever' solution that leads to bugs later. Its meaning becomes conditional on the state of the machine when it was set."

### Lesson 8: Revert Decision Was Data-Driven
After 3 hours of patching, the team evaluated three options:
- **Option A:** Ship patches as-is, plan refactor later — rejected because "planned refactors" never happen and the patches were already generating new edge cases
- **Option B:** Revert and start fresh with split architecture — chosen unanimously
- Revert point: Checkpoint 2 (model download + decode defaults), preserving the infrastructure work while discarding the pipeline patches

### Lesson 9: AudioCaptureManager Should Stay Shared
Both external advisors agreed: keep `AudioCaptureManager` shared with configurable capture modes. The mic, engine, format handling, and BT codec switch logic are backend-agnostic. Only the buffer routing differs:
- Streaming mode: `onBufferCaptured` fires per buffer
- Batch mode: buffers accumulated internally, returned on stop

### Lesson 10: The "Tune First, Speed Up Later" Principle
From the whisperkit-tuning-research session, Gemini recommended:
> "Adding the complexity of streaming on top of an untuned, unpredictable transcription engine is a recipe for debugging nightmares."

The team followed this and got the decode defaults right (commit `7aa2caa`) before attempting any pipeline integration. This was correct — the decode defaults commit was one of the keepers.
