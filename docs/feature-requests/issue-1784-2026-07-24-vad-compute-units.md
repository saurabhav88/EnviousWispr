# #1784 — Pin the bundled VAD model's requested CoreML load policy

## Preface — Lane + Live UAT declaration

- **Lane:** Code
- **Tier:** SMALL (single VAD model-load configuration change; no control flow, lifecycle, public API, module edge, persistence, or migration)
- **Coverage round:** CONDITIONALLY SKIPPED under RULE: council-skip-zero-blast-radius. Apply PR tag `council-skip: zero-blast-radius (single-value config)` only after the four-condition pre-push gate below passes. Otherwise withdraw the exemption and re-evaluate coverage before push.
- **Live UAT:** Y (RULE: runtime-uat-catches-static-misses; SMALL does not waive runtime validation for ML/audio changes)
- **Modules:** EnviousWisprAudio
- **Test:** required (EnviousWisprTests/Audio)

**The zero-blast tag is CONDITIONAL and must be verified before push, not asserted here.** It holds
only after all four: (1) the production comment stays at the two shortened lines in §10;
(2) the test file's `import CoreML` is added; (3) `git diff --stat` confirms ≤20 changed lines across
exactly two files; (4) the §11.3 A/B harness is removed and not committed. If the harness ships or
the diff exceeds 20 changed lines, WITHDRAW the tag and re-evaluate coverage before push.

> **Revision note (grounded review r1/r2/r3).** This preface previously declared MEDIUM. Corrected to
> SMALL because the shipped change is a configuration tweak; retaining Live UAT does not raise the
> tier. The zero-blast exemption is EXPECTED, not pre-proven: r2 added the four-condition gate after
> the earlier proposed comment would have exceeded the 20-line limit.

## Preface — User Rubric

`User Rubric: N/A — not one of epics #314 / #316 / #317 / #320 / #321.`

## 0. TL;DR

`BundledVADModelLoader` builds the Silero VAD model with a bare `MLModelConfiguration()`, taking
CoreML's `.all` default. Set `computeUnits = .cpuAndNeuralEngine` and
`allowLowPrecisionAccumulationOnGPU = true` explicitly, matching what the pinned FluidAudio VAD
loader itself produces at `DownloadUtils.swift:301-303`.

Production replaces one bare load with an explicit policy at one site. The test adds `import CoreML`
and two real-loader assertions. No new symbols, control flow, fallback, or production import.

No public API, control-flow, fallback, or lifecycle change. The observable runtime change is the
requested CoreML hardware policy and any resulting numerical or latency difference.

## 1. Problem

We bundle the VAD model (#1224) and load it ourselves, so we use FluidAudio's pre-loaded-model
initializer. That initializer **stores** the `VadConfig` we pass but never reads its `computeUnits`
field; that field is read only inside the loading path we bypass. The manager therefore reports
`.cpuAndNeuralEngine` while the preloaded model was created with CoreML's requested `.all` default.

We therefore permit GPU execution for this heart-path model even though FluidAudio's pinned VAD
loader requests only CPU and Neural Engine — on every dictation, in every engine, regardless of user
settings. This describes the requested allowed set, not proof of CoreML's resolved device placement.

Crash #1780 occurred inside this model's prediction. **This plan does not claim to fix #1784 → #1780
causation** (see §14).

## 2. Goals & non-goals

### 2.1 Goals

1. The bundled model is constructed with the same requested configuration FluidAudio's pinned VAD
   loader would produce.
2. A real-loader test freezes that policy so a future edit cannot silently restore CoreML's default.
3. A deterministic offline A/B verifies that the policy change does not alter VAD events, segment
   boundaries, or auto-stop decisions on the frozen corpus.
4. A measured latency receipt on the real app proves no heart-path regression.

### 2.2 Non-goals

- **Fixing #1780.** It stays open. Unreproduced across macOS 26 / 14.8.7 / 15.7.7, all four
  `MLComputeUnits`, concurrent, churn, guard-page probe.
- **Any crash safety net** — quarantine, crash counters, one-strike disable, health state, kill
  switch. Founder decision 2026-07-24, on evidence: no competitor ships one (§2.5.3).
- **Any new process boundary.** D-028 collapsed the capture XPC deliberately.
- **Reverting model bundling.** The network fetch stays dead.
- **`CoreMLOutputClassifier.swift:93`**, the second bare-config site. It uses the same constructor
  pattern for a different model whose correct placement policy has not been established. It is a
  limb, but its in-process prediction runs during Apple Intelligence polish before paste
  (`EnviousOutputFilter.swift:78`, `AppleIntelligenceConnector.swift:453`), so a hard CoreML fault
  could still terminate that dictation. Copying the VAD policy into this unrelated model would be
  unsupported scope expansion. Founder-approved as separate work at Gate 1; this VAD-only change does
  not alter it.

  > **Revision note (r1/r2).** This previously read "off the heart path, cannot crash a dictation" —
  > false; a hard fault there can terminate an active dictation. A subsequent draft justified the
  > deferral by a module dependency that explicit local configuration would not actually require.
  > Both reasons were wrong. The deferral stands on scope: this model's correct policy is unestablished.

## 2.5 Grounding brief

### 1. Trace producer → owner → consumer end to end

| Stage | Site | Note |
|---|---|---|
| Model construction | `Sources/EnviousWisprAudio/BundledVADModelLoader.swift:19-38` | **Sole** construction site of the VAD `MLModel`. |
| Consumer | `Sources/EnviousWisprAudio/SilenceDetector.swift:157-158` | Only caller in `Sources/`. Wraps it: `VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)`. |
| Detector construction | `Sources/EnviousWisprPipeline/CaptureVADSignalSource.swift:104` | Sole `SilenceDetector(...)` site. |
| Signal-source construction | `KernelDictationDriverFactory.swift:247-250` | Sole `CaptureVADSignalSource()` site; frozen by `architecture/vadSignalSourceHasSingleConstructionSite`. |
| Both engines | `:257` `makeForParakeet`, `:286` `makeForWhisperKit` | Both receive the SAME instance via `inputs.vadSignalSource`. |
| Execution | `VADMonitorLoop.swift:143` | `await detector.processChunk(chunk)` runs unconditionally; `:149` checks `vadAutoStop` only to decide whether to ACT. |

Capability grep, complete and uncurated:

```
$ grep -rn "BundledVADModelLoader" Sources/ Tests/
Sources/EnviousWisprAudio/SilenceDetector.swift:157
Sources/EnviousWisprAudio/BundledVADModelLoader.swift:13
Tests/EnviousWisprTests/Audio/BundledVADModelLoaderTests.swift:6,9,10,34,43,49,50
```

Closed-world: `BundledVADModelLoader` is a module-internal `enum` with one `static func`. One
production caller, one test suite. Expected 1 production consumer, observed 1.

### 2. Find the existing authority before proposing one

Per RULE: grep-the-dependency-for-lifecycle-before-hand-rolling, the library was grepped BEFORE
designing. **The first search found the wrong authority.** FluidAudio ships a shared factory:

`.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:5-30`

```swift
public enum MLModelConfigurationUtils {
    public static func defaultConfiguration(
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) -> MLModelConfiguration {
        let config = MLModelConfiguration()
        config.allowLowPrecisionAccumulationOnGPU = true
        config.computeUnits = computeUnits
        return config
    }
}
```

**But the VAD loading path does not use that factory.** `loadUnifiedModel` calls
`DownloadUtils.loadModels`, which builds its configuration locally
(`.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/DownloadUtils.swift:301-303`):

```swift
let config = MLModelConfiguration()
config.computeUnits = computeUnits
config.allowLowPrecisionAccumulationOnGPU = true
```

So FluidAudio has two equivalent implementations today, and the one the VAD actually loads through
is the local one. Adopting the factory would NOT be "returning to the VAD paved road" — it would
bind our heart path to a shared factory the VAD loader itself does not use, so a future library
change to that factory could silently alter heart-path CoreML policy on a dependency bump.

**Decision: set the two properties locally, matching `DownloadUtils.swift:301-303` exactly.**

> **Revision note (r1).** This section previously concluded "adopt the factory; do not hand-roll."
> That reversed on evidence: the grounded review found the VAD loader does not call the factory, and
> the citation was verified directly before adopting the correction.

Reachability verified: `Project.swift:232-236` gives `EnviousWisprAudio` a direct
`.package(product: "FluidAudio")` dependency, and `SilenceDetector.swift:2` already does
`@preconcurrency import FluidAudio` in this module.

Our own configuration sites, complete:

```
$ grep -rn "MLModelConfiguration\|computeUnits\|MLComputeUnits" Sources/
Sources/EnviousWisprAudio/BundledVADModelLoader.swift:34   <- this plan
Sources/EnviousWisprASR/WhisperKitBackend.swift:19          (comment)
Sources/EnviousWisprLLM/CoreMLOutputClassifier.swift:93     <- explicit non-goal
```

`ParakeetBackend.swift:115-121` uses `AsrModels.loadFromCache` / `downloadAndLoad` +
`AsrManager(config: .default)` — already the library's own path. `WhisperKitBackend.swift:22-26`
pins `ModelComputeOptions(.cpuAndGPU ×3)` with measured rationale (#879 Phase C). **The ASR paths
are already correct and are not touched.**

### 3. Read prior attempts and live direction

- **#1224** bundled the model to kill a network fetch at record-start that silently broke auto-stop
  for 171 users / 508 occurrences. Bundling stays.
- **#1780 plan §2.5.3** REJECTED gating VAD on `vadAutoStop`: segments feed the dead-air gate,
  `CapturedAudioConditioner.swift:95-159`, Parakeet tail preservation, degraded-lead salvage, and
  `WhisperKitEngineAdapter.swift:687-690` clip ranges. Still rejected; unchanged by this plan.
- **#1783** shipped the record-start funnel (merged). Three markers on Sentry + PostHog.
- **Founder held this pin on 2026-07-24** pending measurement; released it 2026-07-24 after the
  broad-spectrum analysis (issue comments) eliminated the alternatives.
- **Codex council at xhigh** (`docs/audits/2026-07-24-1784-crash-containment-council.txt`) ranked
  "configuration alignment" first-equal and supplied the exact Swift adopted in §10.

### 4. Name the lifecycle, trust, and process boundaries a naive design would miss

- `BundledVADModelLoader` takes the `Bundle` explicitly because `EnviousWisprAudio` is a **static
  framework linked into more than one executable** (`BundledVADModelLoader.swift:8-12`): the app and
  the ASR service each have their own `Bundle.main`. The change is inside the loader, so both
  linkers inherit it identically. Verified today that only the app process constructs a detector —
  `grep -rn "SilenceDetector\|StreamingVad\|VadManager" Sources/EnviousWisprASRService/` returns
  nothing — so there is no second live construction path to keep in sync.
- **No load-order or lifecycle change.** The configuration is constructed and consumed inside one
  synchronous call; nothing is stored, shared, or reused across sessions.
- **Not a settings change.** No `UserDefaults` key, no migration, no persisted state.

### 5. Prove the high-risk premises

| Premise | Proof |
|---|---|
| Only the loading path reads `config.computeUnits`, so changing `VadConfig` alone would be a no-op | `grep -rn "config.computeUnits" .../FluidAudio/Sources/FluidAudio/VAD/VadManager.swift` → exactly one hit, `:135`, inside `loadUnifiedModel`. The pre-loaded init (`:103-107`) assigns `self.config` and `self.vadModel` only. |
| The pinned VAD load policy is CHEAP and does not carry the documented RTFx regression | `DownloadUtils.swift:301-303`, the actual VAD path, constructs a bare configuration and sets only `computeUnits` plus `allowLowPrecisionAccumulationOnGPU`. It sets no `MLOptimizationHints`. The separate shared factory's comments at `MLModelConfigurationUtils.swift:17-29` document the 126.6 → 93.3 regression and leave those hints disabled. The local policy mirrored by this plan therefore does not adopt the regressing hints. **This also corrects an over-stated caution in the #1784 issue body.** |
| Our bundled model is not a different artifact from what the library delivers | `diff -r Sources/EnviousWispr/Resources/VAD/silero-vad-unified-256ms-v6.0.0.mlmodelc "$HOME/Library/Application Support/FluidAudio/Models/silero-vad-coreml/silero-vad-unified-256ms-v6.0.0.mlmodelc"` → **IDENTICAL** (all five files). Model bytes are eliminated as a variable. |
| Chunk feeding is not malformed on the first chunk | `VADMonitorLoop.swift:111-121`: the `while` admits only `processedSampleCount + chunkSize <= currentCount`, so every chunk is exactly `chunkSize`; bounds are re-checked live before slicing. No short or partial first chunk exists. |
| No competitor ships a crash safety net around VAD | Binary sweep of Spokenly / Vox / superwhisper / FluidVoice / TypeWhisper. All four apparent hits were false positives: superwhisper's = Firebase Crashlytics field names (`launchesSinceLastCrash`); TypeWhisper's matched inside `dictationRecoveryModel`; Vox's = `com.apple.quarantine`; FluidVoice's `DirectAudioCaptureConsecutiveFailures` is a capture-path counter beside `ExperimentalDirectAudioCaptureEnabled`, not a VAD guard. Open-source peer `moona3k/macparakeet` returns `nil` on load failure and runs without VAD — load-time fail-open, not crash quarantine. **Open-world claim: no implementation found in these five binaries or the open-source peers read.** |

## 3. Design

`BundledVADModelLoader.loadModel(in:)` remains the sole EnviousWispr authority for the bundled VAD
model's requested CoreML load policy. Construct an `MLModelConfiguration` locally and explicitly set
`computeUnits = .cpuAndNeuralEngine` and `allowLowPrecisionAccumulationOnGPU = true`. These values
match the pinned FluidAudio VAD loader at `DownloadUtils.swift:301-303`. Keeping them explicit
prevents a future dependency update from silently adding or changing heart-path CoreML policy
through a shared factory.

Extract nothing, add no type, add no parameter, add no import.

The loader keeps its existing contract exactly: `resourceNotFound` when the asset is absent,
`loadFailed(Error)` when CoreML rejects it.

### 3b. Ownership justification

**No ownership change.** `BundledVADModelLoader` is already the sole owner of VAD model
construction; this changes what it constructs the model *with*. No coordinator, manager, or
App-owned home gains responsibility.

Alternative owner considered: `SilenceDetector`, which builds the `VadConfig` one line later at
`:158`. Cost of choosing it: the configuration would then be split across two files — the CoreML
configuration in one, the FluidAudio configuration in another — and the caller would have to know
that the pre-loaded initializer ignores half of what it is handed. That is the exact confusion that
produced this defect. Keeping the `MLModel` load policy at the model-construction site prevents
callers from trying to control it through the ignored `VadConfig.computeUnits` field. The separate
segmentation configuration remains owned by `SilenceDetector`.

### 3c. Single-authority check

Concern: "which CoreML load policy is REQUESTED for the bundled VAD model."

- Handled in 2+ places? **No.** One site, `BundledVADModelLoader.swift:34`.
- Existing owner? **In our code, yes — that same site.** In the library there are two equivalent
  implementations (`MLModelConfigurationUtils.swift:11` and `DownloadUtils.swift:301`); the VAD path
  uses the latter, so we mirror it rather than binding to the former.
- Duplicates deleted? Nothing to delete; the bare `MLModelConfiguration()` is replaced in place.

§3c-answer: one EnviousWispr authority — BundledVADModelLoader.loadModel(in:) owns the requested CoreML configuration at the sole VAD MLModel construction site. It explicitly pins the two values matching the current pinned FluidAudio VAD loader (DownloadUtils.swift:301-303). VadConfig.computeUnits remains library-owned metadata consumed only by FluidAudio's bypassed loading path; EnviousWispr creates no second runtime configuration site.

## 4. Contract deltas

**None.** `loadModel(in:)` keeps its signature, return type, and both error cases. No public or
package surface changes. The only direct observable delta is the requested CoreML compute-unit
policy. CoreML's resolved placement is not directly asserted; numerical, boundary, and latency
effects are measured in §11.

## 5. E2E state & lifecycle audit

Six async classes against the change:

| Class | Answer |
|---|---|
| Interrupted | `loadModel` is synchronous and non-suspending. No cancellation point inside it. |
| Deleted | Asset deletion already yields `resourceNotFound`; unchanged. |
| Mutated | No setting feeds this configuration. Nothing to change in flight. |
| Concurrent | Two processes may each load their own model. Every call constructs a new local `MLModelConfiguration`; no configuration object or model state is shared between processes. |
| Nil | No optional dependency. |
| Stale | Nothing cached or snapshotted. |

**Closed-set trigger: NOT met.** No lifecycle/outcome/durability contract changes; no terminal
transition, cancellation, session identity, or durable save/cleanup ordering is touched. Full
`state × event` matrix not required.

## 6. Downstream consumer matrix

| Consumer | Effect |
|---|---|
| `SilenceDetector.processChunk` | Same API. Raw probabilities may differ by compute policy; §11.3 verifies whether any difference reaches VAD events, segment boundaries, or auto-stop decisions. |
| Dead-air gate / `speechEvidenceAtStop` | Unchanged unless segment boundaries shift. |
| `CapturedAudioConditioner` | Unchanged unless segments shift. |
| Parakeet tail preservation, WhisperKit clip ranges | Unchanged unless segments shift. |
| Auto-stop | Unchanged unless segments shift. |

The deterministic offline A/B (§11.3) checks detector behavior. Live UAT (§11.1) then checks
capture, ASR, auto-stop, and paste integration.

## 7. Failure-mode × caller table

| Failure | Behaviour | Caller |
|---|---|---|
| Requested units not all usable on device | `.cpuAndNeuralEngine` permits CPU and Neural Engine execution and excludes GPU execution. CoreML chooses within the permitted resources; this requested policy does not prove which permitted device executes each operation. | None. |
| Model fails to load | `LoadError.loadFailed` — the existing path. `CaptureVADSignalSource` publishes `.unavailable` and ASR runs on raw audio. | Unchanged. |
| Asset missing | `LoadError.resourceNotFound` — unchanged. | Unchanged. |

## 8. Caller-visible signals audit

No new signal, telemetry event, log line, or user-facing string. The #1783 markers
(`dictation.vad_preparation_completed`, `dictation.first_vad_chunk_started`,
`dictation.first_vad_chunk_completed`) already cover this interval and are how a post-ship
recurrence would be detected.

## 9. Fallback source-of-truth audit

Unchanged. `CaptureVADSignalSource.swift:401-413` remains the sole authority for
`.unavailable` vs `.confirmedNoSpeech`.

## 10. File-by-file changes

### File list

| File | Change |
|---|---|
| `Sources/EnviousWisprAudio/BundledVADModelLoader.swift` | Pin the requested CoreML policy explicitly (+3 lines, + comment). No new import. |
| `Tests/EnviousWisprTests/Audio/BundledVADModelLoaderTests.swift` | Add `import CoreML` and freeze the requested configuration through the real loader. |

The §11.3 A/B runs from a temporary, uncommitted test-target file because it needs `@testable` access to the detector's existing injection seam. Remove that file after recording the receipt. If the harness must remain in the repository, add it to the file list and re-evaluate the zero-blast exemption before push.

```swift
// BundledVADModelLoader.swift — inside loadModel(in:)
    do {
      // Match the pinned FluidAudio VAD loader (`DownloadUtils.swift:301-303`).
      // Keep this heart-path policy explicit across dependency updates.
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuAndNeuralEngine
      configuration.allowLowPrecisionAccumulationOnGPU = true
      return try MLModel(contentsOf: url, configuration: configuration)
    } catch {
      throw LoadError.loadFailed(error)
    }
```

## 11. Testing

### 11.1 Live UAT spec

Rebuild the dev app once, after Codex is clean (RULE: codex-clean-gates-runtime-uat), then:

1. `test_recording()` with auto-stop **ON** — assert the transcript pastes and auto-stop fires on
   trailing silence.
2. `test_recording()` with auto-stop **OFF** — assert the transcript pastes and the recording runs
   to manual stop.
3. Both engines: Parakeet and WhisperKit.
4. Read `~/Library/Logs/EnviousWispr/app.log` for `CORRECTION_DEBUG` + `Pipeline timing TOTAL`;
   verdicts come from the log, never the clipboard (RULE: uat-verdicts-from-app-log).
5. Confirm all three #1783 markers still fire in order.

### 11.2 Other test obligations

- **New freeze test** in `BundledVADModelLoaderTests`, exercising the REAL loader:

  ```swift
  import CoreML
  import Foundation
  import Testing

  @testable import EnviousWisprAudio

  // ...
  let fixtureBundle = try #require(Bundle(path: fixtureRoot.path))
  let model = try BundledVADModelLoader.loadModel(in: fixtureBundle)

  #expect(model.configuration.computeUnits == .cpuAndNeuralEngine)
  #expect(model.configuration.allowLowPrecisionAccumulationOnGPU)
  ```

  `MLModel.configuration` reports the load-time configuration that was REQUESTED, not proof of the
  device CoreML ultimately selected. That is the correct oracle here, because the requested policy is
  exactly what this change alters. **No fallback assertion on a library factory** — such a test would
  pass even with the bare configuration still in the loader, which is decoration
  (RULE: verify-the-feature-not-the-crash).
- **Mutation receipt:** remove both explicit property assignments so the loader passes a fresh bare
  `MLModelConfiguration()` to `MLModel`. Confirm that the configuration assertions FAIL. A freeze
  test that passes with the requested policy removed is decoration.
- Full `scripts/xcode-test.sh`, nonzero executed count read from `Test run with N tests`.

### 11.3 Deterministic offline A/B — segment-boundary receipt (runs BEFORE Live UAT)

Live UAT is necessary but insufficient for numerical drift: both engines consume the same VAD, so
engine-swapping provides no independent detector coverage.

Feed identical frozen 16 kHz mono Float32 audio through the checked-in VAD model twice:

- **Arm A** — current bare configuration (`.all`, low-precision GPU accumulation disabled).
- **Arm B** — `.cpuAndNeuralEngine` with low-precision GPU accumulation enabled.

Use the checked-in VAD model and the **five committed fixtures** under `scripts/freeze-suite/clips/`:
`normal-speech.wav`, `mumbled-speech.wav`, `silence.wav`, `background-noise.wav`, and
`sudden-burst.wav`. Verified 2026-07-24 via `afinfo` as 16 kHz mono Int16 PCM — already
detector-native, no resampling, and version-controlled so the measurement is reproducible from the
repo alone. Re-verify that format, record each SHA-256, and decode each file exactly once into one
in-memory mono Float32 buffer. Feed the same decoded buffer to both arms; do not decode independently
per arm.

> **Revision note (r3).** An earlier draft used `/private/tmp/ovh-*.mp3` from the #1780 session —
> 24 kHz MP3s outside the repo that can disappear. That was a
> RULE: use-existing-uat-harness-first miss: this committed corpus already existed.

Create a deterministic quiet-onset fixture from the decoded `normal-speech.wav`: scale complete
chunks 0-1 by `0.10`, chunks 2-3 by `0.25`, chunks 4-5 by `0.50`, and all remaining speech chunks by
`1.0`. Append twelve zero chunks to `normal-speech`, `mumbled-speech`, and quiet-onset so speech-end
and auto-stop behavior receive 3.072 seconds of identical trailing silence. Truncate every fixture to
complete 4,096-sample chunks after constructing it.

Implement the harness as a temporary, uncommitted `EnviousWisprTests` source with:

```swift
@preconcurrency import AVFoundation
import CoreML
@preconcurrency import FluidAudio
import Testing

@testable import EnviousWisprAudio
```

Resolve the checked-in compiled model URL once. Load one model for Arm A using a bare
`MLModelConfiguration()` and one model for Arm B using `.cpuAndNeuralEngine` plus
`allowLowPrecisionAccumulationOnGPU = true`. The loaded model may be reused within its arm.

For every **arm × fixture × repetition × replay mode**, construct a fresh
`VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)`, fresh recording
`StreamingVad` wrapper, and fresh `SilenceDetector` through its internal `makeStreamingVad` seam
(`SilenceDetector.swift:162-168`). Build the detector configuration with
`SmoothedVADConfig.fromSensitivity(0.5, energyGate: true)` and use `silenceTimeout: 1.5` — verified
as the shipped defaults at `SettingsDefaultValues.swift:38-40`, matching production's construction at
`CaptureVADSignalSource.swift:268-271`. Call `prepare()` before feeding audio. **Never reuse
detector, wrapper, or stream state between full-feed and auto-stop, between fixtures, or between
repetitions.** `SilenceDetector` carries `streamState`, `phase`, `emaSmoothedProbability`,
`speechSegments`, `processedSampleCount`, and the prebuffer across calls
(`SilenceDetector.swift:182-194`), so a shared instance would let the first replay contaminate the
second.

Each repetition performs two **independently initialized** replays. The **full-feed** replay records
every chunk, ignores `shouldAutoStop` until the buffer ends, then calls
`finalizeSegments(totalSampleCount:)`. The **auto-stop** replay stops at the first `true`, records
that chunk index, and calls `finalizeSegments(totalSampleCount:)` with the number of samples actually
processed. Capture probabilities, event kinds and indexes, final segments, speech-evidence outcome,
and first auto-stop chunk for both replay modes. Run three repetitions per arm.

**Acceptance: identical event sequences, segment boundaries, and auto-stop decisions for every
fixture.** Report maximum probability delta as supporting evidence. Any decision or boundary
difference STOPS the change for founder review — it would mean the fix silently changes what the
product hears, which is a different decision from the one approved at Gate 1.

Probability values are not required to be equal and have no arbitrary epsilon gate. A numerical delta
is tolerable when all three runs within each arm are stable and both arms produce identical event
kinds and indexes, final segments, speech-evidence outcome, and first auto-stop chunk. A difference
in any of those discrete outputs is a real behavioral change, not a numerical false-fail.

### 11.4 Latency receipt

Use the same five committed `scripts/freeze-suite/clips/*.wav` fixtures and
`Tests/RuntimeUAT/wispr_eyes.py::test_recording`. Do NOT depend on the #1780 session scratchpad or
`/private/tmp/ovh-*`, which are not repository artifacts.

**Arms.** Arm A is a dev app built from baseline commit `d2f903c1`. Arm B is a dev app built from the
final implementation. Preserve both `.app` artifacts at separate temporary paths. Run only one at a
time, fully quitting it before launching the other (RULE: dev-bundle-id-collision-across-worktrees —
all dev builds share one bundle id, so `open` can silently activate the wrong one; verify the running
PID's path). Use identical user settings and model-warm state in both arms.

**Passes.** For each engine, run one unmeasured `normal-speech.wav` warm-up on each arm. Then run
three measured passes per arm, where one pass processes all five fixtures in the §11.3 order. Measured
arm order `A1, B1, B2, A2, A3, B3`. Do not discard any additional measured pass.

**Measured value.** `test_recording` returns only a Boolean (`wispr_eyes.py:1344`), so the timing
must come from the log. Before every call, record the current `~/Library/Logs/EnviousWispr/app.log`
byte offset. After completion, parse the first NEW `Pipeline timing TOTAL:` record for that recording
(`KernelFinalizationWiring.swift:538`) and extract its leading total-seconds value. A failed or
unverifiable recording FAILS the receipt; do not omit or impute it.

**Pairing.** One paired observation is identified by **engine × fixture × measured-pass index**.
Compute `Arm B − Arm A` for all 30 pairs: two engines × five fixtures × three passes. Report
per-engine, per-fixture, and aggregate medians.

**Gate.** Bootstrap the 30 paired deltas with 10,000 resamples using fixed seed `1784`, taking the
median of each resample. A statistically supported regression means the observed aggregate paired
median is positive AND the percentile 95% bootstrap interval excludes zero. An interval containing
zero is not a supported regression. Any supported regression stops for founder review.

## 12. Blast radius & rollback

The shipped change touches one production file and one test file. Production replaces the bare model
configuration with one explicit requested policy; tests freeze that policy through the real loader.
Rollback is a single commit with no downstream cleanup, persisted state, or migration. Blast radius
is the requested compute policy for the bundled VAD model.

## 13. Ship criteria

1. Full `scripts/xcode-test.sh` green with a nonzero executed count.
2. New freeze test passes; mutation receipt shows it FAILS with the bare configuration restored.
3. **§11.3 offline A/B: identical event sequences, segment boundaries, and auto-stop decisions on
   every fixture, across three runs per arm.** Any difference stops the change for founder review.
4. Local whole-diff `codex review` clean.
5. Live UAT §11.1 passes on both engines, auto-stop on and off — run ONCE, after Codex is clean.
6. Latency receipt shows no statistically supported regression.
7. GitHub cloud review clean.

## 14. Open questions

1. **Causation is not claimed.** If #1780 recurs on a configuration-aligned build, the #1783 markers
   will show `first_vad_chunk_started` without `first_vad_chunk_completed`, and the hypothesis space
   changes. #1780 stays open either way.
2. **Could segment boundaries shift? Yes — and Live UAT alone cannot answer it.** Both engines share
   the same VAD instance, so swapping ASR engines gives no independent numerical coverage of the
   detector. **Before Live UAT**, run a deterministic offline A/B (§11.3).
3. **`CoreMLOutputClassifier.swift:93`** uses the same constructor pattern for a different model with
   no established replacement placement policy. Its in-process execution can terminate an active
   dictation on a hard fault. Founder-approved as separate work; unchanged here. Still open on #1784.

## 15. Related

#1784 (this), #1780 (crash, stays open), PR #1783 (record-start observability), #1224 (bundled VAD
model), #879 (WhisperKit compute options), D-028 (`docs/heartpath-refactor/DECISIONS.md`),
`docs/audits/2026-07-24-1784-crash-containment-council.txt`,
`.claude/knowledge/gotchas-audio.md` FACT: bundled-vad-model-pins-its-own-compute-policy (renamed from `...-bypasses-fluidaudio-default-configuration` when this change inverted it).