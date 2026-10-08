import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

/// #3544 P1 — the push-to-talk record gesture as a pure value: given the times of each press and
/// release, it decides start, hands-free lock, triple-press cancel, lock cooldown, locked stop,
/// late press, quick release (with its stop deadline) and hold release.
///
/// When this fails, a double tap does not lock hands-free, a single tap does not stop, a hold is
/// treated as a tap, or the lone-tap stop is scheduled at the wrong time.
///
/// Every input carries both times the #3534 rules are about (when the OS says the key moved, and
/// when it was handled), so each case is a plain value check with no clock and no task.
@Suite(.tags(.productOutcome))
struct RecordGestureTests {

  private typealias T = RecordGesture.InputTime
  private static let binding = ShortcutBinding.keyboard(keyCode: 61, modifiers: [])
  private static let mode = RecordingMode.pushToTalk

  /// An input that happened at `occurred` and was handled at `handled` (default: at once).
  private static func at(_ occurred: TimeInterval?, handled: TimeInterval? = nil) -> T {
    T.accepting(stamp: occurred, handled: handled ?? occurred ?? 0)
  }

  private static func press(_ g: inout RecordGesture, _ t: T) -> RecordGesture.PressDecision? {
    guard case .admitted = g.admitPress(t, binding: binding, mode: mode) else { return nil }
    return g.classifyPress(t, binding: binding, mode: mode)
  }

  @Test("a first press starts an attempt with a fresh identity")
  func firstPressStarts() {
    var g = RecordGesture()
    guard case .start(let id) = Self.press(&g, Self.at(100)) else {
      Issue.record("expected start"); return
    }
    #expect(id == 1)
    #expect(g.isHeld)
    #expect(g.isLiveAttempt(1))
  }

  @Test("a duplicate press while held is absorbed")
  func duplicatePressIsAbsorbed() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    guard case .duplicate = g.admitPress(Self.at(100.01), binding: Self.binding, mode: Self.mode)
    else { Issue.record("expected duplicate"); return }
  }

  @Test("a second press 250 ms after the first locks hands-free, judged by when it happened")
  func secondPressInsideWindowLocks() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    guard case .quick = g.release(Self.at(100.1)) else { Issue.record("expected quick"); return }
    // Handled 750 ms after the first press (busy main), but it HAPPENED at 250 ms.
    // Times are binary fractions so the millisecond values are exact.
    guard
      case .lockIntent(let timing, let elapsedMs, let usesOccurrence) = Self.press(
        &g, Self.at(100.25, handled: 100.75))
    else { Issue.record("expected lock intent"); return }
    #expect(timing == "rescued")
    #expect(elapsedMs == 250)
    #expect(usesOccurrence)
    #expect(g.isLocked)
  }

  @Test("a third press inside the window cancels the hands-free take")
  func thirdPressCancels() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    _ = g.release(Self.at(100.1))
    _ = Self.press(&g, Self.at(100.2))
    _ = g.release(Self.at(100.25))
    guard case .tripleCancel = Self.press(&g, Self.at(100.4)) else {
      Issue.record("expected triple cancel"); return
    }
    #expect(g.isHeld == false)
  }

  @Test("a press just after the window but within 500 ms of locking is ignored as a bounce")
  func pressInsideCooldownIsIgnored() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    _ = g.release(Self.at(100.1))
    _ = Self.press(&g, Self.at(100.25))  // lock at 100.25
    _ = g.release(Self.at(100.375))
    guard case .ignoredCooldown(let ms) = Self.press(&g, Self.at(100.625)) else {
      Issue.record("expected cooldown"); return
    }
    #expect(ms == 375)
    // The caller clears held state AFTER its telemetry (base order).
    #expect(g.isHeld)
  }

  @Test("a single press after the cooldown stops a locked take")
  func pressAfterCooldownStops() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    _ = g.release(Self.at(100.1))
    _ = Self.press(&g, Self.at(100.2))
    _ = g.release(Self.at(100.3))
    guard case .stopLocked = Self.press(&g, Self.at(103)) else {
      Issue.record("expected locked stop"); return
    }
  }

  @Test("a locked take ignores releases")
  func lockedReleaseIsSuppressed() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    _ = g.release(Self.at(100.1))
    _ = Self.press(&g, Self.at(100.2))
    guard case .suppressedLocked = g.release(Self.at(100.3)) else {
      Issue.record("expected suppressed"); return
    }
  }

  @Test("a second press 527 ms after the first is late: no state change")
  func lateSecondPressChangesNothing() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    _ = g.release(Self.at(100.1))
    let generation = g.generation
    guard case .lateAfterWindow(let ms) = Self.press(&g, Self.at(100.527)) else {
      Issue.record("expected late"); return
    }
    #expect(ms == 527)
    #expect(g.generation == generation)
    #expect(g.isLocked == false)
  }

  @Test("a quick release keeps at least 500 ms from when it was handled")
  func quickReleaseDeadlineHasTheHandlingFloor() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    // Happened at 100.1 but handled late at 100.45.
    guard case .quick(let quick) = g.release(Self.at(100.1, handled: 100.45)) else {
      Issue.record("expected quick"); return
    }
    #expect(abs(quick.deadline - 100.95) < 1e-9)
    #expect(abs(quick.eventDeadline - 100.6) < 1e-9)
    #expect(quick.usesOccurrence)
  }

  @Test("a release 800 ms after the press is a hold")
  func longReleaseIsHold() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    guard case .hold = g.release(Self.at(100.8)) else { Issue.record("expected hold"); return }
  }

  @Test("the lone-tap check stops once, then a press that happened before the stop is marked")
  func loneTapStopMarksAnEarlierSecondPress() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    guard case .quick(let quick) = g.release(Self.at(100.1)) else {
      Issue.record("expected quick"); return
    }
    guard
      case .stop(let stop) = g.checkLoneTap(
        capturedGeneration: quick.capturedGeneration, binding: Self.binding, mode: Self.mode)
    else { Issue.record("expected stop"); return }
    #expect(stop.attributable)
    g.cleanup()
    g.recordQuickTapStop(stop, stoppedAt: 100.6)
    // The second press HAPPENED at 100.25 (before the stop) but was handled at 100.75 (after it).
    guard
      case .admitted(let ms) = g.admitPress(
        Self.at(100.25, handled: 100.75), binding: Self.binding, mode: Self.mode)
    else { Issue.record("expected admitted"); return }
    #expect(ms == 250)
  }

  @Test("a lone-tap check after any newer event is stale")
  func loneTapCheckAfterNewerEventIsStale() {
    var g = RecordGesture()
    _ = Self.press(&g, Self.at(100))
    guard case .quick(let quick) = g.release(Self.at(100.1)) else {
      Issue.record("expected quick"); return
    }
    _ = Self.press(&g, Self.at(100.3))  // locks; generation unchanged, but locked
    guard
      case .stale = g.checkLoneTap(
        capturedGeneration: quick.capturedGeneration, binding: Self.binding, mode: Self.mode)
    else { Issue.record("expected stale"); return }
    g.cleanup()
    guard
      case .stale = g.checkLoneTap(
        capturedGeneration: quick.capturedGeneration, binding: Self.binding, mode: Self.mode)
    else { Issue.record("expected stale after cleanup"); return }
  }

  @Test("an OS time older than 2 s or in the future is not trusted")
  func implausibleStampsAreRejected() {
    #expect(T.accepting(stamp: 97.9, handled: 100).occurred == nil)
    #expect(T.accepting(stamp: 100.06, handled: 100).occurred == nil)
    #expect(T.accepting(stamp: 0, handled: 100).occurred == nil)
    #expect(T.accepting(stamp: 99.5, handled: 100).occurred == 99.5)
  }
}
