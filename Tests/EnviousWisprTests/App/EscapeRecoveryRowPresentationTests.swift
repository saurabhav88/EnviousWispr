import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// What a History row says about an Escape Recovery (#2087, chunk 10).
///
/// The badge decision and every string live outside the view because a rule in a
/// SwiftUI `body` is not unit-drivable here — chunks 8 and 9 both paid for that
/// — so these drive the decisions directly and the view renders what it is told.
@MainActor
@Suite("Escape Recovery row presentation (#2087)")
struct EscapeRecoveryRowPresentationTests {

  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private var window: TimeInterval { AppConstants.pendingTranscriptRetention }

  private func held(_ text: String = "held", ago: TimeInterval) -> Transcript {
    Transcript(
      text: text, escapeRecoveredAt: now.addingTimeInterval(-ago),
      escapeRecoveryTakeID: "take-1")
  }

  // MARK: Which badge

  @Test("a live held row shows the countdown")
  func liveHeldRowIsBadgedWithItsCountdown() {
    let badge = EscapeRecoveryRowPresentation.badge(for: held(ago: 3600), now: now)
    #expect(badge == .held(countdown: "Deleted in 23h"))
  }

  @Test("a promoted row shows Kept, derived from the take id that survives promotion")
  func promotedRowIsBadgedKept() {
    let kept = held(ago: 3600).promotedFromPending()
    #expect(kept.escapeRecoveredAt == nil, "precondition: Keep clears the clock")
    #expect(kept.escapeRecoveryTakeID != nil, "precondition: the take id survives")

    #expect(EscapeRecoveryRowPresentation.badge(for: kept, now: now) == .kept)
  }

  @Test("an ordinary dictation gets no badge at all")
  func ordinaryRowIsNotBadged() {
    #expect(EscapeRecoveryRowPresentation.badge(for: Transcript(text: "ordinary"), now: now) == nil)
  }

  @Test("an expired row gets no badge, so a stale render cannot offer it")
  func expiredRowIsNotBadged() {
    #expect(EscapeRecoveryRowPresentation.badge(for: held(ago: window + 1), now: now) == nil)
  }

  @Test("a clock-skewed row gets no badge either")
  func futureStampedRowIsNotBadged() {
    let skewed = Transcript(
      text: "from the future",
      escapeRecoveredAt: now.addingTimeInterval(AppConstants.pendingClockSkewTolerance + 60),
      escapeRecoveryTakeID: "take-skew")
    #expect(EscapeRecoveryRowPresentation.badge(for: skewed, now: now) == nil)
  }

  /// A cross-chunk invariant, pinned rather than trusted.
  ///
  /// The `Recovered` badge means crash rescue (#1063) and must never appear on a
  /// held recovery, which is an ordinary cancel the user can still undo. What
  /// keeps them apart is in ANOTHER file — `RecoverySpoolReplayer` sets
  /// `isRecovered: escapeInfo == nil` — so it is exactly the kind of guarantee
  /// that decays silently when someone edits that line for an unrelated reason.
  @Test("a crash-recovered escape row does not claim to be crash-recovered")
  func escapeRowNeverCarriesTheRecoveredFlag() {
    let replayed = Transcript(
      text: "recovered after a crash, having been escaped",
      recoverySessionID: "session-1",
      isRecovered: false,
      escapeRecoveredAt: now.addingTimeInterval(-60),
      escapeRecoveryTakeID: "take-2")

    #expect(
      replayed.isRecovered != true,
      "the row view renders the Recovered capsule on `== true`, and this must not reach it")
    #expect(
      EscapeRecoveryRowPresentation.badge(for: replayed, now: now) != nil,
      "it is still badged — as held, which is what it actually is")
  }

  // MARK: In-flight policy

  /// POLARITY, asserted behaviourally.
  ///
  /// A connector test counting `.disabled(...)` modifiers cannot see this: the
  /// inverted form `.disabled(!allowed)` contributes the same substring while
  /// enabling the action mid-dictation and disabling it when idle. Only a real
  /// call can tell those apart.
  @Test("a held recovery cannot be pasted while a dictation is in flight")
  func heldRowPasteStandsDownDuringDictation() {
    let row = held(ago: 3600)
    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(for: row, now: now, dictationInFlight: false),
      "allowed when idle")
    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(for: row, now: now, dictationInFlight: true)
        == false,
      "and refused while a dictation is being delivered")
  }

  /// The scope limit, which is the point of the whole policy.
  ///
  /// The in-flight restriction belongs to THIS feature's two entry points. An
  /// ordinary dictation's Paste has never been restricted while recording, and
  /// restricting it would change shipped behaviour for every user with Escape
  /// Recovery switched off. An earlier version of this chunk did exactly that.
  @Test("an ordinary dictation's Paste is unaffected by a dictation in flight")
  func ordinaryRowPasteIsUnrestricted() {
    let ordinary = Transcript(text: "an ordinary dictation")
    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(
        for: ordinary, now: now, dictationInFlight: true),
      "shipped behaviour for rows this feature does not own must not change")
    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(
        for: ordinary, now: now, dictationInFlight: false))
  }

  /// Availability must agree with the press-time guard.
  ///
  /// A stamped row whose offer has ENDED is not an ordinary row, and treating it
  /// as one made the button logically allowed while `textForDelivery` refused
  /// the press — available-looking and inert, which is the worst of both. "No
  /// badge" conflates "this feature does not own the row" with "it does, and the
  /// offer is over".
  @Test(
    "an expired or clock-skewed recovery is not pastable, in flight or not",
    arguments: [true, false])
  func lapsedRecoveryIsNotPastable(inFlight: Bool) {
    let expired = held(ago: window + 1)
    let skewed = Transcript(
      text: "from the future",
      escapeRecoveredAt: now.addingTimeInterval(AppConstants.pendingClockSkewTolerance + 60),
      escapeRecoveryTakeID: "take-skew")

    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(
        for: expired, now: now, dictationInFlight: inFlight) == false,
      "an expired offer cannot be delivered, and the button must not say otherwise")
    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(
        for: skewed, now: now, dictationInFlight: inFlight) == false,
      "nor can one we cannot reason about at all")
  }

  @Test("a kept row is an ordinary row again for this purpose")
  func keptRowPasteIsUnrestricted() {
    let kept = held(ago: 3600).promotedFromPending()
    #expect(
      EscapeRecoveryRowPresentation.allowsPaste(for: kept, now: now, dictationInFlight: true),
      "Keep made it permanent; it is no longer an offer this feature governs")
  }

  @Test(
    "Keep is allowed only for a live held row, and never during a dictation",
    arguments: [
      (true, false, true),  // held, idle -> allowed
      (true, true, false),  // held, in flight -> refused
    ])
  func keepPolicy(isHeld: Bool, inFlight: Bool, expected: Bool) {
    let row = isHeld ? held(ago: 3600) : Transcript(text: "ordinary")
    #expect(
      EscapeRecoveryRowPresentation.allowsKeep(for: row, now: now, dictationInFlight: inFlight)
        == expected)
  }

  @Test("Keep is refused for rows it does not apply to")
  func keepRefusedForNonHeldRows() {
    for row in [
      Transcript(text: "ordinary"),
      held(ago: 3600).promotedFromPending(),
      held(ago: window + 1),
    ] {
      #expect(
        EscapeRecoveryRowPresentation.allowsKeep(for: row, now: now, dictationInFlight: false)
          == false)
    }
  }

  // MARK: Countdown wording

  @Test(
    "the countdown rounds down, and never promises more time than the row has",
    arguments: [
      (86_400.0, "Deleted in 24h"),
      (82_800.0, "Deleted in 23h"),
      (7_199.0, "Deleted in 1h"),
      (3_600.0, "Deleted in 1h"),
      (3_599.0, "Deleted in 59m"),
      (61.0, "Deleted in 1m"),
      (60.0, "Deleted in 1m"),
      (59.0, "Deleted in under a minute"),
      (0.5, "Deleted in under a minute"),
    ])
  func countdownWording(remaining: TimeInterval, expected: String) {
    #expect(EscapeRecoveryRowPresentation.countdown(remaining: remaining) == expected)
  }

  @Test("at or past the deadline the countdown stops counting")
  func countdownAtZero() {
    #expect(EscapeRecoveryRowPresentation.countdown(remaining: 0) == "Deleting")
    #expect(EscapeRecoveryRowPresentation.countdown(remaining: -5) == "Deleting")
  }

  @Test("the countdown never names an instant")
  func countdownNeverPromisesAnExactDeadline() {
    // Nothing deletes files while the app is not running (#1897), so "at 4pm"
    // would be a promise the mechanism does not keep.
    for seconds in [86_400.0, 3_600.0, 90.0, 30.0] {
      let text = EscapeRecoveryRowPresentation.countdown(remaining: seconds)
      #expect(text.hasPrefix("Deleted in"), "\(text) must say how long, never when")
    }
  }

  @Test(
    "the spoken form says hours and minutes in words",
    arguments: [
      (82_800.0, "Kept for now, deleted in 23 hours"),
      (3_600.0, "Kept for now, deleted in 1 hour"),
      (120.0, "Kept for now, deleted in 2 minutes"),
      (60.0, "Kept for now, deleted in 1 minute"),
      (10.0, "Kept for now, deleted in under a minute"),
    ])
  func accessibilityWording(remaining: TimeInterval, expected: String) {
    #expect(EscapeRecoveryRowPresentation.accessibilityLabel(remaining: remaining) == expected)
  }

  // MARK: Delivery guard
  //
  // DEBUG-only: placing a lapsed row in memory needs the seam, because the store
  // refuses to return one — which is the whole scenario, a row that aged out
  // while the window was open.

  #if DEBUG

    @Test("Copy and Paste hand back nothing once the offer has lapsed")
    func deliveryIsRefusedForALapsedRow() throws {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2087-row-\(UUID().uuidString)", isDirectory: true)
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))

      let live = Transcript(
        text: "still offered", escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "t1")
      let lapsed = Transcript(
        text: "gone", escapeRecoveredAt: Date().addingTimeInterval(-(window + 1)),
        escapeRecoveryTakeID: "t2")
      let ordinary = Transcript(text: "an ordinary dictation")
      coordinator.setTranscriptsForTesting([live, lapsed, ordinary])

      #expect(coordinator.textForDelivery(live) == "still offered")
      #expect(
        coordinator.textForDelivery(lapsed) == nil,
        "inert, not merely harmless: text the user was told had gone is not handed back")
      #expect(
        coordinator.textForDelivery(ordinary) == "an ordinary dictation",
        "an ordinary dictation is unaffected — it has no offer to lapse")
    }

    @Test("a row deleted in another pane is refused too")
    func deliveryIsRefusedForADeletedRow() {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2087-row-\(UUID().uuidString)", isDirectory: true)
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let stale = Transcript(
        text: "deleted elsewhere", escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "t3")

      // Never added to the coordinator: the view is holding a row the store no
      // longer has, which is what a delete in another pane leaves behind.
      coordinator.setTranscriptsForTesting([])

      #expect(coordinator.textForDelivery(stale) == nil)
    }

  #endif
}
