#if DEBUG
// **The whole file is DEBUG-only, and that is structural rather than stylistic.**
// Every case here reads a `*ForTesting` accessor, and those live inside `#if
// DEBUG` on the types they belong to. Without this wrapper the RELEASE build of
// the test target does not compile — which a Debug-only local run cannot see, by
// construction, and which CI's `build-release` job catches instead.
  import AppKit
  import EnviousWisprCore
  import EnviousWisprPipeline
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// #2292 chunk C4b. The presentation transaction.
  ///
  /// **Product Outcome.** When these fail the user sees a pill dismissed by a
  /// timer belonging to a dictation that already ended, a button that does nothing
  /// because its handler was dropped, or an Undo that pastes the wrong transcript.
  ///
  /// **No clock anywhere.** The scheduler is a seam: the test holds the armed work
  /// and fires it itself, so "the timer fired" is an event the test causes rather
  /// than something it waits for. `never-guess-when-the-subject-is-finished`
  /// forbids waiting on time; here there is nothing to wait for.
  @MainActor
  @Suite(.tags(.productOutcome))
  struct OverlayDirectorTests {

    init() { _ = NSApplication.shared }

    /// Every host built by this suite, so each test can order its window out.
    /// `NSApp` retains an ordered-in window, so without this the pills accumulate
    /// on screen for the life of the xctest process — which is what put 34 of them
    /// over the founder's terminal before he reported it.
    ///
    /// **Shared across the suite, which is only safe while no test here suspends.**
    /// Every case is synchronous on the main actor, so two cannot interleave and
    /// `closeAllWindows()` can never order out a sibling's window mid-test. Adding
    /// an `async` case reopens that, and the symptom would be a flake rather than a
    /// leak: the teardown is still total, it would just run early. If you add one,
    /// hand each test its own host instead of registering it here.
    private static nonisolated(unsafe) var hosts: [OverlayWindowHost] = []

    /// Recordings go through `presentRecording`, never `send`, because providers
    /// and layout must be installed in the SAME operation that presents the pill.
    /// The director asserts on the wrong order, so this helper is what keeps the
    /// suite expressing the right one.
    private static func record(
      _ d: OverlayDirector, level: Float = 0.2, preview: Bool = false,
      locked: Bool = false,
      elapsed: @escaping () -> TimeInterval? = { nil },
      display: @escaping () -> LivePreviewDisplay = { .off },
      actions: ((OverlayAction) -> Void)? = nil
    ) {
      d.presentRecording(
        audioLevel: level,
        audioLevelProvider: { level },
        recordingElapsedProvider: elapsed,
        isRecordingLocked: locked,
        livePreviewEnabled: { preview },
        livePreviewDisplay: display,
        actions: actions)
    }

    private static func closeAllWindows() {
      for h in hosts { h.panelForTesting?.orderOut(nil) }
      hosts.removeAll()
    }

    private final class Armed {
      var work: OverlayScheduledWork?
    }

    private static let screen = ScreenGeometry(
      id: ScreenID(rawValue: 1),
      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

    private final class Sink {
      var effects: [OverlayEffect] = []
    }

    private static func director(
      position: @escaping () -> OverlayPillPosition = { .bottom }
    ) -> (OverlayDirector, Armed, Sink) {
      let armed = Armed()
      let sink = Sink()
      // Real panels again: the director renders through a real host. Held so the
      // caller can order the window out when the test ends.
      let host = OverlayWindowHost(screens: { OverlayScreenResolver { screen } })
      let d = OverlayDirector(
        host: host, deliverEffect: { sink.effects.append($0) }, position: position,
        scheduler: .manual { armed.work = $0 })
      hosts.append(host)
      return (d, armed, sink)
    }

    // MARK: - Exactly one expiry

    /// **The defect `PresentationID` exists to close.** Seven independently owned
    /// staleness mechanisms in the shipped code each answered "is this deferred
    /// work still valid" their own way, and nothing held them to the same answer.
    @Test("a timer armed for a dismissed pill cannot dismiss its replacement")
    func staleTimerCannotDismissTheLivePill() {
      let (d, armed, _) = Self.director()
      defer { Self.closeAllWindows() }
      d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)
      let staleTimer = try! #require(armed.work)

      Self.record(d, level: 0.4)
      let live = try! #require(d.currentPresentationForTesting?.id)

      staleTimer.fireForTesting()

      #expect(
        d.currentPresentationForTesting?.id == live,
        "a timer from a finished notice closed the live recording pill")
    }

    /// A new occupant REPLACES the armed expiry rather than leaving it running.
    @Test("arming a new expiry cancels the previous one")
    func armingReplacesTheArmedExpiry() {
      let (d, armed, _) = Self.director()
      defer { Self.closeAllWindows() }
      d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)
      let first = try! #require(armed.work)

      d.send(.pipeline(.error(reason: .asrFailed)), actions: nil)

      #expect(first.isCancelled, "the previous pill's timer was left running")
      #expect(armed.work !== first, "a second timer was armed without replacing the first")
    }

    /// A persistent presentation cancels rather than inheriting.
    @Test("a persistent pill leaves no timer armed")
    func persistentPillDisarms() {
      let (d, armed, _) = Self.director()
      defer { Self.closeAllWindows() }
      d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)
      let notice = try! #require(armed.work)

      Self.record(d, level: 0.2)

      #expect(notice.isCancelled)
      #expect(d.hasArmedExpiryForTesting == false, "the recording pill armed a dismissal")
    }

    /// The paired accepted case: a timed pill's OWN timer must still work, or
    /// every guard above is satisfied by a director that never dismisses anything.
    @Test("a pill's own timer dismisses it")
    func ownTimerDismisses() {
      let (d, armed, _) = Self.director()
      defer { Self.closeAllWindows() }
      d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)

      try! #require(armed.work).fireForTesting()

      #expect(d.currentPresentationForTesting == nil)
    }

    // MARK: - Exactly one action binding

    @Test("an action reaches the feature that owns the live pill")
    func actionReachesItsOwner() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let delivered = Sink()
      d.send(.pipeline(.accessibilityToast), actions: { delivered.effects.append(.recordingIntentChanged(true)); _ = $0 })
      let id = try! #require(d.currentPresentationForTesting?.id)
      d.send(.action(id, .grantAccessibility), actions: nil)

      #expect(delivered.effects.count == 1, "the action never reached the handler bound with the request")
    }

    /// **A binding must not outlive its pill.** The shipped panel keeps eight
    /// handler closures alive for the app's lifetime whether or not the pill that
    /// uses them is showing.
    @Test("a binding is dropped when its pill is replaced")
    func bindingDiesWithItsPill() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let delivered = Sink()
      d.send(.pipeline(.accessibilityToast), actions: { _ in delivered.effects.append(.recordingIntentChanged(true)) })
      let toast = try! #require(d.currentPresentationForTesting?.id)

      Self.record(d, level: 0.3)

      #expect(d.hasActiveBindingForTesting == false)
      d.send(.action(toast, .grantAccessibility), actions: nil)
      #expect(delivered.effects.isEmpty, "an action from a dismissed pill reached its old handler")
    }

    /// **Replaced by construction.** There used to be a test that a `bind(for:)`
    /// call naming a non-current pill was refused. That entry point is gone: a
    /// request carries its own handler, so a binding for a presentation that is
    /// not current cannot be expressed. The guard it provided is now a property of
    /// the API rather than a runtime check — which is the better place for it, and
    /// the reason the test is deleted rather than rewritten.
    // MARK: - Payload custody

    /// The payload is taken ONCE. A second Undo press must find nothing rather
    /// than paste the transcript again.
    @Test("the cancelled transcript is handed over exactly once")
    func payloadIsTakenOnce() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let transcript = UUID()
      d.presentEscapeRecovery(
        CancelUndoPayload(transcriptID: transcript, targetApp: nil, targetElement: nil),
        actions: { _ in })

      #expect(d.takeEscapeRecoveryPayload(matching: transcript) != nil)
      #expect(
        d.takeEscapeRecoveryPayload(matching: transcript) == nil,
        "the payload was handed over twice — a double press would paste twice")
    }

    @Test("a payload is never handed to a different transcript")
    func payloadIsKeyedToItsTranscript() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let mine = UUID()
      d.presentEscapeRecovery(
        CancelUndoPayload(transcriptID: mine, targetApp: nil, targetElement: nil),
        actions: { _ in })

      #expect(d.takeEscapeRecoveryPayload(matching: UUID()) == nil)
    }

    /// Custody ends with the pill. Otherwise a payload outlives the dictation it
    /// belongs to and the next Undo could reach it.
    @Test("the payload is released when the pill goes")
    func payloadIsReleasedWithThePill() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let transcript = UUID()
      d.presentEscapeRecovery(
        CancelUndoPayload(transcriptID: transcript, targetApp: nil, targetElement: nil),
        actions: { _ in })
      #expect(d.holdsEscapeRecoveryPayloadForTesting)

      d.send(.pipeline(.hidden), actions: nil)

      #expect(
        d.holdsEscapeRecoveryPayloadForTesting == false,
        "a cancelled transcript outlived the pill offering to restore it")
    }

    /// Custody must end when ANOTHER pill takes the slot, not only when the slot
    /// empties. Clearing it only on empty left a cancelled transcript held while a
    /// different pill was showing.
    @Test("the payload is released when a different pill replaces the recovery pill")
    func payloadIsReleasedOnReplacement() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let transcript = UUID()
      d.presentEscapeRecovery(
        CancelUndoPayload(transcriptID: transcript, targetApp: nil, targetElement: nil),
        actions: { _ in })
      #expect(d.holdsEscapeRecoveryPayloadForTesting)

      Self.record(d, level: 0.3)

      #expect(
        d.holdsEscapeRecoveryPayloadForTesting == false,
        "a cancelled transcript was still held while a different pill was on screen")
    }

    /// **Undo must be bindable, and it was not.** Making the handler arrive with
    /// the request broke this entry point outright: the pill appeared with nothing
    /// bound, so the first press hit the invariant assertion. No test pressed the
    /// button on a pill presented this way, so the suite could not see it.
    @Test("the cancelled-transcript pill carries its Undo handler")
    func escapeRecoveryCarriesItsHandler() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      let transcript = UUID()
      var pressed: [OverlayAction] = []
      d.presentEscapeRecovery(
        CancelUndoPayload(transcriptID: transcript, targetApp: nil, targetElement: nil),
        actions: { pressed.append($0) })
      let id = try! #require(d.currentPresentationForTesting?.id)

      d.send(.action(id, .pasteEscapeRecovery(transcriptID: transcript)), actions: nil)

      #expect(
        pressed == [.pasteEscapeRecovery(transcriptID: transcript)],
        "Undo was pressed and nothing was bound to it")
    }

    /// **A morph keeps its buttons.** An audio-level tick is a same-id update with
    /// no handler and it arrives many times a second; replacing the binding with
    /// whatever the call carried silently disarmed the live pill.
    @Test("a same-pill update does not drop its handler")
    func morphPreservesItsBinding() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      var pressed: [OverlayAction] = []
      Self.record(d, level: 0.1, actions: { pressed.append($0) })
      let id = try! #require(d.currentPresentationForTesting?.id)

      for level in [Float(0.4), 0.7, 0.2] {
        Self.record(d, level: level)
      }
      d.send(.action(id, .discardRecovery), actions: nil)

      #expect(
        pressed == [.discardRecovery],
        "a metering update dropped the live pill's handler")
    }

    // MARK: - Rendering through the host

    /// **A morph is not a fresh presentation, and the host needs that told to it.**
    /// A fresh presentation re-anchors; a morph keeps the live frame. Getting it
    /// wrong moves the pill on every audio tick.
    @Test("a same-pill update is not presented as a fresh occupant")
    func morphIsNotFresh() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      Self.record(d, level: 0.2)
      let first = try! #require(d.presentedIDForTesting)

      Self.record(d, level: 0.8)

      #expect(d.presentedIDForTesting == first, "a metering update changed the presented occupant")
    }

    @Test("a genuinely new pill is a new occupant")
    func replacementIsANewOccupant() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      Self.record(d, level: 0.2)
      let first = try! #require(d.presentedIDForTesting)

      d.send(.pipeline(.warning(reason: .polishFailed)), actions: nil)

      #expect(d.presentedIDForTesting != first)
    }

    /// Emptying the slot must release the recording providers, or a closure
    /// reading a finished dictation outlives it.
    @Test("hiding releases the recording providers and the occupant")
    func hidingReleasesEverything() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      d.renderModel.setRecordingProviders(
        audioLevel: { 0.9 }, recordingElapsed: { 12 }, livePreview: { .off },
        layout: .compact(position: .top), onContentHeightChange: { _ in })
      Self.record(d, level: 0.2)

      d.send(.pipeline(.hidden), actions: nil)

      #expect(d.presentedIDForTesting == nil)
      #expect(d.renderModel.audioLevelProvider() == 0, "a provider outlived its dictation")
      #expect(d.renderModel.recordingElapsedProvider() == nil)
    }

    /// **A REPLACEMENT ends a recording as surely as an empty slot does.** The
    /// first version released the providers only when the presentation became
    /// nil, so a finished dictation's closures were still being polled fifty times
    /// a second behind whatever pill replaced it. The test above cannot see this:
    /// it hides, which is the one path that already worked.
    @Test("a pill that replaces the recording releases its providers too")
    func replacingTheRecordingReleasesItsProviders() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      d.renderModel.setRecordingProviders(
        audioLevel: { 0.9 }, recordingElapsed: { 12 }, livePreview: { .off },
        layout: .compact(position: .top), onContentHeightChange: { _ in })
      Self.record(d, level: 0.2)

      d.send(.pipeline(.processing(phase: .transcribing)), actions: nil)

      #expect(
        d.renderModel.audioLevelProvider() == 0,
        "the finished dictation's level closure is still being polled behind the processing pill")
      #expect(d.renderModel.recordingElapsedProvider() == nil)
    }

    /// A same-id morph is the SAME recording, so it keeps what it installed. This
    /// is the paired accepted case for the rejection above: without it, "release
    /// on any change" would also be satisfied by releasing on every audio tick,
    /// which empties the meter mid-dictation.
    ///
    /// **Asserted as NOT-CLEARED rather than as a specific value**, because
    /// `presentRecording` installs providers on every call by construction — a
    /// tick legitimately replaces the level closure with the new level. What must
    /// never happen is the release path running, which zeroes them.
    ///
    /// Every tick carries the elapsed provider too, at this boundary. An earlier
    /// version of this comment said no tick does; that is true of the audio-level
    /// PUSH and false of `presentRecording`, which takes the full provider set
    /// each time — the distinction the atomic operation exists to enforce.
    @Test("an audio tick does not release the recording's own providers")
    func morphingTheRecordingKeepsItsProviders() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      Self.record(d, level: 0.2, elapsed: { 12 })

      Self.record(d, level: 0.7, elapsed: { 12 })

      #expect(
        d.renderModel.audioLevelProvider() == 0.7,
        "an audio tick emptied the meter it was reporting to")
      #expect(
        d.renderModel.recordingElapsedProvider() == 12,
        "an audio tick dropped the elapsed clock it was handed")
    }

    /// **A morph keeps the LAYOUT it was created with, whatever the setting now
    /// says.** The shipped panel reads the preview setting once at creation and
    /// its width is fixed for that panel's life, because an `NSPanel` cannot grow
    /// mid-recording without a rebuild and a rebuild is the #930 flicker. So a
    /// user toggling Live Preview mid-dictation must not resize the live pill —
    /// which re-resolving the layout on every tick would do.
    @Test("toggling Live Preview mid-dictation does not resize the live pill")
    func morphKeepsTheLayoutItWasCreatedWith() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      Self.record(d, level: 0.2, preview: false)
      let atStart = d.hostForTesting.panelForTesting?.frame.width

      // The setting flips, and the next tick reports it.
      Self.record(d, level: 0.6, preview: true)

      #expect(atStart == 185)
      #expect(
        d.hostForTesting.panelForTesting?.frame.width == 185,
        "a mid-dictation settings change resized the live pill, which is the #930 rebuild flicker")
    }

    /// **The lock is part of the presentation TRANSACTION, not a later morph.**
    /// The reducer's born-locked rule exists for this, and the shipped
    /// `show(intent:isRecordingLocked:)` takes both in one call. Before this, the
    /// caller had to remember a second `send(.lockStateChanged(_:))`, and
    /// forgetting it lost hands-free lock with nothing to say so.
    @Test("a recording is born with the lock value from its presentation transaction")
    func recordingIsBornLocked() {
      let (d, _, _) = Self.director()
      defer { Self.closeAllWindows() }

      Self.record(d, locked: true)

      guard case .recording(_, let locked, _)? = d.currentPresentationForTesting?.content else {
        Issue.record("expected a recording presentation")
        return
      }
      #expect(locked, "the recording rendered unlocked before a later lock morph")
    }

    /// **One position per presentation, not two reads of a provider.** The layout
    /// captures the anchored edge when the pill is composed; the host used to
    /// re-read it, so a setting changed in between would compose against one edge
    /// and place against another.
    ///
    /// Counting READS rather than comparing edges, because the defect is the
    /// second read itself — a test that compared two positions would pass
    /// whenever the provider happened to answer the same twice.
    @Test("recording position is resolved once for composition and placement")
    func recordingPositionIsResolvedOnce() {
      var reads = 0
      let (d, _, _) = Self.director(position: {
        reads += 1
        return reads == 1 ? .bottom : .top
      })
      defer { Self.closeAllWindows() }

      Self.record(d)

      #expect(reads == 1, "the host re-read a position already captured by the recording layout")
    }

    /// **The obligation `OverlayContent.recording` recorded, discharged.** The
    /// non-preview pill reserves a fixed 92-point interaction frame; the Live
    /// Preview variant is content-sized from its first frame so it does not
    /// visibly snap once the real height is measured. The reducer cannot decide
    /// this — preview arrives as a provider, not an event — so the director does.
    ///
    /// Asserted on the WINDOW rather than on the argument, because the argument is
    /// the thing under test: a panel 92 points tall is the reserved frame, and one
    /// that is not is content-sized.
    @Test("Live Preview makes the recording pill content-sized, and only Live Preview")
    func previewLayoutDropsTheReservedFrame() {
      let (fixed, _, _) = Self.director()
      defer { Self.closeAllWindows() }
      Self.record(fixed, level: 0.2, preview: false)
      let reserved = fixed.hostForTesting.panelForTesting?.frame.height
      let fixedWidth = fixed.hostForTesting.panelForTesting?.frame.width

      let (preview, _, _) = Self.director()
      Self.record(preview, level: 0.2, preview: true)
      let measured = preview.hostForTesting.panelForTesting?.frame.height
      let previewWidth = preview.hostForTesting.panelForTesting?.frame.width

      #expect(reserved == 92, "the non-preview recording pill lost its reserved 92-point frame")
      #expect(
        measured != 92,
        "the Live Preview pill took the reserved frame instead of sizing to its content")
      // **The WIDTH is the half that is easy to miss.** The shipped site reads
      // `showsPreview ? previewPillWidth : 185` — 400 against 185 — so carrying
      // only the height still renders a preview pill at under half its size.
      #expect(fixedWidth == 185, "the non-preview recording pill lost its 185-point width")
      #expect(previewWidth == 400, "the Live Preview pill did not take its 400-point width")
    }
  }
#endif
