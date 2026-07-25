# Verdict: PROCEED-WITH-REVISIONS

The compute-unit change is correct and narrowly scoped. Do not use `MLModelConfigurationUtils.defaultConfiguration()`. Set the two properties explicitly in `BundledVADModelLoader`.

The plan’s main errors are:

- FluidAudio’s factory is not its VAD loading authority.
- The proposed fallback test would not test the loader.
- Live UAT alone is too weak for possible boundary movement.
- This qualifies as SMALL, zero-blast-radius work.
- The deferred classifier is not incapable of crashing an active dictation.

## Q1 — Direction

### Case for the FluidAudio factory

- It is public and reachable.
- It currently produces the desired configuration.
- It avoids repeating two assignments.
- It would inherit future FluidAudio defaults automatically.

### Case for explicit local configuration

- This is a pinned fork, and dependency updates are deliberate review points: [Package.resolved:14](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Package.resolved:14).
- A future factory change could silently alter extra CoreML settings in the heart path.
- Most importantly, the factory is not used by FluidAudio’s VAD loader. The real loader creates its configuration locally at [DownloadUtils.swift:301](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/DownloadUtils.swift:301).
- Therefore adopting the factory does not actually “return to the VAD paved road.”

Commitment: configure it locally. This pins the intended heart-path policy while matching the current FluidAudio VAD loader exactly.

```swift
do {
  // Match the pinned FluidAudio VAD load policy explicitly. Keep this
  // heart-path configuration reviewable across dependency updates.
  let configuration = MLModelConfiguration()
  configuration.computeUnits = .cpuAndNeuralEngine
  configuration.allowLowPrecisionAccumulationOnGPU = true
  return try MLModel(contentsOf: url, configuration: configuration)
} catch {
  throw LoadError.loadFailed(error)
}
```

## Q2 — Fact-check

| # | Verdict | Evidence |
|---|---|---|
| 1 | **TRUE** | The sole EnviousWispr VAD `MLModel` construction is [BundledVADModelLoader.swift:19](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/BundledVADModelLoader.swift:19), with the load at [line 34](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/BundledVADModelLoader.swift:34). Its only production caller is [SilenceDetector.swift:157](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/SilenceDetector.swift:157). |
| 2 | **TRUE**, scoped to VAD | The preloaded initializer only stores `config` and `vadModel`: [VadManager.swift:102](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadManager.swift:102). VAD reads `config.computeUnits` only in `loadUnifiedModel`: [VadManager.swift:124](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadManager.swift:124), [line 135](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadManager.swift:135). |
| 3 | **TRUE**, with an important qualification | The factory is public and sets those two properties: [MLModelConfigurationUtils.swift:5](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:5), [lines 11-16](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:11). The optimization hints and 126.6 → 93.3 result are comments only: [lines 17-28](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:17). But the VAD loader does not use this factory; it repeats the settings at [DownloadUtils.swift:301](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/DownloadUtils.swift:301). |
| 4 | **TRUE** | `EnviousWisprAudio` directly depends on FluidAudio: [Project.swift:231](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Project.swift:231) and [Package.swift:89](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Package.swift:89). FluidAudio exports the collision-prone `FluidAudio` struct at [FluidAudioSwift.swift:29](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/FluidAudioSwift.swift:29), but no local `MLModelConfigurationUtils` or `FluidAudio` type exists in `Sources/`. |
| 5 | **TRUE** | First-party modules are static frameworks: [Project.swift:151](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Project.swift:151). Audio reaches the app through Pipeline/AppKit at [Project.swift:278](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Project.swift:278) and reaches the ASR executable directly at [Project.swift:335](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Project.swift:335). The ASR service constructs only `ParakeetBackend`: [ASRServiceHandler.swift:48](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprASRService/ASRServiceHandler.swift:48). The detector construction is in the app pipeline: [CaptureVADSignalSource.swift:99](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprPipeline/CaptureVADSignalSource.swift:99). |
| 6 | **TRUE** for the production VAD feed | The size is 4096: [SilenceDetector.swift:132](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/SilenceDetector.swift:132). Processing begins only when a complete chunk exists, and the slice has that exact size: [VADMonitorLoop.swift:109](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprPipeline/VADMonitorLoop.swift:109), [lines 111-121](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprPipeline/VADMonitorLoop.swift:111). FluidAudio can pad arbitrary callers’ short arrays, but this production caller never supplies one. |
| 7 | **JUDGMENT-CALL** | “Untouched” is factual; “correctly” is a policy judgment. Parakeet uses FluidAudio’s normal model loading and `.default`: [ParakeetBackend.swift:108](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprASR/ParakeetBackend.swift:108), [lines 115-123](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprASR/ParakeetBackend.swift:115). WhisperKit deliberately requests `.cpuAndGPU`: [WhisperKitBackend.swift:9](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprASR/WhisperKitBackend.swift:9), [lines 22-25](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprASR/WhisperKitBackend.swift:22). Neither file is in the planned diff. |
| 8 | **TRUE** | The only `MLModelConfiguration()` constructions in `Sources/` are the VAD loader at [BundledVADModelLoader.swift:34](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprAudio/BundledVADModelLoader.swift:34) and the separate LLM classifier at [CoreMLOutputClassifier.swift:93](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprLLM/CoreMLOutputClassifier.swift:93). |

### Coverage-round skip

The skip is legitimate, but for a different reason than the prior council.

The intended change is:

- At most 20 lines and two files.
- No new symbol, API, control flow, module edge, persistence, or migration.
- A single configuration change with clean rollback.

That exactly matches [workflow-process.md RULE: council-skip-zero-blast-radius:61](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.claude/rules/workflow-process.md:61). Config tweaks are SMALL at [line 141](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.claude/rules/workflow-process.md:141).

The prior council did not cover the weak oracle, deterministic boundary comparison, or incorrect authority claim. Grounded review caught those. But the explicit zero-blast rule still makes the separate coverage round optional.

If the eventual diff exceeds those limits, the exemption must be reconsidered.

## Q3 — Consolidation and authority

The dominant concern is:

> Which requested CoreML load policy is used for the bundled VAD model?

There is one EnviousWispr runtime owner: `BundledVADModelLoader.loadModel(in:)`.

The plan’s claim that FluidAudio’s factory is the authority is false. FluidAudio has two equivalent implementations today:

- Factory: [MLModelConfigurationUtils.swift:11](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:11)
- Actual VAD model loading: [DownloadUtils.swift:301](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.derivedData/Dev/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/DownloadUtils.swift:301)

The correct local authority is therefore the sole model construction site, with a comment saying it intentionally matches the pinned dependency.

Deferring `CoreMLOutputClassifier.swift:93` is acceptable. It is a different model and policy, and `EnviousWisprLLM` does not depend on FluidAudio: [Package.swift:135](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Package.swift:135). Folding it in would add an inappropriate module dependency or broaden the change.

However, the reason written in the plan is false. Classifier inference happens in-process during polish before paste: [EnviousOutputFilter.swift:78](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprLLM/EnviousOutputFilter.swift:78), [AppleIntelligenceConnector.swift:453](/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-1784vadconfig/Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift:453). Throws and timeouts fail open, but a hard CoreML process fault cannot be caught and could terminate the active dictation.

## Q4 — Mandatory plan edits

### 1. Replace the implementation direction

Replace §3’s factory adoption with:

> `BundledVADModelLoader.loadModel(in:)` remains the sole EnviousWispr authority for the bundled VAD model’s requested CoreML load policy. Construct an `MLModelConfiguration` locally and explicitly set `computeUnits = .cpuAndNeuralEngine` and `allowLowPrecisionAccumulationOnGPU = true`. These values match the pinned FluidAudio VAD loader at `DownloadUtils.swift:301-303`. Keeping them explicit prevents a future dependency update from silently adding or changing heart-path CoreML policy through a shared factory.

Replace §3c-answer with:

> `§3c-answer: one EnviousWispr authority — BundledVADModelLoader.loadModel(in:) owns the requested CoreML configuration at the sole VAD MLModel construction site. It explicitly pins the two values matching the current pinned FluidAudio VAD loader. VadConfig.computeUnits remains library-owned metadata consumed only by FluidAudio’s bypassed loading path; EnviousWispr creates no second runtime configuration site.`

Also remove:

> “what every peer app on this library runs”

That was not established by the measurements.

Replace “No behaviour switch” with:

> `No public API, control-flow, fallback, or lifecycle change. The observable runtime change is the requested CoreML hardware policy and any resulting numerical or latency difference.`

### 2. Replace the test oracle

`MLModel.configuration` represents the load-time configuration requested when the model was instantiated, not proof of the hardware CoreML ultimately selected. Apple describes `MLComputeUnits` as the compute devices the application permits, while CoreML chooses within that set. See [MLModel.configuration](https://developer.apple.com/documentation/coreml/mlmodel/configuration) and [MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits).

That makes it a valid oracle for the feature being changed: the loader’s requested policy. It does not prove actual ANE placement.

Use this test:

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

Delete the fallback that tests `MLModelConfigurationUtils.defaultConfiguration()` directly. That fallback would pass even if `BundledVADModelLoader` still used the bare configuration, so it would be decoration.

Keep the mutation receipt: restoring the bare configuration must fail this test.

### 3. Add deterministic offline comparison

Live UAT on both engines is necessary but insufficient. Both engines share the same VAD, so changing ASR engines does not provide independent VAD numerical coverage.

Replace §14 question 2 with:

> **Could segment boundaries shift?** Yes. Before Live UAT, run a deterministic offline A/B using identical frozen 16 kHz mono Float32 audio and the checked-in VAD model. Arm A uses the current bare configuration (`.all`, low-precision GPU accumulation disabled). Arm B uses `.cpuAndNeuralEngine` with low-precision GPU accumulation enabled. Feed only complete 4,096-sample chunks through fresh detector state using the production threshold, smoothing, minimum-speech, silence-timeout, and padding settings. Include silence-only, quiet onset, normal short speech, fillers/internal pauses, and long speech with trailing silence. Record per-chunk probabilities, event types and sample indexes, final SpeechSegment ranges, and the first auto-stop chunk. Run each arm three times to detect within-arm variation. Acceptance requires identical event sequences, segment boundaries, and auto-stop decisions for every fixture. Report maximum probability delta as supporting evidence. Any decision or boundary difference stops the change for founder review. Live UAT then confirms real capture, paste, and both ASR integrations.

### 4. Correct the tier declaration

Replace the preface with:

> - **Lane:** Code  
> - **Tier:** SMALL (single VAD model-load configuration change; no control flow, lifecycle, public API, module edge, persistence, or migration)  
> - **Coverage round:** SKIPPED under RULE: council-skip-zero-blast-radius. The production/test diff remains ≤20 lines across two files and is a single-value configuration change with single-commit rollback. PR tag: `council-skip: zero-blast-radius (single-value config)`.  
> - **Live UAT:** Y (RULE: runtime-uat-catches-static-misses; SMALL does not waive runtime validation for ML/audio changes)  
> - **Modules:** EnviousWisprAudio  
> - **Test:** required (EnviousWisprTests/Audio)

The current MEDIUM declaration over-processes the change. Keeping Live UAT does not make it MEDIUM.

### 5. Correct the classifier deferral

Replace both classifier statements with:

> `CoreMLOutputClassifier.swift:93` uses the same bare-constructor pattern for a different model and a separate placement policy. It is a limb, but its in-process prediction runs during Apple Intelligence polish before paste, so a hard CoreML fault could still terminate that dictation. Founder-approved as separate work at Gate 1; this VAD-only change does not alter it.

### 6. Correct the failure-mode statement

Replace “CoreML falls back internally” with:

> `.cpuAndNeuralEngine` permits CPU and Neural Engine execution and excludes GPU execution. CoreML chooses within the permitted resources; this requested policy does not prove which permitted device executes each operation.

Final position: keep the VAD-only scope, use explicit local settings, strengthen the real-loader test, add the offline A/B boundary receipt, and classify the work as SMALL zero-blast-radius.