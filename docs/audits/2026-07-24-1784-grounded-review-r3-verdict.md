# Verdict: PROCEED-WITH-REVISIONS

The production design is clean. Three plan issues remain:

1. The zero-blast declaration still contradicts its conditional gate.
2. Two sentences still confuse requested policy with actual placement.
3. The validation plan depends on temporary files and a scratch harness that are not available from the repo alone.

## Q1 — Verification of the 17 revisions

The following landed correctly:

- §3b ownership correction: [plan:223-229](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:223)
- Test imports and real-loader assertions: [plan:342-357](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:342)
- Two-assignment mutation receipt: [plan:364-366](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:364)
- Test-file description: [plan:304-307](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:304)
- Temporary test-target harness wording: [plan:309](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:309)
- Two-line production comment: [plan:314-315](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:314)
- `@testable` seam and recording wrapper: [plan:379-382](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:379)
- Decode-once/shared-buffer requirement: [plan:384-389](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:384)
- Production VAD settings and factory method: [plan:391-394](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:391)
- Probability-tolerance clarification: [plan:409-412](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:409)
- Classifier non-goal: [plan:71-82](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:71)
- Classifier open question: [plan:449-451](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:449)
- Goals: [plan:54-61](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:54)
- Corrected FluidAudio premise: [plan:193-201](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:193)
- Contract and lifecycle wording: [plan:243-265](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:243)
- Downstream ownership split: [plan:267-278](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:267)
- Blast-radius wording: [plan:423-428](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:423)

Two were applied correctly in their target sections but remain inconsistent with neighboring text:

- The conditional zero-blast paragraph is correct, but the first bullet and revision note still assert that the exemption already holds.
- The self-contained A/B mechanics are better specified, but their inputs are still external `/private/tmp` files.

## Q2 — Exhaustive four-class sweep

### A. Abandoned factory design

Every remaining factory reference was enumerated:

- [Lines 112-148](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:112): historical explanation of why the factory was rejected. Correct.
- [Line 198](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:198): uses the factory comments only as evidence about disabled optimization hints. Correct.
- [Lines 205-210](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:205): explains why local policy avoids future factory drift. Correct.
- [Lines 235-238](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:235): authority comparison. Correct.
- [Lines 359-363](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:359): rejects a factory-only test oracle. Correct.

The `KernelDictationDriverFactory` reference at line 93 is an unrelated type name.

**Factory-design sweep: clean.**

### B. Live UAT doing §11.3’s job

Every Live UAT reference was enumerated:

- [Lines 3 and 8](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:3): declaration. Correct.
- [Lines 18-20](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:18): tier explanation. Correct.
- [Lines 277-278](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:277): §11.3 owns detector behavior; UAT owns integration. Correct.
- [Lines 327-338](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:327): integration UAT. Correct.
- [Lines 369-372](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:369): explicitly says UAT is insufficient for numerical drift. Correct.
- [Line 437](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:437): ship gate. Correct.
- [Lines 446-448](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:446): points boundary validation to §11.3. Correct.

**Live-UAT ownership sweep: clean.**

### C. “One line” and diff-size claims

Complete list:

- [Line 7](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:7): incorrectly asserts `SKIPPED`, `remains ≤20`, and the PR tag before verification.
- [Lines 12-16](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:12): correctly makes the exemption conditional.
- [Lines 18-21](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:18): incorrectly says the change already meets every condition.
- [Line 34](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:34): “No new import” contradicts the test’s new CoreML import.
- [Lines 223-224](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:223): “one line later” describes current source proximity, not diff size. Correct.
- [Line 306](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:306): production-only `+3 lines` and no production import. Correct.
- [Line 309](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:309): correctly re-evaluates the exemption if the harness ships.

Three stale claims remain: lines 7, 18-21, and 34.

### D. Actual placement versus requested policy

Complete meaningful list:

- [Lines 29-32](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:29): bare configuration takes the requested `.all` default. Correct.
- [Lines 36-37](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:36): explicitly says requested policy. Correct.
- [Line 44](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:44): incorrectly says the model “runs `.all`.”
- [Lines 46-47](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:46): incorrectly describes actual execution in an excluded hardware configuration.
- [Lines 119-136](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:119): code samples showing requested policy. Correct.
- [Line 165](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:165): ASR configuration evidence. Correct.
- [Lines 205-210](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:205): requested load policy. Correct.
- [Lines 245-248](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:245): explicitly refuses to claim resolved placement. Correct.
- [Line 284](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:284): permitted resources and CoreML choice. Correct.
- [Lines 376-377](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:376): A/B requested policies. Correct.
- [Line 419](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:419): “runs once per chunk” means invocation frequency, not placement. Correct.

Two stale placement claims remain: lines 44 and 46-47.

## Q3 — Buildability

The production change and freeze test are buildable without guessing.

The validation plan is not yet self-contained.

### External fixture dependency

Section 11.3 relies on `/private/tmp/ovh-*.mp3`: [plan:396-399](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:396). Those files are not in the repo and can disappear.

The repo already contains five committed 16 kHz mono PCM fixtures:

- `scripts/freeze-suite/clips/normal-speech.wav`
- `scripts/freeze-suite/clips/mumbled-speech.wav`
- `scripts/freeze-suite/clips/silence.wav`
- `scripts/freeze-suite/clips/background-noise.wav`
- `scripts/freeze-suite/clips/sudden-burst.wav`

Those should replace the temporary MP3 corpus.

### Replay lifecycle is not fully defined

The plan does not say:

- How each arm’s `MLModel` and `VadManager` are constructed.
- Whether detector state is reset or reused across the three runs.
- Whether feeding stops at the first auto-stop signal.
- When `finalizeSegments` is called.
- How “quiet onset” is synthesized.

An implementer would have to choose.

### Latency harness is not in the repo

Section 11.4 says “Reuse the #1780 five-scenario harness”: [plan:414-421](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:414). That harness is a session scratch file, not a repository artifact. The number of passes and the meaning of “statistically supported” are also unspecified.

## Q4 — Exact edits

### 1. Replace the coverage bullet and revision note

Replace line 7 with:

> - **Coverage round:** CONDITIONALLY SKIPPED under RULE: council-skip-zero-blast-radius. Apply PR tag `council-skip: zero-blast-radius (single-value config)` only after the four-condition pre-push gate below passes. Otherwise withdraw the exemption and re-evaluate coverage before push.

Replace the revision note at lines 18-21 with:

> **Revision note (grounded review r1/r2).** This preface previously declared MEDIUM. Corrected to SMALL because the shipped change is a configuration tweak; retaining Live UAT does not raise the tier. The zero-blast exemption is expected, not pre-proven: r2 added the four-condition gate after the earlier proposed comment would have exceeded the 20-line limit.

### 2. Replace the TL;DR size sentence

Replace line 34 with:

> Production replaces one bare load with an explicit policy at one site. The test adds `import CoreML` and two real-loader assertions. No new symbols, control flow, fallback, or production import.

### 3. Replace the two actual-placement claims

Replace lines 41-47 with:

> We bundle the VAD model (#1224) and load it ourselves, so we use FluidAudio’s pre-loaded-model initializer. That initializer stores the `VadConfig` we pass but never reads its `computeUnits` field; that field is read only inside the loading path we bypass. The manager therefore reports `.cpuAndNeuralEngine` while the preloaded model was created with CoreML’s requested `.all` default.
>
> We therefore permit GPU execution for this heart-path model even though FluidAudio’s pinned VAD loader requests only CPU and Neural Engine. This describes the requested allowed set, not proof of CoreML’s resolved device placement.

### 4. Make §11.3 repo-contained and executable

Replace the fixture and construction material at lines 374-402 with:

> Use the checked-in VAD model and the five committed fixtures under `scripts/freeze-suite/clips/`: `normal-speech.wav`, `mumbled-speech.wav`, `silence.wav`, `background-noise.wav`, and `sudden-burst.wav`. These files are committed 16 kHz mono Int16 PCM. Verify that format, record each SHA-256, and decode each file exactly once into one in-memory mono Float32 buffer. Feed the same decoded buffer to both arms; do not decode independently per arm.
>
> Create a deterministic quiet-onset fixture from the decoded `normal-speech.wav`: scale complete chunks 0-1 by `0.10`, chunks 2-3 by `0.25`, chunks 4-5 by `0.50`, and all remaining speech chunks by `1.0`. Append twelve zero chunks to `normal-speech`, `mumbled-speech`, and quiet-onset so speech-end and auto-stop behavior receive 3.072 seconds of identical trailing silence. Truncate every fixture to complete 4,096-sample chunks after constructing it.
>
> Implement the harness as a temporary, uncommitted `EnviousWisprTests` source with:
>
> ```swift
> @preconcurrency import AVFoundation
> import CoreML
> @preconcurrency import FluidAudio
> import Testing
>
> @testable import EnviousWisprAudio
> ```
>
> Resolve the checked-in compiled model URL once. Load one model for Arm A using a bare `MLModelConfiguration()` and one model for Arm B using `.cpuAndNeuralEngine` plus `allowLowPrecisionAccumulationOnGPU = true`. For each repetition, construct a fresh `VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)`, a fresh recording `StreamingVad` wrapper, and a fresh `SilenceDetector` through its internal `makeStreamingVad` seam. Build the detector configuration with `SmoothedVADConfig.fromSensitivity(0.5, energyGate: true)` and use `silenceTimeout: 1.5`. Call `prepare()` before feeding audio. Never reuse detector or stream state between repetitions.
>
> Each repetition performs two replays. The full-feed replay records every chunk, ignores `shouldAutoStop` until the buffer ends, then calls `finalizeSegments(totalSampleCount:)`. The auto-stop replay stops at the first `true`, records that chunk index, and calls `finalizeSegments(totalSampleCount:)` with the number of samples actually processed. Capture probabilities, event kinds and indexes, final segments, speech-evidence outcome, and first auto-stop chunk for both replay modes. Run three repetitions per arm.

Keep the existing acceptance text at lines 404-412.

### 5. Replace §11.4 with a repo-contained latency receipt

> ### 11.4 Latency receipt
>
> Use the committed `scripts/freeze-suite/clips/*.wav` fixtures and the repository’s `Tests/RuntimeUAT/wispr_eyes.py::test_recording`; do not depend on the removed #1780 session scratchpad or `/private/tmp/ovh-*`.
>
> Preserve two app artifacts: Arm A built from the pre-change commit and Arm B built from the final change. Use identical dev settings, engine state, fixtures, and expected transcripts. Quit one artifact fully before launching the other.
>
> Pre-warm each arm with one unmeasured pass over all five fixtures. Then run ten measured passes per arm and engine in alternating `A-B-B-A` blocks. For every recording, capture the #1783 first-chunk processing duration and `Pipeline timing TOTAL` from `app.log`, keyed by the recording’s session marker. Report per-fixture and aggregate medians plus paired fixed-minus-baseline deltas.
>
> A statistically supported regression means the fixed arm has a positive paired median delta whose 95% bootstrap confidence interval excludes zero. Any such regression stops for founder review. Otherwise report the observed median and maximum deltas without claiming exact parity.