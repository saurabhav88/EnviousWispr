# Guardrails from Past Attempts

**Compiled by:** Oracle
**Date:** 2026-03-06
**Authority:** These rules are derived from real failures. Violating any of them risks repeating history.

---

## Hard Rules

### G1: Never Overload PipelineState Cases
Each state case must have exactly one meaning. If WhisperKit needs a "loading model" phase, it gets its own state case (or its own state enum). Never reuse `.transcribing` for model loading.

**Evidence:** Failure 1 and 2 — overloaded `.transcribing` caused both the wrong overlay and the `stopRequested` race condition.

### G2: No Boolean Flags as Shadow State Machines
If you're adding a boolean flag to the pipeline, you're probably missing a state in the enum. Before adding any flag, ask: "Can this be an explicit state instead?"

**Exception:** `isStopping` (reentrancy guard) is acceptable because it guards a single method, not a pipeline phase.

**Evidence:** The proliferation of `stopRequested`, `startRequestCancelled`, `streamingASRActive`, `isPreWarmed` made the pipeline unmanageable.

### G3: Each Backend Gets Its Own Pipeline Class
`ParakeetPipeline` and `WhisperKitPipeline` must be separate implementations of a shared `DictationPipeline` protocol. No shared `TranscriptionPipeline` class with backend-conditional logic.

**Evidence:** 3+ hours of patching proved that conditional branches per backend create exponential complexity.

### G4: Shared Infrastructure Must Be Backend-Agnostic
These stay shared: `AudioCaptureManager`, `HotkeyService`, `RecordingOverlayPanel`, `PasteService`, `TranscriptStore`, LLM polish. If any of these starts growing `if whisperKit` branches, something is wrong.

**Evidence:** Both GPT-4o and Gemini agreed on this boundary. AudioCaptureManager uses configurable capture modes (streaming vs batch) without knowing which backend is driving.

### G5: Overlay Communication Via Intent, Not State
Pipelines emit `OverlayIntent` (a shared enum: `.hidden`, `.recording(audioLevel)`, `.processing(label)`), not `PipelineState`. The overlay never knows which pipeline is running.

**Evidence:** The overlay bugs (wrong state during model load, stuck spinner) were caused by the overlay directly consuming `PipelineState`, which has different meanings per backend.

### G6: Model Load Must Not Block the PTT Flow
If the model isn't loaded when PTT is pressed, the user must see an explicit "Loading model..." indicator. They must be able to cancel (release PTT) cleanly without race conditions.

**Evidence:** Failure 2 — silent discard when PTT released during model load. The `WhisperKitPipeline` state machine must handle `idle -> loadingModel -> recording` as a first-class flow.

### G7: WhisperKit Model Path Is ~/Documents/huggingface/
WhisperKit 0.12+ stores models at:
```
~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
```
Never `~/Library/Caches/huggingface/`. This is already fixed in `WhisperKitSetupService.swift:50`.

**Evidence:** Failure that caused the "model not found" bug in the original integration.

### G8: Hardcode Decode Defaults — No User-Facing Knobs
The optimal dictation defaults are known and hardcoded in `WhisperKitBackend.makeDecodeOptions()`:
- `temperature = 0.0` (deterministic)
- `temperatureFallbackCount = 3`
- `compressionRatioThreshold = 2.4`
- `logProbThreshold = -1.0`
- `noSpeechThreshold = 0.6`
- `skipSpecialTokens = true`
- `suppressBlank = true`
- Neural Engine compute options

User-configurable: language (including auto-detect via empty string) and model variant only.

**Evidence:** User-facing sliders (commit `656dfbc`) were removed in commit `7aa2caa` as premature complexity.

### G9: Preserve Parakeet's Perfect Flow
The Parakeet pipeline works flawlessly. The new architecture must not change a single line of Parakeet's behavior. `ParakeetPipeline` should be a near-direct extraction from the current `TranscriptionPipeline`.

**Evidence:** Every WhisperKit patch risked destabilizing Parakeet. The split architecture isolates them completely.

### G10: WhisperKit Batch ASR Phase Must Be Visibly Distinct
WhisperKit's 1-5 second batch transcription is a visible phase that Parakeet doesn't have. The overlay must show "Transcribing..." during this phase, distinct from "Polishing...".

**Evidence:** Without this distinction, users don't understand why WhisperKit "takes longer" — they think the app is stuck.

### G11: Keep the Two Commits That Worked
Commits `9057484` (modularity refactor + model path fix) and `7aa2caa` (hardcoded decode defaults + Neural Engine) are solid infrastructure. The new implementation builds ON TOP of these, not from scratch.

**Evidence:** Both buddies sessions confirmed these should be kept. They fix real bugs and optimize real performance.

### G12: Tune Before You Stream
If WhisperKit streaming (AudioStreamTranscriber) is ever attempted, ensure batch transcription quality is verified first. Never add streaming complexity on top of untuned decode options.

**Evidence:** Gemini's advice in whisperkit-tuning-research: "Adding streaming on top of an untuned engine is a recipe for debugging nightmares."

### G13: Test Each Pipeline in Complete Isolation
Each pipeline must be testable end-to-end without the other being loaded or configured. If removing all WhisperKit files breaks ParakeetPipeline compilation, the separation has failed.

**Evidence:** The modularity refactor (commit `9057484`) already achieved this at the backend level. The pipeline split must maintain this property at the orchestration level.

---

## Assumptions That Turned Out False

| Assumption | Reality |
|------------|---------|
| "WhisperKit models are at ~/Library/Caches/" | WhisperKit 0.12+ uses ~/Documents/huggingface/ |
| "We can share one state machine for both backends" | Streaming and batch have fundamentally different state flows |
| "Users want to tune decode parameters" | Users don't understand temperature/thresholds; hardcoded defaults are optimal |
| "Adding a state is a small change" | Adding `.loadingModel` required changes to 6+ switch statements across 5 files |
| "Boolean flags can compensate for missing states" | Flags create a shadow state machine with 2^N combinations |
| "We can patch WhisperKit into Parakeet's pipeline quickly" | 3+ hours of patches, each revealing new edge cases |
| "Ship patches now, refactor later" | Both external advisors said no; "the refactor never happens" |
| "`distil-large-v3` exists in WhisperKit" | Unverified in WhisperKit 0.12 `ModelVariant` enum (Gemini claimed it) |
| "`large-v3-turbo` exists in WhisperKit" | Also unverified in WhisperKit 0.12 `ModelVariant` enum |

---

## Decision Record

| Decision | Date | By | Rationale |
|----------|------|----|-----------|
| Keep both backends as independent modules | 2026-03-05 | Team + Gemini | Parakeet = English streaming, WhisperKit = multi-language batch |
| Fix model cache path to ~/Documents/ | 2026-03-05 | Team | WhisperKit 0.12+ actual storage location |
| Hardcode decode defaults, remove user sliders | 2026-03-05 | Team + Gemini | Dictation has known optimal values |
| Neural Engine compute options | 2026-03-05 | Team + Gemini | 5-10x speedup over CPU-only default |
| Revert pipeline patches | 2026-03-06 | Team + GPT + Gemini | Patches created more problems than they solved |
| Split pipeline architecture | 2026-03-06 | Team + GPT + Gemini | Only clean solution for two fundamentally different ASR paradigms |
| Revert to Checkpoint 2 | 2026-03-06 | Team + GPT + Gemini | Preserve infrastructure (download + defaults), discard pipeline patches |
