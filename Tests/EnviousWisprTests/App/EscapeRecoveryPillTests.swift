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
  func supersededPillCannotTouchTheNewerPayload() throws {
    let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
    let stale = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    let live = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pasted: [UUID] = []

    let staleReceipt = d.present(
      .escapeRecovery(payload: stale, onPaste: { pasted.append($0.transcriptID) }))
    // A newer offer replaces it. The director's custody follows the OFFER.
    let liveReceipt = d.present(
      .escapeRecovery(payload: live, onPaste: { pasted.append($0.transcriptID) }))

    // The stale pill's own presentation id, replayed after replacement.
    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: stale.transcriptID), for: try #require(staleReceipt))
    #expect(
      pasted.isEmpty,
      "a superseded pill still reached a payload, so a stale press would paste")

    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: live.transcriptID), for: try #require(liveReceipt))
    #expect(pasted == [live.transcriptID], "the live offer did not forward its own payload")
  }

  // **`payloadIsTakenOnce` was DELETED here and in `OverlayDirectorTests`**
  // (#2292 C4a), on a supervisor ruling, and the reason is worth keeping.
  //
  // It asserted that a second DIRECT take returns nil, through an accessor that
  // no longer exists: custody now lives inside the typed request's own binding.
  // Rewriting it through the shipped path would NOT have preserved the claim —
  // `present` returns a receipt rather than an action binding, so after the
  // first Paste the slot is empty and a second event is refused by the
  // presentation-id gate BEFORE custody is ever consulted. The rewrite would
  // have proved staleness while claiming one-shot custody, which is the same
  // oracle mistake C1 made.
  //
  // The user-visible outcome it stood for — a double press must not paste twice
  // — is covered by `secondPressIsInert` below, which drives real presses.


  // MARK: - Pressing Paste takes the offer down with it (#2292 C9)

  /// **An accepted offer must leave the screen**, and the cutover left it up.
  ///
  /// `pillActions` consumed the payload and started the restore without
  /// dismissing anything, so the pill sat there until its dwell expired — an
  /// offer the user had already taken, with a Paste button that now did nothing
  /// at all, because the one-shot take had spent the payload. A live-looking
  /// button that is inert is worse than no button.
  @Test("pressing Paste takes the pill down")
  func pressingPasteDismissesTheOffer() throws {
    let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pasted: [UUID] = []

    let receipt = d.present(
      .escapeRecovery(payload: payload, onPaste: { pasted.append($0.transcriptID) }))
    // Read off the HOST rather than the director's debug seams, so this case
    // compiles and runs in the Release lane too. `currentPresentationForTesting`
    // lives inside `#if DEBUG`, and a Release build that cannot see it fails to
    // COMPILE with zero failure marks — invisible to a Debug-only run.
    #expect(host.isShowing, "the pill never went up")

    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: try #require(receipt))

    #expect(pasted == [payload.transcriptID], "the press did not reach the paste handler")
    #expect(!host.isShowing, "the window still shows a pill the user already accepted")
  }

  // **`pasteHandlerOverlaySurvivesTheDismissal` was DELETED** (#2292 C4a).
  //
  // It asserted that a paste handler presenting its OWN overlay keeps it, on the
  // premise that dismissing after the call would revoke the offer the handler had
  // just put up. That premise was already retracted in C1: the production
  // `pasteAction` copies to the clipboard and dispatches a keystroke, and raises
  // no pill — so no supported user can produce the scenario. The dismissal's real
  // and still-asserted reason is VoiceOver: a spoken "overlay hidden" must not
  // land on top of the restore the user asked for.
  //
  // C4a also made it unreachable: the binding belongs to the director, so there
  // is no caller-supplied handler that could present anything between the take
  // and the dismissal. `pressingPasteDismissesTheOffer` covers what remains.

  /// A second press finds nothing and changes nothing. The one-shot take already
  /// made it safe; this pins that the dismissal did not make it UNsafe by, for
  /// example, re-presenting or reviving custody.
  @Test("a second press after Paste is inert")
  func secondPressIsInert() throws {
    let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pasteCount = 0

    let receipt = d.present(
      .escapeRecovery(payload: payload, onPaste: { _ in pasteCount += 1 }))
    let held = try #require(receipt)
    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: held)
    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: held)

    #expect(pasteCount == 1, "the transcript was pasted twice")
    #expect(!host.isShowing, "the second press brought the pill back")
  }

  // The `pillActions` helper and its throwaway store went with
  // `EscapeRecoveryWiring.pillActions` (#2292 C4a). Its purpose was to drive the
  // REAL production closure rather than a hand-written copy; the cases above now
  // drive the real director binding directly, which is the same discipline one
  // layer in.

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
  func onlyThePillRetainsItsTarget() throws {
    // **Enumerated over what a CALLER can do** (#2292 C5c). This used to sweep
    // `OverlayIntent`, the director's own internal vocabulary, through an ingress
    // that no longer exists. The question is unchanged — does anything else
    // taking the slot leave the payload behind — but it is now asked of the
    // surface a caller has, so a request added to `PillRequest` and forgotten
    // here is the only way this sweep can go stale.
    let others: [(String, (any OverlayPresenting) -> Void)] = [
      ("announced dismissal", { $0.dismissCurrent(.announced) }),
      ("recording", {
        $0.present(
          .recording(
            RecordingPillInput(
              audioLevel: 0, audioLevelProvider: { 0 },
              recordingElapsedProvider: { nil }, isLocked: false)))
      }),
      ("processing", { $0.present(.processing(phase: .transcribing)) }),
      ("clipboard fallback", { $0.present(.clipboardFallback) }),
      ("accessibility notice", { $0.present(.accessibilityNotice) }),
      ("warning", { $0.present(.warning(reason: .polishFailed)) }),
      ("error", { $0.present(.error(reason: .asrFailed)) }),
      ("advisory", { $0.present(.advisory(reason: .zeroSignal)) }),
      ("interruption", { $0.present(.interruption(reason: .deviceRemoved)) }),
      ("caching model", { $0.present(.cachingModel(engineLabel: "Parakeet v3")) }),
      ("engine ready", { $0.present(.engineReady) }),
      ("recovery notice", { $0.present(.recoveryNotice(onDiscard: {})) }),
      ("recovery succeeded", { $0.present(.recoverySucceeded) }),
    ]

    // **The REFUSED arm, and it is not a weaker version of the sweep above — it
    // asserts the opposite outcome for the opposite reason.** A feature request
    // arriving while the pipeline holds the slot is refused, so it replaces
    // nothing: the recovery offer is still the pill on screen, and its payload
    // must still be behind the button. Asserting "everything drops the target"
    // over these two says a live offer stops working because an import finished
    // somewhere else.
    //
    // The old sweep could not reach this. It spelled Bluetooth as a PIPELINE
    // intent through the generic ingress — a spelling no caller ever used, which
    // did take the slot — and had no import-status row at all.
    let refused: [(String, (any OverlayPresenting) -> PillReceipt?)] = [
      ("import status", { $0.present(.importStatus(message: "Importing 3")) }),
      ("bluetooth awareness", {
        $0.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
      }),
    ]
    // **Observed through a real press since C4a**, because custody is no longer
    // reachable from outside the director. A stale press forwarding nothing is
    // the same fact the old accessor asserted, one step further along the path a
    // user actually takes.
    for (label, replace) in others {
      let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
      let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      var pasted: [UUID] = []
      let receipt = try #require(
        d.present(.escapeRecovery(payload: payload, onPaste: { pasted.append($0.transcriptID) })))

      replace(d)

      try host.sendUserActionThroughRoot(
        .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: receipt)
      #expect(
        pasted.isEmpty,
        "\(label) replaced the pill, so it must drop the target with it")
    }

    for (label, attempt) in refused {
      let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
      let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      var pasted: [UUID] = []
      let receipt = try #require(
        d.present(.escapeRecovery(payload: payload, onPaste: { pasted.append($0.transcriptID) })))

      #expect(
        attempt(d) == nil,
        "\(label) took the slot from a live recovery offer, which arbitration refuses")

      try host.sendUserActionThroughRoot(
        .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: receipt)
      #expect(
        pasted == [payload.transcriptID],
        "\(label) was refused and the offer still shows, so Undo must still restore")
    }

    // The paired ACCEPTED case: without it, "drops on everything" would also be
    // satisfied by a director that never holds a payload at all.
    let (d, host) = OverlayTestDouble.headlessDirectorWithHost()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pasted: [UUID] = []
    let receipt = try #require(
      d.present(.escapeRecovery(payload: payload, onPaste: { pasted.append($0.transcriptID) })))
    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: receipt)
    #expect(pasted == [payload.transcriptID])
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
