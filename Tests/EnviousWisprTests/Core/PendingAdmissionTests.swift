import Foundation
import Testing

@testable import EnviousWisprCore

/// `PendingAdmission` is the SINGLE authority for whether an Escape Recovery
/// stamp is still offerable (#2087), consumed by both `TranscriptStore`'s
/// read-time filter and `RecoverySpoolReplayer`'s pre-ASR gate.
///
/// It exists because those two had already drifted: the replayer checked elapsed
/// time and forgot future skew, so a clock-skewed marker spent the ASR engine
/// producing a row the store then rejected. Sharing the CONSTANTS would not have
/// prevented that — two copies of the logic diverge the moment one side gains a
/// condition. These tests pin the rule itself.
/// Class: `.productOutcome` — text the user was told had gone comes back, or text still owed does not.
@Suite("Pending admission rule (#2087)", .tags(.productOutcome))
struct PendingAdmissionTests {

  private let now = Date(timeIntervalSince1970: 1_755_300_000)
  private var retention: TimeInterval { AppConstants.pendingTranscriptRetention }
  private var skew: TimeInterval { AppConstants.pendingClockSkewTolerance }

  @Test("a fresh stamp is live")
  func freshIsLive() {
    #expect(PendingAdmission.verdict(stampedAt: now, now: now) == .live)
    #expect(
      PendingAdmission.verdict(stampedAt: now.addingTimeInterval(-60), now: now) == .live)
  }

  /// The boundary is asserted from BOTH sides, one second apart. A test only at
  /// `+25h` would pass against an off-by-one that lets the closing instant
  /// itself through, which is the moment the user stops being offered the row.
  @Test("the retention boundary expires at exactly the window, not a second later")
  func retentionBoundaryIsExact() {
    let justInside = now.addingTimeInterval(-retention + 1)
    let exactly = now.addingTimeInterval(-retention)
    #expect(PendingAdmission.verdict(stampedAt: justInside, now: now) == .live)
    #expect(
      PendingAdmission.verdict(stampedAt: exactly, now: now) == .expired,
      "at the window it is already gone — `>=`, not `>`")
  }

  /// A stamp in the future is CORRUPT, never "very fresh". Treating it as live
  /// would let a skewed clock hold a row far past the 24 hours the user was
  /// promised — the window would run from a moment that has not happened.
  @Test("a stamp beyond the skew tolerance is corrupt, not live")
  func futureBeyondToleranceIsCorrupt() {
    let withinSkew = now.addingTimeInterval(skew - 1)
    let beyondSkew = now.addingTimeInterval(skew + 1)
    #expect(
      PendingAdmission.verdict(stampedAt: withinSkew, now: now) == .live,
      "a little forward skew is ordinary clock drift, not corruption")
    #expect(PendingAdmission.verdict(stampedAt: beyondSkew, now: now) == .corrupt)
  }

  /// Corrupt beats expired. A stamp that is both nonsensical AND old must report
  /// the nonsense: the two route to different channels (ours vs the world's), so
  /// collapsing them would file a defect of ours as ordinary passage of time.
  @Test("a far-future stamp is corrupt even though it is not expired")
  func corruptTakesPrecedence() {
    let farFuture = now.addingTimeInterval(retention * 10)
    #expect(PendingAdmission.verdict(stampedAt: farFuture, now: now) == .corrupt)
  }
}
