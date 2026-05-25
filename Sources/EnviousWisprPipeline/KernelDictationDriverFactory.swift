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
/// PR-4b.4 swaps the App's `TranscriptionPipeline` construction site for a
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

    // 3. VAD signal source. PR-4b.4 decides whether to call `bind(audioCapture:)`
    //    here or leave the App's `AudioEventRouter` as the `onVADAutoStop`
    //    owner; PR-4b.2 does not call `bind()` from the factory.
    let vad = CaptureVADSignalSource()

    // 4. Parakeet adapter.
    let adapter = ParakeetEngineAdapter(asrManager: inputs.asrManager)

    // 5. Telemetry emitter (factory-internal; App never sees it).
    let emitter = HeartPathTelemetryEmitter(
      backend: .parakeet,
      captureTelemetry: inputs.captureTelemetry
    )

    // 5a. Lifecycle sink (r6) — emits the PR-1 §B.7.2 kernel-owned events
    //     when the observer's lifecycle-event callback fires. Reads
    //     `context.config`, `inputs.audioCapture.currentAudioRoute`, and
    //     `inputs.captureTelemetry`. Internal type; never appears in `Inputs`.
    let lifecycleSink = KernelLifecycleTelemetrySink(
      backend: .parakeet,
      audioCapture: inputs.audioCapture,
      context: context,
      captureTelemetry: inputs.captureTelemetry
    )

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
      deliver: wiring.deliver
    )

    // 8. Observer (constructed AFTER kernel — needs the kernel ref). The
    //    lifecycle callback closes over the internal sink so the observer's
    //    emit-side stays decoupled from Sentry / PostHog wiring.
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel,
      audioCapture: inputs.audioCapture,
      emitter: emitter,
      emitLifecycleEvent: { [lifecycleSink] event in lifecycleSink.emit(event) }
    )

    // 9. Driver.
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
