import Foundation

/// The sole dismissal clock (#2377 Phase 5, C2).
///
/// **One armed piece of work exists at a time, and it lives here.** Arming
/// replaces whatever was armed, which makes a stale dismissal structurally
/// impossible rather than guarded against — a second clock has nowhere to live.
///
/// **Preparing and starting are separate, and that split is the whole design.**
/// A dwell begins when the pill is VISIBLE, not when the plan is applied: the
/// host may defer the first render, and Escape Recovery draws a countdown rail
/// from this same dwell, so a clock started at plan time finishes early and the
/// rail disagrees with the pill it is drawn on. `prepare` therefore returns a
/// start closure the caller invokes once the host has accepted the presentation.
///
/// **Cancellation does NOT wait for that closure.** A cancel is about the
/// OUTGOING pill, which is already gone; deferring it would leave a dead timer
/// live across the gap between one pill and the next.
@MainActor
final class PillExpiryClock {

  /// The ONE armed expiry.
  private var armed: OverlayScheduledWork?

  /// Which prepared arm is still allowed to start.
  ///
  /// **A start closure that has been superseded must not be able to arm**, and
  /// nothing about holding one prevents that. The director prepares before it
  /// renders and starts only from a successful presentation, so a DEFERRED first
  /// render leaves a start closure outstanding while a second plan runs to
  /// completion — prepare A, prepare B, start B, then A's deferral fires. Both
  /// timers would then be live while `armed` names only the later one, which is
  /// the sole-clock invariant broken by the very mechanism that defers arming to
  /// keep the dwell honest.
  ///
  /// Cleared by a cancel, replaced by the next arm, and consumed on start, so a
  /// start closure can arm at most once and only while it is still the current
  /// one.
  private var pendingArmToken: UUID?

  private let schedule: OverlayScheduler
  private let now: () -> Date
  private let publishDwell: (OverlayDwellWindow?) -> Void

  init(
    schedule: OverlayScheduler = .live,
    now: @escaping () -> Date = Date.init,
    publishDwell: @escaping (OverlayDwellWindow?) -> Void
  ) {
    self.schedule = schedule
    self.now = now
    self.publishDwell = publishDwell
  }

  /// Apply an expiry command, and hand back the work that must wait for the
  /// pill to be on screen.
  ///
  /// The returned closure is a no-op for every command but `.arm`, so a caller
  /// can invoke it unconditionally.
  ///
  /// `onExpiry` receives the id and target CAPTURED at arm time. Neither is ever
  /// re-read: a timer fires for the presentation it was armed for or it is
  /// dropped, and the reducer's own identity gate makes a late arrival inert.
  /// The target says WHAT ends — the whole presentation, or only the in-panel
  /// banner inside a live recording.
  func prepare(
    _ command: OverlayExpiryCommand,
    onExpiry: @escaping (PresentationID, OverlayExpiryTarget) -> Void
  ) -> () -> Void {
    switch command {
    case .unchanged:
      // Leave the running clock and its published window exactly as they are.
      // Republishing the window would restart a countdown that has not stopped.
      return {}

    case .cancel:
      pendingArmToken = nil
      armed?.cancel()
      armed = nil
      publishDwell(nil)
      return {}

    case .arm(let id, let seconds, let target):
      armed?.cancel()
      armed = nil
      let token = UUID()
      pendingArmToken = token
      return { [weak self] in
        guard let self, self.pendingArmToken == token else { return }
        self.pendingArmToken = nil
        // The picture and the timer start together: this is the instant the
        // dwell begins, and a view drawing a countdown has no other way to know
        // it.
        self.publishDwell(
          OverlayDwellWindow(id: id, startedAt: self.now(), seconds: seconds))
        self.armed = self.schedule.after(seconds) { onExpiry(id, target) }
      }
    }
  }
}

/// A piece of scheduled work that can be cancelled.
///
/// A seam rather than a raw `Task` or `DispatchWorkItem` so a test can fire the
/// expiry deterministically. `testing-philosophy.md`
/// RULE: never-guess-when-the-subject-is-finished forbids waiting on a clock;
/// with this, a test does not wait at all — it fires the timer itself.
@MainActor
final class OverlayScheduledWork {
  private var cancelled = false
  private let body: () -> Void

  init(body: @escaping () -> Void) { self.body = body }

  func cancel() { cancelled = true }
  var isCancelled: Bool { cancelled }

  /// Run the work now, unless it has been cancelled.
  ///
  /// **Not a test hatch.** `OverlayScheduler.live` calls this from its own timer
  /// callback, so it is the one path a dwell fires through in production as well
  /// as under a manual clock — which is the point: a test that fires a dwell
  /// exercises the same cancellation check a real one does. It replaced a
  /// `fireForTesting` that only tests called, and whose name claimed the
  /// cancellation guard was a testing convenience.
  func fire() {
    guard !cancelled else { return }
    body()
  }
}

/// How the clock arms its single expiry.
@MainActor
struct OverlayScheduler {
  let after: (Double, @escaping () -> Void) -> OverlayScheduledWork

  static let live = OverlayScheduler { seconds, body in
    let work = OverlayScheduledWork(body: body)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak work] in
      work?.fire()
    }
    return work
  }

  /// Arms nothing. The test fires the returned handle itself, so no interval
  /// exists anywhere in the assertion.
  static func manual(_ armed: @escaping (OverlayScheduledWork) -> Void) -> OverlayScheduler {
    OverlayScheduler { _, body in
      let work = OverlayScheduledWork(body: body)
      armed(work)
      return work
    }
  }
}
