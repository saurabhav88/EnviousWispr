import Foundation

/// Polls a condition until it holds or a deadline passes on a monotonic clock (#3986).
///
/// One owner for the "wait until it is observed, not for a guessed interval" loop. Paste Last
/// Dictation's three waits and Quick Add's waits share it, so a fix to the order below reaches
/// every caller. Each caller keeps its own policy: what it polls, how long, how often.
///
/// **Ported unchanged from `LastDictationAction.waitUntil`, and the order is the contract.**
/// Cancellation is checked BEFORE the condition, on entry and after every sleep, and after a sleep
/// expiry is checked before it too. A poll that resumes late, past the deadline, must not accept a
/// condition it only now observes: the action would land long after the user stopped expecting
/// it. Likewise a cancelled task never acts.
///
/// `now` and `sleep` are injected because a loaded main actor makes each sleep longer than asked,
/// so the deadline is read on `now` rather than counted in sleeps, and tests drive both by hand.
public enum DeadlinePoll {

  public enum Result: Equatable, Sendable {
    /// The condition held. `elapsed` is measured on `now` from entry to the look that saw it.
    case met(elapsed: Duration)
    /// The deadline passed before the condition was seen to hold.
    case expired
    /// The task was cancelled; the caller must abandon, never act.
    case cancelled
  }

  @MainActor
  public static func wait(
    within deadline: Duration,
    every interval: Duration,
    now: @MainActor () -> ContinuousClock.Instant,
    sleep: @MainActor (Duration) async -> Void,
    _ condition: @MainActor () -> Bool
  ) async -> Result {
    let start = now()
    let end = start + deadline
    // Even the first look: a task cancelled before it began must not act on a condition that
    // happens to hold already. A condition already true is `met` even for a zero deadline.
    if Task.isCancelled { return .cancelled }
    if condition() { return .met(elapsed: now() - start) }
    while true {
      await sleep(interval)
      if Task.isCancelled { return .cancelled }
      if now() >= end { return .expired }
      if condition() { return .met(elapsed: now() - start) }
    }
  }
}
