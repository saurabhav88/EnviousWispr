import AppKit
import Testing

@testable import EnviousWisprAppKit

/// #4101: the record of the app the user came from, which History Paste pastes into. When this is
/// wrong, History Paste pastes into the wrong app or refuses for no reason. Each test owns its
/// notification center, so no real activation is observed.
@MainActor
@Suite("Previous application tracker (#4101)", .tags(.productOutcome))
struct PreviousApplicationTrackerTests {

  private final class Desk {
    let center = NotificationCenter()
    var frontmost: NSRunningApplication?
    var terminated: Set<pid_t> = []
  }

  /// Three real, running applications: one plays this app, two play others. Compared only.
  private static func apps() throws -> (own: NSRunningApplication, a: NSRunningApplication,
    b: NSRunningApplication)
  {
    let running = NSWorkspace.shared.runningApplications
    try #require(running.count >= 3, "needs three running applications")
    return (running[0], running[1], running[2])
  }

  private func tracker(_ desk: Desk, own: NSRunningApplication) -> PreviousApplicationTracker {
    PreviousApplicationTracker(
      effects: .init(
        notificationCenter: desk.center, frontmost: { desk.frontmost },
        ownProcessIdentifier: own.processIdentifier,
        isTerminated: { desk.terminated.contains($0.processIdentifier) }))
  }

  private func activate(_ app: NSRunningApplication, on desk: Desk) {
    desk.center.post(
      name: NSWorkspace.didActivateApplicationNotification, object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: app])
  }

  @Test("start primes from another live app in front; never from this app, never from nothing")
  func startPriming() throws {
    let (own, a, _) = try Self.apps()
    let other = Desk()
    other.frontmost = a
    let primed = tracker(other, own: own)
    primed.start()
    #expect(primed.lastOtherApplication === a)

    let selfFront = Desk()
    selfFront.frontmost = own
    let none = tracker(selfFront, own: own)
    none.start()
    #expect(none.lastOtherApplication == nil)

    let empty = tracker(Desk(), own: own)
    empty.start()
    #expect(empty.lastOtherApplication == nil)
  }

  @Test("another app's activation is recorded; this app's own activation keeps the last other app")
  func activationUpdates() throws {
    let (own, a, b) = try Self.apps()
    let desk = Desk()
    let subject = tracker(desk, own: own)
    subject.start()
    activate(a, on: desk)
    #expect(subject.lastOtherApplication === a)
    activate(own, on: desk)
    #expect(subject.lastOtherApplication === a, "coming to EnviousWispr must not erase the target")
    activate(b, on: desk)
    #expect(subject.lastOtherApplication === b)
  }

  @Test("a terminated app is never recorded, and a recorded app that quits is not replaced")
  func terminatedApps() throws {
    let (own, a, b) = try Self.apps()
    let desk = Desk()
    let subject = tracker(desk, own: own)
    subject.start()
    activate(a, on: desk)
    desk.terminated = [b.processIdentifier]
    activate(b, on: desk)
    #expect(subject.lastOtherApplication === a, "a quit app's late activation is ignored")
    desk.terminated.insert(a.processIdentifier)
    #expect(subject.lastOtherApplication === a, "History Paste refuses it; nothing is substituted")
  }

  @Test("start twice observes once; stop ends updates and is harmless twice")
  func lifecycle() throws {
    let (own, a, b) = try Self.apps()
    let desk = Desk()
    let subject = tracker(desk, own: own)
    subject.start()
    subject.start()
    activate(a, on: desk)
    #expect(subject.activationsHandled == 1, "one subscription")
    subject.stop()
    #expect(subject.isObserving == false)
    activate(b, on: desk)
    #expect(subject.activationsHandled == 1)
    #expect(subject.lastOtherApplication === a)
    subject.stop()
    #expect(subject.isObserving == false)
  }
}
