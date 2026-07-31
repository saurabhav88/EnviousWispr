import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

// MARK: - #1408 A1 / #1567 E3 — the post-completion interruption REASON matrix

/// The factory forwards a typed `RecordingWarningReason` for each planner effect;
/// #1567 moved the sentence authoring to `DictationNarrator` (the copy oracle now
/// lives in `DictationNarratorTests`). These tests drive a factory-built handler
/// end to end and pin the EXACT reason for each (disclosure × lead-trim) cell, so
/// the disclosure→reason mapping cannot drift and only a verified device removal
/// can ever be forwarded as `.deviceRemoved`.
@MainActor
@Suite("PipelineStateChangeHandlerFactory — interruption reason matrix (#1408/#1567)")
struct PipelineStateChangeHandlerFactoryCopyTests {

  @MainActor
  private final class WarningBox {
    var reasons: [RecordingWarningReason] = []
  }

  /// A factory-built handler whose only live seam is the warning recorder.
  /// `inputMode` returns nil so completion telemetry early-returns; the
  /// transcript carries no recovery session so no cleanup fires.
  private func makeHandler(recording box: WarningBox) -> PipelineStateChangeHandler {
    let steps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      emojiRestore: EmojiRestoreStep())
    let outcome = KernelFinalizationOutcome()
    let context = KernelSessionContext()
    let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      currentTick: { 0 }, sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _ in }, deliver: { _ in .pasted },
      engineMutationScope: .alwaysAllowedForTesting,
      minimumRecordingTicks: 0)
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(),
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: outcome,
      context: context, steps: steps, adapter: adapter,
      engineMutationScope: .alwaysAllowedForTesting)
    let deps = PipelineStateChangeHandlerFactory.Deps(
      showOverlay: { _ in },
      cancelPendingWarning: {},
      schedulePostCompletionWarning: { box.reasons.append($0) },
      appendTranscript: { _ in },
      onDurableSave: { _ in },
      inputMode: { nil },
      driver: driver)
    return PipelineStateChangeHandlerFactory.make(backendLabel: "parakeet", deps: deps)
  }

  private static let cells: [(CompletionInterruptionDisclosure, Bool)] = [
    (.deviceRemoved, false),
    (.deviceRemoved, true),
    (.otherInterruption, false),
    (.otherInterruption, true),
  ]

  @Test("each (disclosure × lead-trim) cell forwards its exact interruptedTail reason")
  func reasonMatrixIsExact() {
    for (disclosure, alsoTrimmedLead) in Self.cells {
      let box = WarningBox()
      let handler = makeHandler(recording: box)
      handler.handle(
        to: PipelineState.complete,
        pipelineOverlayIntent: .hidden,
        lastPolishError: nil,
        currentTranscript: Transcript(text: "hello", backendType: .parakeet),
        historySaved: true,
        historySaveReason: nil,
        salvagedLead: alsoTrimmedLead,
        interruptionDisclosure: disclosure)
      #expect(
        box.reasons == [.interruptedTail(disclosure: disclosure, alsoTrimmedLead: alsoTrimmedLead)],
        "disclosure=\(disclosure) alsoTrimmedLead=\(alsoTrimmedLead)")
    }
  }

  /// A normal completion (nil disclosure) schedules nothing.
  @Test("a normal completion schedules no interruption pill")
  func normalCompletionSchedulesNothing() {
    let box = WarningBox()
    let handler = makeHandler(recording: box)
    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: Transcript(text: "hello", backendType: .parakeet),
      historySaved: true,
      historySaveReason: nil,
      salvagedLead: false,
      interruptionDisclosure: nil)
    #expect(box.reasons.isEmpty)
  }

  // MARK: - #1714: the terminal stamps, driven through the PRODUCTION owners
  //
  // Asserting `TelemetryService` directly proves the SERVICE carries the field.
  // It says nothing about whether the two production call sites actually pass
  // it. These drive a real kernel to a frozen source, build a real driver, and
  // go through the factory handler — so deleting either stamp turns them red.
  //
  // `#if DEBUG` because `testEventHook` and `CapturedTelemetryEvent` are compiled
  // out of release builds, and CI compiles the test target in Release as well as
  // running it in Debug — so an unguarded reference passes every local Debug run
  // and fails `build-release` only. Same gate and same reason as
  // `OllamaReadinessGateTests` and `HeartPathTelemetryWiringTests`.
  #if DEBUG
    private final class EventBox: @unchecked Sendable {
      var event: CapturedTelemetryEvent?
    }

    /// A factory handler whose driver's kernel has really frozen `source`.
    private func makeAttributedHandler(source: String?) async -> PipelineStateChangeHandler {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: clock)
      let capture = FakeAudioCapture()
      capture.stabilizationResults = [true]
      capture.inputResolutionSourcePerAttempt = [source]
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: FakeVADSignalSource(), clock: clock,
        paste: FakePasteTarget())

      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      #expect(wrapper.testKernel.lastInputResolutionSource == source)

      let steps = LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        emojiRestore: EmojiRestoreStep())
      let observer = KernelHeartPathTelemetryObserver(
        kernel: wrapper.testKernel, audioCapture: capture,
        emitter: HeartPathTelemetryEmitter(
          backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
        emitLifecycleEvent: { _ in })
      let driver = KernelDictationDriver(
        kernel: wrapper.testKernel, observer: observer,
        outcome: KernelFinalizationOutcome(), context: KernelSessionContext(),
        steps: steps, adapter: engine,
        engineMutationScope: .alwaysAllowedForTesting)
      let box = WarningBox()
      let deps = PipelineStateChangeHandlerFactory.Deps(
        showOverlay: { _ in },
        cancelPendingWarning: {},
        schedulePostCompletionWarning: { box.reasons.append($0) },
        appendTranscript: { _ in },
        onDurableSave: { _ in },
        inputMode: { "ptt" },
        driver: driver)
      return PipelineStateChangeHandlerFactory.make(backendLabel: "parakeet", deps: deps)
    }

    @Test("factory completion stamps the driver's final input source")
    func completionStampsFinalInputSource() async {
      let handler = await makeAttributedHandler(source: "list_fallback")
      let box = EventBox()
      let previous = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = previous }

      handler.handle(
        to: PipelineState.complete,
        pipelineOverlayIntent: .hidden,
        lastPolishError: nil,
        currentTranscript: Transcript(text: "hello", backendType: .parakeet),
        historySaved: true,
        historySaveReason: nil)

      #expect(box.event?.name == "dictation.completed")
      #expect(box.event?.stringProps["input_resolution_source"] == "list_fallback")
    }

    @Test("factory failure stamps the driver's final input source")
    func failureStampsFinalInputSource() async {
      let handler = await makeAttributedHandler(source: "list_fallback")
      let box = EventBox()
      let previous = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = previous }

      handler.handle(
        to: PipelineState.error(.deviceRemoved),
        pipelineOverlayIntent: .error(reason: .deviceRemoved),
        lastPolishError: nil,
        currentTranscript: nil,
        historySaved: true,
        historySaveReason: nil)

      #expect(box.event?.name == "pipeline.failed")
      #expect(box.event?.stringProps["input_resolution_source"] == "list_fallback")
    }

    @Test("factory failure omits an unavailable input source")
    func failureOmitsUnavailableInputSource() async {
      let handler = await makeAttributedHandler(source: nil)
      let box = EventBox()
      let previous = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = previous }

      handler.handle(
        to: PipelineState.error(.deviceRemoved),
        pipelineOverlayIntent: .error(reason: .deviceRemoved),
        lastPolishError: nil,
        currentTranscript: nil,
        historySaved: true,
        historySaveReason: nil)

      #expect(box.event?.name == "pipeline.failed")
      #expect(box.event?.stringProps.keys.contains("input_resolution_source") == false)
    }
  #endif  // DEBUG (#1714 terminal-stamp tests — TelemetryService.testEventHook)
}
