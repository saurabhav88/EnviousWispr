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

    #expect(r.reduce(.hoverChanged(id, true)).armExpiry == nil)
    // While hovered, the timer firing must not dismiss it.
    #expect(r.reduce(.expiryFired(id)).didChange == false)
    #expect(r.state.current?.id == id)

    let leaving = r.reduce(.hoverChanged(id, false))
    #expect(leaving.armExpiry?.id == id, "leaving a hovered chip did not re-arm its dismissal")
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
}
