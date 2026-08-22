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
      leaving.expiryCommand == .arm(id: id, seconds: 6, target: .presentation),
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
    // path is content-sized (`RecordingOverlayPanel.swift`), so the
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
  /// (`RecordingOverlayPanel.swift`), so once a notice
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
  /// ignores the `width` argument (`RecordingOverlayPanel.swift`), so
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
  ///, so it stays fixed despite `fitToContent: true` at the call
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

  /// `LanguageSuggestionPresenter.currentChip` is cleared by a
  /// GENERATION-GATED call, so an expiry that says only "the slot is
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
  /// (`RecordingOverlayPanel.swift`), a one-shot take. If the pill expires
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

  /// `setRecordingIntentObserver` had no representation at all in the
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

  /// `updateLockState` morphs the live recording pill and does nothing
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
    // Shipped `updateLockState` has NO recording guard.
    #expect(r.reduce(.lockStateChanged(true)).didChange == false)
    #expect(r.state.isLocked, "the lock was dropped because no pill was showing")
  }

  /// `show(...isRecordingLocked:)` exists so a pill is BORN locked. The
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
  /// `.dismissed/.closed`. Collapsing them into one action would
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

  /// **Every notice names the leaf view that draws it, and the mapping is
  /// pinned.** Collapsing eleven `transitionTo*` methods into one model does not
  /// collapse their appearance: a sentence, a severity and a dwell do not say
  /// whether to draw a spinner, a spectrum wheel or a warning triangle.
  ///
  /// Swept over the closed set rather than spot-checked, because the failure is
  /// a WRONG icon rather than a missing one — a cold-start pill that renders the
  /// ready mark looks perfectly fine and says the opposite of the truth.
  ///
  /// **THE ORACLE IS `RecordingOverlayPanel.apply(intent:)`, NOT THIS TABLE.**
  /// The first version of this test listed whatever the reducer already
  /// returned, which makes it a tautology dressed as a guard: it pinned the
  /// mapping to itself and passed. It was rewritten after reading the shipped
  /// switch for all eleven intents, one at a time, and one row was WRONG —
  /// `.recoverySucceeded` draws `ColdStartNoticeView(icon: .ready)`, a green
  /// success mark, and the reducer was routing it through
  /// `NotificationOverlayView`, which paints a warning. So the table below
  /// carries the shipped call site's own line for each row: a reader can check
  /// it, and re-deriving it from the reducer reproduces the tautology.
  ///
  /// Severity rides in the same table because kind alone does not decide the
  /// picture: five intents share `.notification` and only the severity tells
  /// them apart.
  @Test(
    "every notice carries the visual identity its shipped pill had",
    arguments: [
      // intent, kind, severity, shipped call site in RecordingOverlayPanel
      (OverlayIntent.processing(phase: .transcribing), NoticeModel.Kind.processing,
        NoticeModel.Severity.neutral, "showPolishing"),
      (.clipboardFallback, .processing, .neutral, "showClipboardFallback"),
      (.accessibilityToast, .accessibilityToast, .neutral, "showAccessibilityToast"),
      (.warning(reason: .polishFailed), .notification, .warning, "showWarning style .warning"),
      (.error(reason: .asrFailed), .notification, .error, "showError style .error"),
      (.advisory(reason: .zeroSignal), .notification, .advisory, "showAdvisory style .advisory"),
      (.interruption(reason: .deviceRemoved), .notification, .distress,
        "showNotification style .interruption"),
      (.cachingModel(engineLabel: "Parakeet"), .warmingUp, .neutral,
        "ColdStartNoticeView icon .spinner"),
      (.engineReady, .ready, .neutral, "ColdStartNoticeView icon .ready"),
      (.recoveringLastRecording, .recovery, .neutral, "RecoveryNoticeView"),
      (.recoverySucceeded, .ready, .neutral, "ColdStartNoticeView icon .ready"),
    ])
  func noticeVisualIdentityIsPinned(
    row: (
      intent: OverlayIntent, kind: NoticeModel.Kind, severity: NoticeModel.Severity,
      shipped: String
    )
  ) {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(row.intent))
    guard case .notice(let notice)? = r.state.current?.content else {
      Issue.record("\(row.intent) did not produce a notice")
      return
    }
    #expect(
      notice.kind == row.kind,
      "\(row.intent) should draw as \(row.kind) — the shipped panel uses \(row.shipped)")
    #expect(
      notice.severity == row.severity,
      "\(row.intent) should carry severity \(row.severity) — shipped: \(row.shipped)")
  }

  /// **No `.notification` notice may take the severity default.** `.neutral` is
  /// the notice helper's default and is harmless on every other kind, because no
  /// other kind consults it. `.notification` is the one that does:
  /// `OverlayRootView.style(for:)` turns severity into the pill's colour and
  /// icon, so a row that forgets to state one renders as a warning whatever it
  /// actually is.
  ///
  /// This is the guard that would have caught the `.recoverySucceeded` defect
  /// from the other direction, and it is a SET sweep rather than a row: it walks
  /// every intent the reducer can be handed, so a new one cannot be added
  /// without either stating a severity or failing here.
  @Test("a notification-styled notice always states its own severity")
  func notificationNoticesNeverTakeTheSeverityDefault() {
    let everyIntent: [OverlayIntent] = [
      .processing(phase: .transcribing), .clipboardFallback, .accessibilityToast,
      .warning(reason: .polishFailed), .error(reason: .asrFailed),
      .advisory(reason: .zeroSignal), .interruption(reason: .deviceRemoved),
      .cachingModel(engineLabel: "Parakeet"), .engineReady,
      .recoveringLastRecording, .recoverySucceeded,
    ]
    for intent in everyIntent {
      var r = Self.makeReducer()
      _ = r.reduce(.pipeline(intent))
      guard case .notice(let notice)? = r.state.current?.content else { continue }
      guard notice.kind == .notification else { continue }
      #expect(
        notice.severity != .neutral,
        "\(intent) renders through NotificationOverlayView with no severity of its own, so it would paint as a warning regardless of what it means")
    }
  }

  /// **Every notice's BOX comes from its shipped `showPanel` call, and omitting
  /// a height is a decision rather than a default.** The first port carried every
  /// width and no height at all, so eight pills that reserve a fixed box became
  /// content-sized — a geometry change with no compiler error, no failing test
  /// and nothing in the diff to look at, because `reservesFixedHeight` simply
  /// defaults to nil.
  ///
  /// Oracle is `RecordingOverlayPanel`, read one call site at a time; each row
  /// names it. `nil` means the shipped site passes `fitToContent: true`, which
  /// makes the height content-driven and DISCARDS the width argument.
  @Test(
    "every notice reserves the box its shipped pill reserved",
    arguments: [
      // intent, fixed height or nil for content-sized, shipped call site
      (OverlayIntent.processing(phase: .transcribing), CGFloat?.none, "showPanel fitToContent"),
      (.clipboardFallback, nil, "showPanel fitToContent"),
      (.accessibilityToast, 56, "showPanel height: 56"),
      (.warning(reason: .polishFailed), 44, "showPanel default height 44, not fitToContent"),
      (.error(reason: .asrFailed), 44, "showPanel default height 44, not fitToContent"),
      (.interruption(reason: .deviceRemoved), 44, "showPanel default height 44, not fitToContent"),
      // The one notification that IS content-sized: `fitToContent:` is passed
      // `style.isMultiline`, and advisory is the only style where that is true.
      (.advisory(reason: .zeroSignal), nil, "showPanel fitToContent style.isMultiline"),
      (.cachingModel(engineLabel: "Parakeet"), 56, "presentTransientNotice height 56"),
      (.engineReady, 44, "presentTransientNotice height 44"),
      (.recoveringLastRecording, 56, "presentTransientNotice height 56"),
      (.recoverySucceeded, 56, "presentTransientNotice height 56"),
    ])
  func noticeGeometryIsPinned(row: (intent: OverlayIntent, height: CGFloat?, shipped: String)) {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(row.intent))
    guard let presentation = r.state.current else {
      Issue.record("\(row.intent) produced no presentation")
      return
    }
    #expect(
      presentation.reservesFixedHeight == row.height,
      "\(row.intent) should reserve \(String(describing: row.height)) — shipped: \(row.shipped)")
  }

  /// The two presentations that are not notices carry a box too, and neither
  /// goes through the notice factory, so the sweep above cannot see them.
  @Test("the language chip and the accessibility feature request keep their boxes")
  func nonNoticePresentationsKeepTheirBoxes() {
    var chip = Self.makeReducer()
    _ = chip.reduce(
      .pipeline(
        .passiveChip(
          payload: LanguageChipPayload(
            lang: "es", displayName: "Spanish", state: .askToLock, generation: 1))))
    #expect(
      chip.state.current?.reservesFixedHeight == 56,
      "the language chip is showPanel(width: 340, height: 56) at its shipped site")

    var toast = Self.makeReducer()
    _ = toast.reduce(.featureRequest(.accessibilityToast))
    #expect(
      toast.state.current?.reservesFixedHeight == 56,
      "the accessibility toast is showPanel(height: 56) at its shipped site")
  }

  /// The feature-request half of the notice table. The closed-set sweep above
  /// walks PIPELINE intents only, so a feature row could carry any kind at all
  /// and nothing would notice.
  @Test("an accessibility feature request renders as an accessibility toast")
  func featureAccessibilityToastKind() {
    var r = Self.makeReducer()
    _ = r.reduce(.featureRequest(.accessibilityToast))
    guard case .notice(let notice)? = r.state.current?.content else {
      Issue.record("expected a notice")
      return
    }
    #expect(notice.kind == .accessibilityToast)
  }

  /// **Every pipeline intent announces itself, and the priority is per-intent.**
  /// The shipped panel posts for all sixteen; deleting it without these would
  /// make the app silent for VoiceOver users with nothing failing anywhere.
  ///
  /// The priority is NOT derivable from severity — `.recording` and
  /// `.engineReady` are high while `.warning` is medium — so it is enumerated
  /// against the shipped switch rather than computed.
  @Test(
    "every pipeline intent announces itself at its shipped priority",
    arguments: [
      (OverlayIntent.hidden, false), (.recording(audioLevel: 0), true),
      (.processing(phase: .transcribing), false), (.clipboardFallback, true),
      (.accessibilityToast, true), (.warning(reason: .polishFailed), false),
      (.error(reason: .asrFailed), true), (.advisory(reason: .zeroSignal), true),
      (.interruption(reason: .deviceRemoved), true),
      (.cachingModel(engineLabel: "Parakeet"), false), (.engineReady, true),
      (.recoveringLastRecording, true), (.recoverySucceeded, true),
      (.bluetoothAwareness, false),
      // The two the first version of this table left out while its commit body
      // claimed all sixteen. A count in prose is a claim; this is the set.
      (
        .passiveChip(
          payload: LanguageChipPayload(
            lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)), false
      ),
      (
        .escapeRecovery(
          transcriptID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), false
      ),
    ])
  func everyIntentAnnouncesAtItsShippedPriority(row: (intent: OverlayIntent, high: Bool)) {
    var r = Self.makeReducer()
    // A fresh reducer's `pipelineIntent` is `.hidden`, exactly as the shipped
    // panel's `currentIntent` is, so a first `.hidden` push is a REPEAT in both
    // and is correctly silent in both. The row still has to be exercised, so it
    // is primed with something else — the priming is what makes it a change, not
    // a workaround for a defect.
    if case .hidden = row.intent { _ = r.reduce(.pipeline(.engineReady)) }
    let plan = r.reduce(.pipeline(row.intent))
    guard let announcement = plan.announcement else {
      Issue.record("\(row.intent) announced nothing — a VoiceOver user hears silence")
      return
    }
    #expect(
      announcement.text == DictationNarrator.announcement(for: row.intent),
      "the narrator is the sole author of the sentence (#1569 E4)")
    #expect(
      announcement.isHighPriority == row.high,
      "\(row.intent) announced at the wrong priority")
  }

  /// **A repeated intent is silent**, which is the shipped dedup guard's own
  /// condition: the post sits after `guard intent != currentIntent`. Without
  /// this, a live dictation would re-announce on every push.
  @Test("a repeated intent does not announce again")
  func repeatedIntentIsSilent() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0)))

    let second = r.reduce(.pipeline(.recording(audioLevel: 0)))

    #expect(
      second.announcement == nil,
      "the same intent announced twice, so a VoiceOver user hears it repeatedly")
  }

  /// **A repeated intent is DROPPED, not merely silenced.** The first cutover
  /// returned a fresh presentation with a new ID and re-armed the expiry, so a
  /// duplicate push restarted a notice's dwell and reset SwiftUI identity — the
  /// #930 flicker arriving through the guard that exists to prevent it.
  @Test("a repeated non-recording intent changes nothing at all")
  func repeatedIntentIsACompleteNoOp() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.warning(reason: .polishFailed)))
    let first = r.state.current?.id

    let again = r.reduce(.pipeline(.warning(reason: .polishFailed)))

    #expect(again.didChange == false, "a duplicate rebuilt the presentation")
    #expect(again.expiryCommand == .unchanged, "a duplicate restarted the dwell")
    #expect(r.state.current?.id == first, "a duplicate reset SwiftUI identity")
  }

  /// **Import status may only replace ITSELF.** Pipeline idleness alone is not
  /// the shipped rule: a status pill could otherwise take the slot from the
  /// Bluetooth card, which the panel refused.
  @Test("import status cannot take the slot from another feature")
  func importStatusCannotStealAFeatureSlot() {
    var r = Self.makeReducer()
    _ = r.reduce(.featureRequest(.bluetoothAwareness))

    let stolen = r.reduce(.featureRequest(.importStatus(message: "Importing…")))

    #expect(stolen.didChange == false)
    guard case .bluetoothAwareness? = r.state.current?.content else {
      Issue.record("import status evicted the Bluetooth card")
      return
    }

    // The paired ACCEPTED case: it must still replace its own kind, which is the
    // race the #1701 pill exists to survive.
    var live = Self.makeReducer()
    _ = live.reduce(.featureRequest(.importStatus(message: "Importing…")))
    let replaced = live.reduce(.featureRequest(.importStatus(message: "Finished.")))
    #expect(replaced.didChange)
  }

  /// **#1060's `dismissAfter` is a real dwell and it must be ARMED.** It reached
  /// the model and was never read, so the "auto-stop unavailable" banner would
  /// have sat inside the pill until the recording ended.
  @Test("a timed in-panel notice arms its own dwell and clears itself")
  func timedInPanelNoticeClears() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.2)))
    let id = try! #require(r.state.current?.id)

    let armed = r.reduce(.inPanelNotice(.autoStopUnavailable, dismissAfter: 4.0))
    #expect(
      armed.expiryCommand == .arm(id: id, seconds: 4.0, target: .inPanelNotice),
      "the banner's dwell was never armed, so it would never clear")

    let fired = r.reduce(.inPanelNoticeExpiryFired(id))

    guard case .recording(_, _, let notice)? = r.state.current?.content else {
      Issue.record("the expiry ended the whole recording instead of the banner")
      return
    }
    #expect(notice == nil, "the banner outlived its dwell")
    #expect(fired.didChange)
    #expect(r.state.current?.id == id, "clearing the banner replaced the pill")
  }

  /// The approaching-cap banner passes NO dwell and is persistent until the
  /// recording ends. The paired case for the one above: without it, "arm a timer"
  /// would also be satisfied by arming one for every notice.
  @Test("an untimed in-panel notice arms nothing")
  func untimedInPanelNoticeIsPersistent() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.recording(audioLevel: 0.2)))

    let plan = r.reduce(.inPanelNotice(.approachingCap, dismissAfter: nil))

    #expect(plan.expiryCommand == .cancel, "the persistent cap banner armed a dwell")
  }

  @Test("an import-status request renders as import status")
  func importStatusKind() {
    var r = Self.makeReducer()
    _ = r.reduce(.featureRequest(.importStatus(message: "Imported 12 words")))
    guard case .notice(let notice)? = r.state.current?.content else {
      Issue.record("expected a notice")
      return
    }
    #expect(notice.kind == .importStatus)
  }

  /// #1891: the advisory is deliberately NOT an error. Its own severity rather
  /// than `neutral + isMultiline`, because inferring a paint from a LAYOUT flag
  /// is how a wrapping change silently repaints a pill.
  @Test("a user-setup advisory is not painted as an error")
  func advisoryIsNotAnError() {
    var r = Self.makeReducer()
    _ = r.reduce(.pipeline(.advisory(reason: .zeroSignal)))
    guard case .notice(let notice)? = r.state.current?.content else {
      Issue.record("expected a notice")
      return
    }
    #expect(notice.severity == .advisory)
    #expect(notice.severity != .error, "an advisory painted as an error blames our software")
  }
}
