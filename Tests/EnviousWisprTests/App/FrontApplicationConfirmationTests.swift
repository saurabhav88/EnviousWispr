import AppKit
import Testing

@testable import EnviousWisprAppKit

/// #4101: the activation and confirmation steps Paste Last's front route and History Paste share.
/// When this fails, a paste goes to whatever app is in front instead of the one it was meant for.
/// A fake clock and fake desktop: each sleep advances the clock and returns at once.
@MainActor
@Suite("Front application confirmation (#4101)", .tags(.productOutcome))
struct FrontApplicationConfirmationTests {

  private final class Desk {
    var frontmost: NSRunningApplication?
    var terminated: Set<pid_t> = []
    var activations: [pid_t] = []
    /// What `activate` answers; it never changes `frontmost` by itself.
    var activateAnswers = true
    var clock = ContinuousClock.now
    /// Extra time each sleep takes, as on a loaded main actor.
    var lag: Duration = .zero
    var sleeps = 0
    /// Runs on every sleep, after the clock moved, so a test can change the world mid-wait.
    var duringSleep: ((Int) -> Void)?
  }

  private func confirmation(_ desk: Desk) -> FrontApplicationConfirmation {
    FrontApplicationConfirmation(
      effects: .init(
        frontmost: { desk.frontmost },
        isTerminated: { desk.terminated.contains($0.processIdentifier) },
        activate: { app in
          desk.activations.append(app.processIdentifier)
          return desk.activateAnswers
        },
        sleep: { duration in
          desk.sleeps += 1
          desk.clock = desk.clock.advanced(by: duration + desk.lag)
          desk.duringSleep?(desk.sleeps)
        },
        now: { desk.clock }))
  }

  /// Two real, running applications that are not this process. Compared only.
  private static func twoOtherApps() throws -> (NSRunningApplication, NSRunningApplication) {
    let own = ProcessInfo.processInfo.processIdentifier
    let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != own }
    let first = try #require(others.first, "no other application is running")
    let second = try #require(others.dropFirst().first, "needs two other applications")
    return (first, second)
  }

  @Test("an application already in front is confirmed with no activation and no wait")
  func alreadyFront() async throws {
    let (a, _) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = a
    #expect(await confirmation(desk).bringToFront(a) == .confirmed)
    #expect(desk.activations.isEmpty)
    #expect(desk.sleeps == 0)
  }

  @Test("an application that comes to the front during the wait is confirmed once it is seen")
  func delayedActivation() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    desk.duringSleep = { if $0 == 3 { desk.frontmost = a } }
    #expect(await confirmation(desk).bringToFront(a) == .confirmed)
    #expect(desk.activations == [a.processIdentifier])
    #expect(desk.sleeps == 3)
  }

  @Test("an activation request that answers false is not a refusal: what is observed decides")
  func activationFalseStillObserved() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    desk.activateAnswers = false
    desk.duringSleep = { if $0 == 1 { desk.frontmost = a } }
    #expect(await confirmation(desk).bringToFront(a) == .confirmed)
  }

  @Test("an application never seen in front expires: focus lost, or gone when it quit")
  func expiry() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    #expect(await confirmation(desk).bringToFront(a) == .focusLost)
    let polls = Int(
      FrontApplicationConfirmation.activationDeadline / FrontApplicationConfirmation.pollInterval)
    #expect(desk.sleeps == polls, "the deadline is measured on the clock, from after the request")

    let quit = Desk()
    quit.frontmost = b
    quit.terminated = [a.processIdentifier]
    #expect(await confirmation(quit).bringToFront(a) == .targetGone)
  }

  @Test("a wait that resumes past the deadline expires, even if the app is in front by then")
  func lateResumption() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    desk.lag = .seconds(1)
    desk.duringSleep = { _ in desk.frontmost = a }
    #expect(await confirmation(desk).bringToFront(a) == .focusLost)
    #expect(desk.sleeps == 1)
  }

  @Test("a wait cancelled mid-way answers cancelled, never confirmed")
  func cancelledDuringWait() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    let subject = confirmation(desk)
    desk.duringSleep = { count in
      if count == 2 {
        desk.frontmost = a
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    let result = await Task { await subject.bringToFront(a) }.value
    #expect(result == .cancelled)
  }
}
