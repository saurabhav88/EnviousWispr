# Execution Agent Map — WhisperKit Highway

> Author: Talent Team
> Date: 2026-03-06
> Revised: Aligned with Architect's 5-phase plan (Phases 0-4) incorporating Oracle guardrails

---

## Phase 0: Foundation Protocol

**Objective:** Create DictationPipeline protocol + OverlayIntent enum. TranscriptionPipeline gains conformance. AppState routing via activePipeline. Zero behavior change for Parakeet (G9).

**Primary agent:** feature-scaffolding
**Supporting agents:** build-compile, testing
**Skills to invoke:**
- `wispr-scaffold-independent-pipeline` — reference for DictationPipeline protocol definition
- `wispr-run-smoke-test` — compile gate after protocol addition
- `wispr-eyes` — verify Parakeet still works identically (G9)

**Key source files touched:**
- **NEW:** `Pipeline/DictationPipeline.swift` — PipelineEvent enum, OverlayIntent enum, DictationPipeline protocol
- `Pipeline/TranscriptionPipeline.swift` — add DictationPipeline conformance (1-line)
- `App/AppState.swift` — activePipeline: any DictationPipeline routing
- `Views/Overlay/RecordingOverlayPanel.swift` — observe overlayIntent, not PipelineState

**Team composition:** No team needed. Single feature-scaffolding agent. Build validation afterward.

**Gate:** Parakeet VERIFIED with zero regression before proceeding.

---

## Phase 1: WhisperKitPipeline — Independent State Machine (Batch)

**Objective:** Full batch flow: record -> transcribe -> polish -> clipboard. WhisperKitPipelineState with distinct .loadingModel, .recording, .transcribing, .polishing cases. PTT cancel during .loadingModel: clean .idle.

**Primary agent:** audio-pipeline
**Supporting agents:** build-compile, quality-security, testing
**Skills to invoke:**
- `wispr-scaffold-independent-pipeline` — full WhisperKitPipeline template with DictationPipeline conformance
- `wispr-scaffold-whisperkit-capture` — shared AudioCaptureManager wiring for batch mode
- `wispr-manage-model-lifecycle` — model load gate, pre-warm on key-down
- `wispr-auto-fix-compiler-errors` — Swift 6 concurrency issues with new @MainActor class
- `wispr-audit-concurrency` — verify shared AudioCaptureManager safety between pipelines
- `wispr-rebuild-and-relaunch` — full build+bundle+launch for end-to-end testing
- `wispr-eyes` — verify overlay states (loading, recording, transcribing)
- `wispr-test-dual-pipeline` — backend switching regression tests

**Key source files touched:**
- **NEW:** `Pipeline/WhisperKitPipeline.swift` — @MainActor @Observable, DictationPipeline conformance
- `App/AppState.swift` — whisperKitPipeline property, dispatch(_ event:) routing
- `Services/HotkeyService.swift` — route events via AppState.dispatch()

**Team composition:** feature-team (audio-pipeline as domain + builder + auditor + validator)

**Gate checks before Phase 2:**
- Full WhisperKit flow: record -> transcribe -> polish -> clipboard works
- `.loadingModel` overlay visible on cold start
- PTT cancel during model load -> clean idle
- `.transcribing` overlay visible 1-5s during batch ASR
- Parakeet zero regression (G9)

---

## Phase 2: WhisperKit-Native VAD + Quality

**Objective:** EnergyVAD post-processing, chunkingStrategy: .vad for >30s recordings, own SilenceDetector instance. Eliminate hallucination on long recordings.

**Primary agent:** audio-pipeline
**Supporting agents:** build-compile, testing
**Skills to invoke:**
- `wispr-configure-whisperkit-vad` — EnergyVAD integration, chunkingStrategy selection
- `wispr-trace-audio-pipeline` — verify silence filtering in capture path
- `wispr-rebuild-and-relaunch` — test long recordings
- `wispr-eyes` — verify no hallucinations on long recordings
- `wispr-run-benchmarks` — quality comparison: short vs long recordings

**Key source files touched:**
- `Pipeline/WhisperKitPipeline.swift` — add EnergyVAD post-processing in stopAndTranscribe()
- `ASR/WhisperKitBackend.swift` — add chunkingStrategy conditional based on recording length

**Team composition:** fix-team (audio-pipeline as fixer + builder + validator)

**Gate:** Long recordings (>30s) produce clean output, no hallucinations, before proceeding to Phase 3.

---

## Phase 3: Streaming via AudioStreamTranscriber

**Objective:** WhisperKitStreamingCoordinator actor, buffer forwarding, finalize() with timeout + batch fallback, partial transcript for overlay.

**PREREQUISITE:** Read actual AudioStreamTranscriber source in `.build/checkouts/WhisperKit/` first (R5, D10).

**Primary agent:** audio-pipeline
**Supporting agents:** build-compile, quality-security, testing
**Skills to invoke:**
- `wispr-configure-whisperkit-streaming` — streaming coordinator, buffer feeding, finalize guard
- `wispr-scaffold-whisperkit-capture` — Phase 3 extension: wire onBufferCaptured to coordinator
- `wispr-audit-concurrency` — critical: AudioStreamTranscriber is an actor, buffer crossing isolation
- `wispr-auto-fix-compiler-errors` — nonisolated(unsafe) patterns for AVAudioPCMBuffer
- `wispr-manage-model-lifecycle` — streaming lifecycle: start/feed/finalize/cancel
- `wispr-run-benchmarks` — streaming vs batch quality comparison
- `wispr-rebuild-and-relaunch` — full test cycle
- `wispr-eyes` — verify partial transcript appears in overlay

**Key source files touched:**
- **NEW:** `ASR/WhisperKitStreamingCoordinator.swift` — actor wrapping AudioStreamTranscriber
- `Pipeline/WhisperKitPipeline.swift` — add streaming mode, partialTranscript property
- `Views/Overlay/RecordingOverlayPanel.swift` — display partialText from OverlayIntent

**Team composition:** feature-team (audio-pipeline + builder + auditor + validator)

**Rollback:** Set supportsStreaming = false; batch path always active.

---

## Phase 4: Polish Convergence Hardening

**Objective:** All 5 LLM providers verified via WhisperKit highway. Transcript.backendType = .whisperKit in all paths. lastPolishError surfaced. Model unload policy wired.

**Primary agent:** quality-security
**Supporting agents:** audio-pipeline, testing, build-compile
**Skills to invoke:**
- `wispr-audit-concurrency` — full audit of dual-pipeline concurrency
- `wispr-audit-secrets` — verify API keys flow correctly through WhisperKit pipeline
- `wispr-validate-api-contracts` — verify all LLM providers work via WhisperKit highway
- `wispr-test-dual-pipeline` — comprehensive dual-pipeline regression suite
- `wispr-run-benchmarks` — end-to-end performance comparison
- `wispr-rebuild-and-relaunch` — full acceptance test
- `wispr-eyes` — verify history shows correct metadata (backendType, llmProvider)

**Key source files touched:**
- `Pipeline/WhisperKitPipeline.swift` — verify metadata propagation, model unload policy
- `Pipeline/Steps/LLMPolishStep.swift` — verify shared polish path (read-only)
- `Storage/TranscriptStore.swift` — verify transcript persistence with WhisperKit metadata

**Team composition:** audit-team (auditor + builder + validator) + audio-pipeline for pipeline-specific fixes

---

## Resource Summary

| Phase | New Files | Modified Files | Primary Agent | Risk |
|-------|-----------|---------------|---------------|------|
| 0 | 1 | 3 | feature-scaffolding | Low |
| 1 | 1 | 2 | audio-pipeline | Medium |
| 2 | 0 | 2 | audio-pipeline | Low |
| 3 | 1 | 2 | audio-pipeline | High |
| 4 | 0 | 1 | quality-security | Low |

**Total new files: 3** | **Total modified files: ~7**

## Skill Coverage

| Skill | Phases Used |
|-------|-------------|
| wispr-scaffold-independent-pipeline | 0, 1 |
| wispr-scaffold-whisperkit-capture | 1, 3 |
| wispr-configure-whisperkit-vad | 2 |
| wispr-configure-whisperkit-streaming | 3 |
| wispr-test-dual-pipeline | 1, 4 |
| wispr-audit-concurrency | 1, 3, 4 |
| wispr-rebuild-and-relaunch | 1, 2, 3, 4 |
| wispr-eyes | 0, 1, 2, 3, 4 |
| wispr-run-smoke-test | 0 |
| wispr-run-benchmarks | 2, 3, 4 |
