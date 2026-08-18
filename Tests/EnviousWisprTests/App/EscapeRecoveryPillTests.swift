import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// The Escape Recovery pill (#2087, chunk 8).
///
/// Not the pixels. Two properties are worth pinning: that the WHOLE payload
/// travels from the completion to the panel, and that the spoken sentence names
/// History.
///
/// The payload matters because it holds the paste TARGET — the app and field the
/// dictation was aimed at, captured before the terminal cleanup nils them. An
/// earlier version of this chunk passed only the row id, which compiled, showed
/// a pill, and quietly made the feature's promise ("put it back where it was
/// going") unreachable. The id alone is not enough, and nothing would have said so.
///
/// It carries no TEXT, which was right: the dwell is three seconds during which
/// the row can be deleted or expire, so whoever pastes re-reads by id and finds
/// nothing rather than restoring from a copy the store no longer agrees with.
///
/// History matters because a VoiceOver user who misses a three-second dwell needs
/// the unhurried door, and the pill must never be the only way back to the text.
///
/// `RecordingOverlayPanel.show(...)` traps on an implicitly-unwrapped nil in a
/// unit context, so the panel is not driven here; the wiring is asserted at the
/// factory, which is where it is load-bearing.
@MainActor
/// Class: `.productOutcome` — the offer itself: the one visible promise the feature makes.
@Suite("Escape Recovery pill (#2087)", .tags(.productOutcome))
struct EscapeRecoveryPillTests {

  @Test("the completion's whole payload reaches the panel, target included")
  func payloadReachesThePanel() {
    let box = IntentBox()
    let handler = Self.makeHandler(recording: box)
    let first = UUID()
    let second = UUID()

    let firstPayload = CancelUndoPayload(
      transcriptID: first, targetApp: nil, targetElement: nil)
    let secondPayload = CancelUndoPayload(
      transcriptID: second, targetApp: nil, targetElement: nil)

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: Transcript(text: "held"),
      historySaved: true,
      historySaveReason: nil,
      escapeRecoveryCompletion: .saved(firstPayload))
    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: Transcript(text: "held again"),
      historySaved: true,
      historySaveReason: nil,
      escapeRecoveryCompletion: .saved(secondPayload))

    // IDENTITY, not equality of ids. `targetApp` and `targetElement` are nil in
    // a unit context, so a factory that rebuilt the payload from the id alone —
    // discarding both handles, which is exactly the bug this chunk shipped and
    // fixed — would pass an id comparison and fail this.
    #expect(box.payloads.count == 2)
    #expect(box.payloads.first === firstPayload)
    #expect(box.payloads.last === secondPayload)
  }

  #if DEBUG
    /// Panel replacement can be DEFERRED while the overlay is being dragged, so
    /// an outgoing pill's callbacks can fire after a NEWER pill has stored its
    /// payload. Unguarded, the old view's expiry silently revokes the offer the
    /// user is currently looking at, and its Paste restores the new row from a
    /// press aimed at different text.
    ///
    /// Tested against the guard directly: `show(intent:)` traps in a unit host,
    /// so there is no way to reach this through the panel's public surface.
    ///
    /// Driven through the PRODUCTION closures, which is the whole point: the
    /// guard helper passing in isolation says nothing about whether either
    /// callback actually consults it, and an unguarded read inside one of them
    /// is exactly the defect being prevented.
    ///
    /// Debug-only, because reaching those closures without `show(intent:)` needs
    /// the `#if DEBUG` seam. The seam stays DEBUG-gated rather than `package` so
    /// no shipped code can set a paste target it did not earn — which costs this
    /// one test in Release, the same structural trade the rest of the suite
    /// makes.
    @Test("a superseded pill's callbacks cannot touch the newer payload")
    func supersededPillCannotTouchTheNewerPayload() {
      let panel = RecordingOverlayPanel()
      let live = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      let pasted = PayloadBox()

      panel.setEscapeRecoveryPayloadForTesting(live)

      // A pill that has already been superseded — its id is not the live one.
      let stale = panel.escapeRecoveryCallbacksForTesting(
        shownID: UUID(), paste: { pasted.payloads.append($0) })

      stale.onPaste()
      #expect(pasted.payloads.isEmpty, "a stale press must not paste the newer offer")
      #expect(
        panel.escapeRecoveryPayloadForTesting === live,
        "and must not consume it either")

      stale.onExpire()
      #expect(
        panel.escapeRecoveryPayloadForTesting === live,
        "a superseded pill expiring must not revoke the offer the user can see")

      // The live pill's own callbacks still work, or the guard is just a block.
      let current = panel.escapeRecoveryCallbacksForTesting(
        shownID: live.transcriptID, paste: { pasted.payloads.append($0) })

      current.onPaste()
      #expect(pasted.payloads.count == 1, "the matching pill pastes exactly once")
      #expect(pasted.payloads.first === live, "and delivers its own payload, whole")
      #expect(
        panel.escapeRecoveryPayloadForTesting == nil,
        "consumed, so a second press reaches nothing")

      current.onPaste()
      #expect(pasted.payloads.count == 1, "a second press on the same pill pastes nothing")
    }

    /// A paste handler is external code, and it may present an overlay of its
    /// own while it runs. Because `hide()` clears the payload SYNCHRONOUSLY, a
    /// teardown that runs after the handler would wipe whatever the handler just
    /// installed — the offer the user is now looking at revoked by the one they
    /// just accepted.
    ///
    /// So the order is consume, tear down, then hand control out. Nothing binds
    /// `onEscapeRecoveryPaste` yet, so this pins the order for chunk 8b rather
    /// than describing a live path.
    @Test("a paste handler that presents its own offer keeps it")
    func pasteHandlerReentrancyKeepsTheNewOffer() {
      let panel = RecordingOverlayPanel()
      let live = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      let replacement = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      let pasted = PayloadBox()

      panel.setEscapeRecoveryPayloadForTesting(live)

      let callbacks = panel.escapeRecoveryCallbacksForTesting(
        shownID: live.transcriptID,
        paste: { delivered in
          pasted.payloads.append(delivered)
          // The handler presents a new offer while the paste is still running.
          panel.setEscapeRecoveryPayloadForTesting(replacement)
        })

      callbacks.onPaste()

      #expect(pasted.payloads.first === live, "the accepted offer is still delivered whole")
      #expect(
        panel.escapeRecoveryPayloadForTesting === replacement,
        "and the offer raised DURING the paste survives our teardown")
    }
  #endif

  /// The control. An ordinary completion raises no pill, which is the whole of
  /// this chunk's inertness: nothing constructs the intent until a completion
  /// exists to construct it from.
  @Test("an ordinary completion raises no pill")
  func ordinaryCompletionRaisesNoPill() {
    let box = IntentBox()
    let handler = Self.makeHandler(recording: box)

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: Transcript(text: "an ordinary dictation"),
      historySaved: true,
      historySaveReason: nil)

    let pills = box.intents.filter {
      if case .escapeRecovery = $0 { return true } else { return false }
    }
    #expect(pills.isEmpty)
  }

  /// The founder-locked copy, asserted against its spoken equivalent. They have
  /// to agree: the announcement promises the button's action by name, so the
  /// button cannot be relabelled without the sentence changing with it. It did
  /// its job on 2026-08-18 — a rename of the title alone left the sentence
  /// promising an action no button offered, and this is the assertion that
  /// refused it.
  @Test("the pill's copy and its spoken announcement agree")
  func copyAgreesWithTheAnnouncement() {
    #expect(DictationNarrator.escapeRecoveryPillTitle == "Transcript cancelled")
    #expect(DictationNarrator.escapeRecoveryPillAction == "Undo")

    let spoken = DictationNarrator.announcement(
      for: OverlayIntent.escapeRecovery(transcriptID: UUID()))
    #expect(
      spoken.contains(DictationNarrator.escapeRecoveryPillAction),
      "the announcement names the action the button offers")
    #expect(
      spoken.localizedCaseInsensitiveContains("History"),
      "and names History, because the pill must not be the only door")
    #expect(
      spoken.contains("Warning") == false && spoken.contains("Error") == false,
      "nothing went wrong — a cancelled take that was kept is not a fault")
  }

  /// The payload must not outlive its offer. Replacement is the exit with no
  /// teardown of its own — the pill is simply overwritten by the next intent —
  /// and a payload surviving it could paste a later recovery into the app THIS
  /// one was aimed at.
  ///
  /// The RULE is tested, not the assignment: `show(intent:)` posts to
  /// `NSApp.mainWindow` on every arm and traps in a unit host, so the one line
  /// that consults this is not unit-drivable. Enumerated over the whole intent
  /// set so a sixteenth case cannot default into retaining.
  @Test("only the pill itself keeps the paste target alive")
  func onlyThePillRetainsItsTarget() {
    let others: [OverlayIntent] = [
      .hidden, .recording(audioLevel: 0), .processing(phase: .transcribing),
      .clipboardFallback, .accessibilityToast, .warning(reason: .polishFailed),
      .error(reason: .asrFailed), .advisory(reason: .zeroSignal),
      .interruption(reason: .deviceRemoved),
      .cachingModel(engineLabel: "Parakeet v3"), .engineReady,
      .recoveringLastRecording, .recoverySucceeded, .bluetoothAwareness,
    ]
    for intent in others {
      #expect(
        RecordingOverlayPanel.retainsEscapeRecoveryPayload(intent) == false,
        "\(intent) replaces the pill, so it must drop the target with it")
    }
    #expect(
      RecordingOverlayPanel.retainsEscapeRecoveryPayload(
        .escapeRecovery(transcriptID: UUID())))
  }

  /// Unbound in production today, which is the other half of inertness: even if
  /// the pill were somehow raised, a press would reach nobody. Binding it to the
  /// paste cascade is chunk 8b's, and needs chunk 9's pending-row read.
  @Test("a fresh panel has no paste handler bound")
  func handlerIsUnboundByDefault() {
    #expect(RecordingOverlayPanel().onEscapeRecoveryPaste == nil)
  }

  // MARK: Helpers

  private final class IntentBox {
    var intents: [OverlayIntent] = []
    var payloads: [CancelUndoPayload] = []
  }

  /// Collects what the pill's own paste callback actually delivered.
  private final class PayloadBox {
    var payloads: [CancelUndoPayload] = []
  }

  private static func makeHandler(recording box: IntentBox) -> PipelineStateChangeHandler {
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
      showOverlay: { box.intents.append($0) },
      cancelPendingWarning: {},
      schedulePostCompletionWarning: { _ in },
      appendTranscript: { _ in },
      onDurableSave: { _ in },
      inputMode: { nil },
      driver: driver,
      presentEscapeRecoveryPill: { box.payloads.append($0) })
    return PipelineStateChangeHandlerFactory.make(backendLabel: "parakeet", deps: deps)
  }
}
