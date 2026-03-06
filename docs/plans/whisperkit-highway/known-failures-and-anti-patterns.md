# Known Failures and Anti-Patterns

**Compiled by:** Oracle
**Date:** 2026-03-06

---

## Failure 1: `.transcribing` State Overloaded for Model Load AND ASR

**What happened:**
`TranscriptionPipeline.startRecording()` set `state = .transcribing` at line 134 before `await asrManager.loadModel()`. The same `.transcribing` state was set at line 338 during actual batch ASR after recording stopped.

**Why it failed:**
The overlay handler in `AppState` treated both identically — showing a spinner during model load when the user expected to see the recording lips overlay. The user thought the app was processing, not waiting for them to speak.

**Root cause:**
`PipelineState` enum had no `.loadingModel` case. The state machine was designed for Parakeet where model loading never happens during the PTT flow.

**Code location:** `TranscriptionPipeline.swift:134` (model load) and `:338` (actual ASR)

---

## Failure 2: `stopRequested` Race Causing "Recording Too Short 0.00s"

**What happened:**
User presses PTT → model load starts (await suspension) → user releases PTT → `requestStop()` sets `stopRequested = true` → model load completes → `recordingStartTime = Date()` → `stopRequested` check fires → elapsed time is ~0.00s → minimum duration check fails → recording silently discarded.

**Why it failed:**
`stopRequested` was designed to mean "stop recording when it starts," but it fired before any meaningful audio could be captured. The flag was a crude mechanism that didn't account for the model-load suspension window.

**Root cause:**
No distinction between "stop a recording in progress" and "abort a start that hasn't reached recording yet." Both used the same boolean flag.

**Code location:** `TranscriptionPipeline.swift` — `requestStop()` and the `stopRequested` check after line 217

---

## Failure 3: Timer Continuing During Batch ASR (Bad UX)

**What happened:**
After PTT release with WhisperKit, the overlay continued showing the recording timer during the 1-5 second batch transcription phase. The user thought they were still recording.

**Why it failed:**
The overlay state was tied to `PipelineState`, and the transition from `.recording` to `.transcribing` didn't trigger the correct overlay change because the overlay handler didn't distinguish batch ASR processing from streaming ASR (which is invisible).

**Root cause:**
Single overlay mapping for both backends. Parakeet's `.transcribing` phase is milliseconds (streaming finalize), WhisperKit's is seconds (full batch decode).

---

## Failure 4: Overlay Not Transitioning Loading to Recording

**What happened:**
When model load completed and recording should have started, the overlay failed to transition from "Loading model..." spinner to recording lips. Users saw a frozen spinner.

**Why it failed:**
The `transitionToRecording()` method (added as a patch) tried to animate the overlay transition, but the overlay generation counter (`RecordingOverlayPanel`'s integer counter for token-gating async show/hide) discarded the transition as stale.

**Root cause:**
The overlay's async generation gating was designed for rapid idle/recording/idle transitions. A loading-to-recording transition was a new pattern it wasn't built for.

---

## Failure 5: Each Patch Revealed More Edge Cases

**What happened (timeline of patches):**
1. Added `.loadingModel` state → required updating 6+ switch statements across 5 files
2. Added `startRequestCancelled` flag → needed to interact correctly with existing `stopRequested`
3. Added `transitionToRecording()` → fought with overlay generation counter
4. Each fix changed behavior in one path, breaking another path

**Why it failed:**
The monolithic `TranscriptionPipeline` was a 700+ line class with deeply interleaved concerns. Changing model load behavior affected streaming setup, which affected overlay transitions, which affected cancellation paths.

**Root cause:**
Tight coupling. The pipeline class mixed: state management, audio capture control, ASR dispatch, streaming forwarding, VAD monitoring, text processing, clipboard operations, and paste logic.

---

## Anti-Pattern Catalog

### Anti-Pattern 1: Overloaded State Enum Values

**Pattern:** Using the same enum case for semantically different states
**Example:** `.transcribing` for both model loading and ASR processing
**Why it's bad:** Every consumer of the state (overlay, menu bar, status text, toggle logic) gets wrong behavior for one of the two meanings
**Fix:** Separate state for each distinct phase. Compiler-enforced exhaustiveness catches all consumers.

### Anti-Pattern 2: Boolean Flag Gymnastics

**Pattern:** Adding boolean flags to compensate for missing states
**Example:** `stopRequested`, `startRequestCancelled`, `isStopping`, `streamingASRActive`, `isPreWarmed`
**Why it's bad:** Flags create a shadow state machine that runs parallel to the official one. The combinatorial explosion (2^N states) is unmanageable.
**Fix:** Encode all meaningful states in the enum. If you need a flag, you're probably missing a state.

### Anti-Pattern 3: Conditional Branching by Backend Type

**Pattern:** `if backend == .whisperKit { ... } else { ... }` scattered throughout shared code
**Example:** Different overlay behavior, different stop semantics, different model lifecycle
**Why it's bad:** Each backend has fundamentally different flow semantics. Conditionals grow with each backend and each new feature.
**Fix:** Polymorphism. Each backend gets its own pipeline implementation behind a protocol.

### Anti-Pattern 4: Patching a Streaming-Optimized Pipeline for Batch

**Pattern:** Adding hooks and overrides to force batch semantics into a streaming-first pipeline
**Example:** Adding model load phase to a pipeline that assumes models are always loaded
**Why it's bad:** The foundational assumptions are wrong. No amount of patches can make batch feel right in a streaming architecture.
**Fix:** Purpose-built pipeline per paradigm.

### Anti-Pattern 5: Premature User-Facing Configuration

**Pattern:** Exposing internal tuning parameters as settings sliders
**Example:** Temperature, compression ratio threshold, log prob threshold, no-speech threshold
**Why it's bad:** Users don't understand these values. They fiddle, get worse results, and blame the app. The optimal values are well-known for dictation.
**Fix:** Hardcode optimal defaults. Only expose what users can meaningfully control (language, model variant).

### Anti-Pattern 6: Wrong Model Storage Path

**Pattern:** Hardcoding platform-specific paths without verifying the library's actual behavior
**Example:** Assumed `~/Library/Caches/huggingface/` but WhisperKit 0.12+ uses `~/Documents/huggingface/`
**Why it's bad:** Model appears "not downloaded" even when it exists. User re-downloads 1.5GB.
**Fix:** Check the library source code. Don't rely on documentation or assumptions.

### Anti-Pattern 7: "Ship Now, Refactor Later"

**Pattern:** Shipping architectural debt with a plan to fix it "in the next sprint"
**Example:** Option A in the architecture debate — ship patches, plan pipeline split later
**Why it's bad:** The refactor never happens. More features get built on the wrong foundation. The debt compounds. From the buddies session: "The pipeline split is going to be exactly as hard in 2 weeks as it is today, but the patches will have calcified and you'll have more code depending on them."
**Fix:** If the right architecture is clear, implement it now.
