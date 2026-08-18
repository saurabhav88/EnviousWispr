import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// A kept recovery must release its audio, exactly as an ordinary dictation does
/// (#2087, chunk 12).
///
/// While a dictation runs, the app holds an encrypted backup of the recording so
/// a crash cannot lose it. On a normal completion the durable-save callback
/// deletes that spool, its key and its sidecars. The pending path did not call
/// it: the kept row was written, the pill was raised, and the AUDIO stayed on
/// disk until some later launch happened to clean it up.
///
/// That is not a tidiness bug. The setting's own copy says "the audio is deleted
/// once the text is saved", and the help centre repeats it. This suite exists
/// because a mutation battery could delete that call with every other test still
/// green — which is how it got shipped in the first place.
@MainActor
@Suite("Escape Recovery releases its spool (#2087)", .tags(.productOutcome))
struct EscapeRecoverySpoolReleaseTests {

  @MainActor
  private final class Spy {
    var durableSaves: [String] = []
    var pendingAppends: [Transcript] = []
    var ordinaryAppends: [Transcript] = []
  }

  private func makeHandler(_ spy: Spy) -> PipelineStateChangeHandler {
    let steps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      emojiRestore: EmojiRestoreStep())
    let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      currentTick: { 0 }, sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _, _ in }, deliver: { _, _ in .pasted },
      engineMutationScope: .alwaysAllowedForTesting,
      minimumRecordingTicks: 0)
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(),
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: KernelFinalizationOutcome(),
      context: KernelSessionContext(), steps: steps, adapter: adapter,
      engineMutationScope: .alwaysAllowedForTesting)
    let deps = PipelineStateChangeHandlerFactory.Deps(
      showOverlay: { _ in },
      cancelPendingWarning: {},
      schedulePostCompletionWarning: { _ in },
      appendTranscript: { spy.ordinaryAppends.append($0) },
      onDurableSave: { spy.durableSaves.append($0) },
      inputMode: { nil },
      driver: driver,
      appendPendingTranscript: { spy.pendingAppends.append($0) })
    return PipelineStateChangeHandlerFactory.make(backendLabel: "parakeet", deps: deps)
  }

  private func row(recoverySessionID: String?) -> Transcript {
    Transcript(
      text: "kept text", backendType: .parakeet,
      recoverySessionID: recoverySessionID,
      escapeRecoveredAt: Date(), escapeRecoveryTakeID: "take-1")
  }

  private func completeARecovery(_ handler: PipelineStateChangeHandler, row: Transcript) {
    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: row,
      historySaved: true,
      historySaveReason: nil,
      escapeRecoveryCompletion: .saved(
        CancelUndoPayload(transcriptID: row.id, targetApp: nil, targetElement: nil)))
  }

  @Test("a kept recovery deletes this take's audio spool")
  func keptRecoveryReleasesItsSpool() {
    let spy = Spy()
    let handler = makeHandler(spy)
    let kept = row(recoverySessionID: "spool-abc")

    completeARecovery(handler, row: kept)

    #expect(
      spy.pendingAppends.map(\.id) == [kept.id],
      "control: the row itself still reaches History, or this test proves nothing")
    #expect(
      spy.durableSaves == ["spool-abc"],
      """
      the text is durable, so the encrypted audio has nothing left to protect. \
      Skipping this leaves a recording on disk that the setting's own copy \
      promises is already gone.
      """)
  }

  /// Not every take has a spool.
  ///
  /// Crash recovery is a separate setting, and with it off there is no spool to
  /// arm and no id to release. The call must be conditional, not unconditional
  /// with a placeholder — a delete request for an id that never existed is a
  /// failure the coordinator would have to absorb every single time.
  @Test("a kept recovery with no crash-recovery session releases nothing")
  func noSpoolMeansNoRelease() {
    let spy = Spy()
    let handler = makeHandler(spy)

    completeARecovery(handler, row: row(recoverySessionID: nil))

    #expect(spy.pendingAppends.count == 1, "control: the row is still kept")
    #expect(spy.durableSaves.isEmpty, "there was never a spool for this take")
  }

  /// The two paths must agree, and this is the assertion that says so.
  ///
  /// The ordinary path has released its spool since #1063. The bug was that the
  /// kept path forked away from it and quietly dropped the obligation, so this
  /// pins the ordinary side too — if someone ever removes it from THERE, the
  /// pair stops matching and one of these two tests says so.
  @Test("an ordinary completion releases its spool the same way")
  func ordinaryCompletionAlsoReleases() {
    let spy = Spy()
    let handler = makeHandler(spy)

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: Transcript(
        text: "hello", backendType: .parakeet, recoverySessionID: "spool-xyz"),
      historySaved: true,
      historySaveReason: nil)

    #expect(spy.ordinaryAppends.count == 1)
    #expect(spy.pendingAppends.isEmpty, "control: this is not a recovery")
    #expect(spy.durableSaves == ["spool-xyz"])
  }
}
