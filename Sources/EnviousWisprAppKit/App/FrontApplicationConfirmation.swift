import AppKit
import EnviousWisprCore

/// Brings a captured application to the front when it is not already there, and confirms that it
/// is OBSERVED frontmost before a paste may go to it (#4101). Shared by Paste Last's front route
/// and History Paste. It confirms a process, never a window or a field, and activation is only a
/// request: the activation Bool never stands in for the observed confirmation.
@MainActor
struct FrontApplicationConfirmation {
  struct Effects {
    var frontmost: @MainActor () -> NSRunningApplication?
    var isTerminated: @MainActor (NSRunningApplication) -> Bool
    var activate: @MainActor (NSRunningApplication) -> Bool
    var sleep: @MainActor (Duration) async -> Void
    /// A monotonic reading. The wait ends when THIS says the deadline passed, not after a count of
    /// sleeps: a loaded main actor makes each sleep longer than asked.
    var now: @MainActor () -> ContinuousClock.Instant
  }

  enum Result: Equatable {
    /// The application was observed frontmost.
    case confirmed
    /// It quit before it could be confirmed.
    case targetGone
    /// It could not be brought back to the front in time.
    case focusLost
    /// The task was cancelled during the wait; the caller must abandon, never act.
    case cancelled
  }

  /// How often the wait looks, and how long it may take. The look is cheap (one frontmost read);
  /// the deadline is a fail-safe, not an expected duration, measured on `now`. It starts after the
  /// activation request, so it does not bound the request itself.
  static let pollInterval: Duration = .milliseconds(10)
  static let activationDeadline: Duration = .milliseconds(500)

  let effects: Effects

  func isFrontmost(_ application: NSRunningApplication) -> Bool {
    effects.frontmost()?.processIdentifier == application.processIdentifier
  }

  /// Usually the application is already in front and nothing waits. When it is not, ask for it
  /// and wait for that to be observed.
  func bringToFront(_ target: NSRunningApplication) async -> Result {
    guard !isFrontmost(target) else { return .confirmed }
    _ = effects.activate(target)
    switch await DeadlinePoll.wait(
      within: Self.activationDeadline, every: Self.pollInterval, now: effects.now,
      sleep: effects.sleep, { self.isFrontmost(target) })
    {
    case .met: return .confirmed
    case .expired: return effects.isTerminated(target) ? .targetGone : .focusLost
    case .cancelled: return .cancelled
    }
  }
}
