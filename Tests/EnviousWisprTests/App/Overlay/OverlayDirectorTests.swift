// **Release-visible since C6, and the wrapper it lost was load-bearing until
// then.** Every case here used to read a `*ForTesting` accessor, and those lived
// inside `#if DEBUG` on the types they belonged to — so without a wrapper the
// RELEASE build of the test target did not compile, which a Debug-only local run
// cannot see by construction. The accessors are gone: each case now reads what
// the user gets, what the caller was handed back, or what the host was asked
// for, all of which are production surface. 39 cases moved into the Release lane
// with this line.
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

  /// Publishes a recording after release and requires provider defaults.
  /// An empty frame alone cannot prove staged closures were cleared, because a
  /// later recording could publish them again. Used by hide, replacement and refusal.
  @MainActor
  private static func expectReleasedProvidersDoNotReappear(_ model: OverlayRenderModel) {
    let design = RecordingPillDesign.classic
    model.publish(
      PillDefinition(
        id: PresentationID(rawValue: UUID()),
        content: .recording(audioLevel: 0, isLocked: false, notice: nil, design: design),
        expiry: .untilReplaced,
        requestedWidth: .fixed(design.width),
        reservesFixedHeight: design.reservedHeight))
    #expect(
      model.state.recording?.audioLevelProvider() == 0,
      "the released dictation's level closure was staged and reappeared on the next pill")
    #expect(
      model.state.recording?.recordingElapsedProvider() == nil,
      "the released dictation's elapsed clock was staged and reappeared on the next pill")
  }

  /// Recordings go through `presentRecording`, never `send`, because providers,
  /// the resolved design and captured position must be installed in the same
  /// operation that presents the pill. The director asserts on the wrong order,
  /// so this helper is what keeps the suite expressing the right one.
  private static func record(
    _ d: OverlayDirector, level: Float = 0.2, preview: Bool = false,
    locked: Bool = false,
    elapsed: @escaping () -> TimeInterval? = { nil },
    display: @escaping () -> LivePreviewDisplay = { .off },
    // Only the two cases that exercise Live Preview pass one; every other
    // caller records with the feature off and has no setting to flip.
    previewSetting: PreviewSetting? = nil
  ) {
    previewSetting?.isEnabled = preview
    previewSetting?.display = display
    // **No `actions:` parameter, and nothing is lost.** A recording pill draws
    // no buttons, so `PillRequest.recording` carries no callbacks — an action
    // binding on a recording is unspellable rather than merely unused.
    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: level,
          audioLevelProvider: { level },
          recordingElapsedProvider: elapsed,
          isLocked: locked)))
  }

  /// The same wiring as `director()` on a host that never draws, for a case
  /// whose subject is a BUTTON rather than a window.
  ///
  /// The real host has no root to press through, and giving it one would be a
  /// test hatch in shipping code. Every case using this asserts what a press
  /// reached; none of them asks a question about a frame.
  private static func pressableDirector(preview: PreviewSetting = PreviewSetting())
    -> (OverlayDirector, WindowlessOverlayHost, Sink)
  {
    let sink = Sink()
    let host = WindowlessOverlayHost()
    let d = OverlayDirector(
      host: host,
      scheduler: .manual { _ in },
      announce: { sink.announcements.append($0) },
      livePreview: LivePreviewBridge(
        recordingDidChange: { sink.recordingStates.append($0) },
        isEnabledForGeometry: { preview.isEnabled },
        // Derived from this fixture's own verdict, never typed beside it: a
        // fixture stating both independently can contradict itself, and no
        // assertion would catch it.
        wordsCapability: { preview.isEnabled ? .available : .previewOff },
        display: { preview.display() }),
      grantAccessibility: { sink.appActions.append(.grantAccessibility) },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    return (d, host, sink)
  }

  /// **Teardown through `hide()`, the production surface** (#2292 C6). It used
  /// to reach `panelForTesting`, a `#if DEBUG` accessor on the host, which is
  /// what kept this whole suite out of the Release lane once the director's own
  /// hatches were gone. `hide()` does strictly MORE than the old line did: it
  /// orders the panel out AND releases the hosting view, so a hidden pill stops
  /// polling the audio level instead of running invisibly for the rest of the
  /// session.
  /// A windowless host that can be told to refuse, so the refusal path needs no
  /// screen state.
  private final class RefusingWindowlessHost: OverlayWindowHosting {
    var accepts = true
    private(set) var presentCount = 0
    private(set) var hideCount = 0

    @discardableResult
    func present(
      _ view: NSView, width: OverlayWidth, fixedHeight: CGFloat?, isFresh: Bool,
      position: OverlayPillPosition
    ) -> Bool {
      presentCount += 1
      return accepts
    }

    func hide() { hideCount += 1 }
    func resizeCurrentPresentation(to size: CGSize) {}
    func repositionForActiveSpaceChange() {}
  }

  /// Holds the ONE scheduled construction so a test can fire it, which is the
  /// only way to reach the window this whole class of defect lives in.
  ///
  /// **Still a queue in SHAPE, though production now schedules at most once
  /// per director lifetime** (`OverlayFirstRenderGate.scheduleIfNeeded` is a
  /// no-op once `.scheduled`). A one-slot fixture would silently drop a
  /// SECOND block if the gate's own coalescing guard ever regressed and
  /// scheduled twice — keeping the queue shape means that regression fails
  /// LOUD, as an unexpectedly-non-empty `blocks` array, rather than
  /// disappearing into a fixture that can hold only one answer.
  private final class Deferral {
    private var blocks: [() -> Void] = []
    var fired = 0

    var block: (() -> Void)? {
      get { blocks.first }
      set { if let newValue { blocks.append(newValue) } else { blocks = [] } }
    }

    /// Fire the oldest queued block, the way the main queue would.
    func fire() {
      guard !blocks.isEmpty else { return }
      let next = blocks.removeFirst()
      fired += 1
      next()
    }

    /// Drain every queued block in the order they were scheduled.
    func fireAll() { while !blocks.isEmpty { fire() } }
  }

  private static func deferrableDirector(
    _ host: RefusingWindowlessHost, _ deferral: Deferral
  ) -> OverlayDirector {
    OverlayDirector(
      host: host,
      scheduler: .manual { _ in },
      announce: { _ in },
      livePreview: .disabled,
      grantAccessibility: {}, selections: { .shipped },
      firstRenderSchedule: { deferral.block = $0 })
  }

  private static func closeAllWindows() {
    for h in hosts { h.hide() }
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
    var effects: [PillEffect] = []
    /// Recording state as LIVE PREVIEW receives it (#2292 C2).
    ///
    /// This used to arrive as a `.recordingStateChanged` effect in `effects`,
    /// routed to the preview by the composition root. The director now holds a
    /// `LivePreviewBridge` and delivers it there directly, so a suite watching
    /// only `effects` would see an empty list and read a working feature as a
    /// dead one. Same signal, same ordering guarantee, different channel.
    var recordingStates: [Bool] = []
    /// The two buttons whose handler belongs to the APP. Captured so a guard
    /// can prove they are BOUND — both were silently unbound by the cutover
    /// and only a cloud review caught it, because an unbound button renders
    /// perfectly and nothing fails.
    var appActions: [PillAction] = []
    /// The ORDER outputs left the director in. Effects must precede the
    /// render, which is the shipped order and is load-bearing for Live
    /// Preview's first frame.
    var order: [String] = []
    /// What a screen reader would have been told. Captured rather than
    /// inferred: `NSAccessibility.post` returns nothing, so without this seam
    /// the strongest available assertion is that the code which would have
    /// posted was reached — a marker beside the subject rather than the
    /// subject.
    var announcements: [OverlayAnnouncement] = []
  }

  /// Live Preview's enabled answer, held so a test can flip it BETWEEN
  /// presentations (#2292 C2).
  ///
  /// The bridge is supplied at construction now and cannot be replaced, which
  /// is the point of the chunk. That does not make the setting immutable: the
  /// production bridge reads `coordinator.isEnabledForGeometry` live, and a
  /// user toggling Live Preview mid-dictation changes what the next read
  /// returns. This box is the same shape.
  private final class PreviewSetting {
    var isEnabled = false
    var display: () -> LivePreviewDisplay = { .off }
  }

  private static func director(
    position: @escaping () -> OverlayPillPosition = { .bottom },
    warningDismissed: @escaping () -> Bool = { false },
    preview: PreviewSetting = PreviewSetting()
  ) -> (OverlayDirector, Armed, Sink) {
    let armed = Armed()
    let sink = Sink()
    // Real panels again: the director renders through a real host. Held so the
    // caller can order the window out when the test ends.
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { screen } })
    let d = OverlayDirector(
      host: host,
      position: position,
      scheduler: .manual { armed.work = $0 },
      announce: {
        sink.announcements.append($0)
        sink.order.append("announce")
      },
      accessibilityEligibility: OverlayAccessibilityEligibility(
        warningDismissed: warningDismissed),
      livePreview: LivePreviewBridge(
        recordingDidChange: {
          sink.recordingStates.append($0)
          // The SAME marker the effect sink writes: what this suite pins is
          // that the preview learns of the recording before the window is
          // drawn, and that property did not move when the channel did.
          sink.order.append("effect")
        },
        isEnabledForGeometry: { preview.isEnabled },
        // Derived from this fixture's own verdict, never typed beside it: a
        // fixture stating both independently can contradict itself, and no
        // assertion would catch it.
        wordsCapability: { preview.isEnabled ? .available : .previewOff },
        display: { preview.display() }),
      grantAccessibility: { sink.appActions.append(.grantAccessibility) },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    hosts.append(host)
    return (d, armed, sink)
  }

  // MARK: - The clock starts when the pill is visible

  /// **A dwell starts when the pill is ON SCREEN, not when the plan is applied**
  /// (#2377 Phase 5, C2).
  ///
  /// `PillExpiryClockTests` proves the clock separates preparing from starting.
  /// This proves the DIRECTOR uses that split: it must prepare at plan time and
  /// start only from the successful-presentation callback, so a pill whose
  /// first render is deferred spends none of its dwell before anything is
  /// visible. Escape Recovery draws a countdown rail from this same dwell, so a
  /// clock that starts early finishes early and the rail disagrees with the
  /// pill it is drawn on.
  ///
  /// Both halves are asserted. The "nothing yet" half alone is satisfied by a
  /// director that never arms at all.
  @Test("a deferred timed pill arms no clock and publishes no dwell until it lands")
  func aDeferredPillArmsNothingUntilItIsOnScreen() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let armed = Armed()
    let d = OverlayDirector(
      host: host,
      scheduler: .manual { armed.work = $0 },
      announce: { _ in },
      livePreview: .disabled,
      grantAccessibility: {}, selections: { .shipped },
      firstRenderSchedule: { deferral.block = $0 })

    d.present(.warning(reason: .polishFailed))

    #expect(armed.work == nil, "the clock armed before the pill reached the screen")
    #expect(
      d.renderModel.state.dwell == nil,
      "a dwell was published before the pill reached the screen")

    deferral.fire()

    #expect(armed.work != nil, "the pill landed and no clock armed")
    let window = try #require(
      d.renderModel.state.dwell, "the pill landed and no dwell was published")
    #expect(
      window.id == d.renderModel.state.presentation?.id,
      "the published dwell names a pill other than the one on screen")
  }

  // MARK: - Exactly one expiry

  /// **The defect `PresentationID` exists to close.** Seven independently owned
  /// staleness mechanisms in the shipped code each answered "is this deferred
  /// work still valid" their own way, and nothing held them to the same answer.
  @Test("a timer armed for a dismissed pill cannot dismiss its replacement")
  func staleTimerCannotDismissTheLivePill() {
    let (d, armed, _) = Self.director()
    defer { Self.closeAllWindows() }
    d.present(.warning(reason: .polishFailed))
    let staleTimer = try! #require(armed.work)

    Self.record(d, level: 0.4)
    let live = try! #require(d.renderModel.state.presentation?.id)

    staleTimer.fire()

    #expect(
      d.renderModel.state.presentation?.id == live,
      "a timer from a finished notice closed the live recording pill")
  }

  /// A new occupant REPLACES the armed expiry rather than leaving it running.
  @Test("arming a new expiry cancels the previous one")
  func armingReplacesTheArmedExpiry() {
    let (d, armed, _) = Self.director()
    defer { Self.closeAllWindows() }
    d.present(.warning(reason: .polishFailed))
    let first = try! #require(armed.work)

    d.present(.error(reason: .asrFailed))

    #expect(first.isCancelled, "the previous pill's timer was left running")
    #expect(armed.work !== first, "a second timer was armed without replacing the first")
  }

  /// A persistent presentation cancels rather than inheriting.
  @Test("a persistent pill leaves no timer armed")
  func persistentPillDisarms() {
    let (d, armed, _) = Self.director()
    defer { Self.closeAllWindows() }
    d.present(.warning(reason: .polishFailed))
    let notice = try! #require(armed.work)

    Self.record(d, level: 0.2)

    // `isCancelled` on the schedule the director armed IS the observation —
    // it is the object the director acted on, not a flag beside it. The
    // `hasArmedExpiryForTesting` read that used to sit here asked the same
    // question of a private field and could not fail while this one passed.
    #expect(notice.isCancelled, "the notice's dwell survived the recording that replaced it")
  }

  /// The paired accepted case: a timed pill's OWN timer must still work, or
  /// every guard above is satisfied by a director that never dismisses anything.
  @Test("a pill's own timer dismisses it")
  func ownTimerDismisses() {
    let (d, armed, _) = Self.director()
    defer { Self.closeAllWindows() }
    d.present(.warning(reason: .polishFailed))

    try! #require(armed.work).fire()

    #expect(d.renderModel.state.presentation == nil)
  }

  // MARK: - Exactly one action binding

  // **`actionReachesItsOwner` was DELETED** (#2292 C5c). It installed a test
  // observer through the generic ingress's `actions:` parameter, which no
  // longer exists — an action's owner now arrives with the request, so the
  // observer it used cannot be expressed. What it asserted, that a press
  // reaches the owner bound with its own presentation, is asserted in BOTH
  // lanes by `PillRequestParityTests.everyActionIsBound` across the five
  // feature actions and by `grantIsBound` for the app-owned one.

  /// **A binding must not outlive its pill.** The shipped panel keeps eight
  /// handler closures alive for the app's lifetime whether or not the pill that
  /// uses them is showing.
  @Test("a binding is dropped when its pill is replaced")
  func bindingDiesWithItsPill() throws {
    let (d, host, _) = Self.pressableDirector()
    var discards = 0

    // A request that carries its OWN owner, so the observation is the callback
    // the caller supplied rather than a test closure the ingress used to take.
    let notice = try #require(d.present(.recoveryNotice(onDiscard: { discards += 1 })))

    Self.record(d, level: 0.3)

    // The press below IS the assertion: a binding that outlived its pill shows
    // up as a callback firing for a pill nobody can see. The
    // `hasActiveBindingForTesting` read that used to precede it asked about the
    // field instead of the effect, and could not fail while the press passed.
    try host.sendUserActionThroughRoot(.discardRecovery, for: notice)
    #expect(discards == 0, "an action from a replaced pill reached its old handler")
  }

  /// **Replaced by construction.** There used to be a test that a `bind(for:)`
  /// call naming a non-current pill was refused. That entry point is gone: a
  /// request carries its own handler, so a binding for a presentation that is
  /// not current cannot be expressed. The guard it provided is now a property of
  /// the API rather than a runtime check — which is the better place for it, and
  /// the reason the test is deleted rather than rewritten.
  // MARK: - Payload custody

  /// Custody ends with the pill. Otherwise a payload outlives the dictation it
  /// belongs to and the next Undo could reach it.
  ///
  /// **Observed through a PRESS since C6.** "Is a payload held" is a field a
  /// user cannot meet; what they can meet is Undo restoring a transcript from a
  /// dictation they already finished with. Pressing the dismissed pill's own
  /// receipt is how that would happen, so it is what the case does.
  @Test("the payload is released when the pill goes")
  func payloadIsReleasedWithThePill() throws {
    let (d, host, _) = Self.pressableDirector()
    let transcript = UUID()
    var restored: [UUID] = []
    let receipt = try #require(
      d.present(
        .escapeRecovery(
          payload: CancelUndoPayload(
            transcriptID: transcript, targetApp: nil, targetElement: nil),
          onPaste: { restored.append($0.transcriptID) })))

    d.dismissCurrent(.announced)
    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: transcript), for: receipt)

    #expect(
      restored.isEmpty,
      "a cancelled transcript outlived the pill offering to restore it")
  }

  /// Custody must end when ANOTHER pill takes the slot, not only when the slot
  /// empties. Clearing it only on empty left a cancelled transcript held while a
  /// different pill was showing.
  @Test("the payload is released when a different pill replaces the recovery pill")
  func payloadIsReleasedOnReplacement() throws {
    let (d, host, _) = Self.pressableDirector()
    let transcript = UUID()
    var restored: [UUID] = []
    let receipt = try #require(
      d.present(
        .escapeRecovery(
          payload: CancelUndoPayload(
            transcriptID: transcript, targetApp: nil, targetElement: nil),
          onPaste: { restored.append($0.transcriptID) })))

    Self.record(d, level: 0.3)
    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: transcript), for: receipt)

    #expect(
      restored.isEmpty,
      "a cancelled transcript was still held while a different pill was on screen")
  }

  /// **Undo must be bindable, and it was not.** Making the handler arrive with
  /// the request broke this entry point outright: the pill appeared with nothing
  /// bound, so the first press hit the invariant assertion. No test pressed the
  /// button on a pill presented this way, so the suite could not see it.
  ///
  /// Since C4a the request carries `onPaste` and the director owns custody, so
  /// this observes the PAYLOAD arriving rather than a raw action — which is the
  /// thing a user's press has to produce.
  @Test("the cancelled-transcript pill carries its Undo handler")
  func escapeRecoveryCarriesItsHandler() throws {
    let (d, host, _) = Self.pressableDirector()
    let transcript = UUID()
    var pressed: [PillAction] = []
    let receipt = try #require(
      d.present(
        .escapeRecovery(
          payload: CancelUndoPayload(
            transcriptID: transcript, targetApp: nil, targetElement: nil),
          onPaste: { _ in pressed.append(.pasteEscapeRecovery(transcriptID: transcript)) })))

    try host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: transcript), for: receipt)

    #expect(
      pressed == [.pasteEscapeRecovery(transcriptID: transcript)],
      "Undo was pressed and nothing was bound to it")
  }

  // **`morphPreservesItsBinding` was DELETED here** (#2292 C5b), and the reason
  // is a real consequence of the typed boundary rather than a convenience.
  //
  // It proved that an audio-level tick — a same-id morph arriving many times a
  // second — must not replace the live pill's action binding with the nothing
  // that tick carried. Its vehicle was a RECORDING presented with an `actions:`
  // closure and a synthetic `.discardRecovery` press.
  //
  // `PillRequest.recording` carries no callbacks, because a recording pill
  // draws no buttons — so that vehicle cannot be built, and an action binding
  // on a recording is now unspellable rather than merely unused. The only
  // morphable presentation is the recording (`PillUpdate` targets exactly
  // `.recordingLock` and `.inPanelNotice`), so there is no pill that both
  // morphs AND carries a binding, and the defect this case described can no
  // longer occur.
  //
  // **The production guard in `apply` stays and is now DEFENSIVE.** Keeping it
  // costs a comparison; removing it would be a bet that no future request ever
  // becomes both morphable and interactive. Flagged for the C5 review rather
  // than decided here.

  /// **A morph is not a fresh presentation, and the host needs that told to it.**

  // MARK: - Rendering through the host

  /// A fresh presentation re-anchors; a morph keeps the live frame. Getting it
  /// wrong moves the pill on every audio tick.
  @Test("a same-pill update is not presented as a fresh occupant")
  func morphIsNotFresh() {
    let (d, _, _) = Self.director()
    defer { Self.closeAllWindows() }
    Self.record(d, level: 0.2)
    let first = try! #require(d.renderModel.state.presentation?.id)

    Self.record(d, level: 0.8)

    #expect(
      d.renderModel.state.presentation?.id == first,
      "a metering update changed the presented occupant")
  }

  @Test("a genuinely new pill is a new occupant")
  func replacementIsANewOccupant() {
    let (d, _, _) = Self.director()
    defer { Self.closeAllWindows() }
    Self.record(d, level: 0.2)
    let first = try! #require(d.renderModel.state.presentation?.id)

    d.present(.warning(reason: .polishFailed))

    #expect(d.renderModel.state.presentation?.id != first)
  }

  /// Emptying the slot must release the recording providers, or a closure
  /// reading a finished dictation outlives it.
  @Test("hiding releases the recording providers and the occupant")
  func hidingReleasesEverything() {
    let (d, _, _) = Self.director()
    defer { Self.closeAllWindows() }
    d.renderModel.setRecordingProviders(
      audioLevel: { 0.9 }, recordingElapsed: { 12 }, livePreview: { .off },
      design: .classic, position: .top, onContentHeightChange: { _ in })
    Self.record(d, level: 0.2)

    d.dismissCurrent(.announced)

    #expect(d.renderModel.state.presentation == nil)
    #expect(d.renderModel.state.recording == nil, "a provider outlived its dictation")
    Self.expectReleasedProvidersDoNotReappear(d.renderModel)
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
      design: .classic, position: .top, onContentHeightChange: { _ in })
    Self.record(d, level: 0.2)

    d.present(.processing(phase: .transcribing))

    #expect(
      d.renderModel.state.recording == nil,
      "the finished dictation's level closure is still being polled behind the processing pill")
    Self.expectReleasedProvidersDoNotReappear(d.renderModel)
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
      d.renderModel.state.recording?.audioLevelProvider() == 0.7,
      "an audio tick emptied the meter it was reporting to")
    #expect(
      d.renderModel.state.recording?.recordingElapsedProvider() == 12,
      "an audio tick dropped the elapsed clock it was handed")
  }

  /// **A morph keeps the DESIGN it was created with, whatever the setting now
  /// says.** The shipped panel reads the preview setting once at creation and
  /// its width is fixed for that panel's life, because an `NSPanel` cannot grow
  /// mid-recording without a rebuild and a rebuild is the #930 flicker. So a
  /// user toggling Live Preview mid-dictation must not resize the live pill —
  /// which re-resolving the design on every tick would do.
  @Test("toggling Live Preview mid-dictation does not resize the live pill")
  func morphKeepsTheDesignItWasCreatedWith() {
    let setting = PreviewSetting()
    let (d, host, _) = Self.pressableDirector(preview: setting)
    Self.record(d, level: 0.2, preview: false, previewSetting: setting)

    // The setting flips, and the next tick reports it.
    Self.record(d, level: 0.6, preview: true, previewSetting: setting)

    // **Asserted on what the director ASKED FOR, not on the panel it got**
    // (#2292 C6). The claim is about the director's arithmetic — it must
    // preserve the accepted design on a tick. Reading an `NSPanel` frame to
    // check that tested it through AppKit, which is why this case could only
    // run in the Debug lane. Whether a panel honours the width it is handed is
    // `OverlayWindowHostTests`' question.
    #expect(
      host.presented.map(\.width) == [.fixed(185), .fixed(185)],
      "a mid-dictation settings change resized the live pill, which is the #930 rebuild flicker")
  }

  /// **The accessibility notice announces the SAME sentence whether or not the
  /// toast is shown, and that is the whole reason it is one method.**
  ///
  /// The shipped panel posts the accessibility announcement BEFORE its
  /// eligibility branch, so a VoiceOver user hears "Accessibility permission
  /// needed for auto-paste" even on the runs where the toast is suppressed and
  /// the clipboard hint is drawn instead. Routing the suppressed case through
  /// `.pipeline(.clipboardFallback)` would say "Text copied to clipboard" — a
  /// different sentence, and a silent change in what a blind user is told,
  /// arriving inside a refactor.
  ///
  /// Paired ACCEPTED and SUPPRESSED cases, because a guard that only checked
  /// the suppressed one would pass a version that never shows the toast at all.
  @Test("the accessibility notice keeps its spoken sentence when the toast is suppressed")
  func suppressedAccessibilityToastKeepsItsAnnouncement() {
    let (shown, _, shownSink) = Self.director()
    defer { Self.closeAllWindows() }

    shown.present(.accessibilityNotice)

    guard case .notice(let toast)? = shown.renderModel.state.presentation?.content else {
      Issue.record("expected a notice")
      return
    }
    #expect(toast.kind == .accessibilityToast, "an eligible toast was not drawn")
    #expect(
      shownSink.announcements.map(\.text)
        == [DictationNarrator.announcement(for: .accessibilityToast)])

    // Suppressed because the user dismissed the standing warning — the real
    // reason, driven through the real policy rather than a stubbed answer.
    let (suppressed, _, suppressedSink) = Self.director(warningDismissed: { true })

    suppressed.present(.accessibilityNotice)

    guard case .notice(let fallback)? = suppressed.renderModel.state.presentation?.content else {
      Issue.record("expected a notice")
      return
    }
    #expect(
      fallback.text == DictationNarrator.clipboardFallbackText,
      "a suppressed toast did not fall back to the clipboard hint")
    #expect(
      suppressedSink.announcements.map(\.text)
        == [DictationNarrator.announcement(for: .accessibilityToast)],
      "the suppressed run announced the clipboard sentence, which tells a blind user something different from what the shipped app tells them"
    )
  }

  /// **A duplicate push must cost nothing at all**, and "nothing" has three
  /// parts: it must not spend the session's one showing, must not replace the
  /// visible toast with the fallback, and must not announce a second time. The
  /// shipped dedup guard drops an identical intent before any of that;
  /// splitting the notice into two reductions had put the eligibility ask in
  /// front of it.
  ///
  /// The spent-showing half is asserted through what the USER would see on a
  /// later, genuine push rather than by counting calls: if the duplicate ate
  /// the showing, that push draws the clipboard hint instead of the toast. A
  /// counter would prove the same thing one layer further from the harm.
  @Test("a duplicate accessibility push neither reclaims nor replaces the toast")
  func duplicateAccessibilityPushIsACompleteNoOp() {
    let (d, _, sink) = Self.director()
    defer { Self.closeAllWindows() }

    d.present(.accessibilityNotice)
    let first = d.renderModel.state.presentation?.id

    d.present(.accessibilityNotice)

    #expect(d.renderModel.state.presentation?.id == first, "a duplicate push replaced the toast")
    #expect(sink.announcements.count == 1, "a duplicate push announced twice")
    guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
      Issue.record("expected the accessibility toast")
      return
    }
    #expect(notice.kind == .accessibilityToast)

    // A genuine LATER push, after something else has held the slot. The
    // session's showing is already spent by the FIRST push, so this one
    // correctly falls back — and it proves the duplicate did not spend a
    // second one, because there is only ever one to spend.
    d.present(.processing(phase: .transcribing))
    d.present(.accessibilityNotice)
    guard case .notice(let later)? = d.renderModel.state.presentation?.content else {
      Issue.record("expected a notice")
      return
    }
    #expect(
      later.text == DictationNarrator.clipboardFallbackText,
      "the session's one showing was not spent by the push that actually showed it")
  }

  /// **The suppressed toast is ONE transition, not two**, and the two things
  /// that proves are invisible from the picture: the pipeline intent must read
  /// `.accessibilityToast` even though the clipboard hint is what is drawn, and
  /// the effect that ends the recording must survive.
  ///
  /// Reducing two intents and applying the second lost both — the state said
  /// `.clipboardFallback`, so a real clipboard push would have been deduped
  /// away, and `.recordingStateChanged(false)` was discarded, which is how
  /// Live Preview learns the dictation ended.
  @Test("a suppressed accessibility toast ends the recording and keeps its logical intent")
  func suppressedAccessibilityToastPreservesTransitionState() {
    let (d, _, sink) = Self.director(warningDismissed: { true })
    defer { Self.closeAllWindows() }
    Self.record(d)
    sink.effects.removeAll()
    sink.recordingStates.removeAll()
    sink.announcements.removeAll()

    d.present(.accessibilityNotice)

    #expect(
      sink.recordingStates == [false],
      "Live Preview was never told the recording ended")
    // **The "logical intent follows the DECISION, not the picture" claim moved
    // to `OverlayReducerTests`** (#2292 C6). It is a statement about what the
    // reducer commits, and it was read here through a director hatch; the
    // reducer suite can assert it directly and in the Release lane. What this
    // case keeps is the part a user meets: the picture is the clipboard
    // fallback and the sentence spoken is still the accessibility one.
    guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
      Issue.record("expected the clipboard fallback")
      return
    }
    #expect(notice.kind == .processing)
    #expect(
      sink.announcements.map(\.text)
        == [DictationNarrator.announcement(for: .accessibilityToast)])
  }

  /// **The two app-level buttons must be BOUND.** Grant and Discard were
  /// setGrantHandler / setDiscardRecoveryHandler on the deleted panel;
  /// their setters went with the class and both presenting sites passed
  /// `actions: nil`, so the buttons rendered and reached nobody. Nothing
  /// failed, which is why a review found it and the suite did not.
  // **`grantIsBound` was DELETED here** (#2292 C5c) and lives in
  // `PillRequestParityTests`, which runs in the Release lane. This suite is
  // `#if DEBUG` in its entirety, so the Debug-only copy was the weaker of two
  // tests making one claim.

  /// **Observed at the request's own callback since C4b.** There is no app
  /// action sink any more: the router that owned it is deleted, so Discard
  /// reaches the closure the presenting caller supplied and nowhere else.
  // **`discardIsBound` was DELETED here** (#2292 C5c), for the same reason as
  // `grantIsBound` above: `PillRequestParityTests.discardDismisses` asserts it
  // in both lanes, and `discardRunsBeforeDismissal` adds the ordering half.

  /// **A feature that OCCUPIES the slot has to say so.** The presenter used to
  /// confirm its own card by asking `currentIntent` for `.bluetoothAwareness`
  /// before acting on any button, and returning the bare pipeline intent —
  /// which a feature never changes — left that handshake permanently failing
  /// and every button on the card a no-op.
  ///
  /// **The projection is gone and the question is now asked of the screen**
  /// (#2292 C6). Admission moved into `present` in C3, so no presenter reads an
  /// intent any more; what remains is that the card must be the pill on screen
  /// and must hold the slot against the next feature that asks. The
  /// pipeline-intent half is a reducer claim and lives in `OverlayReducerTests`.
  @Test("a Bluetooth card owns the slot it took")
  func bluetoothCardReportsOwnership() throws {
    let (d, _, _) = Self.director()
    defer { Self.closeAllWindows() }

    let receipt = try #require(
      d.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {})))

    guard case .bluetoothAwareness? = d.renderModel.state.presentation?.content else {
      Issue.record("the card is not the pill on screen")
      return
    }
    #expect(d.isCurrent(receipt), "the card does not own the presentation it was issued")
    #expect(
      d.featureSlotIsAvailable == false,
      "the card is up and the slot still reads free, so the next feature evicts it")
  }

  /// **The slot must report a chip as occupying it, exactly as it reports the
  /// card.**
  ///
  /// Bluetooth was projected at the cutover and the chip was not — the same
  /// omission twice, and only the first was found by review.
  /// `LanguageSuggestionPresenter` guards `case .hidden` before showing a
  /// chip, so with its own chip up it read the slot as free.
  ///
  /// **The pipeline-intent assertion this case used to carry was DELETED and
  /// its claim was false** (#2292 C5c). It read "a feature must not change the
  /// PIPELINE intent", which was true of the spelling this case used to send —
  /// a feature request routed through the reducer's feature path, which never
  /// touches `pipelineIntent`. That spelling was not the one production used
  /// and C5c deleted it outright. The typed request travels as
  /// `.pipeline(.passiveChip)` and SETS the pipeline intent, which is the whole
  /// point: the language presenter arbitrates against exactly that.
  /// `PillRequestParityTests.languageChip` owns the claim in its correct
  /// direction, and the two contradicted each other until this one was fixed.
  @Test("a language chip reports itself as the current intent")
  func languageChipReportsOwnership() {
    let (d, _, _) = Self.director()
    defer { Self.closeAllWindows() }
    let payload = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)

    d.present(.languageChip(payload: payload, onLock: {}, onDismiss: {}, onExpire: {}))

    guard case .languageChip(let shown)? = d.renderModel.state.presentation?.content else {
      Issue.record("the chip is not the pill on screen")
      return
    }
    #expect(shown == payload, "a different chip reached the screen")
    #expect(
      d.featureSlotIsAvailable == false,
      "the chip is up and the slot still reads free, so the next feature evicts it")
  }

  /// The non-member, pinned so it is not "fixed" later. Import status is the
  /// one request with no matching `OverlayIntent`; the shipped panel did not
  /// set `currentIntent` for it either, so reporting `.hidden` while a status
  /// pill shows is preserved behaviour rather than a third omission.
  @Test("an import status pill deliberately does not claim the intent")
  func importStatusDoesNotClaimTheIntent() {
    let (d, _, _) = Self.director()
    defer { Self.closeAllWindows() }

    d.present(.importStatus(message: "Importing 3 recordings"))

    #expect(d.renderModel.state.presentation != nil, "the status pill never took the slot")
    #expect(
      d.featureSlotIsAvailable,
      "import status began BLOCKING other features, which the shipped panel never did")
  }

  /// **Effects run before the render.** The shipped
  /// recordingIntentObserver fired at the top of `show(intent:)`, before the
  /// announcement and before any panel work, so Live Preview has frozen its
  /// geometry answer by the time the first frame is sized. Running effects last
  /// can size that frame from the live setting instead.
  @Test("an effect is delivered before the presentation is announced")
  func effectsPrecedeTheAnnouncement() {
    let (d, _, sink) = Self.director()
    defer { Self.closeAllWindows() }

    Self.record(d)

    #expect(
      sink.order.first == "effect",
      "the recording-intent effect arrived after the window was already being drawn")
    #expect(sink.recordingStates == [true])
  }

  /// **The effect must beat the GEOMETRY READ, not merely the render.**
  ///
  /// `presentRecording` reads capability on its way to resolving a design, and
  /// that read happens before `apply` is entered — so moving effects to the top
  /// of `apply` fixed only half of it. `LivePreviewCoordinator` applies its
  /// model-removal suppression inside `setRecording`, so a read that beats the
  /// effect can select `.readingWell` for a pill whose preview is about to
  /// resolve DISABLED: a preview-sized window with no preview in it.
  ///
  /// The probe is the provider itself. It answers true only AFTER the effect
  /// has been delivered, so `canHoldWords` is true if and only if the ordering
  /// is right. Asserting the ORDER directly would need a clock; this needs none.
  ///
  /// **The host must PRESENT for this probe to survive**, and it did not have
  /// to before C7. The first version resolved no screen, so the presentation
  /// was refused -- and the presentation asserted below outlived the refusal
  /// only because refused presentations previously left their owner behind. Reading
  /// state that should not exist is not a weaker test, it is a test of the
  /// defect; with the rollback in place the same probe needs a real screen.
  @Test("a recording's effect is delivered before its geometry is resolved")
  func recordingEffectsPrecedeGeometry() {
    var recordingStarted = false
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { Self.screen } })
    // **Both halves ride on the SAME bridge now** (#2292 C2), which states the
    // ordering this case is about more directly than the old pair did: the
    // recording signal and the geometry answer arrive together, so "did the
    // signal land before the geometry was read" is a question about one value.
    let d = OverlayDirector(
      host: host,
      announce: { _ in },
      livePreview: LivePreviewBridge(
        recordingDidChange: { if $0 { recordingStarted = true } },
        isEnabledForGeometry: { recordingStarted },
        wordsCapability: { recordingStarted ? .available : .previewOff },
        display: { .off }),
      grantAccessibility: {}, selections: { .shipped }, firstRenderSchedule: { $0() })
    Self.hosts.append(host)
    defer { Self.closeAllWindows() }

    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0,
          audioLevelProvider: { 0 },
          recordingElapsedProvider: { nil },
          isLocked: false)))

    // **Reads the DESIGN since #2375 C3b**, which is the same question one
    // authority later: the layout bundle it used to read is gone, and what the
    // pill can hold is now a property of the design the transaction captured.
    #expect(
      d.renderModel.state.presentation?.recordingDesign?.canHoldWords == true,
      "geometry was resolved before the effect that freezes its input")
  }

  /// **A dictation ending announces; a chip dismissal must not.**
  ///
  /// The shipped `hide()` and `show(intent: .hidden)` are different operations
  /// and the difference is audible. `LanguageSuggestionPresenter.hideOverlay`
  /// depends on the silent one, with a comment added by a prior review round
  /// saying exactly that — and nothing anywhere expressed it as a property
  /// until now, so a cutover could have collapsed the two and made every chip
  /// dismissal announce a recording that did not just finish.
  @Test("dismissing silently says nothing, while ending a dictation announces")
  func silentDismissalSaysNothing() {
    let (loud, _, loudSink) = Self.director()
    defer { Self.closeAllWindows() }
    Self.record(loud)
    loudSink.announcements.removeAll()

    loud.dismissCurrent(.announced)

    #expect(
      loudSink.announcements.map(\.text) == ["Recording complete"],
      "ending a dictation stopped announcing completion")

    let (quiet, _, quietSink) = Self.director()
    Self.record(quiet)
    quietSink.announcements.removeAll()

    quiet.dismissCurrent(.silent)

    #expect(
      quietSink.announcements.isEmpty,
      "a silent dismissal announced a completed recording that never happened")
    #expect(
      quiet.renderModel.state.presentation == nil,
      "the silent dismissal did not actually empty the slot")
  }

  /// The announcement is POSTED, not merely computed. The reducer's own guard
  /// proves the plan carries one; this proves the director acts on it.
  @Test("presenting a recording announces it")
  func presentingAnnounces() {
    let (d, _, sink) = Self.director()
    defer { Self.closeAllWindows() }

    Self.record(d)

    #expect(
      sink.announcements.map(\.text) == ["Recording started"],
      "the director computed an announcement and never posted it")
    #expect(sink.announcements.first?.isHighPriority == true)
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

    guard case .recording(_, let locked, _, _)? = d.renderModel.state.presentation?.content else {
      Issue.record("expected a recording presentation")
      return
    }
    #expect(locked, "the recording rendered unlocked before a later lock morph")
  }

  /// **One position per presentation, not two reads of a provider.** The
  /// recording transaction captures the anchored edge when the pill is composed;
  /// the host used to re-read it, allowing composition and placement against
  /// different edges.
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

    #expect(
      reads == 1,
      "the host re-read a position already captured by the recording transaction")
  }

  /// **The obligation `OverlayContent.recording` recorded, discharged.** The
  /// non-preview pill reserves a fixed 92-point interaction frame; the Live
  /// Preview variant is content-sized from its first frame so it does not
  /// visibly snap once the real height is measured. The reducer cannot decide
  /// this — preview arrives as a provider, not an event — so the director does.
  ///
  /// **Asserted on the ARGUMENT since C6, which is the thing under test.** The
  /// earlier version read the resulting `NSPanel` frame on the stated grounds
  /// that "a panel 92 points tall is the reserved frame". That is true and it
  /// measured the director's decision through AppKit, which forced a real
  /// window and kept the case out of the Release lane. A windowless host
  /// records the reserved height and the requested width verbatim; whether a
  /// panel honours them is `OverlayWindowHostTests`' question and it owns it.
  @Test("Live Preview makes the recording pill content-sized, and only Live Preview")
  func previewLayoutDropsTheReservedFrame() throws {
    let fixedSetting = PreviewSetting()
    let (fixed, fixedHost, _) = Self.pressableDirector(preview: fixedSetting)
    Self.record(fixed, level: 0.2, preview: false, previewSetting: fixedSetting)
    let compact = try #require(fixedHost.presented.last)

    let previewSetting = PreviewSetting()
    let (preview, previewHost, _) = Self.pressableDirector(preview: previewSetting)
    Self.record(preview, level: 0.2, preview: true, previewSetting: previewSetting)
    let wide = try #require(previewHost.presented.last)

    #expect(
      compact.fixedHeight == 92,
      "the non-preview recording pill lost its reserved 92-point frame")
    #expect(
      wide.fixedHeight == nil,
      "the Live Preview pill reserved a frame instead of sizing to its content")
    // **The WIDTH is the half that is easy to miss.** The shipped site reads
    // `showsPreview ? previewPillWidth : 185` — 400 against 185 — so carrying
    // only the height still renders a preview pill at under half its size.
    #expect(
      compact.width == .fixed(185), "the non-preview recording pill lost its 185-point width")
    #expect(
      wide.width == .fixed(400), "the Live Preview pill did not take its 400-point width")
  }

  // MARK: - A presentation result is delivered exactly once (PR #2370)

  /// **A caller still waiting on its deferred first render must hear
  /// `false` if the director itself goes away first, not nothing.** The
  /// gate cannot resolve this on its own deallocation — the pending relays
  /// live in the director's `pendingFirstAcceptance`, not on the gate — so
  /// the director's own `deinit` is the only place left to settle them.
  /// Cloud review caught this as a regression: the previous mechanism's
  /// `[weak self]` scheduled block explicitly resolved `false` when `self`
  /// had gone nil.
  @Test("a caller waiting on a deferred first render hears false if the director deallocates first")
  func directorDeallocationResolvesAPendingRelay() {
    let deferral = Deferral()
    var results: [PillPresentationResult] = []

    do {
      let host = RefusingWindowlessHost()
      var d: OverlayDirector? = Self.deferrableDirector(host, deferral)
      _ = d!.present(
        .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
        onResult: { results.append($0) })

      #expect(results.isEmpty, "a verdict arrived before any render")
      d = nil
    }

    #expect(
      results == [.notPresented],
      "a caller was left waiting forever when the director deallocated before its render fired")

    // The gate's own scheduled block still exists (captured by `deferral`,
    // independent of the director); firing it now must be a harmless no-op,
    // not a second callback or a crash on the deallocated `self`.
    deferral.fireAll()
    #expect(results == [.notPresented], "firing a stale block after deinit reported a second time")
  }

  /// **THE DEFECT: a receipt is not proof the pill was drawn.** `present`
  /// returns synchronously, and the FIRST presentation of a launch reaches the
  /// host a run loop later — so at the moment a receipt is handed back there is
  /// nothing truthful it can say about a host call that has not happened.
  ///
  /// REPRODUCIBLE: the app is a login item and the Bluetooth card is requested
  /// from `reconcile(trigger: .launch)`, so it is the request most likely to BE
  /// that first presentation. If the host then refuses for want of a screen
  /// while the display wakes, the old code spent a once-per-launch allowance on
  /// a card nobody saw and recorded a `shown` that never happened.
  @Test("a deferred presentation the host refuses reports notPresented")
  func deferredRefusalReportsNotPresented() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    host.accepts = false
    var results: [PillPresentationResult] = []

    let receipt = d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { result in
        results.append(result)
        // **Rollback-before-callback, checked FROM INSIDE the callback
        // itself** — not merely after `deferral.fire()` returns, which would
        // also pass if the callback ran first and the rollback happened
        // later in the same turn. The caller's own code must see the
        // rollback already applied.
        #expect(
          d.renderModel.state.presentation == nil,
          "the callback ran before the refusal's rollback emptied the model")
        #expect(
          d.featureSlotIsAvailable, "the callback ran before the refusal's rollback freed the slot")
      })

    // The receipt IS handed back — admission succeeded — and no result has been
    // delivered yet, because the host has not been asked.
    #expect(receipt != nil, "admission was refused, so this case never reaches its subject")
    #expect(results.isEmpty, "a verdict was delivered before the host was asked")

    deferral.fire()

    #expect(results == [.notPresented], "a refused card was reported as presented")
    #expect(d.renderModel.state.presentation == nil, "a refused card is still published")
    #expect(d.featureSlotIsAvailable, "the refused card still holds the slot")
  }

  /// The paired accepted case. Without it, "reports notPresented" is also
  /// satisfied by a director that reports notPresented for everything.
  @Test("a deferred presentation the host accepts reports presented, once")
  func deferredAcceptanceReportsPresentedOnce() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var results: [PillPresentationResult] = []

    let receipt = try #require(
      d.present(
        .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
        onResult: { results.append($0) }))
    #expect(results.isEmpty, "a verdict was delivered before the host was asked")

    deferral.fire()

    #expect(results == [.presented(receipt)], "the accepted card was not reported once")
    guard case .bluetoothAwareness? = d.renderModel.state.presentation?.content else {
      Issue.record("the accepted card never reached the screen")
      return
    }
  }

  /// **A REQUEST THAT IS REFUSED ANSWERS FOR ITSELF AND FOR NOTHING ELSE.**
  /// The card is still waiting for its run loop when a second feature asks for
  /// the slot and is turned away. The card is untouched by that: it still
  /// renders, and its owner must still be told, because the owner is what
  /// records the receipt the buttons are dispatched through.
  ///
  /// REPRODUCIBLE: a launch-time reconcile defers the card, a second feature
  /// request arrives in the same run-loop turn and is refused for want of the
  /// slot the card itself holds. Resolving the pending caller on the way in put
  /// a VISIBLE Bluetooth card on screen with dead buttons and no `.shown` — the
  /// user sees a tip they cannot dismiss, and the dashboard says they were
  /// never shown one.
  @Test
  func aRefusedRequestLeavesAPendingDeferralsResultIntact() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var cardResults: [PillPresentationResult] = []
    var refusedResults: [PillPresentationResult] = []

    let receipt = try #require(
      d.present(
        .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
        onResult: { cardResults.append($0) }))

    // A second feature asks while the card holds the slot, and is refused.
    let refused = d.present(
      .importStatus(message: "Imported 3 words"),
      onResult: { refusedResults.append($0) })

    #expect(
      refused == nil, "the second feature was admitted, so this case never reaches its subject")
    #expect(refusedResults == [.notPresented], "the refused caller was not told it was refused")
    #expect(cardResults.isEmpty, "the refused request answered on the pending card's behalf")

    deferral.fire()

    #expect(
      cardResults == [.presented(receipt)],
      "the card rendered but its owner was never told, so its buttons have no target")
    guard case .bluetoothAwareness? = d.renderModel.state.presentation?.content else {
      Issue.record("the card never reached the screen")
      return
    }
  }

  /// The paired case: a request that IS admitted supersedes the pending one,
  /// and the pending caller hears `.notPresented` from its own deferred block.
  /// Without this, the case above is satisfied by a director that simply never
  /// reports supersession.
  @Test
  func anAdmittedRequestStillSupersedesAPendingDeferral() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var cardResults: [PillPresentationResult] = []

    d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { cardResults.append($0) })

    // A recording outranks a feature, so this one IS admitted.
    Self.record(d, level: 0.3)
    deferral.fire()

    #expect(
      cardResults == [.notPresented],
      "a card that lost the slot before rendering was reported as presented")
  }

  /// **A DIFFERENT-ID SUPERSESSION RESOLVES ITS OUTGOING CALLER IMMEDIATELY,
  /// NOT WHEN CONSTRUCTION EVENTUALLY COMPLETES.** Nothing is built until the
  /// gate's one scheduled block runs, so a second, different presentation
  /// arriving first coalesces onto the pending slot — and the card that slot
  /// used to hold must hear it lost the slot as soon as that decision is
  /// made, not lazily on an unrelated construction's schedule.
  @Test
  func twoQueuedDeferralsEachAnswerTheirOwnCaller() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var cardResults: [PillPresentationResult] = []
    var noticeResults: [PillPresentationResult] = []

    d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { cardResults.append($0) })

    #expect(cardResults.isEmpty, "a verdict arrived before any render")

    // A pipeline pill outranks the feature, so this one IS admitted — and it
    // defers too, because nothing has rendered yet.
    let notice = try #require(
      d.present(.clipboardFallback, onResult: { noticeResults.append($0) }))

    #expect(
      cardResults == [.notPresented],
      "a different-id supersession must resolve the outgoing owner immediately")
    #expect(noticeResults.isEmpty, "a verdict arrived before any render")

    deferral.fireAll()

    #expect(
      cardResults == [.notPresented],
      "the superseded card was reported through the wrong transaction's verdict")
    #expect(
      noticeResults == [.presented(notice)],
      "the pill that actually rendered was not reported to its own caller")
  }

  /// **A SAME-ID coalescing must retain EVERY caller's relay, not just the
  /// first.** Two audio-level ticks for one ongoing recording share one
  /// presentation id — `presentRecording`'s own `.morphed` branch says so —
  /// and each is a real `present(_:onResult:)` call with its own completion.
  /// `onResult` promises exactly one answer per call, so losing the second
  /// caller's relay to "retain the original" would leave it waiting forever;
  /// both must hear the SAME verdict once the ONE coalesced construction
  /// actually lands.
  @Test
  func twoSameIDCallsBeforeReadinessBothHearTheSingleVerdict() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var firstResults: [PillPresentationResult] = []
    var secondResults: [PillPresentationResult] = []

    let firstReceipt = try #require(
      d.present(
        .recording(
          RecordingPillInput(
            audioLevel: 0.2, audioLevelProvider: { 0.2 },
            recordingElapsedProvider: { nil }, isLocked: false)),
        onResult: { firstResults.append($0) }))
    let secondReceipt = try #require(
      d.present(
        .recording(
          RecordingPillInput(
            audioLevel: 0.4, audioLevelProvider: { 0.4 },
            recordingElapsedProvider: { nil }, isLocked: false)),
        onResult: { secondResults.append($0) }))

    #expect(
      firstResults.isEmpty && secondResults.isEmpty, "a verdict arrived before any render")
    #expect(
      firstReceipt.presentationID == secondReceipt.presentationID,
      "two ticks of the SAME recording minted two different presentation ids")

    deferral.fireAll()

    #expect(host.presentCount == 1, "two same-id ticks produced more than one host command")
    #expect(
      firstResults == [.presented(firstReceipt)],
      "the first caller never heard the single coalesced construction land")
    #expect(
      secondResults == [.presented(secondReceipt)],
      "the second caller's relay was dropped rather than retained")
    guard case .recording(let level, _, _, _)? = d.renderModel.state.presentation?.content else {
      Issue.record("the recording never reached the published frame")
      return
    }
    #expect(
      level == 0.4,
      "the published frame carries the FIRST tick's level, not the latest one the user spoke")
  }

  /// The refusing twin: both callers must hear the SAME refusal, not just the
  /// original.
  @Test
  func twoSameIDCallsBeforeReadinessBothHearARefusal() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    host.accepts = false
    var firstResults: [PillPresentationResult] = []
    var secondResults: [PillPresentationResult] = []

    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0.2, audioLevelProvider: { 0.2 },
          recordingElapsedProvider: { nil }, isLocked: false)),
      onResult: { firstResults.append($0) })
    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0.4, audioLevelProvider: { 0.4 },
          recordingElapsedProvider: { nil }, isLocked: false)),
      onResult: { secondResults.append($0) })

    deferral.fireAll()

    #expect(host.presentCount == 1, "two same-id ticks produced more than one host command")
    #expect(firstResults == [.notPresented], "the first caller did not hear the shared refusal")
    #expect(secondResults == [.notPresented], "the second caller did not hear the shared refusal")
  }

  /// **The real AppKit surface, not the windowless fake's call count.** Every
  /// other same-id row above counts calls into `RefusingWindowlessHost`; this
  /// one asks the actual `OverlayWindowHost` what it told a real `NSPanel` to
  /// do, so a bug that produced one FAKE-host call but two real
  /// `orderFrontRegardless` commands — a shape none of the windowless rows
  /// above could ever see — still fails here.
  @Test("two same-id updates before readiness issue exactly one real orderFrontRegardless")
  func twoSameIDUpdatesIssueExactlyOneRealHostCommand() {
    let recorder = OverlayPanelCommandRecorder()
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { Self.screen } }, panelFactory: recorder.makeFactory())
    let deferral = Deferral()
    let d = OverlayDirector(
      host: host, scheduler: .manual { _ in }, announce: { _ in }, livePreview: .disabled,
      grantAccessibility: {}, selections: { .shipped },
      firstRenderSchedule: { deferral.block = $0 })
    defer { recorder.panel?.orderOut(nil) }

    Self.record(d, level: 0.2)
    Self.record(d, level: 0.4)

    deferral.fireAll()

    let orderFrontCount = recorder.commands.reduce(into: 0) { count, command in
      if case .orderFrontRegardless = command { count += 1 }
    }
    #expect(
      orderFrontCount == 1,
      "two same-id updates issued \(orderFrontCount) real orderFrontRegardless commands")
  }

  /// **Nothing announces or arms before the gate fires, and coalescing an
  /// `.unchanged` update onto an armed `.arm` must not lose the arm.** A
  /// recording presents (its own announcement pending), then an in-panel
  /// notice arms a timed dismiss on the SAME id, then an audio tick —
  /// `.unchanged` — arrives before any of this has rendered. `.unchanged`
  /// must PRESERVE the pending expiry start, not silently drop it.
  @Test("a same-id notice arm survives a later unchanged tick, and nothing fires early")
  func recordingThenTimedNoticeThenUnchangedTickPreservesTheArm() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    var announcements: [OverlayAnnouncement] = []
    let d = OverlayDirector(
      host: host, scheduler: .manual { _ in }, announce: { announcements.append($0) },
      livePreview: .disabled, grantAccessibility: {}, selections: { .shipped },
      firstRenderSchedule: { deferral.block = $0 })

    Self.record(d, level: 0.2)
    d.update(.inPanelNotice(.autoStopUnavailable, dismissAfter: 4.0))
    Self.record(d, level: 0.4)

    #expect(announcements.isEmpty, "an announcement fired before the gate ever ran")
    #expect(d.renderModel.state.dwell == nil, "a dwell was published before anything rendered")

    deferral.fireAll()

    #expect(
      announcements.map(\.text) == ["Recording started"],
      "coalescing must not duplicate or drop the recording's own announcement")
    let dwell = d.renderModel.state.dwell
    #expect(dwell != nil, "the `.arm` from the in-panel notice was lost under a later `.unchanged`")
    #expect(dwell?.seconds == 4.0, "the armed dwell does not match the notice's own dismiss time")
  }

  /// The paired case: `.cancel` on a same-id update MUST clear a previously
  /// armed expiry, not merely leave it alone like `.unchanged` does.
  @Test("a same-id notice cancel clears a previously armed dwell")
  func recordingThenTimedNoticeThenCancelClearsTheArm() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = OverlayDirector(
      host: host, scheduler: .manual { _ in }, announce: { _ in },
      livePreview: .disabled, grantAccessibility: {}, selections: { .shipped },
      firstRenderSchedule: { deferral.block = $0 })

    Self.record(d, level: 0.2)
    d.update(.inPanelNotice(.autoStopUnavailable, dismissAfter: 4.0))
    // A persistent notice cancels the timed one before either ever rendered.
    d.update(.inPanelNotice(.approachingCap, dismissAfter: nil))

    deferral.fireAll()

    #expect(
      d.renderModel.state.dwell == nil,
      "a `.cancel` coalesced onto a pending `.arm` left a dwell armed anyway")
  }

  /// **A REENTRANT `present` from inside a supersession callback must not be
  /// silently overwritten by the outer call finishing its own bookkeeping
  /// after the reentrant call already installed its own slot.** `resolve`
  /// runs arbitrary caller code, and presenting again from inside it is a
  /// real, reachable shape.
  @Test("a reentrant present from inside a supersession callback is not clobbered")
  func reentrantPresentDuringASupersessionCallbackIsNotClobbered() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var aResults: [PillPresentationResult] = []
    var bResults: [PillPresentationResult] = []
    var cResults: [PillPresentationResult] = []
    var cReceipt: PillReceipt?

    d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { result in
        aResults.append(result)
        // Reentrant, synchronous, from inside B's own admission call: a
        // pipeline event always replaces whatever the pipeline last showed,
        // so C supersedes B here — before B's own `present` call returns.
        cReceipt = d.present(.warning(reason: .polishFailed), onResult: { cResults.append($0) })
      })

    let bReceipt = d.present(.clipboardFallback, onResult: { bResults.append($0) })

    #expect(bReceipt != nil, "B was refused, so this case never reaches its subject")
    #expect(aResults == [.notPresented], "A's own refusal callback did not fire exactly once")
    let unwrappedCReceipt = try #require(cReceipt, "the reentrant C call was not admitted")

    deferral.fireAll()

    #expect(aResults == [.notPresented], "A was reported more than once")
    #expect(bResults == [.notPresented], "B was superseded by the reentrant C but not told")
    #expect(
      cResults == [.presented(unwrappedCReceipt)],
      "C, the reentrant presentation, never reached the screen")
  }

  /// **A dismissal before the gate ever fires must still let the ONE
  /// construction complete** — the gate has no cancel, by design (its own
  /// doc comment: "schedule it once, build once") — but that one completed
  /// construction must never reach the host, since nothing was showing by
  /// the time it landed. The proof that only ONE construction happened,
  /// not zero and not two, is that the NEXT presentation is synchronous.
  @Test(
    "dismissing before the gate fires presents nothing, and the next presentation is synchronous")
  func dismissalBeforeReadinessPresentsNothingAndLeavesTheGateReady() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)

    d.present(.warning(reason: .polishFailed))
    d.dismissCurrent(.silent)

    deferral.fireAll()

    #expect(
      host.presentCount == 0,
      "the one construction the gate always completes reached the host after a dismissal")
    #expect(deferral.fired == 1, "more than one construction ran for a single director lifetime")

    d.present(.warning(reason: .polishFailed))

    #expect(
      host.presentCount == 1,
      "a presentation after the gate is ready deferred again instead of rendering synchronously")
    #expect(deferral.fired == 1, "the second presentation scheduled a SECOND construction")
  }

  /// Exactly once, on the path that has the most terminals to get it wrong: the
  /// host refuses, which rolls back through a dismissal that itself renders
  /// successfully. Reading a bare render outcome reported that dismissal as the
  /// presentation's own success.
  @Test
  func aRefusedDeferralReportsExactlyOnce() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    host.accepts = false
    var results: [PillPresentationResult] = []

    d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { results.append($0) })

    deferral.fireAll()
    // Firing again must add nothing: the queue is drained and the relay spent.
    deferral.fireAll()

    #expect(results == [.notPresented], "the refused card was reported \(results.count) times")
  }

  /// A deferred presentation superseded before it renders never reached the
  /// screen, and its caller must hear that rather than nothing at all — a
  /// silent path is what leaves a once-per-launch allowance spent forever.
  @Test("a deferred presentation superseded before rendering reports notPresented")
  func supersededDeferralReportsNotPresented() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    var results: [PillPresentationResult] = []

    d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { results.append($0) })

    // A recording takes the slot while the card is still waiting to render.
    Self.record(d, level: 0.3)
    deferral.fire()

    #expect(results == [.notPresented], "a superseded card was reported as presented")
  }

  /// The ordinary path, which is every presentation after the first: no
  /// deferral, one result, delivered before `present` returns.
  @Test("an immediate presentation reports presented exactly once")
  func immediatePresentationReportsPresentedOnce() throws {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)

    // Spend the deferral on a first presentation, so the next one is
    // synchronous — then clear the slot, or the card is refused at admission
    // and this case never reaches the immediate render it is about.
    d.present(.engineReady)
    deferral.fire()
    d.dismissCurrent(.silent)

    var results: [PillPresentationResult] = []
    let receipt = try #require(
      d.present(
        .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
        onResult: { results.append($0) }))

    #expect(
      deferral.fired == 1, "the second presentation deferred, so this is not the immediate path")
    #expect(
      results == [.presented(receipt)], "the immediate path did not report exactly one result")
  }

  /// Admission refusal is the fourth terminal and the only one that also
  /// returns nil. A caller that hears nothing here would keep an allowance
  /// pending forever waiting for a verdict that never arrives.
  @Test("a request refused at admission reports notPresented and returns nil")
  func admissionRefusalReportsNotPresented() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)
    Self.record(d, level: 0.3)
    deferral.fire()

    var results: [PillPresentationResult] = []
    let receipt = d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { results.append($0) })

    #expect(receipt == nil, "a recording holds the slot, so the card is refused")
    #expect(results == [.notPresented], "an admission refusal delivered no verdict")
  }

  // MARK: - Fail closed (#2292 C19)

  // **`escapeRecoveryWithoutPayloadFailsClosed` was DELETED** (#2292 C5c), and
  // its own comment names the reason it can go: it was "preserved because a
  // bare call still COMPILES". It does not. The one route to that presentation
  // is `present(.escapeRecovery(payload:onPaste:))`, whose payload is not
  // optional, so an offer to Paste with no target behind it is no longer a
  // shape anyone can write. The rule it protected became a property of the API,
  // which is the stronger place for it.

  // MARK: - The first render is deferred one run loop (#2292 C15)

  /// **A crash fix, asserted through the production deferral rather than the
  /// synchronous double the other cases use.**
  ///
  /// `MenuBarController.toggleRecordingAction` reaches the director while the
  /// status-item menu dismiss animation is still running, and building the
  /// `NSHostingView` during it causes a re-entrant `NSWindow` layout cycle and
  /// SIGABRT. The deleted panel deferred every creation with
  /// `DispatchQueue.main.async` and carried that reason in a comment.
  ///
  /// The barrier below is a SIGNAL, not a clock: a continuation enqueued
  /// behind the deferred work resumes only after it has run, so this waits on
  /// the subject rather than on time.
  @Test("the first presentation reaches the window on the NEXT run loop")
  func firstRenderIsDeferred() async {
    let host = WindowlessOverlayHost()
    // The production `firstRenderSchedule` — the default — is the subject here.
    let d = OverlayDirector(
      host: host, announce: { _ in },
      livePreview: .disabled, grantAccessibility: {}, selections: { .shipped })

    d.present(.warning(reason: .polishFailed))
    #expect(
      host.presented.isEmpty,
      "the first presentation reached the window synchronously — this is the menu-dismiss crash")

    await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }

    #expect(host.presented.count == 1, "the deferred first presentation never arrived")
    #expect(host.isShowing, "the deferred presentation did not leave the window showing")
  }

  /// **A first request that is SUPERSEDED must leave the deferral armed.**
  ///
  /// The first version of this fix set a "deferred once" flag when the work was
  /// SCHEDULED. Two paths then reopened the crash: another event arriving
  /// before the queued block ran saw the flag set and built the view
  /// synchronously, and a request dropped by its own identity gate left the
  /// flag set with nothing built, so the next presentation did the same.
  /// Cloud review caught both; keying on whether the view EXISTS closes both.
  @Test("a superseded first request leaves the next one still deferred")
  func supersededFirstRequestKeepsDeferring() async {
    let host = WindowlessOverlayHost()
    let d = OverlayDirector(
      host: host, announce: { _ in },
      livePreview: .disabled, grantAccessibility: {}, selections: { .shipped })

    // First request, deferred. A second replaces it before the run loop turns,
    // so the first drops on its identity gate and builds nothing.
    d.present(.warning(reason: .polishFailed))
    d.present(.processing(phase: .transcribing))
    #expect(host.presented.isEmpty, "a presentation reached the window synchronously")

    await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }

    #expect(
      host.presented.count == 1,
      "the superseded request drew, or the live one never did")
    #expect(host.isShowing, "nothing ended up on screen after the run loop turned")
  }

  /// The pair: only the FIRST is deferred. Every later presentation morphs a
  /// view that already exists, so deferring them all would add a frame of
  /// latency to every transition for a crash window that has closed.
  @Test("a later presentation is not deferred")
  func laterRendersAreSynchronous() async {
    let host = WindowlessOverlayHost()
    let d = OverlayDirector(
      host: host, announce: { _ in },
      livePreview: .disabled, grantAccessibility: {}, selections: { .shipped })
    d.present(.warning(reason: .polishFailed))
    await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }

    d.present(.processing(phase: .transcribing))

    #expect(
      host.presented.count == 2,
      "a later presentation was deferred too, costing a frame on every transition")
  }

  // MARK: - A dictation is ONE presentation, however its content changes (#2292 C12)

  /// **#2195, arriving through the identity gate rather than the placement
  /// value.** `OverlayWindowHostTests` already proves the host keeps a dragged
  /// pill when told `isFresh: false`, and it does. Nothing tested what the
  /// DIRECTOR passes, and the director passed `presentedID != presentation.id`
  /// — true for every occupant change, because the reducer mints a new
  /// `PresentationID` for each one.
  ///
  /// So a dragged pill snapped back to centre the moment the recording became
  /// processing, with the host, the placement value and the whole host suite
  /// behaving perfectly. The rule it broke is written down:
  /// `pill-position-behavior.md` RULE: continuing-panel-vs-fresh-panel.
  /// **Asserted on `isFresh` since C6, which is the value this case is about.**
  /// Its own paragraph says so: the host was already proven to keep a dragged
  /// pill when told `isFresh: false` (`OverlayWindowHostTests` :106), and
  /// nothing tested what the DIRECTOR passes. Reading the resulting panel
  /// origin proved the director's flag through AppKit's placement arithmetic,
  /// which needed a real window and kept the case out of the Release lane. The
  /// windowless host records the flag itself.
  @Test("a dragged pill keeps its place when the recording becomes processing")
  func draggedPillSurvivesAContentChange() throws {
    let (d, host, _) = Self.pressableDirector()
    Self.record(d, level: 0.2)

    d.present(.processing(phase: .transcribing))

    // The first presentation is fresh because nothing is showing. This case
    // asserts only the later recording-to-processing continuation.
    #expect(
      host.presented.last?.isFresh == false,
      """
      the director called the content change a FRESH presentation, so a dragged \
      pill snaps back to centre — #2195 through the director
      """)
  }

  /// The paired case, without which the guard above is satisfied by a director
  /// that never marks anything fresh. A pill appearing when NOTHING is showing
  /// is genuinely new and must centre, drag history or not.
  @Test("a pill appearing after the overlay was hidden is marked fresh again")
  func hiddenThenShownRecentres() {
    let (d, host, _) = Self.pressableDirector()
    Self.record(d, level: 0.2)

    d.dismissCurrent(.announced)
    Self.record(d, level: 0.2)

    #expect(
      host.presented.last?.isFresh == true,
      """
      a pill raised after the overlay emptied was called CONTINUING, so it inherits \
      a drag from a dictation that is over
      """)
  }

  // MARK: - A feature that takes the slot is spoken (#2292 C8)

  /// **The Bluetooth card appeared in silence, and it is the worst case for
  /// that.** Every other pill is transient; this one persists until it is
  /// dismissed, so a VoiceOver user got no signal at all that the overlay had
  /// changed and no later event to infer it from.
  ///
  /// The shipped `apply(intent:)` has a `.bluetoothAwareness` arm posting
  /// `DictationNarrator`'s sentence at MEDIUM priority, and the wiring reached
  /// it by calling `show(intent: .bluetoothAwareness)`. The cutover routed the
  /// card through `reduceFeature`, the one presenting plan that carried no
  /// announcement, and nothing failed.
  @Test("a Bluetooth card is announced at medium priority")
  func bluetoothCardIsAnnounced() {
    let (d, _, sink) = Self.director()
    defer { Self.closeAllWindows() }

    d.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))

    #expect(sink.announcements.count == 1, "the card appeared and said nothing")
    #expect(
      sink.announcements.first?.isHighPriority == false,
      "the card interrupted at high priority; the shipped arm posts medium")
    #expect(
      sink.announcements.first?.text == DictationNarrator.announcement(for: .bluetoothAwareness),
      "the card announced something other than the narrator's sentence")
  }

  /// **The same defect, the same line, the second feature.** The review named
  /// the Bluetooth card; the language chip goes through `reduceFeature` too and
  /// the shipped switch has a `.passiveChip` arm posting at medium. Fixing one
  /// and leaving the other would ship half a repair.
  @Test("a language chip is announced at medium priority")
  func languageChipIsAnnounced() {
    let (d, _, sink) = Self.director()
    defer { Self.closeAllWindows() }
    let payload = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)

    d.present(.languageChip(payload: payload, onLock: {}, onDismiss: {}, onExpire: {}))

    #expect(sink.announcements.count == 1, "the chip appeared and said nothing")
    #expect(
      sink.announcements.first?.isHighPriority == false,
      "the chip interrupted at high priority; the shipped arm posts medium")
  }

  /// **Import status is silent, and that is the shipped behaviour rather than
  /// an omission.** It is the one request with no matching `OverlayIntent`, so
  /// the shipped switch has no arm for it. Asserted so a later reading of
  /// "features announce" cannot quietly add one.
  @Test("an import status pill stays silent, as it shipped")
  func importStatusIsNotAnnounced() {
    let (d, _, sink) = Self.director()
    defer { Self.closeAllWindows() }

    d.present(.importStatus(message: "Importing 3 recordings"))

    #expect(
      d.renderModel.state.presentation != nil, "the status pill never took the slot")
    #expect(
      sink.announcements.isEmpty,
      "import status announced, which the shipped panel never did")
  }

  /// **A refused presentation must not be announced**, which is why the post
  /// moved behind the render rather than staying where the shipped panel put
  /// it. Announcing first makes the sentence unconditional, so a card the host
  /// refuses is still spoken — and told to the one user who has no other way
  /// to discover it is not there.
  @Test("a refused presentation says nothing")
  func refusedPresentationIsNotAnnounced() {
    let (d, sink, _) = Self.refusingDirectorWithSink({ false })
    defer { Self.closeAllWindows() }

    d.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))

    #expect(
      sink.announcements.isEmpty,
      "a card that never reached the screen was announced as though it had")
    #expect(d.featureSlotIsAvailable, "the C7 rollback did not run")
  }

  // MARK: - A refused presentation leaves no owner behind (#2292 C7)

  /// A director whose host refuses every presentation until `screenAvailable`
  /// is flipped.
  ///
  /// **The resolver is re-read on every `present`**, which is what makes the
  /// retry testable: the same director refuses, then succeeds, with nothing
  /// rebuilt in between. A second director would prove only that a fresh one
  /// works, which was never in doubt.
  /// **Captures the armed expiry since C6.** The rollback case needs to fire
  /// whatever timer a refused presentation left behind, and it cannot: this rig
  /// used the LIVE scheduler, so an armed dwell was unreachable and the only
  /// way to ask about one was a Boolean hatch reading `armedExpiry != nil`.
  /// A captured schedule can be FIRED, which turns "is a timer armed" into
  /// "does the timer take the successor down" — the thing a user would meet.
  private static func refusingDirectorWithSink(_ screenAvailable: @escaping () -> Bool)
    -> (OverlayDirector, Sink, Armed)
  {
    let sink = Sink()
    let armed = Armed()
    let host = OverlayWindowHost(
      screens: { OverlayScreenResolver { screenAvailable() ? screen : nil } })
    let d = OverlayDirector(
      host: host,
      scheduler: .manual { armed.work = $0 },
      announce: { sink.announcements.append($0) },
      livePreview: .disabled,
      grantAccessibility: { sink.appActions.append(.grantAccessibility) },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    hosts.append(host)
    return (d, sink, armed)
  }

  /// **Clearing the window is not the same as releasing the slot.**
  ///
  /// `OverlayWindowHost.present` refuses on two causes — no screen, and a
  /// presentation it cannot size — and both leave through the same `guard`, so
  /// one of them proves the director's half of the contract. The host suite
  /// owns the pair; this owns what the director does with a `false`.
  ///
  /// The first version cleared `presentedID` and hid the window, which reads
  /// like a rollback and is not one: the reducer, the render model, the
  /// binding and the armed expiry all still named an occupant that was never
  /// drawn.
  ///
  /// **Asserted through CONSEQUENCES since C6**, because the internal markers
  /// this used to read are gone and most of them had none on their own: nobody
  /// can press a button on a pill that was never drawn, and an internal id
  /// nobody reads cannot hurt a user. What DOES reach a person is the slot —
  /// a refused card that keeps holding it means every later feature is refused
  /// for the rest of the session, which is the failure this case exists for.
  ///
  /// **The armed-timer half is deliberately NOT re-asserted here**, and the
  /// reason is worth stating because the obvious attempt does not work. Firing
  /// "the armed work" after presenting a successor fires the SUCCESSOR'S OWN
  /// dwell, which correctly dismisses it — a test that cannot pass. Firing the
  /// timer captured before the successor tests nothing when the rollback is
  /// correct, because there is no timer to fire. The property that actually
  /// matters — a timer armed for one presentation cannot dismiss another — is
  /// scoped by `PresentationID` and owned by
  /// `staleTimerCannotDismissTheLivePill`, which proves it for every armed
  /// timer including this one.
  @Test("a refused presentation leaves nothing claiming the slot")
  func refusedPresentationReleasesEverything() {
    let (d, _, _) = Self.refusingDirectorWithSink({ false })
    defer { Self.closeAllWindows() }

    d.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))

    #expect(d.renderModel.state.presentation == nil, "a refused card was published anyway")
    #expect(
      d.featureSlotIsAvailable,
      "the refused card still holds the slot, so every later feature is refused too")
  }

  /// **The dedup guard is what turns a refusal into a PERMANENT failure.**
  ///
  /// A repeated intent is dropped as a no-op, by design — it is the guard that
  /// stops an audio tick re-arming a dwell. But a refusal that leaves
  /// `pipelineIntent` holding the refused intent makes the retry look like
  /// that repeat, so the pill never comes back once a screen returns. The
  /// user-visible shape: unplug the external display mid-dictation, plug it
  /// back in, and the overlay is gone for the rest of the session.
  @Test("the same intent presents on retry after a refusal")
  func refusedIntentRetriesSuccessfully() {
    var hasScreen = false
    let (d, _, _) = Self.refusingDirectorWithSink({ hasScreen })
    defer { Self.closeAllWindows() }

    d.present(.warning(reason: .polishFailed))
    #expect(d.renderModel.state.presentation == nil, "the refusal did not take")

    hasScreen = true
    d.present(.warning(reason: .polishFailed))

    #expect(
      d.renderModel.state.presentation != nil,
      "the retry was deduplicated against the intent the refusal left behind")
  }

  /// **A recording's providers are polled ~50 times a second**, so leaving
  /// them installed for a pill that was refused means a finished dictation's
  /// closures run behind an empty screen for the rest of the session. Same
  /// lifetime rule as a replaced recording, arriving through the refusal path
  /// instead.
  @Test("a refused recording releases its providers and its lock survives")
  func refusedRecordingReleasesProviders() {
    let (d, _, _) = Self.refusingDirectorWithSink({ false })
    defer { Self.closeAllWindows() }

    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0.5,
          audioLevelProvider: { 0.5 },
          recordingElapsedProvider: { 3 },
          isLocked: true)))

    #expect(d.renderModel.state.presentation == nil, "a refused recording was published anyway")
    // Asserted through the FRAME rather than a test-only flag: a refused
    // recording that left its providers reachable would leave a recording
    // frame published, and that frame is the only thing a leaf can poll.
    #expect(
      d.renderModel.state.recording == nil,
      "a refused recording's providers are still reachable to poll")
    Self.expectReleasedProvidersDoNotReappear(d.renderModel)
    // **The lock is NOT part of the rollback, and that claim moved to the
    // reducer suite** (#2292 C6). It outlives any one presentation by design,
    // so a refused frame must not silently unlock a hands-free session that is
    // still running — but the lock is only OBSERVABLE where it is drawn, and
    // every recording request carries its own lock flag, so a later pill
    // reports what that call asked for rather than what survived. There is no
    // rendered observation of this property at the director level.
    //
    // `OverlayReducerTests.lockWithoutRecordingIsRemembered` asserts it where
    // it is real: the lock is remembered with NO pill showing, which is the
    // same state a refusal leaves. That case runs in the Release lane.
  }

  // MARK: - Idle prewarm (#2377 Phase 6 C4)
  //
  // `OverlayFirstRenderGateTests` proves the gate's own `scheduleIfNeeded(using:)`
  // override and both race directions in isolation. These four prove the
  // DIRECTOR wires `prewarmFirstRender(idleScheduler:)` into that same gate
  // correctly — no second construction path, no synchronous build, and both
  // scheduler-race outcomes resolve through the full present()/renderModel
  // surface, not just the gate's internal state.

  @Test("prewarmFirstRender registers work asynchronously; nothing constructs before it fires")
  func prewarmRegistersAsynchronously() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let prewarmDeferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)

    d.prewarmFirstRender(idleScheduler: { prewarmDeferral.block = $0 })

    #expect(prewarmDeferral.fired == 0, "prewarm registers work but does not run it synchronously")
    #expect(host.presentCount == 0, "nothing was constructed or presented yet")
  }

  @Test("repeated prewarmFirstRender calls schedule and build at most once")
  func repeatedPrewarmCallsBuildOnce() {
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let prewarmDeferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)

    d.prewarmFirstRender(idleScheduler: { prewarmDeferral.block = $0 })
    d.prewarmFirstRender(idleScheduler: { prewarmDeferral.block = $0 })
    d.prewarmFirstRender(idleScheduler: { prewarmDeferral.block = $0 })
    prewarmDeferral.fireAll()

    #expect(prewarmDeferral.fired == 1, "only one block was ever queued across three calls")

    // A real presentation afterward finds the root already built — it
    // resolves on the SAME turn, with no `deferral.fire()` needed, which is
    // only true if construction already happened via prewarm.
    var results: [PillPresentationResult] = []
    let receipt = d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { results.append($0) })
    #expect(receipt != nil)
    #expect(results.count == 1, "the presentation resolved immediately, without deferral.fire()")
  }

  @Test("prewarmFirstRender after a real presentation already scheduled is a no-op")
  func prewarmAfterDemandDrivenAlreadyScheduledIsANoOp() {
    // Race direction 1: demand-driven wins. Prewarm arriving second must
    // never touch its own scheduler — the gate is already `.scheduled`.
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let prewarmDeferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)

    var results: [PillPresentationResult] = []
    let receipt = d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { results.append($0) })
    #expect(receipt != nil)
    #expect(deferral.fired == 0, "not yet fired")

    d.prewarmFirstRender(idleScheduler: { prewarmDeferral.block = $0 })
    #expect(
      prewarmDeferral.block == nil,
      "prewarm's scheduler never receives work — demand-driven already claimed .scheduled")

    deferral.fire()
    #expect(results.count == 1, "the presentation commits via the scheduler that won the race")
  }

  @Test("a real presentation before prewarm fires still commits once, via the prewarm scheduler")
  func earlyPresentationBeforePrewarmFiresStillCommitsOnce() {
    // Race direction 2, the mirror: prewarm wins. A presentation arriving
    // before the prewarm scheduler fires must coalesce and wait for it — the
    // demand-driven scheduler must never receive work either.
    let host = RefusingWindowlessHost()
    let deferral = Deferral()
    let prewarmDeferral = Deferral()
    let d = Self.deferrableDirector(host, deferral)

    d.prewarmFirstRender(idleScheduler: { prewarmDeferral.block = $0 })

    var results: [PillPresentationResult] = []
    let receipt = d.present(
      .bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}),
      onResult: { results.append($0) })
    #expect(receipt != nil)
    #expect(results.isEmpty, "not yet built — waiting on the prewarm scheduler's fire")
    #expect(
      deferral.fired == 0,
      "the demand-driven scheduler must never receive work: prewarm already scheduled")

    prewarmDeferral.fireAll()

    #expect(results.count == 1, "the presentation commits exactly once, via the prewarm scheduler")
    guard case .bluetoothAwareness? = d.renderModel.state.presentation?.content else {
      Issue.record("the presentation never reached the screen")
      return
    }
  }
}
