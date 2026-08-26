import AppKit

/// Owns ONE deferred construction: schedule it once, build once, publish the
/// result once — however many callers ask before it is ready.
///
/// **Construction readiness only.** This type never stores a presentation,
/// an identity, or a queue of pending work — that is the Director's job,
/// which lets a caller ask "is it ready yet" without also asking "for whom".
///
/// Setting `.scheduled` BEFORE invoking `schedule` is load-bearing: an
/// immediate (synchronous) test scheduler would otherwise re-enter
/// `scheduleIfNeeded()` from inside `schedule`'s own call, before `state` had
/// recorded that a construction was already underway, and build twice.
@MainActor
final class OverlayFirstRenderGate {
  typealias Schedule = (@escaping () -> Void) -> Void

  private enum State {
    case idle
    case scheduled
    case ready(NSView)
  }

  private let schedule: Schedule
  private let construct: () -> NSView
  private let didBecomeReady: (NSView) -> Void
  private var state: State = .idle

  init(
    schedule: @escaping Schedule = {
      DispatchQueue.main.async(execute: $0)
    },
    construct: @escaping () -> NSView,
    didBecomeReady: @escaping (NSView) -> Void
  ) {
    self.schedule = schedule
    self.construct = construct
    self.didBecomeReady = didBecomeReady
  }

  var readyRoot: NSView? {
    guard case .ready(let root) = state else { return nil }
    return root
  }

  /// `scheduleOverride` lets a caller supply a DIFFERENT scheduling primitive
  /// for this one call while every other caller keeps using the instance's
  /// own default. Idle prewarm is the one caller that needs this: it wants
  /// the main run loop's `.beforeWaiting` boundary (`idleScheduler()` below),
  /// while demand-driven rendering keeps the constructor's `schedule`
  /// (`DispatchQueue.main.async` in production) unchanged — that default is
  /// load-bearing for the menu-dismiss crash fix and must not move.
  func scheduleIfNeeded(using scheduleOverride: Schedule? = nil) {
    guard case .idle = state else { return }
    state = .scheduled

    (scheduleOverride ?? schedule) { [weak self] in
      guard let self, case .scheduled = self.state else { return }
      let root = self.construct()
      self.state = .ready(root)
      self.didBecomeReady(root)
    }
  }
}

extension OverlayFirstRenderGate {
  /// A one-shot `Schedule` that fires when the main run loop next reaches
  /// `.beforeWaiting` — the plan's literal "first idle main-run-loop turn",
  /// as opposed to `DispatchQueue.main.async`'s "next queue turn", which can
  /// still be contending with whatever async launch work the app itself
  /// queued (recovery scan, expired-pending sweep, and anything
  /// `AppLifecycleCoordinator.runDidFinishLaunching()` starts).
  ///
  /// `repeats: false` in `CFRunLoopObserverCreateWithHandler` invalidates the
  /// observer after its first fire, so it costs nothing to leave registered
  /// beyond that — there is no manual removal to forget.
  static func idleScheduler() -> Schedule {
    { work in
      let observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
        false, 0
      ) { _, _ in work() }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
  }
}
