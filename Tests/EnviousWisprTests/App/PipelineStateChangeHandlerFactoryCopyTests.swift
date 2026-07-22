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
}
