# Phase-to-Specialist Mapping

> Author: Talent Team
> Date: 2026-03-06
> Revised: Aligned with Architect's 5-phase plan (0-4) incorporating Oracle guardrails

---

## Parallelism Analysis

```
Phase 0  ──> Phase 1 ──> Phase 2 ──> Phase 3 ──> Phase 4
```

**All phases are strictly serial.** Each phase depends on the previous phase's infrastructure. No parallel execution is possible between phases.

**Within each phase**, some tasks can be parallelized (e.g., builder validates while auditor reviews).

---

## Phase-by-Phase Specialist Mapping

### Phase 0: Foundation Protocol

| Role | Agent | Subagent Type | Justification |
|------|-------|---------------|---------------|
| Primary | feature-scaffolding | `feature-scaffolding` | Protocol + enum creation is scaffolding domain |
| Builder | build-compile | `build-compile` | Compile validation |
| Validator | testing | `testing` | Parakeet regression check (G9) |

**Team:** No formal team needed. Single agent + validation pass.
**Estimated complexity:** LOW — 1 new file, 3 modified files. Protocol conformance is 1-line addition.
**New files:** `Pipeline/DictationPipeline.swift` (PipelineEvent, OverlayIntent, DictationPipeline protocol)
**Gate:** Parakeet VERIFIED with zero regression before proceeding.

---

### Phase 1: WhisperKitPipeline — Independent State Machine (Batch)

| Role | Agent | Subagent Type | Justification |
|------|-------|---------------|---------------|
| Domain lead | audio-pipeline | `audio-pipeline` | Pipeline orchestration is core domain |
| Platform | macos-platform | `macos-platform` | AppState wiring, HotkeyService routing |
| Builder | build-compile | `build-compile` | Largest code volume, highest error risk |
| Auditor | quality-security | `quality-security` | Shared AudioCaptureManager safety (D1) |
| Validator | testing | `testing` | End-to-end flow + dual-pipeline regression |

**Team:** `feature-team` composition (full 5-member).
**Estimated complexity:** HIGH — this is the core architectural change.
- New WhisperKitPipeline class with WhisperKitPipelineState
- Shared AudioCaptureManager wiring (batch mode, no onBufferCaptured)
- AppState dispatch routing via PipelineEvent
- .loadingModel overlay on cold start
- PTT cancel during model load: clean idle (G6)
- .transcribing overlay visible during batch ASR (G10)
**Skills:** `wispr-scaffold-independent-pipeline`, `wispr-scaffold-whisperkit-capture`
**Highest-risk files:** `App/AppState.swift`, `App/AppDelegate.swift`

**Gate checks:**
- Full WhisperKit flow: record -> transcribe -> polish -> clipboard
- `.loadingModel` overlay visible on cold start
- PTT cancel during model load -> clean idle
- `.transcribing` overlay visible 1-5s during batch ASR
- Parakeet zero regression (G9)

---

### Phase 2: WhisperKit-Native VAD + Quality

| Role | Agent | Subagent Type | Justification |
|------|-------|---------------|---------------|
| Domain lead | audio-pipeline | `audio-pipeline` | VAD is audio-pipeline domain |
| Builder | build-compile | `build-compile` | Compile validation |
| Validator | testing | `testing` | Long-recording hallucination tests |

**Team:** `fix-team` composition (lighter than feature-team).
**Estimated complexity:** LOW — EnergyVAD post-processing in stopAndTranscribe(), chunkingStrategy conditional. No new files.
**Skills:** `wispr-configure-whisperkit-vad`

**Gate:** Long recordings (>30s) produce clean output, no hallucinations. MANDATORY before Phase 3 (G12).

---

### Phase 3: Streaming via AudioStreamTranscriber

| Role | Agent | Subagent Type | Justification |
|------|-------|---------------|---------------|
| Domain lead | audio-pipeline | `audio-pipeline` | Streaming ASR is core domain |
| Builder | build-compile | `build-compile` | Actor boundary crossing, nonisolated(unsafe) |
| Auditor | quality-security | `quality-security` | Critical: AudioStreamTranscriber actor isolation |
| Validator | testing | `testing` | Streaming vs batch quality, timeout fallback |

**Team:** `feature-team` composition (full team for high-risk streaming work).
**Estimated complexity:** HIGH — new actor (WhisperKitStreamingCoordinator), buffer feeding across isolation boundaries, timeout/fallback logic, exactly-once finalization guard, partial transcript for overlay.
**Skills:** `wispr-configure-whisperkit-streaming`, `wispr-scaffold-whisperkit-capture` (Phase 3 extension)
**PREREQUISITE:** Read actual AudioStreamTranscriber source in `.build/checkouts/WhisperKit/` first (R5, D10).
**Rollback:** Set supportsStreaming = false; batch path always active.

---

### Phase 4: Polish Convergence Hardening

| Role | Agent | Subagent Type | Justification |
|------|-------|---------------|---------------|
| Auditor lead | quality-security | `quality-security` | Full dual-pipeline audit |
| Pipeline support | audio-pipeline | `audio-pipeline` | Fix any metadata propagation issues |
| Builder | build-compile | `build-compile` | Compile validation for audit fixes |
| Validator | testing | `testing` | All LLM providers, all backends, full matrix |

**Team:** `audit-team` composition + audio-pipeline support.
**Estimated complexity:** LOW — mostly verification and metadata work, not new architecture.
**Skills:** `wispr-test-dual-pipeline`, `wispr-audit-concurrency`, `wispr-validate-api-contracts`

---

## Summary: Resource Requirements per Phase

| Phase | Agents Needed | Team Type | Complexity | Key Skills |
|-------|---------------|-----------|------------|-----------|
| 0 | 3 | None | LOW | wispr-scaffold-independent-pipeline |
| 1 | 5 | feature-team | HIGH | wispr-scaffold-independent-pipeline, wispr-scaffold-whisperkit-capture |
| 2 | 3 | fix-team | LOW | wispr-configure-whisperkit-vad |
| 3 | 4 | feature-team | HIGH | wispr-configure-whisperkit-streaming |
| 4 | 4 | audit-team | LOW | wispr-test-dual-pipeline |

**Total unique agents used:** 5 (audio-pipeline, build-compile, quality-security, testing, feature-scaffolding/macos-platform)
**Total new skills created:** 5 (all created and wired to agents)
**Highest-risk phases:** 1 (state machine + shared ACM) and 3 (streaming)

---

## Implementation Order with Skill Prerequisites

```
All 5 skills already created:
  wispr-scaffold-whisperkit-capture     (wired to audio-pipeline)
  wispr-scaffold-independent-pipeline   (wired to feature-scaffolding)
  wispr-configure-whisperkit-vad        (wired to audio-pipeline)
  wispr-configure-whisperkit-streaming  (wired to audio-pipeline)
  wispr-test-dual-pipeline              (wired to testing)

Execution:
  1. Phase 0 — Foundation Protocol
  2. Phase 1 — WhisperKitPipeline (batch) <-- minimum shippable highway
  3. Phase 2 — VAD + Quality (mandatory gate)
  4. Phase 3 — Streaming
  5. Phase 4 — Polish hardening
```
