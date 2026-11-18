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
/// **The clock alone owns the remainder arithmetic (#4675).** A hover-resumable
/// dwell is frozen by `.pause`, which invalidates the armed callback and stores
/// what was left; `.resume` arms `max(remaining, floor)` and keeps the ORIGINAL
/// total so the rail draws the true share left, including time the floor added.
/// No reducer, director or view computes a deadline or a remainder.
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

  /// Which STARTED arm may still call out when its timer fires.
  ///
  /// **Separate from `pendingArmToken` on purpose.** The token answers "may this
  /// prepared start begin?" and is consumed the moment it does; this answers "is
  /// the callback that is now scheduled still the current one?" and lives until
  /// that arm expires, is cancelled or is replaced. Each start mints a fresh
  /// identity, so re-arming the SAME presentation id still invalidates the
  /// earlier callback: the presentation id cannot tell the two arms apart, and
  /// the scheduler's own cancel flag is the only other guard, which a captured
  /// closure never consults.
  ///
  /// Cleared by cancel and by the next arm (before it starts), and consumed when
  /// the callback dispatches, so a callback calls out at most once.
  private var activeArmID: UUID?

  /// What a prepared arm will start, kept beside `pendingArmToken` so a hover
  /// that lands before the first render is accepted can still freeze it. Always
  /// set and cleared together with the token.
  private var preparedArm: Dwell?

  /// The STARTED dwell, with the instant it ends, so `.pause` can store what was
  /// left. Cleared whenever `activeArmID` is.
  private var running: (dwell: Dwell, deadline: Date)?

  /// A hover-frozen dwell and the time that was left. Discarded by cancel and by
  /// the next arm (a replacement), consumed by the resume that starts again.
  private var paused: (dwell: Dwell, remaining: Double)?

  /// One countdown's identity and its ORIGINAL length.
  private struct Dwell {
    let id: PresentationID
    let target: OverlayExpiryTarget
    /// The length armed from now, which a resume may raise to its floor.
    let seconds: Double
    /// The first full dwell, which progress is always measured against.
    let total: Double
  }

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
  /// The returned closure is a no-op for every command but `.arm` and `.resume`,
  /// so a caller can invoke it unconditionally.
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
      discardEverything()
      publishDwell(nil)
      return {}

    case .arm(let id, let seconds, let target):
      // A replacement discards any frozen remainder of the outgoing pill.
      discardEverything()
      let dwell = Dwell(id: id, target: target, seconds: seconds, total: seconds)
      let token = UUID()
      pendingArmToken = token
      preparedArm = dwell
      return { [weak self] in
        guard let self, self.pendingArmToken == token else { return }
        self.pendingArmToken = nil
        self.preparedArm = nil
        self.start(dwell, onExpiry: onExpiry)
      }

    case .pause:
      // A prepared start that has not begun must not begin under a hover.
      pendingArmToken = nil
      let prepared = preparedArm
      preparedArm = nil
      if let running {
        let remaining = max(0, running.deadline.timeIntervalSince(now()))
        invalidateRunning()
        freeze(running.dwell, remaining: remaining)
      } else if let prepared {
        // Hover landed before the host accepted the pill: nothing has counted
        // down yet, so the whole dwell is what remains.
        freeze(prepared, remaining: prepared.seconds)
      }
      return {}

    case .resume(let id, let floorSeconds):
      guard let frozen = paused, frozen.dwell.id == id else { return {} }
      let token = UUID()
      pendingArmToken = token
      return { [weak self] in
        guard let self, self.pendingArmToken == token, let frozen = self.paused,
          frozen.dwell.id == id
        else { return }
        self.pendingArmToken = nil
        self.paused = nil
        self.start(
          Dwell(
            id: id, target: frozen.dwell.target,
            seconds: max(frozen.remaining, floorSeconds), total: frozen.dwell.total),
          onExpiry: onExpiry)
      }
    }
  }

  /// Begin counting `dwell` down now: the picture and the timer start together.
  private func start(
    _ dwell: Dwell, onExpiry: @escaping (PresentationID, OverlayExpiryTarget) -> Void
  ) {
    let startedAt = now()
    // This is the instant the dwell begins, and a view drawing a countdown has
    // no other way to know it.
    publishDwell(
      OverlayDwellWindow(
        id: dwell.id, startedAt: startedAt, seconds: dwell.seconds, totalSeconds: dwell.total))
    let armID = UUID()
    activeArmID = armID
    running = (dwell, startedAt.addingTimeInterval(dwell.seconds))
    armed = schedule.after(dwell.seconds) { [weak self] in
      // Verified before dispatching the captured presentation and target.
      guard let self, self.activeArmID == armID else { return }
      self.activeArmID = nil
      self.running = nil
      onExpiry(dwell.id, dwell.target)
    }
  }

  /// Stop the armed callback without touching prepared or frozen state.
  private func invalidateRunning() {
    activeArmID = nil
    running = nil
    armed?.cancel()
    armed = nil
  }

  private func freeze(_ dwell: Dwell, remaining: Double) {
    paused = (dwell, remaining)
    publishDwell(
      OverlayDwellWindow(
        id: dwell.id, pausedAt: now(), remaining: remaining, totalSeconds: dwell.total))
  }

  /// Forget every armed, prepared and frozen dwell. A cancel is about the
  /// OUTGOING pill and does not wait for any start closure.
  private func discardEverything() {
    pendingArmToken = nil
    preparedArm = nil
    paused = nil
    invalidateRunning()
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
  /// exercises the same cancellation check a real one does.
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
