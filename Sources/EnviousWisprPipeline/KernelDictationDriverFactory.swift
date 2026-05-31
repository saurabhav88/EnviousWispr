import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Composition root for `KernelDictationDriver` (epic #827, PR-4b.2; PR-5 Rung 4
/// added the second-engine branch; PR-5 Rung 5 narrowed the factory surface
/// from `public` to `package` and added the shared VAD signal source seam).
///
/// The App layer needs a `KernelDictationDriver` but cannot construct one
/// directly: `RecordingSessionKernel`, `ParakeetEngineAdapter`,
/// `WhisperKitEngineAdapter`, `KernelHeartPathTelemetryObserver`, `LimbSteps`,
/// `KernelFinalizationOutcome`, `KernelSessionContext`, `KernelFinalizationWiring`,
/// `HeartPathTelemetryEmitter`, `KernelLifecycleTelemetrySink`, and
/// `CaptureVADSignalSource` are all module-internal-or-package by design (epic
/// placement — none of those types are App-visible as public surface). This
/// factory builds the full stack from package-typed inputs and returns the
/// public driver.
///
/// PR-4b.4 swapped the App's the old Parakeet pipeline construction site for a
/// call to `KernelDictationDriverFactory.makeForParakeet(inputs:)`. PR-5 Rung 5
/// flipped the App's WhisperKit construction site onto the WhisperKit branch
/// and added `makeSharedVADSignalSource(audioCapture:)` so the App owns the
/// single `CaptureVADSignalSource` shared between both drivers — preventing
/// the second factory call from overwriting the first driver's
/// `audioCapture.onVADAutoStop` binding.
@MainActor
public enum KernelDictationDriverFactory {

  /// Heart-path infrastructure-error sink. Defaults to the global
  /// `SentryBreadcrumb.captureError` so production behavior is byte-identical;
  /// tests inject a per-instance spy/no-op closure so a pipeline-under-test
  /// never touches the process-global `SentryBreadcrumb.captureErrorDelegate`.
  /// That global is the cross-test pollution vector behind the release-config
  /// one-per-run flake (#875): a `@MainActor` test suspended at an `await`
  /// yields the main actor to a sibling test whose pipeline fires
  /// `captureError` into whatever delegate is currently installed. Injecting
  /// the sink removes pipelines-under-test from that path entirely.
  /// Carries the optional `RecordingSnapshot` so this one sink can stand in for
  /// EVERY heart-path `captureError` route under the driver — the emitter
  /// (always `snapshot: nil`), `KernelLifecycleTelemetrySink`'s plain and
  /// snapshot-carrying variants, and the driver's direct `.asrInterrupted`
  /// emit. A single injected sink therefore observes all of them, so the
  /// cancellation "zero Sentry errors" test catches a regression through any
  /// path — not only the emitter (Codex review #875).
  package typealias HeartPathCaptureErrorSink = @MainActor (
    _ error: any Error,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?,
    _ snapshot: SentryBreadcrumb.RecordingSnapshot?
  ) -> Void

  /// The production default — forwards to the global `SentryBreadcrumb`,
  /// including the snapshot (nil collapses to the no-snapshot call, so every
  /// consumer stays byte-identical to its prior in-line default). Named once
  /// here so both inputs structs share one source of truth.
  package static let defaultCaptureErrorSink: HeartPathCaptureErrorSink = {
    error, category, stage, extra, snapshot in
    SentryBreadcrumb.captureError(
      error, category: category, stage: stage, extra: extra, snapshot: snapshot)
  }

  /// Package-typed inputs for the Parakeet engine branch. Narrowed from
  /// `public` to `package` in PR-5 Rung 5: the only consumers are the
  /// `EnviousWispr` App target and `EnviousWisprTests`, both in the same
  /// Swift package, so `package` is the right access level for these inputs
  /// after `CaptureVADSignalSource` (a stored field below) widened to
  /// `package` to be shareable across drivers.
  package struct ParakeetInputs {
    package let audioCapture: any AudioCaptureInterface
    package let asrManager: any ASRManagerInterface
    package let vadSignalSource: CaptureVADSignalSource
    package let transcriptStore: TranscriptStore
    package let keychainManager: KeychainManager
    package let captureTelemetry: CaptureTelemetryState
    package let pasteCompletionRegistry: PasteCompletionRegistry
    /// Heart-path error sink (defaulted to the production global). See
    /// `HeartPathCaptureErrorSink`.
    package let captureErrorSink: HeartPathCaptureErrorSink
    /// App-owned output-safety classifier holder (#832/#913 PR8). Optional —
    /// nil when no classifier (tests, or before prewarm). Read lazily at polish
    /// time by `LLMPolishStep`.
    package let outputClassifierHolder: OutputClassifierHolder?

    /// Explicit package init: Swift's synthesized memberwise init is `internal`
    /// and would prevent App callers from constructing this struct. `@MainActor`
    /// because `captureErrorSink`'s default is a main-actor-isolated value;
    /// every caller (App init, `@MainActor` test suites) is already on the
    /// main actor.
    @MainActor
    package init(
      audioCapture: any AudioCaptureInterface,
      asrManager: any ASRManagerInterface,
      vadSignalSource: CaptureVADSignalSource,
      transcriptStore: TranscriptStore,
      keychainManager: KeychainManager,
      captureTelemetry: CaptureTelemetryState,
      pasteCompletionRegistry: PasteCompletionRegistry,
      captureErrorSink: @escaping HeartPathCaptureErrorSink = defaultCaptureErrorSink,
      outputClassifierHolder: OutputClassifierHolder? = nil
    ) {
      self.audioCapture = audioCapture
      self.asrManager = asrManager
      self.vadSignalSource = vadSignalSource
      self.transcriptStore = transcriptStore
      self.keychainManager = keychainManager
      self.captureTelemetry = captureTelemetry
      self.pasteCompletionRegistry = pasteCompletionRegistry
      self.captureErrorSink = captureErrorSink
      self.outputClassifierHolder = outputClassifierHolder
    }
  }

  /// Package-typed inputs for the WhisperKit engine branch (PR-5 Rung 4;
  /// access narrowed in Rung 5). Carries the WhisperKit-flavored dependencies:
  /// the model-owning backend actor and the LID actor.
  package struct WhisperKitInputs {
    package let audioCapture: any AudioCaptureInterface
    package let whisperKitBackend: WhisperKitBackend
    package let languageDetector: LanguageDetector
    package let vadSignalSource: CaptureVADSignalSource
    package let transcriptStore: TranscriptStore
    package let keychainManager: KeychainManager
    package let captureTelemetry: CaptureTelemetryState
    package let pasteCompletionRegistry: PasteCompletionRegistry
    /// Heart-path error sink (defaulted to the production global). See
    /// `HeartPathCaptureErrorSink`.
    package let captureErrorSink: HeartPathCaptureErrorSink
    /// App-owned output-safety classifier holder (#832/#913 PR8). See
    /// `ParakeetInputs.outputClassifierHolder`.
    package let outputClassifierHolder: OutputClassifierHolder?

    /// Explicit package init — same reasoning as `ParakeetInputs.init`.
    /// `languageDetector` is intentionally non-optional (no default) so the
    /// production caller in Rung 5 must explicitly pass the `LanguageDetector`
    /// it already constructs with `onLanguageFlip` telemetry wiring
    /// (epic plan §3.4, council consensus 2026-05-27). `@MainActor` for the
    /// same reason as `ParakeetInputs.init` — the `captureErrorSink` default
    /// is main-actor-isolated.
    @MainActor
    package init(
      audioCapture: any AudioCaptureInterface,
      whisperKitBackend: WhisperKitBackend,
      languageDetector: LanguageDetector,
      vadSignalSource: CaptureVADSignalSource,
      transcriptStore: TranscriptStore,
      keychainManager: KeychainManager,
      captureTelemetry: CaptureTelemetryState,
      pasteCompletionRegistry: PasteCompletionRegistry,
      captureErrorSink: @escaping HeartPathCaptureErrorSink = defaultCaptureErrorSink,
      outputClassifierHolder: OutputClassifierHolder? = nil
    ) {
      self.audioCapture = audioCapture
      self.whisperKitBackend = whisperKitBackend
      self.languageDetector = languageDetector
      self.vadSignalSource = vadSignalSource
      self.transcriptStore = transcriptStore
      self.keychainManager = keychainManager
      self.captureTelemetry = captureTelemetry
      self.pasteCompletionRegistry = pasteCompletionRegistry
      self.captureErrorSink = captureErrorSink
      self.outputClassifierHolder = outputClassifierHolder
    }
  }

  @MainActor
  private final class TelemetryRelay {
    var kernel: RecordingSessionKernel?
    var recordingStopped: (@MainActor (Int) -> Void)?

    func emitRecordingStopped(sampleCount: Int) {
      recordingStopped?(sampleCount)
    }

    func modelLoadWedgeTelemetry() -> KernelModelLoadWedgeTelemetry? {
      kernel?.modelLoadWedgeTelemetry
    }
  }

  /// PR-5 Rung 5 (#827): construct the App-owned shared VAD signal source.
  /// Called exactly once by `EnviousWisprApp.init` after `audioCapture` exists
  /// and BEFORE either `makeForParakeet` / `makeForWhisperKit` runs. The
  /// returned source is passed into both inputs structs so the two drivers
  /// share a single binding to `audioCapture.onVADAutoStop` — preventing the
  /// second driver's construction from silently overwriting the first
  /// driver's VAD callback (Codex r2 new defect 1).
  ///
  /// `architecture/vadSignalSourceHasSingleConstructionSite` enforces that
  /// the VAD-source type's constructor only appears here in `Sources/`.
  package static func makeSharedVADSignalSource(
    audioCapture: any AudioCaptureInterface
  ) -> CaptureVADSignalSource {
    let vad = CaptureVADSignalSource()
    vad.bind(audioCapture: audioCapture)
    return vad
  }

  /// Build the driver stack for the Parakeet engine and arm both observation
  /// arms before returning. Live App caller in `EnviousWisprApp`.
  package static func makeForParakeet(inputs: ParakeetInputs) -> KernelDictationDriver {
    // PR-6 (#827): concrete adapter construction is owned by
    // `KernelAdapterFactory` (the single construction site). This file no
    // longer names a concrete adapter type in code (EngineIdentityFreezeTests
    // Test B); it assembles around the opaque `any ASREngineAdapter` returned.
    let adapter = KernelAdapterFactory.makeParakeetAdapter(asrManager: inputs.asrManager)
    return assembleDriver(
      adapter: adapter,
      audioCapture: inputs.audioCapture,
      vadSignalSource: inputs.vadSignalSource,
      transcriptStore: inputs.transcriptStore,
      keychainManager: inputs.keychainManager,
      captureTelemetry: inputs.captureTelemetry,
      pasteCompletionRegistry: inputs.pasteCompletionRegistry,
      captureErrorSink: inputs.captureErrorSink,
      outputClassifierHolder: inputs.outputClassifierHolder)
  }

  /// Build the driver stack for the WhisperKit engine. PR-5 Rung 5 flips the
  /// App caller from the legacy `WhisperKitPipeline` to this entry point;
  /// the deleted `EngineIdentityFreezeTests.makeForWhisperKitHasNoProductionCaller`
  /// invariant inverts to `makeForWhisperKitHasExactlyOneProductionCaller`
  /// (locked in the same architecture freeze file).
  package static func makeForWhisperKit(inputs: WhisperKitInputs) -> KernelDictationDriver {
    // PR-5 Rung 4.5 (#827): plumb the audio-capture session-id source to the
    // adapter so it can snapshot at `beginSession` (race-safe for delayed LID
    // perf signposts like `t_clipboard_write`).
    // PR-6 (#827): concrete adapter construction is owned by
    // `KernelAdapterFactory`; this file names no concrete adapter type in code.
    let captureSource = inputs.audioCapture
    let adapter = KernelAdapterFactory.makeWhisperKitAdapter(
      backend: inputs.whisperKitBackend,
      languageDetector: inputs.languageDetector,
      audioCaptureSessionIDSource: { captureSource.currentCaptureSessionID })
    return assembleDriver(
      adapter: adapter,
      audioCapture: inputs.audioCapture,
      vadSignalSource: inputs.vadSignalSource,
      transcriptStore: inputs.transcriptStore,
      keychainManager: inputs.keychainManager,
      captureTelemetry: inputs.captureTelemetry,
      pasteCompletionRegistry: inputs.pasteCompletionRegistry,
      captureErrorSink: inputs.captureErrorSink,
      outputClassifierHolder: inputs.outputClassifierHolder)
  }

  /// Engine-agnostic assembler. The two package entry points construct their
  /// engine-specific adapter and hand it here; every step below reads identity
  /// through `adapter.engineIdentity.backendType` (PR-5 Rung 1) so this body
  /// stays engine-agnostic and `EngineIdentityFreezeTests` keeps catching any
  /// reintroduction of a hard-coded engine-identity case literal here.
  private static func assembleDriver(
    adapter: any ASREngineAdapter,
    audioCapture: any AudioCaptureInterface,
    vadSignalSource: CaptureVADSignalSource,
    transcriptStore: TranscriptStore,
    keychainManager: KeychainManager,
    captureTelemetry: CaptureTelemetryState,
    pasteCompletionRegistry: PasteCompletionRegistry,
    captureErrorSink: @escaping HeartPathCaptureErrorSink,
    outputClassifierHolder: OutputClassifierHolder? = nil
  ) -> KernelDictationDriver {
    // 1. LimbSteps — same instances driver + wiring hold by reference.
    // #832/#913 PR8: the live-dictation LLMPolishStep receives the app-owned
    // output-safety classifier holder (read lazily at polish time).
    let llmPolish = LLMPolishStep(keychainManager: keychainManager)
    llmPolish.outputClassifierHolder = outputClassifierHolder
    let limbSteps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      llmPolish: llmPolish
    )

    // 2. Shared mutable holders.
    let outcome = KernelFinalizationOutcome()
    let context = KernelSessionContext()
    let telemetryState = KernelTelemetryState()

    // 3. VAD signal source — App-owned and shared across drivers. The single
    //    construction of the source type lives in
    //    `makeSharedVADSignalSource(audioCapture:)`. Two-driver safety:
    //    `audioCapture.onVADAutoStop` is bound exactly once when the App
    //    builds the shared source, so the second factory call cannot
    //    overwrite the first driver's binding (Codex r2 new defect 1).
    let vad = vadSignalSource

    // 4a. Polish-step backend stamp — sourced from the adapter's self-declared
    // identity so this site never hard-codes engine identity (PR-5 Rung 1).
    // Late-assigned after limbSteps construction because `LLMPolishStep` is
    // class-typed and nothing between step 1 and here reads `llmPolish.backend`.
    limbSteps.llmPolish.backend = adapter.engineIdentity.backendType
    // PR-4b.4 of #827: a non-nil `onToken` callback is the discriminant that
    // tells `GeminiConnector` to use `streamGenerateContent?alt=sse` instead
    // of batch `generateContent`. The old Parakeet pipeline set this to a
    // no-op closure for the same purpose; preserve that behavior so Gemini
    // polish stays on the streaming endpoint post-cutover. Live token UI is
    // a separate follow-up; this callback intentionally discards tokens.
    limbSteps.llmPolish.onToken = { _ in }

    // 5. Telemetry emitter (factory-internal; App never sees it). The
    //    capture-error sink is threaded from inputs (defaulted to the global
    //    `SentryBreadcrumb.captureError`), so production is byte-identical and
    //    tests inject a per-instance sink to stay off the process-global
    //    delegate (#875 cross-test pollution fix).
    let emitter = HeartPathTelemetryEmitter(
      backend: adapter.engineIdentity.backendType,
      captureTelemetry: captureTelemetry,
      // The emitter never carries a snapshot — adapt the unified sink down to
      // its snapshot-less shape.
      captureError: { error, category, stage, extra in
        captureErrorSink(error, category, stage, extra, nil)
      }
    )

    let telemetryRelay = TelemetryRelay()

    // 6. Finalization wiring (closures over store + paste).
    let textProcessingRunner = TextProcessingRunner()
    let wiring = KernelFinalizationWiring(
      outcome: outcome,
      context: context,
      adapter: adapter,
      steps: limbSteps,
      textProcessingRunner: textProcessingRunner,
      save: { transcript in try transcriptStore.save(transcript) },
      deliverPaste: { request in await PasteCascadeExecutor().deliver(request) },
      pasteCompletionRegistry: pasteCompletionRegistry
    )

    // 7. Kernel.
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: audioCapture,
      vad: vad,
      currentTick: wiring.currentTick,
      sleepTicks: wiring.sleepTicks,
      processText: wiring.processText,
      store: wiring.store,
      deliver: wiring.deliver,
      // Production wedge-stall window — `RecordingSessionKernel` defaults
      // to 2 ticks (test-only value); with the wiring's 100ms tick clock
      // that would cancel cold model loads after ~200ms instead of the
      // documented 10-tick / 1000ms production window. Pass the production
      // constant explicitly so cold loads don't get false-positive wedged.
      wedgeStallTicks: KernelFinalizationWiring.wedgeStallTicks,
      zombieZeroPeakTelemetry: { ctx in
        emitter.zombieZeroPeak(ctx: ctx)
      },
      recordingStoppedTelemetry: { sampleCount in
        telemetryRelay.emitRecordingStopped(sampleCount: sampleCount)
      },
      markPipelineTimingStart: {
        outcome.pipelineStartedAtSeconds = CFAbsoluteTimeGetCurrent()
      },
      markASRTimingStart: { streaming in
        outcome.asrStartedAtSeconds = CFAbsoluteTimeGetCurrent()
        outcome.streamingMode = streaming
      },
      markASRTimingEnd: {
        outcome.asrEndedAtSeconds = CFAbsoluteTimeGetCurrent()
      },
      telemetryState: telemetryState
    )
    telemetryRelay.kernel = kernel

    // 8. Lifecycle sink (r6) — emits the PR-1 §B.7.2 kernel-owned events
    //     when the observer's lifecycle-event callback fires. Reads
    //     `context.config`, `audioCapture.currentAudioRoute`, and
    //     `captureTelemetry`. Internal type; never appears in inputs.
    let lifecycleSink = KernelLifecycleTelemetrySink(
      backend: adapter.engineIdentity.backendType,
      audioCapture: audioCapture,
      context: context,
      outcome: outcome,
      captureTelemetry: captureTelemetry,
      telemetryState: telemetryState,
      modelLoadWedgeTelemetry: { telemetryRelay.modelLoadWedgeTelemetry() },
      // Route both lifecycle captureError variants through the same injected
      // sink so a test observing one sink sees every error this sink can emit
      // (Codex review #875). Production stays byte-identical: the default sink
      // forwards (error, …, snapshot) to `SentryBreadcrumb.captureError`.
      captureError: { error, category, stage, extra in
        captureErrorSink(error, category, stage, extra, nil)
      },
      captureErrorWithSnapshot: { error, category, stage, extra, snapshot in
        captureErrorSink(error, category, stage, extra, snapshot)
      },
      // Div 6 of seam audit (TP:273-291): route `.noAudioCaptured` through
      // the emitter so the rich payload (sourceType, isActivelyCapturing,
      // device IDs) AND the stall/XPC-failure dedup contract reach Sentry —
      // both were lost when the sink shipped the basic-error fallback.
      noAudioCapturedRich: { [emitter] ctx in emitter.noAudioCaptured(ctx: ctx) }
    )
    telemetryRelay.recordingStopped = { [lifecycleSink] sampleCount in
      lifecycleSink.emitRecordingStopped(sampleCount: sampleCount)
    }

    // 9. Observer (constructed AFTER kernel — needs the kernel ref). The
    //    lifecycle callback closes over the internal sink so the observer's
    //    emit-side stays decoupled from Sentry / PostHog wiring.
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel,
      audioCapture: audioCapture,
      emitter: emitter,
      emitLifecycleEvent: { [lifecycleSink] event in lifecycleSink.emit(event) }
    )

    // 10. Driver. Pass the unified sink so the driver's direct
    //     `.asrInterrupted` captureError emit (XPC crash fallback) also routes
    //     through the injected sink — full parity with the old global delegate
    //     spy for tests (Codex review #875).
    let driver = KernelDictationDriver(
      kernel: kernel,
      observer: observer,
      outcome: outcome,
      context: context,
      steps: limbSteps,
      adapter: adapter,
      captureErrorSink: captureErrorSink
    )
    driver.start()  // arms driver-side state observation (PR-4a)

    // Observer's `observeKernelState()` is the PR-4b.1 split of the old
    // `observer.start()` — the factory drives it after construction since
    // the App-side `start()` shim no longer exists.
    observer.observeKernelState()

    return driver
  }
}
