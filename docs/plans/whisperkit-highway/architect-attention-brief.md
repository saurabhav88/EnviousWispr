# Architect Attention Brief

**From:** ChatterBox
**To:** Architect
**Date:** 2026-03-06

Top items the Architect should pay attention to when designing the phased plan, based on Oracle's historical findings and external LLM consultations.

---

## 1. The "Ready" State Is Critical for UX

GPT-4.1 identified a state missing from most designs: **Ready** (model loaded and warm, pipeline idle). Without it, every PTT press after idle timeout triggers a cold-start model load. Users who dictate multiple times in succession will hit the model load delay every time.

**Action:** Include Ready in the state machine. Idle timeout transitions from Ready to Idle (unloaded), not directly from any active state.

---

## 2. OverlayIntent Must Be the Only Overlay API

Oracle documented 3 of 5 failures as overlay-related. The Architect's plan must enforce that pipelines emit `OverlayIntent` values, and the overlay never reads `PipelineState` directly. This is the single most impactful guardrail.

**Action:** Define `OverlayIntent` enum in Phase 1 before any pipeline code is written. Make it the sole communication channel between pipeline and overlay.

---

## 3. Backend Switching Needs Explicit Drain Protocol

Both GPT-4.1 and Gemini flagged backend switching as a high-risk operation. The Architect should define the exact drain sequence (stop -> finalize -> wait for terminal state -> release resources -> initialize new backend).

**Action:** Include backend switching as a named concern in the plan, not an afterthought. The coordinator must enforce single-active-backend invariant.

---

## 4. Don't Over-Engineer the State Machine

GPT-4.1 proposed 9 states. The Oracle's failures suggest 6-7 are sufficient. Specifically:
- **ModelWarming** can likely be merged with ModelLoading (WhisperKit's `prewarm` flag handles this internally)
- **Delivering** is a clipboard copy that takes <1ms — making it a state adds ceremony without value
- Each state added means another case in every switch statement

**Action:** Start with the minimum viable state set. Add states only when a concrete failure or UX gap demands it.

---

## 5. Parakeet Pipeline Must Be a Zero-Diff Extraction

Oracle's Guardrail G9 states: "The new architecture must not change a single line of Parakeet's behavior." The Architect should plan ParakeetPipeline as a direct extraction from the existing TranscriptionPipeline, not a rewrite.

**Action:** Phase 1 should extract ParakeetPipeline with zero behavioral changes, validate it passes all existing tests, THEN build WhisperKitPipeline separately.

---

## 6. Model Lifecycle Is WhisperKit's Unique Complexity

Parakeet's model is always loaded (bundled, tiny). WhisperKit's model may be: not downloaded, downloaded but not loaded, loaded but not warmed, warm, or unloaded-after-idle. This lifecycle is the primary source of past failures.

**Action:** WhisperKitPipeline should own model lifecycle as a first-class concern. The `ModelUnloadPolicy` timer that already exists in `ASRManager` needs to integrate cleanly with the new pipeline's state machine.

---

## 7. The LLM Polish Merge Point Needs a Language Contract

WhisperKit supports 99 languages; Parakeet is English-only. The LLM polish stage currently assumes English. If a user dictates in Japanese via WhisperKit, the LLM polish prompt must know the language to polish correctly.

**Action:** Add language code to the data flowing into the polish stage. This is a contract change at the merge point, not a pipeline change.

---

## 8. Batch Transcription UX Must Handle "Dead Air"

GPT-4.1's UX consultation emphasized: the moment the user releases PTT with WhisperKit, the overlay must immediately transition to "Transcribing..." with active animation. Any dead/static overlay during the 1-5 second batch phase will feel broken to users accustomed to Parakeet's instant results.

**Action:** WhisperKitPipeline's Recording -> Transcribing transition must trigger an overlay intent change synchronously, not after an async gap.

---

## 9. Thread Safety Audit on Shared Resources

With two pipeline implementations sharing TranscriptStore, ClipboardSnapshot, and PasteService, thread safety becomes a concern even if only one backend is active at a time. Race conditions during backend switching (teardown of old + init of new) could cause concurrent access.

**Action:** Verify all shared services are MainActor-isolated or otherwise thread-safe. The coordinator's drain sequence must guarantee old pipeline has released all shared resources before new pipeline touches them.

---

## 10. Test Each Pipeline in Complete Isolation (G13)

Oracle's Guardrail G13: removing all WhisperKit files must not break ParakeetPipeline compilation, and vice versa. This is a concrete, testable requirement.

**Action:** Include compilation isolation as a gate criterion at the end of Phase 1. If either pipeline has import dependencies on the other's files, the separation has failed.
