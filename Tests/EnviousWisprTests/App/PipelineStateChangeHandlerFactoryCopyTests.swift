import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

// MARK: - #1408 A1 — the post-completion interruption copy matrix

/// The factory is the SINGLE copy authority for the interruption pill (plan
/// §21.2 A1). These tests drive a factory-built handler end to end and pin the
/// EXACT sentence for each (disclosure × lead-trim) cell, so the copy cannot
/// drift and only a verified device removal can ever claim the microphone.
///
/// The two "Microphone disconnected" strings are founder-approved (2026-07-09).
/// The two "Recording interrupted" strings are provisional pending founder
/// sign-off (plan §21.3); when the wording lands, this file is the one place
/// the tests change.
@MainActor
@Suite("PipelineStateChangeHandlerFactory — interruption copy matrix (#1408)")
struct PipelineStateChangeHandlerFactoryCopyTests {

  @MainActor
  private final class WarningBox {
    var messages: [String] = []
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
      minimumRecordingTicks: 0)
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(),
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: outcome,
      context: context, steps: steps, adapter: adapter)
    let deps = PipelineStateChangeHandlerFactory.Deps(
      showOverlay: { _ in },
      cancelPendingWarning: {},
      schedulePostCompletionWarning: { box.messages.append($0) },
      appendTranscript: { _ in },
      onDurableSave: { _ in },
      inputMode: { nil },
      driver: driver)
    return PipelineStateChangeHandlerFactory.make(backendLabel: "parakeet", deps: deps)
  }

  private static let expectedCopy: [(CompletionInterruptionDisclosure, Bool, String)] = [
    (.deviceRemoved, false, "Microphone disconnected. Text may be cut short."),
    (.deviceRemoved, true, "Microphone disconnected. Words may be missing."),
    (.otherInterruption, false, "Recording interrupted. Text may be cut short."),
    (.otherInterruption, true, "Recording interrupted. Words may be missing."),
  ]

  @Test("each (disclosure × lead-trim) cell schedules its exact sentence")
  func copyMatrixIsExact() {
    for (disclosure, alsoTrimmedLead, expected) in Self.expectedCopy {
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
        box.messages == [expected],
        "disclosure=\(disclosure) alsoTrimmedLead=\(alsoTrimmedLead)")
    }
  }

  /// Only a VERIFIED removal may name the microphone. If this ever fails, a
  /// user whose engine died with the mic still attached is being lied to.
  @Test("the neutral family never mentions the microphone")
  func neutralCopyNeverClaimsTheMicrophone() {
    for (disclosure, alsoTrimmedLead, expected) in Self.expectedCopy
    where disclosure == .otherInterruption {
      _ = alsoTrimmedLead
      #expect(!expected.localizedCaseInsensitiveContains("microphone"))
      #expect(!expected.localizedCaseInsensitiveContains("mic"))
    }
  }

  /// Rule 6: no em/en-dashes in user-facing copy.
  @Test("no em or en dashes in any interruption sentence")
  func noDashesInCopy() {
    for (_, _, expected) in Self.expectedCopy {
      #expect(!expected.contains("\u{2014}"))
      #expect(!expected.contains("\u{2013}"))
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
    #expect(box.messages.isEmpty)
  }
}
