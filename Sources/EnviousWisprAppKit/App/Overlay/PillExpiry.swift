import CoreGraphics
import Foundation

/// What a hover does to a countdown (#4675).
///
/// **Exhaustive on purpose.** This replaced a Bool, and a Bool could only say
/// "pausable"; the learned pill needs a third answer, so every site that reads
/// it now switches over all three cases and a fourth would fail to compile.
enum HoverPolicy: Equatable, Sendable {
  /// A hover changes nothing: the dwell runs out underneath the pointer.
  case ignore
  /// Entering cancels the dwell; leaving arms the FULL dwell again. Language
  /// Chip (6 s) and Escape Recovery (3 s) keep exactly this behavior.
  case restartFull
  /// Entering freezes the remainder; leaving resumes it, but never with less
  /// than `floorSeconds` left, so a person who hovers at the last moment still
  /// has time to act (the learned offer, founder 2026-11-17/18).
  case resume(floorSeconds: Double)
}

/// How long a presentation lives without further input.
enum OverlayExpiry: Equatable, Sendable {
  /// Stays until something replaces it. Recording and processing are persistent.
  case untilReplaced
  /// Dismisses itself after an interval; `hover` says what a pointer over it does.
  case after(seconds: Double, hover: HoverPolicy)

  static func after(seconds: Double) -> OverlayExpiry {
    .after(seconds: seconds, hover: .ignore)
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
  /// When the remainder window began. For a paused dwell, when it was frozen.
  let startedAt: Date
  /// The length of the window that begins at `startedAt`: the time left from
  /// that instant. Equals `totalSeconds` for a dwell that was never paused.
  let seconds: Double
  /// The ORIGINAL dwell, which the rail's share is drawn against. A resume can
  /// arm more than the remainder (the floor), so the rail must be measured
  /// against this and not against `seconds`, or it would hide the added time.
  let totalSeconds: Double
  /// Non-nil while the countdown is frozen by a hover: the time that was left.
  let pausedRemaining: Double?
  /// The steady-clock (`systemUptime`) reading at `startedAt`, set by `PillExpiryClock` for a
  /// running window. The clock measures on that clock, so a drawing that reads it too cannot
  /// disagree with the deadline when the wall clock jumps. `nil` for a paused window (it needs no
  /// anchor) and for any window built without one, which then reads `Date`.
  let startedUptime: TimeInterval?

  /// A running dwell. `totalSeconds` defaults to `seconds`, the never-paused case.
  init(
    id: PresentationID, startedAt: Date, seconds: Double, totalSeconds: Double? = nil,
    startedUptime: TimeInterval? = nil
  ) {
    self.id = id
    self.startedUptime = startedUptime
    self.startedAt = startedAt
    self.seconds = seconds
    self.totalSeconds = totalSeconds ?? seconds
    self.pausedRemaining = nil
  }

  /// A frozen dwell: `remaining` is what was left at `at`, and stays so.
  init(id: PresentationID, pausedAt: Date, remaining: Double, totalSeconds: Double) {
    self.id = id
    self.startedAt = pausedAt
    self.seconds = remaining
    self.totalSeconds = totalSeconds
    self.pausedRemaining = remaining
    self.startedUptime = nil
  }

  var isPaused: Bool { pausedRemaining != nil }

  /// What fraction of the ORIGINAL dwell has elapsed at `now`, clamped to
  /// 0...1. Frozen while paused.
  func elapsedFraction(at now: Date) -> Double {
    guard totalSeconds > 0 else { return 1 }
    return min(1, max(0, (totalSeconds - remaining(at: now)) / totalSeconds))
  }

  /// How long is left to animate at `now`, never negative. A paused dwell has
  /// nothing to animate: it reports what was left when it froze.
  func remaining(at now: Date) -> Double {
    if let pausedRemaining { return max(0, pausedRemaining) }
    return max(0, seconds - now.timeIntervalSince(startedAt))
  }

  /// As `elapsedFraction(at:)`, measured on the steady clock when this window carries an anchor:
  /// `date` is read only for a window without one.
  func elapsedFraction(atUptime uptime: TimeInterval, orDate date: Date) -> Double {
    guard let startedUptime, !isPaused else { return elapsedFraction(at: date) }
    guard totalSeconds > 0 else { return 1 }
    let remaining = max(0, seconds - (uptime - startedUptime))
    return min(1, max(0, (totalSeconds - remaining) / totalSeconds))
  }
}
