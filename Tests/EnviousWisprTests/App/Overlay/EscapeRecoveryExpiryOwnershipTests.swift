import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The Escape Recovery pill takes no expiry callback (#2377 Phase 5, C4).
///
/// **The view's own three-second timer went in #2292 C18; what survived was a
/// handle nothing assigned and a closure nothing called.** `dismissTask` was only
/// ever set to `nil`, so its two `cancel()` calls were no-ops, and `onExpire` was
/// kept in the signature with a comment recording that this view no longer uses
/// it — the root passed `{}`.
///
/// The rail itself is untouched by this chunk. It is a PICTURE of the director's
/// dwell: hover resets it instantly, hover-exit re-arms through the reducer, and
/// a late reader draws the REMAINDER from the published window rather than a
/// fresh three seconds. `EscapeRecoveryPillTests` owns those claims and passes
/// unchanged either side of this deletion.
@Suite(.tags(.productOutcome))
@MainActor
struct EscapeRecoveryExpiryOwnershipTests {

  /// **A COMPILE contract.** It asserts nothing at runtime because the claim is
  /// about the initialiser's shape: the leaf can no longer be handed an expiry
  /// callback, so the compiler is the only thing that can check it.
  ///
  /// Committed before the deletion, where it fails to build for want of
  /// `onExpire`.
  @Test("the recovery pill is constructible with no expiry callback")
  func recoveryPillTakesNoExpiryCallback() {
    _ = EscapeRecoveryPillView(onPaste: {}, dwell: nil)
  }

  /// A dwell that arrives late is drawn from its REMAINDER, not from the start.
  ///
  /// Not a new claim and not this chunk's subject — it is here because the
  /// deletion is one edit away from `scheduleExpiry()`, and this is the value
  /// that function reads. If the arithmetic moved, this row says so.
  @Test("a window already half spent reports half elapsed and half remaining")
  func aLateReaderDrawsTheRemainder() {
    let started = Date(timeIntervalSince1970: 1_000)
    let window = OverlayDwellWindow(
      id: PresentationID(rawValue: UUID()), startedAt: started, seconds: 4)
    let halfway = started.addingTimeInterval(2)

    #expect(window.elapsedFraction(at: halfway) == 0.5)
    #expect(window.remaining(at: halfway) == 2)
  }
}
