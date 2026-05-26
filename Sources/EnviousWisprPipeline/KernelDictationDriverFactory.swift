import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Composition root for `KernelDictationDriver` (epic #827, PR-4b.2).
///
/// The App layer needs a `DictationPipeline`-conforming object but cannot
/// construct one directly: `RecordingSessionKernel`, `ParakeetEngineAdapter`,
/// `KernelHeartPathTelemetryObserver`, `LimbSteps`, `KernelFinalizationOutcome`,
/// `KernelSessionContext`, `KernelFinalizationWiring`, `HeartPathTelemetryEmitter`,
/// `KernelLifecycleTelemetrySink`, and `CaptureVADSignalSource` are all
/// module-internal by design (epic placement — none of those types are
/// App-visible). This factory builds the full stack from public-typed inputs
/// and returns the public driver.
///
/// PR-4b.4 swaps the App's the old Parakeet pipeline construction site for a
/// call to `KernelDictationDriverFactory.make(inputs:)`. PR-4b.2 ships the
/// factory production-unwired — no App caller invokes it yet.
@MainActor
public enum KernelDictationDriverFactory {

  /// All public-typed inputs. The factory constructs every internal type
  /// (`LimbSteps`, kernel, adapter, wiring, observer, sink, etc.) from these.
  public struct Inputs {
    public let audioCapture: any AudioCaptureInterface
    public let asrManager: any ASRManagerInterface
    public let transcriptStore: TranscriptStore
    public let keychainManager: KeychainManager
    public let captureTelemetry: CaptureTelemetryState
    public let pasteCompletionRegistry: PasteCompletionRegistry

    /// Explicit public init: Swift's synthesized memberwise init is `internal`
    /// and would prevent App callers from constructing `Inputs`.
    public init(
      audioCapture: any AudioCaptureInterface,
      asrManager: any ASRManagerInterface,
      transcriptStore: TranscriptStore,
      keychainManager: KeychainManager,
      captureTelemetry: CaptureTelemetryState,
      pasteCompletionRegistry: PasteCompletionRegistry
    ) {
      self.audioCapture = audioCapture
      self.asrManager = asrManager
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

  /// Build the driver stack and arm both observation arms before returning.
  public static func make(inputs: Inputs) -> KernelDictationDriver {
    // 1. LimbSteps — same instances driver + wiring hold by reference.
    let limbSteps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      llmPolish: LLMPolishStep(keychainManager: inputs.keychainManager)
    )

    // 2. Shared mutable holders.
    let outcome = KernelFinalizationOutcome()
    let context = KernelSessionContext()
    let telemetryState = KernelTelemetryState()

    // 3. VAD signal source.
    let vad = CaptureVADSignalSource()
    vad.bind(audioCapture: inputs.audioCapture)

    // 4. Parakeet adapter.
    let adapter = ParakeetEngineAdapter(asrManager: inputs.asrManager)

    // 4a. Polish-step backend stamp — sourced from the adapter's self-declared
    // identity so this site never hard-codes engine identity (PR-5 Rung 1).
    // Late-assigned after step 4 because `LLMPolishStep` is class-typed and
    // nothing between step 1 and here reads `llmPolish.backend`.
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
      captureTelemetry: inputs.captureTelemetry
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
      save: { transcript in try inputs.transcriptStore.save(transcript) },
      deliverPaste: { request in await PasteCascadeExecutor().deliver(request) },
      pasteCompletionRegistry: inputs.pasteCompletionRegistry
    )

    // 7. Kernel.
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: inputs.audioCapture,
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
    //     `context.config`, `inputs.audioCapture.currentAudioRoute`, and
    //     `inputs.captureTelemetry`. Internal type; never appears in `Inputs`.
    let lifecycleSink = KernelLifecycleTelemetrySink(
      backend: adapter.engineIdentity.backendType,
      audioCapture: inputs.audioCapture,
      context: context,
      outcome: outcome,
      captureTelemetry: inputs.captureTelemetry,
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
      audioCapture: inputs.audioCapture,
      emitter: emitter,
      emitLifecycleEvent: { [lifecycleSink] event in lifecycleSink.emit(event) }
    )

    // 10. Driver.
    let driver = KernelDictationDriver(
      kernel: kernel,
      observer: observer,
      outcome: outcome,
      context: context,
      steps: limbSteps
    )
    driver.start()  // arms driver-side state observation (PR-4a)

    // Observer's `observeKernelState()` is the PR-4b.1 split of the old
    // `observer.start()` — the factory drives it after construction since
    // the App-side `start()` shim no longer exists.
    observer.observeKernelState()

    return driver
  }
}
