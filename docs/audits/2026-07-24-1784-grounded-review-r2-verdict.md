# Verdict: PROCEED-WITH-REVISIONS

The main design is now right. Four real issues remain:

- The classifier deferral still uses a factory-era dependency argument.
- Several untouched sections still mention the removed factory or give Live UAT the job now assigned to §11.3.
- The A/B input normalization and executable harness route are underspecified.
- The exact proposed diff likely exceeds the zero-blast 20-line limit because of the long production comment.

## Q1 — Six revisions

### 1. Explicit local configuration: correctly landed

Correct in:

- TL;DR: [plan:21](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:21)
- Library comparison and revision note: [plan:98](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:98)
- Design decision: [plan:192](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:192)
- Proposed Swift: [plan:295](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:295)

Two factory-era remnants remain in §2.5 and §5, covered below.

### 2. Single authority: correctly landed

The new answer at [plan:218-228](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:218) is correct.

However, §3b still says “Keeping both inside the loader keeps one place to read” at [plan:212-216](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:212). `VadConfig` remains in `SilenceDetector`, so “both” are not inside the loader.

Replace the final sentence of §3b with:

> Keeping the `MLModel` load policy at the model-construction site prevents callers from trying to control it through the ignored `VadConfig.computeUnits` field. The separate segmentation configuration remains owned by `SilenceDetector`.

### 3. Real-loader test: partially landed

The assertions are correct at [plan:335-349](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:335).

Two corrections remain:

- The drop-in test omitted `import CoreML`.
- The mutation instruction still says “revert the one line” at [plan:350](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:350), but the revised implementation uses two property assignments.

Use:

```swift
import CoreML
import Foundation
import Testing

@testable import EnviousWisprAudio
```

Replace the mutation receipt with:

> **Mutation receipt:** remove both explicit property assignments so the loader passes a fresh bare `MLModelConfiguration()` to `MLModel`. Confirm that the configuration assertions FAIL. A freeze test that passes with the requested policy removed is decoration.

Also change §10’s test-file row to:

> `Tests/EnviousWisprTests/Audio/BundledVADModelLoaderTests.swift` | Add `import CoreML` and freeze the requested configuration through the real loader.

### 4. Offline A/B: direction correctly landed, execution underspecified

The ordering, fixtures, trace outputs, and stop gate landed at [plan:354-378](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:354). Ship criteria also correctly gate on it at [plan:394-403](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:394).

But the named files are 24 kHz MP3s, not frozen 16 kHz Float32 buffers. The plan does not define decoding or resampling. It also calls the harness a scratchpad, but constructing two `SilenceDetector` instances with alternate preloaded models requires the module’s internal test seam at [SilenceDetector.swift:162](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/SilenceDetector.swift:162).

Replace the beginning of §11.3 after the two arm definitions with:

> Implement this as a temporary, uncommitted test-target harness using `@testable import EnviousWisprAudio`, so it can use `SilenceDetector`’s internal `makeStreamingVad` seam. Wrap each arm’s `VadManager` in a recording `StreamingVad` that delegates every call while capturing probability, event kind, and sample index.
>
> The named `ovh-*.mp3` fixtures are 24 kHz mono MP3 files, not detector-ready PCM. Decode and resample each fixture exactly once to one in-memory 16 kHz mono Float32 buffer before constructing either arm. Feed that same buffer object to both arms, in complete 4,096-sample chunks, and discard the same incomplete final remainder. Do not independently decode or resample per arm. Record the source-file SHA-256 values and decoded sample counts in the measurement receipt.
>
> Use `vadSensitivity = 0.5`, `vadEnergyGate = true`, and `vadSilenceTimeout = 1.5`, matching current production defaults. This produces the `SmoothedVADConfig` through `SmoothedVADConfig.fromSensitivity` rather than restating its derived thresholds in the harness.

Replace §10’s scratchpad sentence with:

> The §11.3 A/B runs from a temporary, uncommitted test-target file because it needs `@testable` access to the detector’s existing injection seam. Remove that file after recording the receipt. If the harness must remain in the repository, add it to the file list and re-evaluate the zero-blast exemption before push.

### 5. SMALL retier: correctly landed, line-limit claim needs repair

The classification at [plan:5-13](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:5) is directionally correct.

However, the production comment proposed at [plan:298-308](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:298) is eleven lines. Combined with the configuration, test assertions, test import, and deleted lines, the planned diff is about 23 changed lines. That conflicts with the `≤20` assertion.

Replace that production comment with:

```swift
// Match the pinned FluidAudio VAD loader (`DownloadUtils.swift:301-303`).
// Keep this heart-path policy explicit across dependency updates.
```

The detailed rationale already lives in the plan. With that shortened comment, the shipped diff should fit the exemption. Verify the actual `git diff --stat` and changed-line count before using the PR tag.

### 6. Classifier and failure wording: partially landed

The compute-unit failure wording is correct at [plan:264-270](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:264).

The classifier correction accurately admits the hard-fault risk at [plan:61-71](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:61), but its dependency rationale is now wrong. Explicit local configuration would not require `EnviousWisprLLM` to depend on FluidAudio.

Replace the classifier non-goal with:

> **`CoreMLOutputClassifier.swift:93`**, the second bare-config site. It uses the same constructor pattern for a different model whose correct placement policy has not been established. It is a limb, but its in-process prediction runs during Apple Intelligence polish before paste, so a hard CoreML fault could still terminate that dictation. Copying the VAD policy into this unrelated model would be unsupported scope expansion. Founder-approved as separate work at Gate 1; this VAD-only change does not alter it.

## Q2 — Remaining contradictions and stale sections

### §2.1 does not include the new behavioral gate

The goals at [plan:46-51](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:46) still jump from configuration freeze to latency.

Replace them with:

> 1. The bundled model is constructed with the same requested configuration FluidAudio’s pinned VAD loader would produce.  
> 2. A real-loader test freezes that policy so a future edit cannot silently restore CoreML’s default.  
> 3. A deterministic offline A/B verifies that the policy change does not alter VAD events, segment boundaries, or auto-stop decisions on the frozen corpus.  
> 4. A measured latency receipt on the real app proves no heart-path regression.

### §2.5 still grounds the optimization-hints claim through the wrong implementation

At [plan:187](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:187), “the library default” again points primarily to the factory.

Replace that premise row with:

> The pinned VAD load policy is CHEAP and does not carry the documented RTFx regression | `DownloadUtils.swift:301-303`, the actual VAD path, constructs a bare configuration and sets only `computeUnits` plus `allowLowPrecisionAccumulationOnGPU`. It sets no `MLOptimizationHints`. The separate shared factory’s comments at `MLModelConfigurationUtils.swift:17-29` document the 126.6 → 93.3 regression and leave those hints disabled. The local policy mirrored by this plan therefore does not adopt the regressing hints.

### §4 claims actual hardware placement rather than requested policy

At [plan:230-233](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:230), replace the final sentence with:

> The only direct observable delta is the requested CoreML compute-unit policy. CoreML’s resolved placement is not directly asserted; numerical, boundary, and latency effects are measured in §11.

### §5 still invokes the removed factory

The concurrent row at [plan:244](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:244) is stale.

Replace it with:

> Concurrent | Two processes may each load their own model. Every call constructs a new local `MLModelConfiguration`; no configuration object or model state is shared between processes.

### §6 contradicts the A/B design

At [plan:256](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:256), “Silero is deterministic per chunk” is too broad when the plan explicitly tests compute-policy drift.

Replace that row with:

> `SilenceDetector.processChunk` | Same API. Raw probabilities may differ by compute policy; §11.3 verifies whether any difference reaches VAD events, segment boundaries, or auto-stop decisions.

Replace [plan:262](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:262) with:

> The deterministic offline A/B (§11.3) checks detector behavior. Live UAT (§11.1) then checks capture, ASR, auto-stop, and paste integration.

### §11.3 acceptance is achievable

The current criterion does not require bit-identical probabilities. It requires identical discrete behavior. That is the right bar.

A different segment boundary is not harmless floating-point noise. Those boundaries feed dead-air handling, conditioning, Parakeet tail preservation, WhisperKit clipping, and auto-stop. Founder review is appropriate if one moves.

Add this clarification after [plan:375-378](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:375):

> Probability values are not required to be equal and have no arbitrary epsilon gate. A numerical delta is tolerable when all three runs within each arm are stable and both arms produce identical event kinds and indexes, final segments, speech-evidence outcome, and first auto-stop chunk. A difference in any of those discrete outputs is a real behavioral change, not a numerical false-fail.

### §12 understates the shipped diff

At [plan:389-392](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:389), replace:

> The shipped change touches one production file and one test file. Production replaces the bare model configuration with one explicit requested policy; tests freeze that policy through the real loader. Rollback is a single commit with no downstream cleanup, persisted state, or migration. Blast radius is the requested compute policy for the bundled VAD model.

### §14 contradicts the corrected classifier section

At [plan:413-414](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:413), “same defect, off the heart path” repeats both rejected claims.

Replace it with:

> **`CoreMLOutputClassifier.swift:93`** uses the same constructor pattern for a different model with no established replacement placement policy. Its in-process execution can terminate an active dictation on a hard fault. Founder-approved as separate work; unchanged here.

Sections §8, §9, and §15 remain consistent.

## Q3 — SMALL and coverage skip

**SMALL remains correct.** Validation effort does not raise the implementation tier. The shipped change remains a configuration tweak with no new control flow, API, lifecycle, persistence, or module edge.

The scratch A/B harness also does not count toward shipped blast radius if it is genuinely uncommitted and removed after producing the receipt.

The zero-blast skip is legitimate only after:

1. Shortening the production comment.
2. Adding the missing test import.
3. Counting the actual final diff and confirming it is ≤20 changed lines across two files.
4. Ensuring the A/B harness does not remain in the repository.

If the harness becomes a committed script or the final diff exceeds 20 changed lines, the plan must withdraw the zero-blast tag and re-evaluate coverage before push.