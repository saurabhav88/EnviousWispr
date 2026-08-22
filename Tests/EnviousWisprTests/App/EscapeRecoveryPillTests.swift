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
/// **The overlay IS driven here now (#2292).** It used to be that
/// `RecordingOverlayPanel.show(...)` trapped on an implicitly-unwrapped nil in a
/// unit context, so the panel could not be exercised and the wiring was asserted
/// at the factory instead. `OverlayDirector` refuses to draw without a screen
/// rather than trapping, so the custody rules below run through the production
/// path.
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

  /// **Custody, driven through the DIRECTOR rather than a DEBUG seam.**
  ///
  /// These two used to reach the panel's callbacks through
  /// escapeRecoveryCallbacksForTesting, because `show(...)` trapped in a unit
  /// context and the real path could not be driven. The director can be driven,
  /// so they now exercise the production route: present, press, observe. That is
  /// strictly better coverage, and it is why they are rewritten rather than
  /// deleted (#2292).
  @Test("a superseded pill's press cannot touch the newer payload")
  func supersededPillCannotTouchTheNewerPayload() {
    let d = OverlayTestDouble.headlessDirector()
    let stale = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    let live = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)

    d.presentEscapeRecovery(stale, actions: { _ in })
    // A newer offer replaces it. The director's custody follows the OFFER.
    d.presentEscapeRecovery(live, actions: { _ in })

    #expect(
      d.takeEscapeRecoveryPayload(matching: stale.transcriptID) == nil,
      "a superseded pill could still reach a payload, so a stale press would paste")
    #expect(d.takeEscapeRecoveryPayload(matching: live.transcriptID) != nil)
  }

  /// The take is ONE-SHOT, which is what makes a repeated press safe: the second
  /// finds nothing rather than pasting twice.
  @Test("a payload can be taken exactly once")
  func payloadIsTakenOnce() {
    let d = OverlayTestDouble.headlessDirector()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)

    d.presentEscapeRecovery(payload, actions: { _ in })

    #expect(d.takeEscapeRecoveryPayload(matching: payload.transcriptID) != nil)
    #expect(
      d.takeEscapeRecoveryPayload(matching: payload.transcriptID) == nil,
      "a second press pasted the same transcript again")
  }


  // MARK: - Pressing Paste takes the offer down with it (#2292 C9)

  /// **An accepted offer must leave the screen**, and the cutover left it up.
  ///
  /// `pillActions` consumed the payload and started the restore without
  /// dismissing anything, so the pill sat there until its dwell expired — an
  /// offer the user had already taken, with a Paste button that now did nothing
  /// at all, because the one-shot take had spent the payload. A live-looking
  /// button that is inert is worse than no button.
  @Test("pressing Paste takes the pill down")
  func pressingPasteDismissesTheOffer() {
    let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pasted: [UUID] = []
    let actions = Self.pillActions(director: d, onPaste: { pasted.append($0.transcriptID) })

    d.presentEscapeRecovery(payload, actions: actions)
    // Read off the HOST rather than the director's debug seams, so this case
    // compiles and runs in the Release lane too. `currentPresentationForTesting`
    // lives inside `#if DEBUG`, and a Release build that cannot see it fails to
    // COMPILE with zero failure marks — invisible to a Debug-only run.
    #expect(host.isShowing, "the pill never went up")

    actions(.pasteEscapeRecovery(transcriptID: payload.transcriptID))

    #expect(pasted == [payload.transcriptID], "the press did not reach the paste handler")
    #expect(!host.isShowing, "the window still shows a pill the user already accepted")
  }

  /// **The ORDER is the half a reader would drop**, and the shipped panel
  /// carries a comment saying why: the paste handler may present its OWN
  /// overlay. Dismissing after the call tears down the pill that handler just
  /// put up, so the offer the user is now looking at is revoked by the one they
  /// just accepted.
  ///
  /// Proved by having the handler present something and asserting it SURVIVES.
  /// Asserting the ordering directly would need a clock; this needs none.
  @Test("a paste handler that presents its own overlay keeps it")
  func pasteHandlerOverlaySurvivesTheDismissal() {
    let (d, _) = OverlayTestDouble.headlessDirectorWithHost()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    let successor = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    let actions = Self.pillActions(
      director: d, onPaste: { _ in d.presentEscapeRecovery(successor, actions: { _ in }) })

    d.presentEscapeRecovery(payload, actions: actions)
    actions(.pasteEscapeRecovery(transcriptID: payload.transcriptID))

    #expect(
      d.takeEscapeRecoveryPayload(matching: successor.transcriptID) != nil,
      "the dismissal ran AFTER the handler and revoked the offer it had just put up")
  }

  /// A second press finds nothing and changes nothing. The one-shot take already
  /// made it safe; this pins that the dismissal did not make it UNsafe by, for
  /// example, re-presenting or reviving custody.
  @Test("a second press after Paste is inert")
  func secondPressIsInert() {
    let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pasteCount = 0
    let actions = Self.pillActions(director: d, onPaste: { _ in pasteCount += 1 })

    d.presentEscapeRecovery(payload, actions: actions)
    actions(.pasteEscapeRecovery(transcriptID: payload.transcriptID))
    actions(.pasteEscapeRecovery(transcriptID: payload.transcriptID))

    #expect(pasteCount == 1, "the transcript was pasted twice")
    #expect(!host.isShowing, "the second press brought the pill back")
  }

  /// The REAL `EscapeRecoveryWiring.pillActions`, with only its outward paste
  /// call replaced by a probe.
  ///
  /// A hand-written copy of that closure would be a second definition of the
  /// behaviour under test: it would have passed happily while production was
  /// missing the dismissal, which is the exact defect these cases exist for.
  /// The seam is production API with a production default, added for this.
  @MainActor
  private static func pillActions(
    director: OverlayDirector, onPaste: @escaping (CancelUndoPayload) -> Void
  ) -> (OverlayAction) -> Void {
    EscapeRecoveryWiring.pillActions(
      director: director,
      coordinator: TranscriptCoordinator(store: Self.throwawayStore()),
      paste: onPaste)
  }

  /// A store in a fresh temp directory. The coordinator is required by the
  /// production signature and is never consulted here — the probe replaces the
  /// one call that would reach it — but it must not be pointed at the real
  /// user's transcript directory to prove that.
  private static func throwawayStore() -> TranscriptStore {
    TranscriptStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2292-c9-\(UUID().uuidString)", isDirectory: true))
  }

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
  /// teardown of its own — the pill is simply overwritten by the next occupant —
  /// and a payload surviving it could paste a later recovery into the app THIS
  /// one was aimed at.
  ///
  /// **Driven now, not enumerated.** This used to assert a static intent table
  /// (retainsEscapeRecoveryPayload) because `show(intent:)` trapped in a unit
  /// host, so the line that consults the rule was not drivable. The director is,
  /// so the rule is tested through the behaviour instead of through a lookup
  /// table that could drift from the code reading it (#2292).
  @Test("any other occupant drops the paste target with the pill")
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
      let d = OverlayTestDouble.headlessDirector()
      let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      d.presentEscapeRecovery(payload, actions: { _ in })

      // A recording is a TRANSACTION, not an event — `send` asserts on one, and
      // that invariant caught this loop on its first run.
      if case .recording = intent {
        d.presentRecording(
          audioLevel: 0, audioLevelProvider: { 0 }, recordingElapsedProvider: { nil },
          isRecordingLocked: false, actions: nil)
      } else {
        d.send(.pipeline(intent), actions: nil)
      }

      #expect(
        d.takeEscapeRecoveryPayload(matching: payload.transcriptID) == nil,
        "\(intent) replaced the pill, so it must drop the target with it")
    }

    // The paired ACCEPTED case: without it, "drops on everything" would also be
    // satisfied by a director that never holds a payload at all.
    let d = OverlayTestDouble.headlessDirector()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    d.presentEscapeRecovery(payload, actions: { _ in })
    #expect(d.takeEscapeRecoveryPayload(matching: payload.transcriptID) != nil)
  }

  #if DEBUG
    /// A fresh director has nothing bound, which is the other half of inertness:
    /// even if a pill were somehow raised, a press would reach nobody and the
    /// director's own invariant would say so rather than silently dropping it.
    ///
    /// Just this ONE case is DEBUG-gated, not the file: it is the only one here
    /// reading a `*ForTesting` accessor, and wrapping the suite would drop every
    /// other guard out of the Release lane for one test's sake — the mistake the
    /// first repair of this class made two commits ago.
    @Test("a fresh director has no active binding")
    func handlerIsUnboundByDefault() {
      #expect(OverlayTestDouble.headlessDirector().hasActiveBindingForTesting == false)
    }
  #endif

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
