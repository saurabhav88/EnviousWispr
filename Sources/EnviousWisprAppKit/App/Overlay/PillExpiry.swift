import CoreGraphics
import Foundation

/// How long a presentation lives without further input.
enum OverlayExpiry: Equatable, Sendable {
  /// Stays until something replaces it. Recording and processing are persistent.
  case untilReplaced
  /// Dismisses itself after an interval, unless the user is hovering it.
  case after(seconds: Double, pausesOnHover: Bool)

  static func after(seconds: Double) -> OverlayExpiry {
    .after(seconds: seconds, pausesOnHover: false)
  }
}

/// The dwell a countdown is drawing, as a WINDOW rather than a start signal
/// (#2292, C20b).
///
/// **Publishing an identity and treating its delivery as the start is wrong, and
/// subtly so.** SwiftUI processes a published change on a later render
/// transaction -- normally the next one, arbitrarily later while the UI is busy.
/// The director's timer is already running by then, so a rail that starts when
/// the signal ARRIVES lags the clock it draws and gets cut off before its end.
///
/// Carrying `startedAt` lets a late reader compute how much of the dwell it has
/// already missed and draw the REMAINDER, which is correct whenever it runs.
///
/// It also fixes a second case the identity form could not express: a hover-exit
/// re-arms the same presentation, so an id-only signal does not change and the
/// rail never restarts.
struct OverlayDwellWindow: Equatable, Sendable {
  let id: PresentationID
  let startedAt: Date
  let seconds: Double

  /// What fraction has already elapsed at `now`, clamped to 0...1.
  func elapsedFraction(at now: Date) -> Double {
    guard seconds > 0 else { return 1 }
    return min(1, max(0, now.timeIntervalSince(startedAt) / seconds))
  }

  /// How long is left to animate at `now`, never negative.
  func remaining(at now: Date) -> Double {
    max(0, seconds - now.timeIntervalSince(startedAt))
  }
}
