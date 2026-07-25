Short answer: the premise is false. A hard fault inside CoreML/Espresso/BNNS cannot be contained inside the same process. Without a process boundary, the only way to eliminate that crash class is to stop executing that CoreML path.

My practical recommendation is: align the model configuration, then add a one-strike local quarantine that disables VAD after an incomplete first prediction and deliberately reports `.unavailable`. That prevents another four-crash loop, but it cannot save the first crash.

## Q0 — Challenge the premise

### Missing premise 1: Swift cannot contain this hard fault

The current `do/catch` at `Sources/EnviousWisprAudio/SilenceDetector.swift:240-258` contains a thrown `MLModel`/FluidAudio error. It cannot contain `SIGSEGV`, `SIGBUS`, `SIGABRT`, or an `EXC_BAD_ACCESS`.

The hard-fault boundary is deeper:

- FluidAudio writes through raw `MLMultiArray` pointers at `.build/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadManager.swift:208-258`.
- It enters the synchronous CoreML prediction at `VadManager.swift:268`.
- The enclosing Swift actor at `SilenceDetector.swift:107` serializes access; it does not provide another address space.

Apple describes Swift errors as recoverable thrown values, while crash reports treat bad memory access as an unrecoverable process failure. Apple’s signal documentation also warns that almost everything beyond setting a flag in a signal handler is unsafe. [Swift error handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/), [Apple crash-report guidance](https://developer.apple.com/documentation/xcode/analyzing-a-crash-report), [Apple `sigaction` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/sigaction.2.html).

Exact design text:

> This design does not claim in-process crash containment. A SIGSEGV, SIGBUS, SIGABRT, or EXC_BAD_ACCESS raised during CoreML/Espresso/BNNS execution terminates the application process. `do/catch`, `Result`, actors, tasks, queues, timeouts, Objective-C exception wrappers, signal handlers, and Mach exception handlers are not credited as containment. Under the no-new-process constraint, only not executing this implementation eliminates this hard-fault class.

If “the silence detector must be unable to crash the app” is literal and covers every possible detector bug, a separate address space is required. A replacement written in Swift can remove this CoreML crash class, but even Swift can trap or call unsafe system libraries.

### Missing premise 2: “no detector” and “detector found no speech” are already different states

The rejected `vadAutoStop` gate remains correctly rejected. But deliberate health-based VAD unavailability is not equivalent to returning permanently empty segments from a prepared detector.

The current contract says:

- `.confirmedNoSpeech` may skip ASR: `Sources/EnviousWisprPipeline/VADSignalSource.swift:63-72` and `RecordingSessionKernel.swift:1628-1674`.
- `.unavailable` explicitly lets ASR run.
- When no prepared detector exists, finalization publishes `[]` plus `.unavailable`: `CaptureVADSignalSource.swift:401-407`.
- Empty segments then make conditioning a raw-audio no-op: `CapturedAudioConditioner.swift:84-99`.
- WhisperKit also runs raw ASR without clip timestamps: `WhisperKitEngineAdapter.swift:654-690`.

Exact design text:

> A deliberately disabled or quarantined VAD MUST represent “no detector ran,” not “the detector confirmed no speech.” It MUST leave `directDetectorPrepared == false`, publish `.unavailable`, return `[]` segments, and continue raw ASR. It MUST NOT publish `.confirmedNoSpeech`.

That avoids the silent dead-air discard. It still loses auto-stop, VAD conditioning, tail information, degraded-lead gating and WhisperKit clip ranges. That is a real quality cost, but different from losing the raw transcript.

## Q1 — Pathways

### 1. Align the configuration and accept the remaining risk

Mechanism: load the bundled model using FluidAudio’s actual default configuration.

Exact Swift:

```swift
import CoreML
@preconcurrency import FluidAudio
import Foundation

// Inside BundledVADModelLoader.loadModel(in:)
let configuration = MLModelConfigurationUtils.defaultConfiguration()
return try MLModel(contentsOf: url, configuration: configuration)
```

This belongs at the sole model-construction point, `Sources/EnviousWisprAudio/BundledVADModelLoader.swift:19-34`. Changing only `VadConfig.computeUnits` would do nothing: the preloaded-model initializer merely stores that configuration at `.build/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadManager.swift:102-107`; only FluidAudio’s separate loading path reads it at `:124-145`.

- Contains: recoverable model-loading errors, through the existing readiness handling.
- May reduce: hard-fault probability if `.all` produced a different CoreML execution plan.
- Does not contain: hard faults, hangs or wrong answers.
- Cost: compute scheduling and possibly small numerical/segment differences.
- Fair case for it: one unexplained installation, extensive negative reproduction, same in-process stack works elsewhere, and the divergence is real.
- Fair limit: the crash was on CPU/BNNS and `.cpuAndNeuralEngine` still permits CPU.

### 2. Add a one-strike crash-loop quarantine

Mechanism: use a local marker around the first VAD prediction. A stale marker on next launch means the preceding process never completed that prediction, so VAD is quarantined and the recording uses `.unavailable`.

Exact contract:

> After successful model preparation and before making the detector eligible to run, atomically arm a local first-prediction marker. Clear it only after `SilenceDetector.processChunk` returns and `dictation.first_vad_chunk_completed` has been emitted. Clear it on a normal stop in which no first chunk ran. If the next launch finds the marker stale, or if arming it fails, do not make the detector prepared: run the max-duration monitor with `detector: nil` and publish `.unavailable`. Key quarantine by VAD model hash, FluidAudio revision, compute-unit configuration, OS build and Mac model. Retry only when that tuple changes or through an explicit canary.

- Contains: repeat hard faults and repeat hangs in the guarded interval.
- Does not contain: the first hard fault or wrong answers.
- Cost: synchronous local metadata work, false quarantine if the app is killed during the short armed interval, and degraded VAD functionality thereafter.
- Owner: `CaptureVADSignalSource`, which already owns detector preparation, monitor selection and fail-open evidence at `CaptureVADSignalSource.swift:225-335` and `:401-413`.

### 3. Deliberately disable CoreML VAD

This is the pure subtraction path: do not construct or invoke the CoreML detector for a quarantined tuple, affected OS/hardware combination, or emergency cached kill switch.

Exact contract:

> VAD disablement is a health policy, never an alias for the user’s `vadAutoStop` preference. The decision must be available locally before recording; network availability must not gate record-start. The disabled path passes `detector: nil`, retains max-duration protection, publishes `.unavailable`, and sends raw capture to ASR.

- Contains: every CoreML VAD hard fault, hang and wrong answer while disabled, because no prediction occurs.
- Does not contain: other app faults.
- Cost: no silence auto-stop or segment-driven conditioning/routing.

### 4. Replace the CoreML detector

Replace Silero/CoreML with a non-CoreML detector, such as a carefully validated energy/spectral detector, while preserving the existing shared VAD signal contract.

The existing seam is `StreamingVad` at `Sources/EnviousWisprAudio/SilenceDetector.swift:5-26`. Both engines must continue to receive the single shared source created at `KernelDictationDriverFactory.swift:237-253`.

Exact contract:

> The replacement MUST preserve one result for every 4,096-sample chunk, the monotonically advancing sample clock, speech-start/end boundaries, open-segment finalization and the `.voiced` / `.confirmedNoSpeech` / `.unavailable` distinction. It may replace the detector implementation in `EnviousWisprAudio`; it may not create separate Parakeet and WhisperKit VAD owners.

- Contains: this CoreML/Espresso/BNNS failure class.
- Does not contain: traps or hard faults in the replacement, or wrong segmentation.
- Cost: substantial correctness validation across quiet speech, noise, soft onsets and tails.

### 5. Simplify FluidAudio’s input-buffer path

Remove pooled `MLMultiArray` reuse and create fresh correctly shaped input arrays per call. Validate counts and finite values before prediction.

Exact experiment text:

> Replace the three `memoryOptimizer.getPooledBuffer` calls at `VadManager.swift:216-229` with fresh `MLMultiArray` allocations of identical shape and type. Keep model, state progression and prediction API unchanged. Credit the experiment only if it changes the crash or produces a reproducible memory-safety signal; do not call it containment.

- Contains: only a proven pooling, lifetime, shape or aliasing defect.
- Does not contain: arbitrary CoreML hard faults or hangs.
- Cost: allocations every 256 ms, possible latency/energy churn and a maintained FluidAudio fork.

### 6. Reuse the existing ASR XPC process

This is the only path that contains the hard fault without adding a second helper process. Move VAD execution into the existing ASR service.

The target already imports Audio and FluidAudio at `Project.swift:323-344`, but the VAD resource currently exists only in the app target at `Project.swift:392-399`. The service is explicitly Parakeet-only today at `Sources/EnviousWisprASRService/ASRServiceHandler.swift:6-18`.

Exact contract:

> Move, do not duplicate, VAD model ownership into the existing ASR service. Extend `ASRServiceProtocol` with start, ordered-chunk and finalize operations. On service invalidation or deadline expiry, the host MUST publish `.unavailable` and continue from its retained raw capture. This pathway is accepted only after fault injection proves that killing the helper during VAD still yields a raw pasted transcript for both engines.

- Contains: VAD hard faults; the app survives.
- Can contain hangs only with a host deadline plus connection invalidation.
- Does not contain: wrong answers.
- Cost: chunk IPC, ordering/backpressure, resource packaging and new coupling between a limb and ASR.

### 7. Defer VAD

For auto-stop-off sessions, process the complete sequence after capture rather than live. This is already described at `docs/feature-requests/issue-1780-2026-07-24-record-start-observability.md:319-322`.

- Before ASR/paste: removes the record-start exposure but still lets VAD kill the app before text delivery.
- After paste: protects the delivered transcript, but VAD can no longer affect that dictation’s conditioning or decoder ranges.
- Does not contain the hard fault.
- Cost: burst work on long recordings, stop latency, or loss of current-dictation consumers.

Exact disposition:

> Deferred VAD is an exposure-reduction or transcript-first pathway. It MUST NOT be described as crash containment.

### 8. Actor, task, thread, timeout, exception or signal wrappers

- `do/catch`: contains only thrown errors.
- Actor/serial queue: contains races through serialization, not process faults.
- Detached worker plus timeout: may let the caller stop waiting, but cannot safely terminate a wedged CoreML thread.
- Signal/Mach exception recovery: process state, Swift frames and CoreML locks may already be corrupt.

Exact disposition:

> Reject all same-address-space wrappers as a hard-fault containment claim. Keep the existing actor for serialization and the existing `do/catch` for recoverable errors only.

### 9. Crash recovery and relaunch

The existing spool is a best-effort recovery limb on a background queue: `Sources/EnviousWisprAudio/RecoverySpoolWriter.swift:5-14` and `AudioCaptureManager.swift:1078-1113`.

- Contains: some post-crash audio loss when the spool was armed and sufficiently flushed.
- Does not contain: the crash, immediate paste failure, the unsaved tail or recovery failures.
- Cost: the brand-new user still sees an app crash and no immediate text.

Exact disposition:

> Crash recovery may remain defence in depth. It MUST NOT be credited as VAD containment, and the recovery owner MUST NOT also become the VAD health/quarantine owner.

### 10. A dedicated VAD helper

This is the clean containment baseline: XPC invalidation converts the helper crash into an unavailable VAD result. Apple explicitly states that XPC services run in another process and can be restarted after crashing. [Apple XPC](https://developer.apple.com/documentation/XPC).

It violates the founder’s stated constraint and reintroduces the distributed lifecycle cost documented in `docs/heartpath-refactor/DECISIONS.md:55-91`. But it is the only honest way to retain this exact CoreML implementation while making its first hard fault nonfatal to both the app and ASR process.

## Q2 — Strongest argument against every pathway

1. **Configuration only:** it is not causal evidence. The proposed configuration still permits the observed CPU/BNNS path.  
   Exact correction: describe it as “configuration alignment and risk reduction,” never “the #1780 fix.”

2. **Crash-loop quarantine:** it cannot save the first crash and can falsely quarantine after a force-quit or unrelated crash. It also risks adding a second health owner beside `VADModelReadinessTracker` at `CaptureVADSignalSource.swift:53-58`.  
   Exact correction:

   > Do not add a parallel quarantine Boolean. Replace the current typed readiness state with one authority that can represent `unknown`, `ready`, `broken` and `quarantined`; keep storage mechanics injected and keep the execution decision in `CaptureVADSignalSource`.

3. **Global/tuple disable:** it removes multiple useful consumers, not just auto-stop.  
   Exact correction: limit it to health quarantine or an evidence-backed denylist; never bind it to the user’s auto-stop preference.

4. **Replacement detector:** a mediocre VAD can silently damage far more dictations than this crash. ASR-native endpointing would also add Parakeet and WhisperKit owners for a concern currently owned once.  
   Exact correction: keep one source and require downstream-equivalence evidence, including dead-air routing, conditioned samples, tail preservation and final text.

5. **Fresh buffers:** it targets an unproven hypothesis. The crash occurred at first-use and the guard-page probe was negative. Repeated allocation can create a different performance problem.  
   Exact correction: allow one bounded paired experiment; stop if it produces neither a crash signal nor measurable memory-safety evidence.

6. **Existing ASR XPC:** the VAD limb could now kill the ASR helper. That may preserve the app window while losing the raw transcript—the wrong reliability trade. XPC replies are also serialized, as the protocol itself warns at `Sources/EnviousWisprCore/ASRServiceProtocol.swift:98-105`.  
   Exact correction: reject until process-kill UAT proves raw paste for both engines and proves VAD calls cannot head-of-line block ASR.

7. **Deferral:** it relocates the crash. Before paste, it still breaks the heart; after paste, its current consumers are too late.  
   Exact correction: call it transcript-first only if paste completion is the hard boundary.

8. **Same-process wrappers:** they create false confidence around corrupted process state.  
   Exact correction: the Q0 hard-fault paragraph should be a plan-level acceptance criterion.

9. **Recovery:** it changes “lost forever” into “possibly recoverable later,” not “heart never failed.”  
   Exact correction: report recovery separately from immediate text delivery.

10. **Dedicated helper:** it cleanly solves containment but pays exactly the process-boundary cost the founder rejected.  
    Exact correction: reconsider it only if literal first-fault containment outranks D-028.

## Q3 — Placement challenge

I rank the crash-loop quarantine first among the no-new-process substitutes.

The correct policy owner is `CaptureVADSignalSource` because it already owns:

- detector creation and preparation: `CaptureVADSignalSource.swift:241-312`;
- detector versus nil monitor selection: `:325-335`;
- the final `.unavailable` versus `.confirmedNoSpeech` decision: `:401-413`.

Exact ownership text:

> `CaptureVADSignalSource` is the sole owner of whether VAD executes for a recording and which speech-evidence state is published. The persistent guard store reports only marker facts; it does not decide fallback.

The strongest alternative owner is `SilenceDetector`, because it is closest to `MLModel.prediction`.

The cost of choosing it is worse ownership: the Audio module would now need persistent product policy and would have to influence Pipeline’s `.unavailable` decision. It could stop making predictions, but it cannot by itself prevent Pipeline from interpreting a prepared detector with no segments as `.confirmedNoSpeech`. That splits execution health from fallback semantics.

## Q4 — Evidence that would change my ranking

1. **Affected-environment A/B:** reproduce on the original Mac/macOS 14.2.1 combination with `.all`, then show the same unchanged workload survives with `.cpuAndNeuralEngine`. That would move configuration-only to first.  
   Obtainable only with the original machine or a matching environment. A VM is partial evidence because the observed stack was CPU, but it cannot reproduce all hardware scheduling.

2. **Post-fix recurrence:** one configuration-aligned build producing `first_vad_chunk_started` without `first_vad_chunk_completed`, paired with a matching Sentry CoreML crash, would demote configuration-only immediately. A second distinct installation would move deliberate quarantine/disablement above observation.  
   Obtainable with the merged Sentry/PostHog funnel.

3. **Equivalent exposure with zero recurrence:** after the aligned build accumulates at least the same number of first-recording VAD starts as the affected release, with no matching incomplete pair or crash, configuration-only could move above quarantine. That is evidence of reduced risk, not proof of impossibility.

4. **Quarantine overhead:** use the five-scenario paired harness to enclose marker arm/clear through verified paste. Any statistically supported median or p95 regression—or meaningful false quarantine during normal stop/cancel tests—moves quarantine down.  
   Obtainable now.

5. **Fault-injection receipt:** deliberately terminate the app during the guarded first-chunk interval, relaunch, and prove both engines paste raw text with VAD reported unavailable. This determines whether quarantine actually prevents the second crash loop.  
   Obtainable with a separate UAT harness; a unit test cannot survive its own process death.

6. **Replacement correctness:** compare segment boundaries, speech evidence, conditioner route, tail handling, WhisperKit clip ranges and final transcript—not merely latency—over quiet speech, noise, soft onset and long-tail fixtures. If a non-CoreML detector is equivalent, replacement moves near the top.  
   Obtainable, but the current latency harness alone is insufficient.

7. **Existing-XPC proof:** kill the ASR service during VAD preparation and prediction for both engines. If the app reliably reconstructs raw ASR and the five-scenario harness shows no meaningful paste delay or reply blocking, reusing that boundary moves above replacement.  
   Obtainable, but it must test the heart result, not merely app survival.

## Q5 — Industry precedent

What is genuinely common:

- Small first-party CoreML models run in the application process. FluidAudio’s documented streaming example constructs `VadManager` in a Swift `Task` and invokes it directly; its documented default is `.cpuAndNeuralEngine`. [FluidAudio VAD API](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md#voice-activity-detection)
- Muesli publicly documents “in-process CoreML/ANE” and Silero VAD through FluidAudio. [Muesli](https://github.com/Muesli-HQ/muesli)
- CoreML’s documented recoverable failures are ordinary thrown prediction errors. [Apple CoreML integration](https://developer.apple.com/documentation/coreml/integrating-a-core-ml-model-into-your-app)

So the common small-model practice is: configure the model deliberately, serialize state, catch documented errors, measure performance and collect crash reports. It is not hard-fault containment.

What is genuinely common when host survival is mandatory:

- Another process. Apple’s Audio Unit design makes the trade explicit: out-of-process prevents a misbehaving plug-in from crashing the host; opting into in-process removes IPC overhead but gives up that stability boundary. [Apple Audio Unit guidance](https://developer.apple.com/documentation/audiotoolbox/incorporating-audio-effects-and-instruments)
- XPC services are launched and restarted separately by `launchd`. [Apple XPC](https://developer.apple.com/documentation/XPC)

What is merely possible, not responsible precedent:

- catching fatal signals and continuing;
- `setjmp`/`longjmp` across CoreML/Swift frames;
- Mach exception tricks;
- moving prediction to a thread and abandoning it after a timeout.

Apple’s signal manual says most operations from a signal handler have undefined behaviour and handlers should do little more than set a flag.

The competitor evidence is useful but limited. Spokenly, Vox and FluidVoice running the same library in-process without this observed crash supports “rare environment-specific failure,” not “our configuration is equivalent” or “the component cannot crash.”

Exact precedent wording:

> Public precedent supports in-process VAD as common practice and process isolation as the only real hard-fault boundary. Competitor non-reproduction is negative evidence about frequency only; it is not evidence of their compute units, model lifecycle or crash-containment design.

## Unhedged ranking

Under the no-new-process constraint:

1. **Configuration alignment plus a one-strike local quarantine to `.unavailable`.**
2. **Configuration alignment alone**, if the marker mechanism cannot clear the latency and false-quarantine gates.
3. **Evidence-backed tuple disablement** using the existing raw-ASR fallback.
4. **A validated non-CoreML replacement.**
5. **Reuse the existing ASR XPC**, only after process-kill heart-path proof.
6. **Fresh-buffer FluidAudio experiment.**
7. **Deferral.**
8. **Recovery, threads, timeouts, signals or exception wrappers—they are not containment.**

The plan must not say “VAD is unable to crash the app.” The honest no-new-process promise is:

> VAD remains in-process, so its first hard fault can still terminate the app. The model configuration is aligned with FluidAudio, the fault interval is observable, and an incomplete first prediction quarantines VAD on relaunch so subsequent dictations fail open to raw ASR.

If literal first-fault nonfatality is non-negotiable, I would reject every no-new-process design. A process boundary is the answer.