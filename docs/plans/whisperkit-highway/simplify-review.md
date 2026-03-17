# WhisperKit Highway Planning Package — Simplify Review

> Reviewer: Quality Reviewer (simplifier)
> Date: 2026-03-06
> Scope: All 15 artifacts in docs/plans/whisperkit-highway/

---

## Critical Issues

### C1: Execution Agent Map uses WRONG phase numbering and contradicts Master Plan

**Files:** `execution-agent-map.md` vs `master-phased-implementation-plan.md`, `phase-map.md`

The Master Plan has 5 phases (0-4). The Execution Agent Map has 7 phases (0-6) with completely different phase content:

| Phase | Master Plan | Execution Agent Map |
|-------|-------------|---------------------|
| 0 | DictationPipeline protocol + OverlayIntent | "Foundation and Audit Gate" (read-only audit) |
| 1 | WhisperKitPipeline (full pipeline class) | "WhisperKit-Specific Recording Capture" (WhisperKitAudioCapture) |
| 2 | WhisperKit-Native VAD | "WhisperKitPipeline -- Independent State Machine" |
| 3 | Streaming via AudioStreamTranscriber | "WhisperKit-Native VAD Integration" |
| 4 | Polish Convergence Hardening | "WhisperKit Streaming Transcription" |
| 5 | (does not exist) | "Live Partial Transcript Display" |
| 6 | (does not exist) | "Polish Convergence Hardening" |

The Execution Agent Map also references creating `WhisperKitAudioCapture` as a separate capture coordinator (Phase 1), which directly contradicts the Master Plan's decision D1 (shared AudioCaptureManager, no separate wrapper). The Master Plan was revised to remove this after Oracle Lesson 9 correction, but the Execution Agent Map was not updated.

**Impact:** An implementation team following the Execution Agent Map would build the wrong things in the wrong order, including a component (WhisperKitAudioCapture) that the Master Plan explicitly says should NOT exist.

### C2: Phase-to-Specialist Mapping also uses the WRONG 7-phase numbering

**File:** `phase-to-specialist-mapping.md`

Same problem as C1. Uses Phases 0-6 instead of 0-4. References "Phase 1: WhisperKit-Specific Recording Capture" and "Phase 2: WhisperKitPipeline" which don't match the Master Plan. Also references "Two AudioCaptureManager instances" in Phase 1 auditor justification, contradicting D1.

**Impact:** Same as C1 — wrong execution order, wrong components.

### C3: Missing Skills doc references separate AudioCaptureManager

**File:** `missing-skills-and-recommended-new-agents.md`

- Section "1. wispr-scaffold-whisperkit-capture" describes creating `WhisperKitAudioCapture`, "a @MainActor capture coordinator wrapping AudioCaptureManager." The Master Plan says NO separate capture coordinator.
- Research Gap #2 says "Phase 1 recommends creating a separate AudioCaptureManager instance" and asks about "two AVAudioEngine instances." The Master Plan explicitly rejects this (D1).
- The skills have since been created (wispr-scaffold-whisperkit-capture, wispr-scaffold-independent-pipeline, etc.) with the CORRECT shared-AudioCaptureManager approach, making the doc's descriptions stale.

**Impact:** Misleading if anyone reads the missing-skills doc — it describes architecture that was rejected.

---

## Medium Issues

### M1: Massive content redundancy across documents

The same information is repeated 4-6 times across different files. Examples:

- **Guardrails G1-G13** are listed in full in: `guardrails-from-past-attempts.md`, `master-phased-implementation-plan.md` (compliance matrix), `architect-research-notes.md` (quick reference), and partially in `risks-open-questions-and-decisions.md`, `phase-map.md`, and `known-failures-and-anti-patterns.md`.

- **The 5 known failures** are described in: `known-failures-and-anti-patterns.md` (full), `historical-lessons.md` (as lessons), `master-phased-implementation-plan.md` (current state section), and `architect-research-notes.md`.

- **The "split pipeline" decision** and external advisor quotes are repeated in: `historical-lessons.md`, `external-feedback-digest.md`, `cross-model-critiques.md`, `guardrails-from-past-attempts.md` (decision record), and `risks-open-questions-and-decisions.md`.

- **AudioCaptureManager shared decision** is stated in: `master-phased-implementation-plan.md`, `system-boundaries-and-handoffs.md`, `risks-open-questions-and-decisions.md` (D1), `cross-model-critiques.md`, `external-feedback-digest.md`, `architect-research-notes.md`, `historical-lessons.md` (Lesson 9).

- **OverlayIntent enum definition** appears in: `master-phased-implementation-plan.md`, `system-boundaries-and-handoffs.md`, `parakeet-success-patterns.md`, `external-feedback-digest.md`, `architect-research-notes.md`.

- **Default model variant small.en** is stated in: `master-phased-implementation-plan.md`, `system-boundaries-and-handoffs.md`, `risks-open-questions-and-decisions.md` (D7), `architect-research-notes.md`.

**Suggested fix:** The Master Plan should be the single source of truth for decisions. Other docs should reference it, not repeat it. Cut redundant decision/guardrail listings from research notes, feedback digests, and critiques — those are research artifacts, not decision records.

### M2: LLM provider count inconsistency

**Files:** `master-phased-implementation-plan.md` (line 348 says "5 LLM providers", line 425 says "6 LLM providers"), `phase-map.md` (says "5 LLM providers")

The Master Plan's Phase 4 section says "each of the 5 LLM providers (OpenAI, Gemini, Ollama, Apple Intelligence, none)" but the Definition of Done says "All 6 LLM providers." Which is it — 5 or 6? And does "none" count as a provider?

**Suggested fix:** Enumerate the exact list once, reference it elsewhere. Clarify whether "none" (polish disabled) counts as a provider to test.

### M3: OverlayIntent.recording signature inconsistency

**Files:** `master-phased-implementation-plan.md` vs `parakeet-success-patterns.md`

- Master Plan defines: `case recording(audioLevel: Float)`
- Phase 3 update proposes: `case recording(audioLevel: Float, partialText: String?)`
- Parakeet Success Patterns shows: `case recording(audioLevelProvider: () -> Float)`

The associated value type differs (Float vs closure). The Master Plan's Phase 3 also proposes changing the signature by adding `partialText`, which is a breaking change to all consumers.

**Suggested fix:** Pick one signature and use it consistently. The `Float` version is simpler and matches the `Equatable` conformance on `OverlayIntent`. The closure version cannot conform to `Equatable`.

### M4: "ParakeetPipeline" naming confusion

**Files:** `guardrails-from-past-attempts.md` (G3), `architect-attention-brief.md` (item 5), `cross-model-critiques.md`

Several docs refer to extracting "ParakeetPipeline" as a separate class. The Master Plan says TranscriptionPipeline stays as-is with only a 1-line protocol conformance added (G9). These are contradictory: is it extracted or left in place?

**Suggested fix:** Clarify that `TranscriptionPipeline` IS the Parakeet pipeline and simply gains `DictationPipeline` conformance. No extraction, no rename. Remove references to "ParakeetPipeline" as a new class.

### M5: Architect Attention Brief item 1 ("Ready" state) not adopted

**File:** `architect-attention-brief.md` item 1 recommends adding a "Ready" state for warm-but-idle. The Master Plan's `WhisperKitPipelineState` does not include it. This is fine (the brief is advisory), but the brief should note the resolution.

**Suggested fix:** Add a note to the brief or the cross-model-critiques that the Ready state was intentionally deferred — the ModelUnloadPolicy + pre-warm-on-key-down covers the same UX concern without adding state complexity.

### M6: Event-driven PipelineEvent: Gemini's version vs Master Plan's version

**Files:** `external-feedback-digest.md` (Topic 6) vs `master-phased-implementation-plan.md`

Gemini proposed: `pttDown, pttUp, modelFinishedLoading, asrFinishedTranscription`
Master Plan uses: `preWarm, toggleRecording, requestStop, cancelRecording, reset`

These are fundamentally different designs. Gemini's events include internal events (modelFinishedLoading, asrFinishedTranscription) mixed with external events. The Master Plan's events are all external. The feedback digest doesn't note this distinction or explain which was adopted.

**Suggested fix:** Add a note in the feedback digest that the Master Plan adopted external-only events and that internal state transitions are handled within the pipeline, not via events.

---

## Low Issues

### L1: Stale research gap in missing-skills doc

**File:** `missing-skills-and-recommended-new-agents.md`, "Research Gaps" section

All 5 recommended skills have been created (visible in the skill list). The doc still reads as if they need to be created.

**Suggested fix:** Mark the skills section as resolved or delete it. Keep only genuinely unresolved gaps.

### L2: Cross-model critiques "unanimous rejection" section is confusing

**File:** `cross-model-critiques.md`, "Critique of Architect's State Machine" section

This describes rejecting an early draft of the Architect's state machine (without .loadingModel). The final Master Plan includes .loadingModel. Reading this section without context makes it seem like the current plan was rejected.

**Suggested fix:** Add a note: "This critique was addressed in the final Master Plan, which includes .loadingModel."

### L3: historical-lessons.md and known-failures-and-anti-patterns.md overlap heavily

Both describe the same 5 failures and the same anti-patterns. historical-lessons.md frames them as "lessons learned" with timeline context; known-failures.md frames them as a reference catalog. The content is ~70% identical.

**Suggested fix:** Merge into one doc or make historical-lessons purely chronological (timeline + decisions) and known-failures purely categorical (failure patterns + anti-patterns). Currently both try to do both.

### L4: guardrails-from-past-attempts.md "Assumptions That Turned Out False" table duplicates content from historical-lessons.md

**Suggested fix:** Keep the table in one place only.

### L5: Dead weight sections

- `architect-research-notes.md` "Oracle Guardrails Quick Reference" is a strict subset of `guardrails-from-past-attempts.md`. Delete it.
- `architect-research-notes.md` "Parakeet Patterns to Replicate Exactly" is a strict subset of `master-phased-implementation-plan.md` "Parakeet Patterns Adopted" table. Delete it.

---

## Summary

| Severity | Count | Action Required |
|----------|-------|-----------------|
| Critical | 3 | Must fix before implementation: execution-agent-map.md and phase-to-specialist-mapping.md use wrong phase numbers and reference rejected architecture (separate AudioCaptureManager) |
| Medium | 6 | Should fix: redundancy, naming inconsistencies, unresolved advisory items |
| Low | 5 | Nice to fix: duplicate content between research artifacts |

**The single most important fix:** Align `execution-agent-map.md` and `phase-to-specialist-mapping.md` to the Master Plan's 5-phase (0-4) structure and remove all references to a separate `WhisperKitAudioCapture` class. Without this fix, the Talent Team artifacts will actively mislead implementation agents.
