# WhisperKit Highway — Risks, Open Questions, and Decisions

> Author: Architect agent
> Date: 2026-03-06
> Status: FINAL v2 — incorporates Oracle findings (G1-G13, 5 known failures, 7 anti-patterns) + ChatterBox/GPT-4.1 new risks

---

## Critical Risks

### R1: `AudioCaptureManager` Shared Between Two Pipelines
**Risk:** Both highways use the same `AudioCaptureManager` instance. If both try to capture simultaneously (a bug), audio state is corrupted.

**Analysis:** `AudioCaptureManager.isCapturing` is the guard. Only one pipeline can have `isCapturing == true` at a time. Gated by `activePipeline` routing in `AppState` — only the active backend's pipeline receives hotkey events.

**Mitigation:**
- Assert `!audioCapture.isCapturing` at the start of `WhisperKitPipeline.startRecording()`
- `AppState.activePipeline` switch is atomic on `@MainActor`
- `AudioCaptureManager` has no `if whisperKit` branches — it is backend-agnostic (G4)

**Decision:** Keep `AudioCaptureManager` shared. Do NOT create a second instance. Oracle (Lesson 9) confirms: both external advisors recommended shared `AudioCaptureManager` with configurable modes.

**Residual risk:** Backend switch during active recording is a misuse scenario. Gate with `state.isActive` check before allowing `switchBackend()`.

---

### R2: WhisperKit Model Download Gate
**Risk:** `WhisperKitPipeline.startRecording()` must never silently fail if the model is not downloaded. The original integration had no gate — it attempted `prepare()` and produced a cryptic error.

**Analysis:** `WhisperKitSetupService.isModelCached(variant:)` is a synchronous file check. `WhisperKitPipeline` must check this before entering `.loadingModel` state and surface the download prompt if not cached.

**Mitigation:**
- Check `WhisperKitSetupService.isModelCached()` at start of `startRecording()`
- If not cached: `state = .error("Model not downloaded — go to Settings → Speech Engine to download WhisperKit")` with actionable deep link
- On PTT pre-warm (`preWarmAudioInput()`): if model not cached, skip model pre-load gracefully

**Decision:** Block recording start if model not cached. Never auto-trigger download from the hotkey path — the user must explicitly initiate download in Settings.

---

### R3: `.loadingModel` State Race — PTT Release During Model Load (G6, Failure 2)
**Risk:** User presses PTT, model starts loading (1-5s), user releases PTT during load. Without proper handling, this is exactly Failure 2 from Oracle: `stopRequested` race causing "recording too short 0.00s" silent discard.

**Analysis:** Oracle confirmed this is the most disruptive past failure. Root cause: no explicit state for model loading, boolean flag (`stopRequested`) could not represent "abort a start that hasn't reached recording yet."

**Mitigation (how Phase 1 fixes this):**
- `WhisperKitPipelineState.loadingModel` is a first-class state (G1)
- `cancelRecording()` during `.loadingModel` cancels the load task and transitions to `.idle` — clean, explicit, no race
- No `stopRequested` flag needed for this case because state is explicit (G2)
- Implementation pattern:
  ```swift
  func cancelRecording() async {
      if state == .loadingModel {
          modelLoadTask?.cancel()
          state = .idle
          return
      }
      // ... handle .recording cancellation
  }
  ```

---

### R4: Overloaded `.transcribing` State (G1, Failure 1)
**Risk:** Re-introducing the `.transcribing` overload from the past — using one state case for both model loading and ASR processing.

**Analysis:** Oracle confirmed this caused two bugs simultaneously: wrong overlay during model load, and the `stopRequested` race (Failure 1 and 2). The fix is `WhisperKitPipelineState` with distinct cases.

**Mitigation:** `WhisperKitPipelineState` never reuses a case. Compiler-enforced exhaustiveness catches all consumers (switch statements) automatically when adding a new case.

**Enforcement:** Code review gate. Any PR that removes `.loadingModel` or reuses `.transcribing` for model loading is a hard block.

---

### R5: AudioStreamTranscriber API Stability (Phase 3)
**Risk:** `AudioStreamTranscriber` is documented in `whisperkit-research.md` but the actual source in `.build/checkouts/WhisperKit/` may differ.

**Mitigation:** Read `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/AudioStreamTranscriber.swift` as the first action in Phase 3. Do not write any `WhisperKitStreamingCoordinator` code before verifying the API.

**Decision:** Phase 3 implementation starts with API verification, not assumption.

---

### R6: `RecordingOverlayPanel` Generation Counter Fights New Transitions (Failure 4)
**Risk:** The overlay's `generation` counter was designed for simple idle/recording/idle transitions. A new pattern (loading → recording → transcribing) may trigger the "stale generation" discard and produce a frozen spinner.

**Analysis:** Oracle confirmed this as Failure 4 — the `transitionToRecording()` patch fought with the generation counter. The fix is `OverlayIntent` (G5) — the pipeline emits intent changes, the overlay responds to intent values, not pipeline states directly.

**Mitigation:** `OverlayIntent` enum values are the only input to `RecordingOverlayPanel`. The pipeline emits intents synchronously on `@MainActor`. No async gaps between "send intent" and "update overlay" that could trigger stale generation discards.

---

### R7: `large-v3` Unusable for Dictation
**Risk (confirmed by source code):** `WhisperKitBackend` defaults to `large-v3` (RTF 5-10 on M1 Pro). A 30-second recording takes 2.5-5 minutes to transcribe.

**Mitigation:** Default model variant changed to `small.en` in `WhisperKitSetupService.modelVariant`. Expose variant selector in Settings → Speech Engine. `large-v3` remains available.

**Decision (D7):** Default = `small.en`. `large-v3` is for users who prioritize accuracy over speed.

---

### R8: Boolean Flag Proliferation (G2, Lesson 3)
**Risk:** Repeating the flag pattern from `TranscriptionPipeline` — each new edge case spawns a new boolean, creating a shadow state machine with 2^N complexity.

**Oracle data:** Current `TranscriptionPipeline` has 5 boolean flags (`stopRequested`, `startRequestCancelled`, `isStopping`, `streamingASRActive`, `isPreWarmed`). "Nearly unmanageable" per Oracle's Lesson 3.

**Mitigation:**
- `WhisperKitPipeline` starts with zero flags
- `isStopping` (reentrancy guard) is the only acceptable flag (G2 exception)
- Before adding any boolean: ask "Can this be an explicit state case?" If yes, add the state.

**Enforcement:** PR review gate. New boolean flags require explicit justification against G2.

---

### R9: Thread Safety on Shared Resources During Backend Switch (ChatterBox new risk)
**Risk:** Both pipelines share `TranscriptStore`, `PasteService`, and `AudioCaptureManager`. Even if only one is active at a time, the teardown of the old pipeline and initialization of the new pipeline may overlap — creating a window where both touch shared state.

**Analysis:** This is distinct from R1 (concurrent capture). R9 is about shared services during the transition window — the ~100ms between "old pipeline released its state" and "new pipeline has taken ownership."

**Mitigation:**
- All shared services (`TranscriptStore`, `ClipboardSnapshot`, `PasteService`) are `@MainActor`-isolated — no concurrent access is possible from two MainActor contexts
- Backend switching drain protocol enforces old pipeline reaches terminal state BEFORE `activePipeline` reference is changed
- `AudioCaptureManager.isCapturing` assert as final gate before new pipeline can start

**Decision:** The `@MainActor` isolation of all shared services provides structural thread safety. The drain protocol provides behavioral safety. No additional locking required. Document this explicitly so future shared services know they must be `@MainActor`-isolated.

---

### R10: Zombie Backend (ChatterBox new risk)
**Risk:** A backend that fails to reach a terminal state during switching (e.g., stuck awaiting a WhisperKit decode that hangs indefinitely) remains "alive" while the new backend tries to take over shared resources.

**Analysis:** WhisperKit batch decode can theoretically hang if the model has a bug or input is corrupted. A 5-second timeout in the drain sequence handles the expected case, but a truly stuck Task cannot be cancelled (Swift Task cancellation is cooperative).

**Mitigation:**
- Drain sequence enforces 5-second timeout with force-reset after timeout
- WhisperKit batch decode task is wrapped in `withTaskCancellationHandler` — cancellation signals `whisperKit.cancelTranscription()`
- After force-reset: assert `audioCapture.isCapturing == false`; if assertion fails in production, log and proceed (shared resources are `@MainActor`-safe)
- Log zombie events under `"Pipeline"` category for forensic analysis

**Decision (D17):** Drain protocol timeout = 5 seconds. Force-reset after timeout. Log zombie events. The system remains operational even if a zombie backend cannot be cleanly shut down — the `@MainActor` isolation prevents corruption.

---

## Open Questions

### Q1: Should `preWarmAudioInput()` also pre-load the WhisperKit model?

**Context:** On PTT key-down, `preWarmAudioInput()` pre-warms the audio engine. For WhisperKit, model load (1-5s) is the bigger latency contributor.

**Recommendation:** Start model load on key-down as a parallel async task (fire-and-forget). If model ready before key-up, recording starts seamlessly with no visible loading state. If not, `.loadingModel` overlay appears. After first load, model stays loaded per `ModelUnloadPolicy`.

**Decision:** Pre-load model on key-down in parallel with audio pre-warm. `.loadingModel` state is only visible on first-ever cold start.

---

### Q2: Should `WhisperKitPipeline` use its own `SilenceDetector` or share with `TranscriptionPipeline`?

**Context:** `SilenceDetector` is an `actor` with `VadStreamState` that persists across chunks until `reset()` is called.

**Decision:** Each pipeline creates its own `SilenceDetector` instance. Full isolation per G13. Init is cheap.

---

### Q3: How does backend switching interact with an in-progress download?

**Decision:** Download continues in background regardless of active backend. `WhisperKitPipeline` gates recording on `isModelCached()`, not download state.

---

### Q4: What model variants should be offered in Settings?

**From Oracle (Assumptions table):** `distil-large-v3` and `large-v3-turbo` are unverified in WhisperKit 0.12 `ModelVariant` enum. Only offer variants confirmed in source.

**Verified variants:** `tiny`, `tiny.en`, `base`, `base.en`, `small`, `small.en`, `medium`, `medium.en`, `large-v3`.

**Default:** `small.en` (per D7).

---

## Decisions Made (Comprehensive)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Shared `AudioCaptureManager` instance (not separate) | Oracle Lesson 9: both advisors recommended shared + configurable modes |
| D2 | `DictationPipeline` protocol + `OverlayIntent` enum in Phase 0 | Structural prerequisite before any new pipeline code |
| D3 | `WhisperKitPipelineState` separate from `PipelineState` | G1: no overloaded cases; compiler-enforced exhaustiveness |
| D4 | `.loadingModel` as explicit state, no `stopRequested` flag | G1, G2, G6: fixes the exact Failure 2 race condition |
| D5 | `OverlayIntent` enum — pipeline emits intent, not state | G5: fixes Failure 3 (timer during batch ASR) and Failure 4 (frozen spinner) |
| D6 | `TranscriptionPipeline` untouched except protocol conformance | G9: Parakeet must have zero regression risk |
| D7 | Default model variant: `small.en` not `large-v3` | RTF 5-10 on large-v3 is unusable for dictation; small.en RTF 0.5-0.8 |
| D8 | Hardcoded decode defaults, no user sliders | G8, Oracle Lesson 5: optimal dictation values are known |
| D9 | Phase 3 (streaming) blocked on Phase 2 (VAD + quality) | G12: tune before stream |
| D10 | Read `AudioStreamTranscriber` source before Phase 3 | R5: documented API may not match actual source |
| D11 | `isStopping` only acceptable boolean flag | G2: reentrancy guard is the exception; all other conditions → explicit state |
| D12 | `WhisperKitPipeline` creates its own `LLMPolishStep` instance | No shared mutable state between pipelines |
| D13 | `WhisperKitPipeline` creates its own `SilenceDetector` instance | Full isolation per G13; `VadStreamState` persistence is per-pipeline |
| D14 | Block recording if model not cached; show actionable error | G6: model load must not silently fail |
| D15 | Pre-warm model on key-down in parallel with audio pre-warm | Hides cold-start latency; `.loadingModel` only visible on first use |
| D16 | Add `.ready` state to `WhisperKitPipelineState` | ChatterBox Item 1: without it, every PTT after idle timeout cold-loads model. `ModelUnloadPolicy` timer fires from `.ready`, transitions to `.idle` (unloaded) |
| D17 | Drain timeout = 5 seconds, then force-reset | R10: zombie backends must not block switching indefinitely; @MainActor isolation prevents corruption even in timeout case |

---

## Oracle False Assumptions — Do Not Repeat (Source: guardrails-from-past-attempts.md)

| False Assumption | Reality |
|-----------------|---------|
| WhisperKit models at `~/Library/Caches/` | Path is `~/Documents/huggingface/` — already fixed (G7) |
| One state machine can serve both backends | Streaming and batch have fundamentally different state flows (G3) |
| Users want decode tuning sliders | Hardcoded optimal defaults; sliders removed in `7aa2caa` (G8, D8) |
| Adding a state to a shared enum is a small change | Adding `.loadingModel` to shared `PipelineState` required 6+ switch updates across 5 files — this is why WhisperKit gets its own state enum |
| Boolean flags can compensate for missing states | Creates 2^N shadow state machine — "nearly unmanageable" (G2, R8) |
| We can patch WhisperKit into Parakeet's pipeline | 3+ hours of patches, each revealing new edge cases (Failure 5, AP4) |
| Ship patches now, refactor later | "The refactor never happens" — unanimous external advisor opinion (AP7, D6) |
| `distil-large-v3` exists in WhisperKit 0.12 | Unverified in `ModelVariant` enum — Q4 uses only confirmed variants |
| `large-v3-turbo` exists in WhisperKit 0.12 | Also unverified — Q4 uses only confirmed variants |

---

## Anti-Patterns to Avoid (Oracle + Codebase Combined)

From `known-failures-and-anti-patterns.md`, `guardrails-from-past-attempts.md`, and `gotchas.md`:

1. **Do NOT reuse `.transcribing` for model loading** — Oracle Anti-Pattern 1, Failure 1. One case, one meaning.

2. **Do NOT add boolean flags for pipeline phases** — Oracle Anti-Pattern 2. Add an explicit state case instead.

3. **Do NOT add `if backend == .whisperKit` branches in shared code** — Oracle Anti-Pattern 3. Use the `DictationPipeline` protocol.

4. **Do NOT patch `TranscriptionPipeline` for WhisperKit** — Oracle Anti-Pattern 4. `WhisperKitPipeline` is the answer.

5. **Do NOT expose temperature/threshold sliders** — Oracle Anti-Pattern 5. Hardcoded defaults only. (G8)

6. **Do NOT assume WhisperKit model paths** — Oracle Anti-Pattern 6. Path is `~/Documents/huggingface/`. (G7)

7. **Do NOT use `Task { @MainActor }` for overlay show/hide** — Use `DispatchQueue.main.async` (gotchas.md: NSHostingView animation crash).

8. **Do NOT call `finalizeStreaming()` / `cancelStreaming()` more than once** — Use `defer` + `Bool` flag (gotchas.md, Phase 3).

9. **Do NOT install tap before `engine.start()`** — Remove tap in catch block on start failure (gotchas.md).

10. **Do NOT force-index `NSScreen.screens[0]`** — Use `.first` with guard (gotchas.md: NSScreen.screens can be empty).

11. **Do NOT ship patches and plan refactor later** — Oracle Anti-Pattern 7. "The pipeline split is going to be exactly as hard in 2 weeks." (G3)

12. **Do NOT write Phase 3 streaming code before reading `AudioStreamTranscriber` source** — R5. API assumptions from docs are wrong.
