import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2292 chunk C2. The arbitration and identity rules that decide WHAT occupies
/// the overlay slot.
///
/// **Product Outcome, and the sentence finishes easily for every case here:**
/// when one of these fails the user sees the wrong pill, sees a pill vanish
/// mid-recording, or sees a notice from a dictation that already ended.
///
/// Every test in this suite runs with no AppKit, no window server, no run loop
/// and no clock. That is not a convenience — it is the property the reducer was
/// extracted to have. The rules it encodes are today spread across a shared
/// `currentIntent` slot, an `importStatusOwnsCurrentSlot` computed property, a
/// Bluetooth `isPresented` flag and a passive-chip generation counter, and
/// nothing holds those four to the same answer because no test can reach them
/// together.
@Suite(.tags(.productOutcome))
struct OverlayReducerTests {

  /// Deterministic ids, so identity can be asserted rather than inferred.
  private static func sequencedReducer() -> (OverlayReducer, () -> PresentationID) {
    var n = 0
    let make = {
      n += 1
      return PresentationID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!)
    }
    return (OverlayReducer(makeID: make), make)
  }

  private static func makeReducer() -> OverlayReducer { sequencedReducer().0 }

  // MARK: - The arbitration rule

  @Test("a feature cannot take the slot while the pipeline is recording")
  func featureIsRefusedDuringRecording() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.4)))

    let plan = r.reduce(.featureRequest(.importStatus(message: "Imported 12 words")))

    #expect(plan.didChange == false)
    #expect(plan.presentation == nil)
    // The recording pill is still the occupant — the feature did not displace it.
    if case .recording = r.state.current?.content {
    } else {
      Issue.record("recording pill lost the slot to a feature request")
    }
  }

  /// The PAIRED accepted case. Without it, a reducer that refuses every feature
  /// request unconditionally would pass the test above and look correct.
  @Test("a feature takes the slot while the pipeline is idle")
  func featureIsAcceptedWhenIdle() {
    var r = Self.makeReducer()
    let plan = r.reduce(.featureRequest(.importStatus(message: "Imported 12 words")))

    #expect(plan.didChange)
    guard case .notice(let notice)? = plan.presentation?.content else {
      Issue.record("expected an import-status notice to occupy the slot")
      return
    }
    #expect(notice.text == "Imported 12 words")
  }

  @Test(
    "every feature request obeys the same arbitration rule",
    arguments: [
      OverlayRequest.importStatus(message: "x"),
      .bluetoothAwareness,
      .accessibilityToast,
      .passiveChip(
        payload: LanguageChipPayload(
          lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)),
    ])
  func everyFeatureObeysTheRule(request: OverlayRequest) {
    // The defect this guards is not one feature getting it wrong; it is the four
    // features DISAGREEING, which is what four separate ownership flags produce.
    var busy = Self.makeReducer()
    _ = busy.reduce(.pipeline(.recording(audioLevel: 0.1)))
    #expect(busy.reduce(.featureRequest(request)).didChange == false)

    var idle = Self.makeReducer()
    #expect(idle.reduce(.featureRequest(request)).didChange)
  }

  // MARK: - Identity

  @Test("audio-level updates keep the recording pill's identity")
  func meteringDoesNotChurnIdentity() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.1)))
    let first = r.state.current?.id

    for level in [Float(0.2), 0.3, 0.9, 0.0] {
      _ = r.reduce(.pipeline(.recording(audioLevel: level)))
    }

    #expect(r.state.current?.id == first)
    // A new id per metering tick would re-arm expiry and re-measure the frame on
    // every audio callback, which is many times a second.
    guard case .recording(let level, _, _)? = r.state.current?.content else {
      Issue.record("expected a recording pill")
      return
    }
    #expect(level == 0.0)
  }

  @Test("a stale expiry cannot dismiss the presentation that replaced it")
  func staleExpiryIsDropped() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.warning(reason: .polishFailed)))
    let stale = try! #require(r.state.current?.id)

    // A newer presentation takes the slot before the old timer fires.
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.5)))
    let live = try! #require(r.state.current?.id)
    #expect(stale != live)

    let plan = r.reduce(.expiryFired(stale))

    #expect(plan.didChange == false)
    #expect(r.state.current?.id == live, "a stale expiry dismissed the live recording pill")
  }

  /// Paired accepted case: the CURRENT id's expiry must still work, or the guard
  /// above is satisfied by a reducer that ignores expiry entirely.
  @Test("the current presentation's own expiry dismisses it")
  func currentExpiryDismisses() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.warning(reason: .polishFailed)))
    let live = try! #require(r.state.current?.id)

    let plan = r.reduce(.expiryFired(live))

    #expect(plan.didChange)
    #expect(plan.presentation == nil)
    #expect(r.state.current == nil)
  }

  @Test("a stale action is dropped")
  func staleActionIsDropped() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.accessibilityToast))
    let stale = try! #require(r.state.current?.id)
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.2)))

    let plan = r.reduce(.action(stale, .grantAccessibility))

    #expect(plan.deliverAction == nil, "an action from a dismissed pill reached a feature")
  }

  @Test("the current presentation's action is delivered")
  func currentActionIsDelivered() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.accessibilityToast))
    let live = try! #require(r.state.current?.id)

    #expect(r.reduce(.action(live, .grantAccessibility)).deliverAction == .grantAccessibility)
  }

  // MARK: - The in-panel notice

  @Test("an in-panel notice morphs the live recording pill rather than replacing it")
  func inPanelNoticeMorphsRatherThanReplaces() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.3)))
    let id = try! #require(r.state.current?.id)

    let plan = r.reduce(.inPanelNotice(.approachingCap, dismissAfter: nil))

    #expect(plan.didChange)
    #expect(plan.presentation?.id == id, "the notice replaced the pill instead of morphing it")
    guard case .recording(let level, _, let notice)? = plan.presentation?.content else {
      Issue.record("expected the recording pill to survive")
      return
    }
    #expect(notice?.reason == .approachingCap)
    #expect(level == 0.3, "the notice discarded the live audio level")
  }

  @Test("an in-panel notice with no recording pill is a no-op")
  func inPanelNoticeWithoutRecordingIsIgnored() {
    var r = Self.makeReducer()
    #expect(r.reduce(.inPanelNotice(.autoStopUnavailable, dismissAfter: 4)).didChange == false)
    #expect(r.state.current == nil)
  }

  // MARK: - Hover

  @Test("hovering a pausable presentation stops it expiring, and leaving re-arms it")
  func hoverPausesExpiry() {
    var r = Self.makeReducer()
    let payload = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)
    _ = r.reduce(.pipeline(.passiveChip(payload: payload)))
    let id = try! #require(r.state.current?.id)

    #expect(r.reduce(.hoverChanged(id, true)).expiryCommand == .cancel,
      "hover-enter did not cancel the armed timer, so hover-pause does nothing")
    // While hovered, the timer firing must not dismiss it.
    #expect(r.reduce(.expiryFired(id)).didChange == false)
    #expect(r.state.current?.id == id)

    let leaving = r.reduce(.hoverChanged(id, false))
    #expect(
      leaving.expiryCommand == .arm(id: id, seconds: 6),
      "leaving a hovered chip did not re-arm its dismissal")
  }

  // MARK: - No-ops

  @Test("hiding an already-empty slot is not a change")
  func hidingAnEmptySlotIsANoOp() {
    var r = Self.makeReducer()
    #expect(r.reduce(.pipeline(.hidden)).didChange == false)
  }

  @Test("hiding an occupied slot is a change")
  func hidingAnOccupiedSlotIsAChange() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.1)))
    let plan = r.reduce(.pipeline(.hidden))
    #expect(plan.didChange)
    #expect(plan.presentation == nil)
  }

  // MARK: - The reserved interaction frame

  @Test("only the NON-PREVIEW recording pill reserves a fixed height")
  func onlyRecordingReservesAFixedFrame() {
    // #1060: the 92-point recording frame is deliberate — it holds the normal
    // 185x44, the locked 120x64 and the in-panel notice expansion without
    // resizing on every morph. This migration does NOT make every kind
    // content-sized, and asserting that here is what stops a later chunk
    // "simplifying" it away.
    //
    // Scoped to NON-PREVIEW deliberately. With Live Preview on, the shipped
    // path is content-sized (`RecordingOverlayPanel.swift:855-861`), so the
    // earlier unscoped name claimed more than the code does. The reducer cannot
    // yet tell the two apart — the preview flag is a provider the director owns
    // — so C3 adds that branch and this test gains its pair.
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.1)))
    #expect(r.state.current?.reservesFixedHeight == 92)
    #expect(r.state.current?.requestedWidth == .fixed(185))

    _ = r.reduce(.pipeline(.hidden))
    _ = r.reduce(.pipeline(.clipboardFallback))
    #expect(r.state.current?.reservesFixedHeight == nil)
  }

  // MARK: - Regressions cloud review found in the first version of this chunk

  /// **The expensive one.** Shipped `hide()` sets `currentIntent = .hidden`
  /// (`RecordingOverlayPanel.swift:1912`, `:1924`), so once a notice
  /// auto-dismisses the pipeline is idle and features may take the slot again.
  /// The first reducer left `pipelineIntent` at `.warning` forever, so EVERY
  /// feature pill was blocked for the rest of the session after any pipeline
  /// notice — the arbitration rule this reducer exists to state, failing in the
  /// direction nothing would ever report.
  @Test("a feature can take the slot again after a pipeline notice expires")
  func pipelineReturnsToIdleWhenItsNoticeExpires() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.warning(reason: .polishFailed)))
    let id = try! #require(r.state.current?.id)
    _ = r.reduce(.expiryFired(id))

    #expect(
      r.reduce(.featureRequest(.importStatus(message: "Imported 12 words"))).didChange,
      "features stayed blocked after a pipeline notice expired")
  }

  /// A `.untilReplaced` presentation has no timer, so an expiry naming it is by
  /// definition stale. The first version dismissed it, which would close the
  /// recording pill mid-dictation.
  @Test("an expiry cannot dismiss a presentation that has no timer")
  func expiryCannotDismissAPersistentPresentation() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.4)))
    let id = try! #require(r.state.current?.id)

    let plan = r.reduce(.expiryFired(id))

    #expect(plan.didChange == false)
    #expect(r.state.current?.id == id, "a stray expiry closed the live recording pill")
  }

  /// Hover must not suppress the expiry of a notice that is not hover-pausable.
  /// The first version recorded hover unconditionally and only then checked
  /// `pausesOnHover`, so a stray pointer over an ordinary notice left it on
  /// screen until something replaced it. No existing test reached it because
  /// every hover case in this suite used a pausable kind.
  @Test("hovering a non-pausable notice does not stop it expiring")
  func hoverDoesNotPauseAnOrdinaryNotice() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.error(reason: .asrFailed)))
    let id = try! #require(r.state.current?.id)

    _ = r.reduce(.hoverChanged(id, true))
    let plan = r.reduce(.expiryFired(id))

    #expect(plan.didChange, "a hover kept a non-pausable notice on screen indefinitely")
    #expect(r.state.current == nil)
  }

  /// A width the shipped code DISCARDS must not be carried as a literal.
  /// `showPanel(fitToContent:)` sizes from the view's own `fittingSize` and
  /// ignores the `width` argument (`RecordingOverlayPanel.swift:1430-1435`), so
  /// a row whose view pins no width is `.measured` however plausible the number
  /// at its call site looks. Two review rounds were spent on this exact shape.
  @Test(
    "a presentation whose view does not pin a width is measured, not a literal",
    arguments: [
      OverlayIntent.processing(phase: .transcribing),
      .clipboardFallback,
    ])
  func viewSizedPresentationsAreMeasured(intent: OverlayIntent) {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(intent))
    #expect(r.state.current?.requestedWidth == .measured)
  }

  /// The paired case, or the guard above is satisfied by making everything
  /// measured. `BluetoothAwarenessCardView` pins `.frame(width: 320)` of its own
  /// (`:58`, `:119`), so it stays fixed despite `fitToContent: true` at the call
  /// site — the call-site flag is not the discriminator, the VIEW is.
  @Test("a presentation whose view pins its own width stays fixed")
  func viewPinnedPresentationsStayFixed() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.bluetoothAwareness))
    #expect(r.state.current?.requestedWidth == .fixed(320))
  }

  /// A new occupant must never inherit the previous one's timer. `.unchanged`
  /// here would leave a dismissal armed for a pill that is gone, which is the
  /// stale-dismissal defect one level up from the id check.
  @Test("a persistent presentation cancels the previous occupant's timer")
  func persistentPresentationCancelsTheArmedTimer() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.warning(reason: .polishFailed)))
    let plan = r.reduce(.pipeline(.recording(audioLevel: 0.3)))
    #expect(plan.expiryCommand == .cancel)
  }

  // MARK: - Facts a bare enum case would have thrown away

  /// `LanguageSuggestionPresenter.currentChip` (`:46`) is cleared by a
  /// GENERATION-GATED call (`:279-281`), so an expiry that says only "the slot is
  /// empty" leaves the presenter holding a chip forever.
  @Test("an auto-dismissed language chip tells its owner, with the generation")
  func chipExpiryNotifiesItsOwner() {
    var r = Self.makeReducer()
    let payload = LanguageChipPayload(
      lang: "fr", displayName: "French", state: .askToLock, generation: 42)
    _ = r.reduce(.pipeline(.passiveChip(payload: payload)))
    let id = try! #require(r.state.current?.id)

    let plan = r.reduce(.expiryFired(id))

    #expect(plan.effects.contains(.languageChipAutoDismissed(generation: 42)))
  }

  /// The escape-recovery payload is taken by transcript id
  /// (`RecordingOverlayPanel.swift:137`), a one-shot take. If the pill expires
  /// unpressed, the owner must drop it.
  @Test("an expired escape-recovery pill releases its payload")
  func escapeRecoveryExpiryReleasesThePayload() {
    var r = Self.makeReducer()
    let transcript = UUID()
    _ = r.reduce(.pipeline(.escapeRecovery(transcriptID: transcript)))
    let id = try! #require(r.state.current?.id)

    let plan = r.reduce(.expiryFired(id))

    #expect(plan.effects.contains(.escapeRecoveryExpired(transcriptID: transcript)))
  }

  /// `setRecordingIntentObserver` (`:469`) had no representation at all in the
  /// first model — not a wrong value, an absent one.
  @Test("the recording intent observer is told when recording starts and stops")
  func recordingIntentIsObservable() {
    var r = Self.makeReducer()
    #expect(
      r.reduce(.pipeline(.recording(audioLevel: 0.2))).effects
        == [.recordingIntentChanged(true)])
    // A metering update is not a start: it must not re-notify.
    #expect(r.reduce(.pipeline(.recording(audioLevel: 0.9))).effects.isEmpty)
    #expect(r.reduce(.pipeline(.hidden)).effects == [.recordingIntentChanged(false)])
  }

  /// `updateLockState` (`:1601`) morphs the live recording pill and does nothing
  /// otherwise. The first model carried `isLocked` with no event able to set it.
  @Test("hands-free lock morphs the live recording pill")
  func lockMorphsTheRecordingPill() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.5)))
    let id = try! #require(r.state.current?.id)

    let plan = r.reduce(.lockStateChanged(true))

    #expect(plan.didChange)
    #expect(plan.presentation?.id == id, "locking replaced the pill instead of morphing it")
    guard case .recording(let level, let locked, _)? = plan.presentation?.content else {
      Issue.record("expected the recording pill to survive locking")
      return
    }
    #expect(locked)
    #expect(level == 0.5, "locking discarded the live audio level")
    // Idempotent: the same state again is not a change.
    #expect(r.reduce(.lockStateChanged(true)).didChange == false)
  }

  @Test("a lock change with no recording pill draws nothing but is remembered")
  func lockWithoutRecordingIsRemembered() {
    var r = Self.makeReducer()
    // Shipped `updateLockState` (`:1601-1604`) has NO recording guard.
    #expect(r.reduce(.lockStateChanged(true)).didChange == false)
    #expect(r.state.isLocked, "the lock was dropped because no pill was showing")
  }

  /// `show(...isRecordingLocked:)` (`:502`) exists so a pill is BORN locked. The
  /// first model always started `isLocked: false`, so a locked start would have
  /// rendered unlocked for a frame and then morphed.
  @Test("a recording pill that starts while locked is born locked")
  func recordingIsBornLocked() {
    var r = Self.makeReducer()
    _ = r.reduce(.lockStateChanged(true))

    let plan = r.reduce(.pipeline(.recording(audioLevel: 0.3)))

    guard case .recording(_, let locked, _)? = plan.presentation?.content else {
      Issue.record("expected a recording pill")
      return
    }
    #expect(locked, "the pill rendered unlocked despite the lock being on")
  }

  @Test("a recording pill that starts unlocked is not born locked")
  func recordingIsNotBornLockedByDefault() {
    var r = Self.makeReducer()
    let plan = r.reduce(.pipeline(.recording(audioLevel: 0.3)))
    guard case .recording(_, let locked, _)? = plan.presentation?.content else {
      Issue.record("expected a recording pill")
      return
    }
    #expect(locked == false)
  }

  /// `BluetoothAwarenessPresenter` emits `.dismissed/.gotIt` versus
  /// `.dismissed/.closed` (`:193-196`). Collapsing them into one action would
  /// have made the dashboard unable to tell "I understand" from "go away".
  @Test("acknowledging and closing the Bluetooth card stay distinct")
  func bluetoothDismissalsStayDistinct() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.bluetoothAwareness))
    let id = try! #require(r.state.current?.id)

    #expect(
      r.reduce(.action(id, .acknowledgeBluetoothAwareness)).deliverAction
        == .acknowledgeBluetoothAwareness)
    #expect(
      r.reduce(.action(id, .closeBluetoothAwareness)).deliverAction
        == .closeBluetoothAwareness)
    #expect(OverlayAction.acknowledgeBluetoothAwareness != .closeBluetoothAwareness)
  }

  /// `onEscapeRecoveryPaste` takes the payload, and the panel looks it up by id
  /// with a one-shot take. A bare `.pasteEscapeRecovery` would have delivered
  /// "the user pressed Undo" with nothing to undo.
  @Test("the Undo action carries the transcript it undoes")
  func undoCarriesItsTranscript() {
    var r = Self.makeReducer()
    let transcript = UUID()
    _ = r.reduce(.pipeline(.escapeRecovery(transcriptID: transcript)))
    let id = try! #require(r.state.current?.id)

    #expect(
      r.reduce(.action(id, .pasteEscapeRecovery(transcriptID: transcript))).deliverAction
        == .pasteEscapeRecovery(transcriptID: transcript))
  }
}
