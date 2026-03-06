# WhisperKit Highway — Phase Map

> Author: Architect agent
> Date: 2026-03-06
> Revised: incorporates Oracle guardrails G1-G13

---

## Phase Sequence

```
Phase 0: Foundation Protocol
│   Create DictationPipeline protocol + OverlayIntent enum
│   TranscriptionPipeline gains DictationPipeline conformance (1-line)
│   AppState routing via activePipeline: any DictationPipeline
│   RecordingOverlayPanel observes overlayIntent, not PipelineState
│   Zero behavior change for Parakeet (G9)
│
▼
Phase 1: WhisperKitPipeline — Independent State Machine (Batch)
│   Create WhisperKitPipeline conforming to DictationPipeline
│   WhisperKitPipelineState with distinct .loadingModel, .recording,
│     .transcribing, .polishing cases (G1, G2, G6, G10)
│   Full batch flow: record → transcribe → polish → clipboard
│   .loadingModel overlay on cold start
│   .transcribing overlay (visible 1-5s) during batch ASR (G10)
│   PTT cancel during .loadingModel: clean .idle, no race (G6)
│   Parakeet: zero regression (G9)
│
▼
Phase 2: WhisperKit-Native VAD + Quality
│   EnergyVAD post-processing in stopAndTranscribe()
│   chunkingStrategy: .vad for recordings >30s
│   VAD auto-stop: own SilenceDetector instance (G13)
│   Eliminates hallucination on long recordings
│   [GATE: verify batch quality before streaming — G12]
│
▼
Phase 3: Streaming via AudioStreamTranscriber
│   [PREREQUISITE: read actual AudioStreamTranscriber source first]
│   Create WhisperKitStreamingCoordinator actor
│   Wire buffer forwarding in startRecording()
│   finalize() with 10s timeout + batch fallback
│   partialTranscript published for overlay
│   OverlayIntent.recording updated with partialText
│
▼
Phase 4: Polish Convergence Hardening
    All 5 LLM providers verified via WhisperKit highway
    Transcript.backendType = .whisperKit in all paths
    lastPolishError surfaced in UI
    Model unload policy wired correctly
```

---

## Critical Path

Strictly sequential — each phase is a gate for the next:

```
Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4
```

**Phase 1 is the minimum shippable highway.** Full end-to-end recording works. Phases 2-4 improve quality, performance, and UX.

**Phase 2 is the mandatory quality gate before Phase 3.** Never add streaming complexity on top of untuned batch. (G12, Oracle Lesson 10)

---

## Oracle Guardrail Changes vs Original Plan

The Oracle findings caused three significant revisions to the original plan:

| Original | Revised | Reason |
|----------|---------|--------|
| Phase 0: smoke test only | Phase 0: `DictationPipeline` protocol + `OverlayIntent` | G3, G5 require structural groundwork first |
| Phase 1: separate AudioCaptureManager instance | Phase 1: shared AudioCaptureManager | Oracle Lesson 9: both advisors recommended shared |
| Phase 1: basic state machine | Phase 1: with `.loadingModel` + `.transcribing` as distinct cases | G1, G6, G10: these states are not optional |
| Phase 3 streaming before Phase 2 VAD | Phase 2 VAD first, Phase 3 streaming second | G12: tune before stream |
| No mention of OverlayIntent | OverlayIntent introduced in Phase 0 | G5: Failure 4 caused by overlay consuming PipelineState directly |

---

## Gate Points (Do Not Proceed Without)

| Gate | Condition | Guardrail |
|------|-----------|-----------|
| Phase 0 → Phase 1 | `DictationPipeline` protocol exists, Parakeet VERIFIED with zero regression | G3, G9 |
| Phase 1 → Phase 2 | Full WhisperKit flow: record → transcribe → polish → clipboard | G12 |
| Phase 1 → Phase 2 | `.loadingModel` overlay visible on cold start | G6 |
| Phase 1 → Phase 2 | PTT cancel during model load → clean idle | G6, G2 |
| Phase 1 → Phase 2 | `.transcribing` overlay visible 1-5s during batch ASR | G10 |
| Phase 2 → Phase 3 | Long recordings (>30s) produce clean output, no hallucinations | G12 |
| Phase 3 → Phase 4 | Read AudioStreamTranscriber source; streaming matches batch | R5 |

---

## Rollback Map

```
Current: Phase 3 (streaming)
Rollback to Phase 1 (batch):
→ Set supportsStreaming = false
→ WhisperKitStreamingCoordinator never called; batch path always active

Current: Phase 2 (VAD)
Rollback to Phase 1 (raw samples):
→ Remove EnergyVAD call from stopAndTranscribe() (1 line)
→ Revert chunkingStrategy to .none in makeDecodeOptions() (2 lines)

Current: Phase 1 (WhisperKitPipeline)
Rollback to Phase 0:
→ Revert AppState.activePipeline to TranscriptionPipeline for all backends
→ WhisperKitPipeline.swift is additive — delete the file

Current: Phase 0 (protocol)
Rollback to pre-Phase 0:
→ Remove TranscriptionPipeline DictationPipeline conformance (1-line removal)
→ Revert AppState routing (return to TranscriptionPipeline directly)
→ DictationPipeline.swift is additive — delete the file
```

---

## Phase vs Feature Readiness

| Capability | Available From Phase |
|-----------|---------------------|
| `DictationPipeline` protocol + routing | Phase 0 |
| Overlay decoupled from PipelineState | Phase 0 |
| WhisperKit pipeline independently testable | Phase 1 |
| Full end-to-end (record → polish → clipboard) | Phase 1 |
| `.loadingModel` overlay on cold start | Phase 1 |
| Visible "Transcribing..." during batch ASR | Phase 1 |
| PTT cancel during model load: clean | Phase 1 |
| Long recording without hallucination | Phase 2 |
| VAD auto-stop on WhisperKit highway | Phase 2 |
| Real-time streaming transcription | Phase 3 |
| Live partial transcript in overlay | Phase 3 |
| Full telemetry + LLM metadata hardening | Phase 4 |

---

## Estimated Complexity by Phase

| Phase | New Files | Modified Files | Risk Level | Primary Guardrails |
|-------|-----------|---------------|------------|--------------------|
| 0 | 1 (`DictationPipeline.swift`) | 3 (`TranscriptionPipeline`, `AppState`, `RecordingOverlayPanel`) | Low | G3, G5, G9 |
| 1 | 1 (`WhisperKitPipeline.swift`) | 1 (`AppState`) | Medium | G1, G2, G6, G10, G13 |
| 2 | 0 | 2 (`WhisperKitPipeline`, `WhisperKitBackend`) | Low | G12 |
| 3 | 1 (`WhisperKitStreamingCoordinator.swift`) | 2 (`WhisperKitPipeline`, `RecordingOverlayPanel`) | High | G12, R5 |
| 4 | 0 | 1 (`WhisperKitPipeline`) | Low | G11 |

**Total new files across entire highway: 3**
**Total modified files: ~7**
