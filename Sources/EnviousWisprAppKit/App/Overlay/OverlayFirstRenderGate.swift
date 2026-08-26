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

  func scheduleIfNeeded() {
    guard case .idle = state else { return }
    state = .scheduled

    schedule { [weak self] in
      guard let self, case .scheduled = self.state else { return }
      let root = self.construct()
      self.state = .ready(root)
      self.didBecomeReady(root)
    }
  }
}
