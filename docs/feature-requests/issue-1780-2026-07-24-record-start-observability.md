# Issue #1780 — VAD compute-unit pin + heart-path record-start telemetry — 2026-07-24

## Preface — Lane + Live UAT declaration

**Lane: Code.** Live UAT REQUIRED (audio capture + record-start path; runtime-only behaviour that logic tests cannot observe).
**Tier: MEDIUM** (audio capture, net-new runtime telemetry). Modules: `EnviousWisprAudio`, `EnviousWisprPipeline`, `EnviousWisprServices`.

## Preface — User Rubric

`User Rubric: performance-only. No UI or copy changes. Aaron Wu must not pay higher repeated-dictation latency, battery drain, or thermals; Frank Chen on older supported Apple Silicon must not experience a slower first recording or delayed paste. With the compute-unit pin HELD (§2.6) this PR changes no compute scheduling, so those risks do not arise here; the residual user-facing cost is the three added synchronous PostHog queue writes per recording, measured under §11.`

## 0. TL;DR

Two changes, both defensible independent of #1780's unproven root cause:

1. **SHIPPING — record-start observability.** THREE new VAD-interval markers, each emitted as BOTH a Sentry breadcrumb (crash-local evidence) and a PostHog event (fleet funnel), so the next record-start crash localises itself instead of requiring thread-stack forensics. The capture-established edge is NOT re-instrumented — `dictation.invoked` and the `Recording started` breadcrumb already cover it.
2. **HELD pending founder decision — VAD compute-unit pin.** Loading the model through FluidAudio's `MLModelConfigurationUtils.defaultConfiguration()`. Coverage review (2026-07-24) recommends holding: the crash occurred on the CPU path and `.cpuAndNeuralEngine` still permits CPU, so the change does not target the observed mechanism, while altering compute scheduling for ~600 currently-working users. Requires representative cold/warm evidence plus explicit founder approval (§2.6).

**Explicitly NOT shipping:** the "skip VAD when auto-stop is off" idea. §2.5 proved it unsafe — see Non-goals.

## 1. Problem

`EXC_BAD_ACCESS` inside `VadManager.processUnifiedModel` → `MLModel.prediction` → Espresso → BNNS, at record-start, three consecutive times for one user (macOS 14.2.1, Parakeet, built-in mic, streaming off). Root cause unproven; not reproduced on macOS 14.8.7 / 15.7.7 / 26 across all four `MLComputeUnits`, concurrent, with churn, or under a guard-page over-read probe.

Two real defects surfaced during that investigation, both on the crash path:

- PostHog has no record-start stage events after capture commits. Sentry already records `Recording started`, backend, streaming state, and audio route, but it has no breadcrumb immediately before and after VAD preparation or the first VAD prediction. The observability gap is therefore inside the VAD interval, not the whole record-start window.
- We bypass the library's intended model configuration. This is a genuine mismatch, but it is a fleet-wide compute-scheduling experiment, not a correctness repair — see §2.6.

## 2. Goals & non-goals

**Goals.** Make the dark VAD interval observable, in both Sentry (crash-local) and PostHog (fleet). Establish whether the compute-unit mismatch is safe to correct fleet-wide, without shipping it on assumption.

**Non-goals.**
- Claiming #1780 is fixed. Neither change is proven causal; #1780 stays open.
- **Gating VAD execution on `vadAutoStop`.** REJECTED on evidence (§2.5.3): VAD segments gate the heart path. Skipping them would silently discard quiet recordings.
- Enabling `MLOptimizationHints`. Upstream documents a 126.6 → 93.3 RTFx regression (-26%) for this exact model.
- Moving VAD out of process. #1543 deliberately moved capture in-process; not revisiting.
- Shipping the compute-unit pin in this PR without the §2.6 evidence gate and explicit founder approval.

## 2.5 Grounding brief

### 2.5.1 Producer → owner → consumer for the VAD model configuration

`BundledVADModelLoader.loadModel(in:)` (`Sources/EnviousWisprAudio/BundledVADModelLoader.swift:34`) is the sole producer of the VAD `MLModel`:

```swift
return try MLModel(contentsOf: url, configuration: MLModelConfiguration())
```

Sole consumer: `SilenceDetector`'s default `makeStreamingVad` closure (`SilenceDetector.swift:158`), which passes the loaded model to `VadManager(config:vadModel:)`.

Capability grep for other producers:

```
$ grep -rn "silero-vad\|BundledVADModelLoader\|vadModel:" Sources/ Tests/ | sort
Sources/EnviousWisprAudio/BundledVADModelLoader.swift:  (definition)
Sources/EnviousWisprAudio/SilenceDetector.swift:158:      return VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
Tests/EnviousWisprTests/Audio/BundledVADModelLoaderTests.swift  (tests)
```

One producer, one consumer. Closed.

### 2.5.2 What the library intends (checkout grep, Tier 3)

`.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift:11`:

```swift
public static func defaultConfiguration(
    computeUnits: MLComputeUnits = .cpuAndNeuralEngine
) -> MLModelConfiguration {
    let config = MLModelConfiguration()
    config.allowLowPrecisionAccumulationOnGPU = true
    config.computeUnits = computeUnits
    return config
}
```

| Setting | Library intends | We ship today |
|---|---|---|
| `computeUnits` | `.cpuAndNeuralEngine` (GPU excluded) | `.all` (CoreML default) |
| `allowLowPrecisionAccumulationOnGPU` | `true` | `false` |

`VadConfig.computeUnits` also defaults to `.cpuAndNeuralEngine` (`VadTypes.swift:4`) but is applied **only** in FluidAudio's own loading path (`VadManager.swift:124`), which the already-loaded-model initialiser (`VadManager.swift:102`) bypasses. So today nothing applies it.

Linkage verified: `Package.swift:92` lists `FluidAudio` as a dependency of `EnviousWisprAudio`, so the loader can import it. Per `swift-patterns.md` RULE: fluidaudio-unqualified-symbols, reference `MLModelConfigurationUtils` unqualified.

### 2.5.3 Why gating VAD on `vadAutoStop` is REJECTED

`VADMonitorLoop.swift:100` runs `detector.processChunk(chunk)` unconditionally; line 102 gates only the auto-stop *action* (`if shouldStop && vadAutoStop && isRecording()`). The prediction is deliberately unconditional. Consumers of its output, all reached with `vadAutoStop == false`:

| Consumer | Site | Effect if segments were always empty |
|---|---|---|
| VAD gate | `RecordingSessionKernel.swift:1673` | `finishTerminal(.noSpeech(.vadGate))` — **recording silently discarded** |
| Faint-speech recovery | `RecordingSessionKernel.swift:1680` | `attemptedFromEnergyDespiteNoSegments` always true |
| Degraded-lead salvage (#1434) | `RecordingSessionKernel.swift:2124` | gated by `effectiveSpeechEvidence`; Parakeet-only via `decodesConditionedBatchSamples` — **silently disabled** |
| Terminal routing | `RecordingSessionKernel.swift:2195` | `.noSpeech` vs user-visible `.failed(.asrEmpty)` inverted |
| Archive labelling | `RecordingSessionKernel.swift:2424` | `asrEmpty` vs `noSpeech` mislabelled |
| WhisperKit LID filter | `WhisperKitEngineAdapter.swift:681` | `SampleFilter.filter(from:segments:)` loses conditioning |
| Empty-result diagnostics | `ASREmptyResultDiagnostics.swift:137` | loses first/last segment |

**Correction (grounded review r1):** the table above is INCOMPLETE and one row was overclaimed. Archive labelling is inside `#if DEBUG` (`RecordingSessionKernel.swift:2111-2113`), so it did NOT run in the affected user's release build. The complete production inventory funnels through two kernel calls — `speechEvidenceAtStop()` (`RecordingSessionKernel.swift:1628`) and `speechSegmentsAtStop()` (`:1708`) — plus the stop-time freeze at `CaptureVADSignalSource.swift:298-311`, and additionally reaches: segment clamping / adapter handoff (`:1707-1748`), batch conditioning (`:1759-1760`, `CapturedAudioConditioner.swift:95-159`), VAD duration + diagnostic fields (`:1761`, `:1853-1888`), Parakeet tail preservation (`:1782-1837`), tail-clip diagnostics (`:2029-2033`), and WhisperKit decoder clip ranges (`WhisperKitEngineAdapter.swift:687-690`).

The rejection stands, and rests primarily on **conditioning and decoder routing**, not the DEBUG archive row: with permanently empty segments the dead-air gate discards quiet recordings, `SampleFilter` stops conditioning the batch, tail preservation cannot identify a VAD-trimmed tail, and salvage is suppressed. Skipping VAD would trade a crash for silent data loss. **Rejected.**

### 2.5.4 Telemetry gap — negative capability grep

```
$ grep -n 'PostHogSDK.shared.capture("' Sources/EnviousWisprServices/TelemetryService.swift \
    | sed 's/.*capture("\([^"]*\)".*/\1/' | sort -u | grep -iE "dictation|record|audio|capture|asr|engine|warm"
asr.completed
audio.capture_interrupted
coldstart.warmup_completed
dictation.canceled
dictation.completed
dictation.invoked
```

No PostHog event exists between `dictation.invoked` and `asr.completed`. Sentry is better off but still blind at the point that matters: #1780's breadcrumbs end at `Recording started` and the process dies, with nothing around detector preparation or the first prediction. `AppLogger` file output is `#if DEBUG` **and** requires in-app Debug Mode, so release users leave no trace in this window.

`BundledVADModelLoader` is the sole PRODUCTION producer used by `SilenceDetector`'s default factory. Tests may inject another `StreamingVad` via the internal seam; this claim does not cover test-only injection.

Crash durability verified, not assumed: the pinned PostHog SDK encodes and writes each captured event to its disk-backed queue **synchronously** on the calling thread, explicitly "to preserve crash durability" (`.build/checkouts/posthog-ios/PostHog/PostHogQueue.swift:359`). Production confirms it — #1780's `dictation.invoked` reached PostHog despite the process dying immediately after. Sentry breadcrumbs remain the authoritative crash-local sequence because they travel inside the crash report.

This is not speculative instrumentation (RULE: prove-the-regression-before-building-the-guard): a real production crash could not be localised from our own data and had to be reconstructed from crash-dump thread states.

### 2.5.5 Prior art / owner search for the telemetry shape

`TelemetryService.swift` is the single authority for PostHog emission (`analytics-operations.md` FACT: app-posthog-events). New events go there, dot-separated, privacy-boundary respected (metadata only, never dictated content — `sentry-operations.md` RULE: telemetry-privacy-boundary).

## 2.6 Pre-approval evidence gate (compute-unit pin only)

Issue #1780 classified the investigation as LARGE. This reduced plan is **MEDIUM only** because observability stays inside the existing lifecycle/VAD telemetry owners and changes no kernel control flow. Any kernel lifecycle, VAD scheduling, or deferred-processing change returns the work to LARGE.

The compute-unit pin does not ship in this PR. Before it may be proposed again:

1. Bring the exact VAD benchmark into a reviewable branch, or name a committed immutable artifact and command both configurations run unchanged. The `Tests/RuntimeUAT/repro-1780` harness lives only in the annotated tag `parked/1780-vad-repro-2026-08-01` (branch `investigate/1780-vad-repro` archived into it and deleted 2026-08-01) and is NOT in this worktree; the measurement may not depend on an investigation-branch artifact. Restore with `git checkout parked/1780-vad-repro-2026-08-01 -- Tests/RuntimeUAT/repro-1780`.
2. Run the unchanged harness against current `.all` and proposed `.cpuAndNeuralEngine` before any implementation approval.
3. Record cold preparation, first prediction, sustained prediction, CPU time, and energy, broken out by tested hardware and macOS version.
4. Obtain explicit founder approval for changing compute scheduling for all users.

Missing representative evidence or approval removes the pin entirely. The observability work proceeds independently and does not depend on it.

## 3. Design

### 3.1 VAD model configuration (HELD — not in this PR)

Would build the configuration via `MLModelConfigurationUtils.defaultConfiguration()` rather than a bare `MLModelConfiguration()`. No signature change, no new parameter, no call-site change.

Held per §2.6. The case against shipping it now, stated plainly: the crash occurred on the CPU/BNNS path; `.cpuAndNeuralEngine` still permits CPU, so the change does not target the observed mechanism; every configuration survived on every machine tested; the mismatch predates the affected release; and it would alter compute scheduling for ~600 currently-working users. "FluidAudio defaults to this" justifies an experiment, not a fleet rollout.

### 3.2 Record-start observability

The capture-established edge is **already** instrumented and is NOT duplicated: `.recordingCommitted` (`KernelHeartPathTelemetryObserver.swift:252-256`) drives both PostHog `dictation.invoked` and the Sentry `Recording started` breadcrumb from the same handler (`KernelLifecycleTelemetrySink.swift:204-217`). An earlier draft added a `dictation.capture_started` marker there; it provided no additional localisation and is dropped.

Three new VAD markers, each emitted as BOTH a non-alerting Sentry breadcrumb and a PostHog event:

| Event | Exact boundary | Properties |
|---|---|---|
| `dictation.vad_preparation_completed` | readiness evaluation returned, immediately before monitor entry | `backend`, `input_route`, `ready`, `model_reused` |
| `dictation.first_vad_chunk_started` | immediately BEFORE the first `SilenceDetector.processChunk` await | `backend`, `input_route`, `monitor_to_first_chunk_ms` |
| `dictation.first_vad_chunk_completed` | immediately AFTER that await returns | `backend`, `input_route`, `chunk_processing_latency_ms`, `should_stop` |

**"Chunk", not "prediction", is deliberate.** These boundaries surround `SilenceDetector.processChunk`; the FluidAudio/CoreML prediction begins deeper inside it (`SilenceDetector.swift:240-248`). Claiming the pair brackets `MLModel.prediction` would overstate what the markers prove.

The diagnostic value is the pair:

- `started` present, `completed` absent → fatal failure during first-chunk processing, which contains the observed CoreML path. **This is what #1780 would have shown.**
- both present, then a crash → a later chunk or downstream work.
- neither → the failure precedes VAD entirely.

`should_stop` is the actual returned value. `processChunk` is **non-throwing** (`SilenceDetector.swift:212`) — it catches the underlying `StreamingVad` error and returns `false` (`:250-258`) — so there is no error result to report and no throwing path to test.

**Monitor-run identity guard — complete mutation inventory and reachability audit.** Rounds 1 and 2 each produced a finding of this class, so I enumerated the surface rather than take another single-finding round. Round 3 then corrected my reachability claims — recorded here rather than quietly fixed.

`CaptureVADSignalSource.monitorTask` has exactly three grouped mutation/cancellation locations: `configureSession`, `startMonitoring`, `finalizeAtStop` (`:171-172`, `:191-192`, `:299-300`). `CaptureVADSignalSource.currentSessionID` has exactly one writer (`:129`) and exactly one production caller (`RecordingSessionKernel.swift:1039`); tests also drive the seam directly, and the kernel owns a *separate* property of the same name.

| Path | Production reachability | Required protection |
|---|---|---|
| `configureSession` invalidates the prior run before the new session is stamped | **Not** an interleaving window — both calls are synchronous on `MainActor` with no suspension between them. But an old task can resume later after an actor await. | Generation invalidation stops the later resumption emitting |
| `startMonitoring` replaces a run within the same session | **Not** currently reachable — one production caller (`beginLiveRecording`), itself after the single successful live transition. Retained as defence against direct tests and future callers. | Generation invalidation |
| `finalizeAtStop` cancels while the session id is unchanged | **Reachable** | Generation invalidation required |
| Task-local code reads mutable session/backend/route after starting | **Reachable** after suspension | Snapshot session id, backend, route and generation synchronously BEFORE creating the task |

So: two genuinely reachable failures, two defensive. One `invalidateMonitor()` — cancel, clear, advance a monotonic generation — at all three locations, plus the synchronous snapshot, closes both reachable paths and keeps the defensive ones safe.

**Every** new emission must re-check that captured session id AND captured generation are still current immediately before emitting — including the directly-emitted `vad_preparation_completed`, not only the two loop callbacks. It sits after an actor await, so it is exposed to exactly the same resumption.

`model_reused` is snapshotted from `await directDetector.isReady` immediately after selecting the retained-or-new detector and **before** readiness preparation. `SilenceDetector.reset()` does not unload `vadManager`, so `true` means this retained detector entered the recording with its model already loaded. Reading `isReady` **after** preparation is forbidden — it would measure final readiness, and every successful preparation would falsely report as reuse.

`backend` is snapshotted from `adapter.engineIdentity.rawValue`, passed in by the kernel. `input_route` is snapshotted from `audioCapture.currentAudioRoute` (`AudioCaptureInterface.swift:14`), the existing low-cardinality route label. It deliberately does NOT alias `currentResolvedRoute.selected` or `.effective` — those are distinct telemetry facts and are not added by this PR.

`monitor_to_first_chunk_ms` starts at `VADMonitorLoop.run` entry. No key-press timestamp reaches this owner (`DictationSessionConfig` carries none), so naming it press-to-chunk latency would fabricate a metric.

## 3b. Ownership justification

**Correction from coverage review:** an earlier draft claimed `RecordingSessionKernel` emits `dictation.invoked`. It does not — `KernelLifecycleTelemetrySink` does (`:204-208`). Verified.

Observation points must stay split, because each boundary physically exists in a different owner:

- `CaptureVADSignalSource` observes detector readiness — it owns detector creation, reuse, preparation and monitor launch (`:199-205`, `:242-277`).
- `VADMonitorLoop` observes first-chunk entry/return — those exact positions exist at its await site (`:98-102`), and it already owns per-run local state (`:52-61`).

Emission is consolidated through one new internal, stateless `RecordStartTelemetrySink`. It is the sole coordinator of dual-channel parity and the sole owner of the three breadcrumb messages. `TelemetryService` remains the existing authority for exact PostHog event names and property serialisation — an earlier draft overclaimed the sink as owning those too.

Placement challenge: putting the sink in `EnviousWisprServices` would move record-start stage semantics down into an infrastructure module; duplicating emission across `CaptureVADSignalSource` and `VADMonitorLoop` would split parity between two observation owners and drift. `EnviousWisprPipeline` is the narrowest correct owner — Pipeline coordinates stage facts, Services performs SDK-specific emission. Dependency direction verified clean (`scripts/check-dependency-direction.sh:42`; Pipeline→Services already allowed).

Against "new shared objects are guilty until proven innocent": the sink has one purpose, exactly three methods, injected emission closures, no mutable state, no session/lifecycle/detector/backend state, and no orchestration authority. It does not violate `keep-central-types-thin`.

`RecordingSessionKernel` gains no telemetry call and no telemetry-only stored state. Its sole change is passing the already-resolved backend string into `startMonitoring` — the backend is not otherwise reachable from the VAD source (`DictationSessionConfig` has no backend field; verified by grep).

## 3c. Single-authority check

Concern: ordered record-start observability.

`RecordStartTelemetrySink` is the sole owner of the three breadcrumb messages and the dual-channel parity rule. `TelemetryService` remains the sole authority for the exact PostHog event names and property serialisation. `CaptureVADSignalSource` and `VADMonitorLoop` only observe physical boundaries and report typed facts to the sink.

Existing capture-established signals are REUSED, not duplicated: PostHog `dictation.invoked`, Sentry `Recording started`. No `dictation.capture_started` is added.

§3c-answer: consolidated to RecordStartTelemetrySink (three breadcrumb messages + dual-channel parity) and TelemetryService (PostHog names + serialisation); CaptureVADSignalSource gains invalidateMonitor as the single monitor-cancellation authority, replacing the three scattered cancel-and-clear pairs.

## 4. Contract deltas

- `TelemetryService`: three additive `package` event methods. Exact PostHog names and property serialisation stay owned by Services; no public API is added. (`package` visibility is already used 471× across `Sources/`, including in Services — verified, so it compiles in both build graphs.)
- `VADMonitorLoop.run`: additive defaulted observation callbacks + injectable monotonic clock.
- `CaptureVADSignalSource.startMonitoring`: receives the already-resolved backend string.
- New `RecordStartTelemetrySink` (pipeline-internal).
- `CaptureVADSignalSource`: additive internal detector-factory injection, defaulting to the existing `SilenceDetector` construction. Tests use it to supply a continuation-controlled detector; production construction and visibility are unchanged. Required because the source constructs `SilenceDetector` directly (`:199`) and the fake-`StreamingVad` seam is internal to `EnviousWisprAudio` (`SilenceDetector.swift:164`), so without this the generation and `model_reused` tests cannot deterministically control suspension.
- No model configuration, protocol, enum, persisted setting, or migration change. The loader is untouched (pin held, §2.6).

## 5. E2E state & lifecycle audit

| Class | Answer |
|---|---|
| Interrupted | Facade calls do not throw, but PostHog encodes + persists synchronously on the caller's thread. Cancellation owes no cleanup, but a cancelled task may resume after a `SilenceDetector` actor await. Every marker emits only while its captured session id AND monitor generation are both current. |
| Deleted | N/A — no persisted domain state created or deleted. |
| Mutated | Backend and input route are captured as values at monitor start; later settings or route changes cannot rewrite this record-start sequence. |
| Concurrent | All three cancellation/replacement locations invalidate the monitor generation. Session id, backend and route are captured before task creation, so a later actor resumption cannot emit under a newer run. The once-latch is local per run. |
| Nil | A missing weak `self` returns without emitting. Observability never changes the recording outcome. |
| Stale | The local latch prevents repeats within a run. The captured-session plus captured-generation check prevents ALL late markers after invalidation, including the directly-emitted preparation marker. |

Closed-set trigger: **not met**. These changes observe existing execution points and add no state transition, terminal outcome, cancellation/preemption contract, durable ordering, recovery rule, or raw-text fallback change. Clause 1 of `workflow-process.md` RULE: async-edge-case-enumeration is false. The six-class audit above remains mandatory because this is MEDIUM.

## 6. Downstream consumer matrix

| Consumer | Impact |
|---|---|
| PostHog Pipeline Performance dashboard | add a record-start funnel: `dictation.invoked` → `dictation.vad_preparation_completed` → `dictation.first_vad_chunk_started` → `dictation.first_vad_chunk_completed`; segment by app version, OS version, hardware, backend, input route |
| `workers/product-health` | no threshold in this PR — establish event coverage and a fleet baseline first |
| `workers/daily-report` | unaffected; does not enumerate these event names |
| Sentry | matching breadcrumbs provide the authoritative stage sequence on fatal crashes |
| `SilenceDetector` / `VadManager` | unaffected — no behavioural change, emits only |

## 7. Failure-mode × caller table

| Failure | Caller sees |
|---|---|
| PostHog offline / queue full | unchanged — SDK persists to disk then drops per its own policy; emits are non-throwing and never gate the recording result |
| Sentry disabled | breadcrumb is a no-op; PostHog event still emitted |
| Stale callback or direct preparation emission from an invalidated monitor run | dropped by the captured-session plus captured-generation check immediately before emission; nothing emitted |
| Detector never becomes ready | `vad_preparation_completed` still emits with `ready=false` — the negative case is the diagnostic |

## 8. Caller-visible signals audit

No user-facing string, AX label, or status text changes. No new pill, notice, or error surface.

## 9. Fallback source-of-truth audit

Unchanged. Raw-text-on-limb-failure floor untouched; neither change sits on the polish path.

## 10. File-by-file changes

| File | Change |
|---|---|
| `Sources/EnviousWisprPipeline/RecordStartTelemetrySink.swift` | **new** — sole owner of the three breadcrumb messages and Sentry/PostHog parity; delegates PostHog names and serialisation to `TelemetryService` |
| `Sources/EnviousWisprPipeline/CaptureVADSignalSource.swift` | capture session id/backend/route at monitor start; `invalidateMonitor()` + generation; emit `vad_preparation_completed`; supply guarded first-chunk callbacks; add an internal defaulted detector-factory seam for deterministic source-level tests |
| `Sources/EnviousWisprPipeline/VADMonitorLoop.swift` | defaulted first-chunk started/completed callbacks, injectable clock, per-run latch |
| `Sources/EnviousWisprServices/TelemetryService.swift` | three additive emit funcs |
| `Sources/EnviousWisprPipeline/RecordingSessionKernel.swift` | one line — pass the resolved backend into `startMonitoring` |
| `Sources/EnviousWisprPipeline/KernelLifecycleTelemetrySink.swift` | **no change** (capture edge already instrumented) |
| `Sources/EnviousWisprAudio/BundledVADModelLoader.swift` | **no change** (pin held, §2.6) |
| `Tests/EnviousWisprTests/Pipeline/` | latch, ordering, non-throwing-path, parity, generation-invalidation, synchronous-snapshot, and `model_reused` ordering tests (§11) |
| `Tests/EnviousWisprTests/Services/` | `TelemetryService` schema test for the three `package` methods (§11) |

Knowledge updates (`analytics-operations.md` event table; `gotchas-audio.md` configuration-bypass trap) are **local source-of-truth edits outside this PR's diff** — `.claude/` is gitignored and absent from this worktree (verified).

## 11. Testing

- **Latch test.** Drive multiple chunks through `VADMonitorLoop`; assert exactly one started/completed pair per run, and a fresh pair on a new run.
- **Ordering test.** Injected monotonic clock + a fake `StreamingVad` recording interleaving; assert `started` precedes detector entry and `completed` follows return. The diagnostic value depends entirely on this ordering.
- **Non-throwing path test.** Inject a `StreamingVad` that throws. Because `SilenceDetector.processChunk` catches it and returns `false` (`:250-258`), assert BOTH callbacks still fire and `should_stop == false`. (There is no throwing path out of `processChunk` — an earlier draft wrongly assumed one.)
- **Parity test.** Exercise `RecordStartTelemetrySink` directly with injected breadcrumb + telemetry spies; each method must produce exactly one breadcrumb AND one matching PostHog call. A marker with a single sink is a defect.
- **Generation invalidation test.** Through the injected detector factory and a continuation-controlled fake `StreamingVad`, exercise preparation suspension and first-chunk suspension **separately**. For each suspension point, invalidate via `configureSession`, same-session `startMonitoring` replacement, and `finalizeAtStop` in turn; resume the old operation and assert no marker after invalidation is emitted. Also start a new run with the SAME session id and assert the old generation cannot emit into it.
- **Synchronous snapshot tests.** (1) Call `startMonitoring` with `backendA` while `audioCapture.currentAudioRoute == "routeA"`, mutate the live route to `"routeB"` before the task executes, and assert preparation, started, and completed all retain `backendA` / `routeA`. (2) Change the source session identity before the task executes and assert the superseded run emits no marker. (Corrected from an earlier single bullet that was self-contradictory: a dropped emission cannot also retain a snapshot.)
- **`model_reused` ordering test.** Using the injected detector factory, return an unready detector whose preparation is continuation-controlled; assert the first run reports `model_reused == false` after preparation completes. Then reuse that same now-ready detector and assert the next run reports `true`. This is the test that catches reading `isReady` on the wrong side of preparation.
- **`TelemetryService` schema test.** Under the existing DEBUG `testEventHook`, call all three `package` methods directly and assert fully-qualified event names, exact property keys, value types, and absence semantics. The sink parity test does NOT prove the names/serialisation owned by Services.
- **Full suite** via `scripts/xcode-test.sh`; read `Test run with N tests`, require nonzero and the expected count (RULE: verify-the-feature-not-the-crash).
- **Live UAT.** Confirm dictation completes with auto-stop on and off, and verify the three events arrive in order in PostHog dev. **`app.log` is NOT the oracle here** — neither `SentryBreadcrumb.add` nor `TelemetryService` writes to `AppLogger` (verified); app.log verifies dictation success only.
- **Overhead receipt.** One fixed prerecorded audio fixture through the existing recording UAT harness. Same machine, input route, backend, settings and PostHog dev configuration. Collect ≥30 successful warm samples from the exact baseline SHA and ≥30 from the exact instrumented SHA, alternating build order in blocks to limit thermal and time drift. Measure **external wall-clock from immediately before recording invocation through verified paste completion**, so all three synchronous PostHog writes are enclosed — `startMonitoring` runs after the session goes live (`RecordingSessionKernel.swift:2901`), so a narrower "record-start" window can end before the writes occur. Preserve raw samples; report per-arm count, median, p95, and instrumented-minus-baseline deltas. `monitor_to_first_chunk_ms` and `chunk_processing_latency_ms` are reported for diagnostic interpretation ONLY and cannot clear this criterion.

## 12. Blast radius & rollback

Blast radius: every recording emits three additional PostHog events and three Sentry breadcrumbs. VAD model configuration and lifecycle behaviour are unchanged. PostHog capture performs synchronous queue persistence, so record-start overhead is explicitly measured (§11).

Correction from grounded review: an earlier draft claimed the VAD model loads every recording. It does not — the detector is retained and reused unless the silence timeout changes (`CaptureVADSignalSource.swift:173-177`, `:199-205`), and `SilenceDetector.prepare` is idempotent (`:174-179`).

Rollback: single revert. No persisted state, no migration, no appcast implication.

## 13. Ship criteria

1. Latch, callback ordering, non-throwing-path, dual-channel parity, all three generation invalidations, synchronous snapshot, `model_reused` ordering, and `TelemetryService` schema tests pass; full suite green with a nonzero executed count.
2. Live UAT: dictation completes with auto-stop on and off; the three events arrive in order in PostHog dev. app.log confirms dictation success only, not marker delivery.
3. Overhead receipt in the PR: exact baseline and instrumented SHAs; fixed prerecorded fixture; identical machine, route, backend, settings and PostHog configuration; ≥30 successful warm invocation-to-paste samples per arm; raw samples, median, p95 and instrumented-minus-baseline deltas reported. Any statistically supported slowdown is resolved or explicitly accepted. `monitor_to_first_chunk_ms` and `chunk_processing_latency_ms` are reported separately and are NOT substitutes for this enclosing measurement.
4. Codex whole-diff review clean, then GitHub cloud review clean.
5. Save and verify the PostHog record-start funnel (`dictation.invoked` → `dictation.vad_preparation_completed` → `dictation.first_vad_chunk_started` → `dictation.first_vad_chunk_completed`), segmented by app version, OS version, hardware, backend and input route, against a development event before merge. Do NOT set an alert threshold until a real baseline exists — otherwise this repeats the same problem one layer up: data that exists but nobody reads.
6. Documented production read at 24 hours and 7 days: event coverage, stage drop-off, first-chunk latency, any new crash.
7. PR body and release notes state plainly that #1780 is NOT fixed and stays open. No "fixed #1780" release note.

## 14. Open questions

- **Founder decision required:** ship the compute-unit pin at all? Coverage review says hold; I agree on the evidence. Counter-argument for shipping: running a model under a configuration its library never selects is a defect regardless of #1780. Not blocking this PR either way.
- **Future, separate LARGE plan:** "defer, do not skip" — when live auto-stop is disabled, process the same complete 4,096-sample sequence after capture stops and before any segment consumer runs. Preserves final-segment semantics while removing VAD prediction from record-start. Not in this PR: it changes stop latency, moves work into the delivery path, and could burst badly on long recordings. Needs short/long benchmarks and exact segment-equivalence tests. Reducing prediction FREQUENCY stays rejected — FluidAudio's streaming state advances per processed chunk, so sampling every Nth chunk corrupts the segment clock.

## 15. Related

#1780 (crash, stays open), #1782 (Apple Intelligence default), #1224 (bundled VAD model), #1434 (degraded-lead salvage), #1543 (capture moved in-process).
