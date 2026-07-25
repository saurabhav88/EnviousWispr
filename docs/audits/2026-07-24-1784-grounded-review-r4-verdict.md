# Verdict: PROCEED-WITH-REVISIONS

The production change and freeze test are ready. Two substantive validation ambiguities remain:

1. The two offline replay modes appear to share detector state.
2. The latency receipt does not define the measured value, app artifacts, pairing unit, or bootstrap sample.

Per the round-four rule, these require founder escalation rather than another routine review round.

## Q1 — Round-three edits

Correctly landed:

- Conditional coverage exemption: [plan:7-21](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:7)
- Accurate TL;DR/import statement: [plan:29-38](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:29)
- Requested-policy wording: [plan:42-49](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:42)
- Committed fixture selection and format: [plan:381-391](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:381)
- Quiet-onset and trailing-silence construction: [plan:393-397](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:393)
- Harness imports and model policies: [plan:399-419](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:399)
- Full-feed and auto-stop modes: [plan:421-426](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:421)
- Repository-based latency inputs and defined regression direction: [plan:441-455](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:441)

Two are partial:

### Offline state isolation

The plan constructs one fresh detector “for each repetition” at [plan:410-419](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:410), then performs two replays during that repetition at [plan:421-426](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:421).

If interpreted literally, auto-stop starts with state left by full-feed. `SilenceDetector` retains stream state, EMA, phase, segments, and counters across calls: [SilenceDetector.swift:181-193](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/SilenceDetector.swift:181). Each replay mode needs its own fresh detector.

### Latency measurement

The regression formula landed, but its inputs remain undefined. `test_recording` returns only a Boolean: [wispr_eyes.py:1240](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Tests/RuntimeUAT/wispr_eyes.py:1240), [line 1344](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Tests/RuntimeUAT/wispr_eyes.py:1344).

The plan does not specify:

- Whether the measured value is wall time, `Pipeline timing TOTAL`, or VAD chunk latency.
- How Arm A and Arm B app artifacts are preserved and alternated.
- What one paired observation is.
- Whether the bootstrap operates over three passes, fixtures, engines, or all recording cells.
- What “one discarded pass per block” means.

Those choices materially change the verdict.

## Q2 — Independent sweeps

### A. Abandoned factory design: CLEAN

Remaining references at lines 113-150, 200, 207-212, 237-240, and 361-365 are historical explanation, supporting evidence, or explicit rejection of the factory. None proposes using it.

### B. Live UAT versus §11.3 ownership: CLEAN

The plan consistently assigns:

- Detector numerical/behavioral comparison to §11.3: [plan:273-280](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:273)
- Capture, engine, auto-stop, and paste integration to Live UAT: [plan:329-340](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:329)
- The limitation of Live UAT to §11.3: [plan:371-374](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:371)

### C. One-line and diff-size claims: CLEAN

All operative claims are conditional and internally consistent:

- Conditional exemption: [plan:7-16](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:7)
- Expected, not pre-proven: [plan:18-21](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:18)
- Production-only `+3 lines` claim: [plan:306-309](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:306)

“One line later” at line 225 describes source proximity, not diff size.

### D. Requested policy versus actual placement: CLEAN

The plan now consistently says:

- Bare loading requests `.all`: [plan:42-45](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:42)
- This permits GPU but does not prove resolved placement: [plan:47-49](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:47)
- CoreML chooses within the permitted set: [plan:284-286](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:284)

### Fixture-swap sweep: CLEAN

No operative instruction still assumes MP3, resampling, the old five-scenario labels, or non-repository inputs.

The only matches are:

- Historical revision note: [plan:389-391](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:389)
- Explicit prohibition in latency testing: [plan:443-445](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:443)

The five committed files are confirmed as 16 kHz, mono, Int16 PCM.

## Q3 — Final buildability

- Production change: **buildable without guessing**
- Freeze test: **buildable without guessing**
- Offline A/B: **not buildable unambiguously until state isolation is corrected**
- Latency receipt: **not buildable unambiguously until its measurement contract is specified**

## Q4 — Required edits

### 1. Make every replay independent

Replace [plan:410-426](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/docs/feature-requests/issue-1784-2026-07-24-vad-compute-units.md:410) with:

> Resolve the checked-in compiled model URL once. Load one model for Arm A using a bare `MLModelConfiguration()` and one model for Arm B using `.cpuAndNeuralEngine` plus `allowLowPrecisionAccumulationOnGPU = true`. The loaded model may be reused within its arm.
>
> For every **arm × fixture × repetition × replay mode**, construct a fresh `VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)`, fresh recording `StreamingVad` wrapper, and fresh `SilenceDetector` through its internal `makeStreamingVad` seam (`SilenceDetector.swift:162-168`). Build the detector configuration with `SmoothedVADConfig.fromSensitivity(0.5, energyGate: true)` and use `silenceTimeout: 1.5`, matching `SettingsDefaultValues.swift:38-40` and production construction at `CaptureVADSignalSource.swift:268-271`. Call `prepare()` before feeding audio. Never reuse detector, wrapper, or stream state between full-feed and auto-stop, between fixtures, or between repetitions.
>
> Each repetition performs two independently initialized replays. The **full-feed** replay records every chunk, ignores `shouldAutoStop` until the buffer ends, then calls `finalizeSegments(totalSampleCount:)`. The **auto-stop** replay stops at the first `true`, records that chunk index, and calls `finalizeSegments(totalSampleCount:)` with the number of samples actually processed. Capture probabilities, event kinds and indexes, final segments, speech-evidence outcome, and first auto-stop chunk for both replay modes. Run three repetitions per arm.

Delete the duplicated “Run each arm three times” sentence at lines 428-429.

### 2. Define the latency measurement contract

Replace §11.4 with:

> ### 11.4 Latency receipt
>
> Use the same five committed `scripts/freeze-suite/clips/*.wav` fixtures and `Tests/RuntimeUAT/wispr_eyes.py::test_recording`. Do not depend on the #1780 scratchpad or `/private/tmp/ovh-*`.
>
> Arm A is a dev app built from baseline commit `d2f903c1`. Arm B is a dev app built from the final implementation. Preserve both `.app` artifacts at separate temporary paths. Run only one at a time, fully quitting it before launching the other. Use identical user settings and model-warm state in both arms.
>
> For each engine, run one unmeasured `normal-speech.wav` warm-up on each arm. Then run three measured passes per arm, where one pass processes all five fixtures in the order listed in §11.3. Use measured arm order `A1, B1, B2, A2, A3, B3`. Do not discard any additional measured pass.
>
> Before every `test_recording` call, record the current `app.log` byte offset. After completion, parse the first new `Pipeline timing TOTAL:` record for that recording and extract its leading total-seconds value. A failed or unverifiable recording fails the receipt; do not omit or impute it.
>
> One paired observation is identified by **engine × fixture × measured-pass index**. Compute `Arm B - Arm A` for all 30 pairs: two engines × five fixtures × three passes. Report per-engine, per-fixture, and aggregate medians.
>
> For the aggregate gate, bootstrap the 30 paired deltas with 10,000 resamples using fixed seed `1784`, calculating the median for each resample. A statistically supported regression means the observed aggregate paired median is positive and the percentile 95% bootstrap interval excludes zero. An interval containing zero is not a supported regression. Any supported regression stops for founder review.