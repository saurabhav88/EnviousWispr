import Foundation

/// The single authority for whether an Escape Recovery stamp is still OFFERABLE
/// at a given instant (#2087).
///
/// Two call sites need this answer and must never drift apart:
/// - `TranscriptStore.decodeCandidate` decides whether a saved pending row may be
///   shown, restored, searched or counted.
/// - `RecoverySpoolReplayer` decides, before spending the ASR engine, whether a
///   crash-recovered take could ever be shown at all.
///
/// Expressed as a shared RULE rather than shared constants on purpose. Two copies
/// of `>= retention` reading the same numbers still diverge the moment one side
/// gains a condition the other lacks — which is exactly what happened here: the
/// replayer checked elapsed time and forgot future skew, so a clock-skewed marker
/// burned the engine producing a row the store then refused to show.
public enum PendingAdmission {
  /// Outcomes are distinguished because they are not the same event. A stamp in
  /// the future is CORRUPT (or a badly skewed clock) and says nothing about the
  /// user; an elapsed one is the ordinary passage of time.
  public enum Verdict: Equatable, Sendable {
    case live
    case expired
    case corrupt
  }

  public static func verdict(
    stampedAt: Date,
    now: Date,
    retention: TimeInterval = AppConstants.pendingTranscriptRetention,
    skewTolerance: TimeInterval = AppConstants.pendingClockSkewTolerance
  ) -> Verdict {
    // Future first: a stamp beyond tolerance is not a fresh row that happens to
    // be young, it is one we cannot reason about at all.
    if stampedAt > now.addingTimeInterval(skewTolerance) { return .corrupt }
    return now < stampedAt.addingTimeInterval(retention) ? .live : .expired
  }
}
