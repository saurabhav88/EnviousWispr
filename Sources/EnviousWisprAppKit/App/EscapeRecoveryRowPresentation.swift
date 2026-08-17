import EnviousWisprCore
import Foundation

/// What a History row says about an Escape Recovery (#2087, chunk 10).
///
/// A plain enum of decisions rather than logic inside the row view, for the
/// reason chunks 8 and 9 both established the hard way: a rule living in a
/// SwiftUI `body` is not unit-drivable here, so it ships untested, and a view
/// that picks between two plausible values picks wrong silently. Everything the
/// row needs to know is decided here and asserted directly.
///
/// Exhaustive by construction — `badge(for:now:)` returns an optional over a
/// closed set, so a third kind of row has to come here and decide rather than
/// defaulting into looking like an ordinary dictation.
enum EscapeRecoveryRowPresentation {

  /// The three states a row can be in. `nil` from `badge(for:now:)` means an
  /// ordinary dictation, which is deliberately not a case: absence of a badge
  /// is not a kind of badge.
  enum Badge: Equatable {
    /// Still being offered. Carries the countdown text, so the view renders a
    /// string it did not compose.
    case held(countdown: String)
    /// Promoted by Keep. Permanent now, and the badge says so because the row
    /// spent time looking temporary and the user chose otherwise.
    case kept
  }

  static let keptLabel = "Kept"
  static let pasteLabel = "Paste"
  static let keepLabel = "Keep"

  /// `Kept` is derived from the take id SURVIVING promotion, which is the only
  /// marker a promoted row keeps — `escapeRecoveredAt` is cleared by design.
  /// The id's VALUE is never rendered; it is used here purely as provenance.
  ///
  /// Deliberately NOT the `Recovered` badge, which means crash rescue (#1063).
  /// `RecoverySpoolReplayer` already sets `isRecovered: escapeInfo == nil`, so a
  /// crash-recovered ESCAPE row reports `false` and cannot pick it up; that is a
  /// cross-chunk invariant, so it is pinned by a test rather than trusted.
  static func badge(for transcript: Transcript, now: Date) -> Badge? {
    if let stamped = transcript.escapeRecoveredAt {
      // Fail closed through the shared authority: an expired or clock-skewed
      // row gets no badge, because it should not be on screen at all.
      guard PendingAdmission.verdict(stampedAt: stamped, now: now) == .live else { return nil }
      return .held(countdown: countdown(remaining: remaining(from: stamped, now: now)))
    }
    return transcript.escapeRecoveryTakeID == nil ? nil : .kept
  }

  /// Whether Paste may run right now.
  ///
  /// **Scoped to held recoveries on purpose.** The in-flight restriction comes
  /// from this feature's plan, which names recovery Paste and Keep. An ordinary
  /// dictation's Paste has never been restricted while recording, and making it
  /// so would be a product change to shipped behaviour for every user, feature
  /// off included — not this chunk's to make. An earlier version did exactly
  /// that, and also restricted Copy, which the plan never mentions.
  /// Branches on the STAMP, not the badge. "No badge" conflates two different
  /// rows: one this feature does not own, and one it owns whose offer has
  /// ended. Treating the second as ordinary returned `true` here while
  /// `textForDelivery` refused the press, so the button looked available and
  /// did nothing — availability and press-time policy have to agree.
  static func allowsPaste(for transcript: Transcript, now: Date, dictationInFlight: Bool) -> Bool {
    // No stamp: an ordinary dictation, or a row Keep already made permanent.
    // Shipped behaviour, untouched.
    guard let stamped = transcript.escapeRecoveredAt else { return true }
    // Stamped, so this feature owns it. Expired or clock-skewed means the offer
    // is over and nothing may be delivered from it.
    guard PendingAdmission.verdict(stampedAt: stamped, now: now) == .live else { return false }
    return !dictationInFlight
  }

  /// Whether Keep may run right now.
  ///
  /// Unconditionally in-flight-guarded, because Keep exists only for a held row:
  /// there is no ordinary-row behaviour to preserve.
  static func allowsKeep(for transcript: Transcript, now: Date, dictationInFlight: Bool) -> Bool {
    guard case .held = badge(for: transcript, now: now) else { return false }
    return !dictationInFlight
  }

  /// How long the offer has left.
  static func remaining(from stamped: Date, now: Date) -> TimeInterval {
    stamped.addingTimeInterval(AppConstants.pendingTranscriptRetention).timeIntervalSince(now)
  }

  /// The row's countdown.
  ///
  /// Rounds DOWN, so the row never promises more time than it has. Below an
  /// hour it switches to minutes rather than showing "0h", and below a minute it
  /// stops counting rather than racing the user to a number.
  ///
  /// Says "Deleted in", not "Deleted at": nothing removes a file while the app
  /// is not running, so naming an instant would be a promise the mechanism does
  /// not keep (#1897). The help text carries the full "within 24 hours, while
  /// the app is running or on next launch".
  static func countdown(remaining: TimeInterval) -> String {
    guard remaining > 0 else { return "Deleting" }
    if remaining >= 3600 { return "Deleted in \(Int(remaining / 3600))h" }
    if remaining >= 60 { return "Deleted in \(Int(remaining / 60))m" }
    return "Deleted in under a minute"
  }

  /// Spoken form. VoiceOver reads "23h" as an abbreviation, and a row whose
  /// whole point is a deadline should not need decoding.
  static func accessibilityLabel(remaining: TimeInterval) -> String {
    guard remaining > 0 else { return "Deleting now" }
    if remaining >= 3600 {
      let hours = Int(remaining / 3600)
      return "Kept for now, deleted in \(hours) hour\(hours == 1 ? "" : "s")"
    }
    if remaining >= 60 {
      let minutes = Int(remaining / 60)
      return "Kept for now, deleted in \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
    return "Kept for now, deleted in under a minute"
  }
}
