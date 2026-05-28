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
/// The App layer needs a `DictationPipeline`-conforming object but cannot
/// construct one directly: `RecordingSessionKernel`, `ParakeetEngineAdapter`,
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

    /// Explicit package init: Swift's synthesized memberwise init is `internal`
    /// and would prevent App callers from constructing this struct.
    package init(
      audioCapture: any AudioCaptureInterface,
      asrManager: any ASRManagerInterface,
      vadSignalSource: CaptureVADSignalSource,
      transcriptStore: TranscriptStore,
      keychainManager: KeychainManager,
      captureTelemetry: CaptureTelemetryState,
      pasteCompletionRegistry: PasteCompletionRegistry
    ) {
      self.audioCapture = audioCapture
      self.asrManager = asrManager
      self.vadSignalSource = vadSignalSource
      self.transcriptStore = transcriptStore
      self.keychainManager = keychainManager
      self.captureTelemetry = captureTelemetry
      self.pasteCompletionRegistry = pasteCompletionRegistry
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

    /// Explicit package init — same reasoning as `ParakeetInputs.init`.
    /// `languageDetector` is intentionally non-optional (no default) so the
    /// production caller in Rung 5 must explicitly pass the `LanguageDetector`
    /// it already constructs with `onLanguageFlip` telemetry wiring
    /// (epic plan §3.4, council consensus 2026-05-27).
    package init(
      audioCapture: any AudioCaptureInterface,
      whisperKitBackend: WhisperKitBackend,
      languageDetector: LanguageDetector,
      vadSignalSource: CaptureVADSignalSource,
      transcriptStore: TranscriptStore,
      keychainManager: KeychainManager,
      captureTelemetry: CaptureTelemetryState,
      pasteCompletionRegistry: PasteCompletionRegistry
    ) {
      self.audioCapture = audioCapture
      self.whisperKitBackend = whisperKitBackend
      self.languageDetector = languageDetector
      self.vadSignalSource = vadSignalSource
      self.transcriptStore = transcriptStore
      self.keychainManager = keychainManager
      self.captureTelemetry = captureTelemetry
      self.pasteCompletionRegistry = pasteCompletionRegistry
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
    let adapter = ParakeetEngineAdapter(asrManager: inputs.asrManager)
    return assembleDriver(
      adapter: adapter,
      audioCapture: inputs.audioCapture,
      vadSignalSource: inputs.vadSignalSource,
      transcriptStore: inputs.transcriptStore,
      keychainManager: inputs.keychainManager,
      captureTelemetry: inputs.captureTelemetry,
      pasteCompletionRegistry: inputs.pasteCompletionRegistry)
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
    let captureSource = inputs.audioCapture
    let adapter = WhisperKitEngineAdapter(
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
      pasteCompletionRegistry: inputs.pasteCompletionRegistry)
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
    pasteCompletionRegistry: PasteCompletionRegistry
  ) -> KernelDictationDriver {
    // 1. LimbSteps — same instances driver + wiring hold by reference.
    let limbSteps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      llmPolish: LLMPolishStep(keychainManager: keychainManager)
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

    // 5. Telemetry emitter (factory-internal; App never sees it).
    let emitter = HeartPathTelemetryEmitter(
      backend: adapter.engineIdentity.backendType,
      captureTelemetry: captureTelemetry
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

    // 10. Driver.
    let driver = KernelDictationDriver(
      kernel: kernel,
      observer: observer,
      outcome: outcome,
      context: context,
      steps: limbSteps,
      adapter: adapter
    )
    driver.start()  // arms driver-side state observation (PR-4a)

    // Observer's `observeKernelState()` is the PR-4b.1 split of the old
    // `observer.start()` — the factory drives it after construction since
    // the App-side `start()` shim no longer exists.
    observer.observeKernelState()

    return driver
  }
}
