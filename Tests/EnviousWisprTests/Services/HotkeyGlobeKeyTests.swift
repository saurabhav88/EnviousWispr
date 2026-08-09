import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

/// #1987 — the Globe / Fn key behaves exactly like Right Option.
///
/// Every case drives the REAL modifier dispatch path, `handleFlagsChangedValues`,
/// with the physical event shape measured on hardware (probe, 2026-08-08): press
/// carries `.function`, release does not, and both arrive as `.flagsChanged` with
/// key code 63. A suite that asserted set membership instead would prove the key
/// is *accepted* and nothing at all about what pressing it does.
///
/// THREE MECHANISMS THIS SUITE GOT WRONG FIRST, recorded because each produced a
/// failure that read like a production bug:
///
/// 1. A QUICK release does not stop recording. Releasing within 500 ms of the
///    start arms a real debounce timer and waits to see whether a double-press
///    follows (`handleRecordRelease`). Only a release after holding LONGER than
///    that stops immediately. So a hold-to-talk case must actually hold, by
///    advancing the pinned clock before releasing.
/// 2. The fake must model `onLockRequested`. Production asks the app whether the
///    hands-free lock can be published and calls `performCleanup()` on
///    `.unavailable`; a nil callback DEFAULTS to `.unavailable`, so the service
///    correctly destroyed the session and three gestures failed as though
///    hands-free were broken.
/// 3. Counting `Task.yield()` turns is a scheduling assumption, not a signal, and
///    is flaky in both directions. Starts, stops and cancels are now awaited
///    through the service's own `awaitInFlightStartForTesting()` seam.
///
/// The clock is pinned throughout for the same reason the hands-free suite pins
/// it: the windows are measured in elapsed wall time, so an unpinned test takes
/// whichever branch the scheduler happens to allow.
@MainActor
@Suite struct HotkeyGlobeKeyTests {

  @MainActor final class ManualClock {
    private(set) var now = Date(timeIntervalSince1970: 2_000_000)
    func advance(ms: Int) { now = now.addingTimeInterval(Double(ms) / 1000.0) }
  }

  /// Signal-driven wait for a callback that has no task to await.
  ///
  /// The callback IS the signal; the deadline exists only so a regression fails
  /// loudly instead of hanging CI with no failing test name. An earlier version
  /// counted `Task.yield()` turns, which is a scheduling assumption in disguise
  /// and flaky in both directions on a loaded machine.
  @MainActor final class CallbackWaiter {
    private struct Pending {
      let id: UUID
      let target: Int
      let continuation: CheckedContinuation<Void, Never>
    }

    private var count = 0
    private var pending: Pending?

    func note() {
      count += 1
      guard let pending, count >= pending.target else { return }
      self.pending = nil
      pending.continuation.resume()
    }

    func wait(until target: Int, timeout: Duration = .seconds(5)) async {
      if count >= target { return }
      let id = UUID()
      let timeoutTask = Task { @MainActor [weak self] in
        // settle: deadline fallback AROUND the callback signal, never the wait
        // itself. The callback resumes the continuation and cancels this task;
        // this exists only so a regression fails loudly instead of hanging.
        try? await Task.sleep(for: timeout)
        self?.expire(id: id)
      }
      await withCheckedContinuation { continuation in
        pending = Pending(id: id, target: target, continuation: continuation)
      }
      timeoutTask.cancel()
    }

    private func expire(id: UUID) {
      guard let pending, pending.id == id else { return }
      self.pending = nil
      Issue.record(Comment(rawValue: "timed out waiting for callback count \(pending.target)"))
      pending.continuation.resume()
    }
  }

  /// Counts what the service asked the app to do. Start resolves immediately as a
  /// live session: these cases are about gesture routing, not the start-acceptance
  /// race that `HotkeyHandsFreeLockGateTests` already owns.
  @MainActor final class Spy {
    var starts = 0
    var stops = 0
    var cancels = 0
    var toggles = 0
    var actions: [String] = []
    let toggleWaiter = CallbackWaiter()

    var sink: HotkeyTelemetrySink {
      HotkeyTelemetrySink(
        registrationFailed: { _, _, _, _ in },
        pressed: { [weak self] _, _, _, action in self?.actions.append(action) },
        lockResolved: { _, _ in })
    }
  }

  private func makeService(
    _ spy: Spy, clock: ManualClock, mode: RecordingMode = .pushToTalk
  ) -> HotkeyService {
    let service = HotkeyService(telemetry: spy.sink, now: { clock.now })
    service.recordingMode = mode
    service.toggleKeyCode = ModifierKeyCodes.globe
    service.onStartRecording = { [weak spy] in
      spy?.starts += 1
      return .recording("globe-session")
    }
    // Production asks the app whether the hands-free lock can actually be
    // published, and tears the whole session down if the answer is no
    // (`publishLockIfReady` -> `.unavailable` -> `performCleanup`). A spy that
    // leaves this nil defaults to `.unavailable`, so the service correctly
    // destroyed the recording and three gesture cases failed as though hands-free
    // were broken. The fake must model the guard, not omit it.
    service.onLockRequested = { _ in .published }
    service.onStopRecording = { [weak spy] in spy?.stops += 1 }
    service.onCancelRecording = { [weak spy] in spy?.cancels += 1 }
    service.onToggleRecording = { [weak spy] in
      spy?.toggles += 1
      spy?.toggleWaiter.note()
    }
    return service
  }

  /// The measured press shape. `.function` present means held.
  private func press(_ service: HotkeyService, keyCode: UInt16 = ModifierKeyCodes.globe) {
    service.handleFlagsChangedValues(keyCode: keyCode, flags: [.function])
  }

  /// The measured release shape. The flag is gone.
  private func release(_ service: HotkeyService, keyCode: UInt16 = ModifierKeyCodes.globe) {
    service.handleFlagsChangedValues(keyCode: keyCode, flags: [])
  }

  /// The service's own deterministic seam (`HotkeyService.swift:378`). Start,
  /// stop and cancel each replace `recordingTask` synchronously before returning,
  /// so awaiting it observes the callback rather than guessing a scheduling turn.
  /// Under the flag mutation it returns immediately because no task exists, so
  /// assertions fail instead of hanging.
  private func settle(_ service: HotkeyService) async {
    await service.awaitInFlightStartForTesting()
  }

  // MARK: - Gesture 1: hold to talk

  @Test("Holding past the debounce window and releasing records once and stops once")
  func pushToTalkHoldAndRelease() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)

    press(service)
    await settle(service)
    #expect(spy.starts == 1)
    #expect(spy.stops == 0, "recording must not stop while the key is still held")

    clock.advance(ms: 800)  // a genuine hold, past the double-press window
    release(service)
    await settle(service)

    #expect(spy.starts == 1)
    #expect(spy.stops == 1)
    #expect(spy.cancels == 0)
  }

  /// The specific failure the derived-membership design exists to prevent. If the
  /// Globe key were a member with no flag, `contains([])` would be true on the
  /// release event too, so release would read as a second PRESS and recording
  /// would never stop. This is the case the mutation control drives RED.
  @Test("Release is distinguishable from press, so recording can actually stop")
  func releaseIsNotReadAsPress() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)

    press(service)
    await settle(service)
    clock.advance(ms: 800)
    release(service)
    await settle(service)

    #expect(spy.stops == 1, "release did not stop the recording")
    #expect(spy.starts == 1, "release was misread as a second press")
    #expect(spy.actions == ["start"], "a misread release would emit a second start")
  }

  // MARK: - Gesture 2: double press enters hands-free

  @Test("Double press inside the window locks hands-free instead of stopping")
  func doublePressEntersHandsFree() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)

    press(service)
    await settle(service)
    release(service)  // quick release, arms the debounce
    clock.advance(ms: 120)
    press(service)  // inside the window
    await settle(service)

    #expect(spy.actions.contains("lock"), "second press did not request hands-free")
    #expect(spy.stops == 0, "hands-free entry must not stop the recording")
    #expect(spy.starts == 1, "the second press must not start a new recording")
  }

  // MARK: - The lock cooldown

  @Test("A press inside the lock cooldown is ignored, not treated as a stop")
  func pressInsideCooldownIsIgnored() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)

    press(service)
    await settle(service)
    release(service)
    clock.advance(ms: 450)
    press(service)  // locks, still inside the 500 ms start window
    await settle(service)
    release(service)

    // Past the start window, but inside the 500 ms cooldown that follows the lock.
    clock.advance(ms: 150)
    press(service)
    await settle(service)

    #expect(spy.actions.contains("ignored_cooldown"))
    #expect(spy.stops == 0)
    #expect(spy.cancels == 0)
  }

  // MARK: - Gesture 3: single press after the cooldown stops hands-free

  @Test("A press after the cooldown stops hands-free exactly once")
  func singlePressAfterCooldownStops() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)

    press(service)
    await settle(service)
    release(service)
    clock.advance(ms: 450)
    press(service)  // locks
    await settle(service)
    release(service)

    clock.advance(ms: 900)  // past both the start window and the lock cooldown
    press(service)
    await settle(service)

    #expect(spy.stops == 1)
    #expect(spy.actions.contains("stop"))
    #expect(spy.cancels == 0)
  }

  // MARK: - Gesture 4: triple press cancels

  @Test("Triple press inside the window cancels hands-free and delivers nothing")
  func triplePressCancels() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)

    press(service)
    await settle(service)
    release(service)
    clock.advance(ms: 100)
    press(service)  // locks
    await settle(service)
    release(service)
    clock.advance(ms: 100)
    press(service)  // third press, still inside the start window
    await settle(service)

    #expect(spy.cancels == 1)
    #expect(spy.stops == 0, "a cancel must not also deliver the recording")
    #expect(spy.actions.contains("cancel"))
  }

  // MARK: - Gesture 5: toggle mode

  @Test("Toggle mode acts on press and ignores release")
  func toggleModeActsOnPressOnly() async {
    let spy = Spy()
    let service = makeService(spy, clock: ManualClock(), mode: .toggle)

    // Toggle mode never creates a recording task, so the start seam is not the
    // signal here; the toggle callback itself is.
    press(service)
    await spy.toggleWaiter.wait(until: 1)
    #expect(spy.toggles == 1)

    release(service)
    #expect(spy.toggles == 1, "release must not toggle a second time")

    press(service)
    await spy.toggleWaiter.wait(until: 2)
    #expect(spy.toggles == 2, "a second tap must toggle recording off")
  }

  // MARK: - Negative controls

  /// Arrow keys really do carry `.function` (probe, 2026-08-08). They arrive as
  /// `.keyDown` rather than `.flagsChanged` in production, but this drives them
  /// through the modifier path anyway: the guard must reject them on KEY CODE, not
  /// rely on the event type happening to differ.
  @Test(
    "An arrow key carrying .function cannot start dictation",
    arguments: [UInt16(123), 124, 125, 126])
  func arrowKeysCannotTrigger(code: UInt16) async {
    let spy = Spy()
    let service = makeService(spy, clock: ManualClock())

    service.handleFlagsChangedValues(keyCode: code, flags: [.function])
    await settle(service)

    #expect(spy.starts == 0)
    #expect(spy.actions.isEmpty)
  }

  /// The F-row carries `.function` too. Static membership rejection is proven in
  /// `KeySymbolsTests`; this proves the DISPATCH seam refuses them, which is what
  /// the plan asked for and what the earlier version only did for arrows.
  @Test(
    "An F-row key carrying .function cannot start dictation",
    arguments: [UInt16(122), 120, 99, 118, 96, 97])
  func fRowKeysCannotTrigger(code: UInt16) async {
    let spy = Spy()
    let service = makeService(spy, clock: ManualClock())

    service.handleFlagsChangedValues(keyCode: code, flags: [.function])

    #expect(spy.starts == 0)
    #expect(spy.actions.isEmpty)
  }

  @Test("A different standalone modifier cannot drive the Globe binding")
  func otherModifierDoesNotTrigger() async {
    let spy = Spy()
    let service = makeService(spy, clock: ManualClock())

    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightOption, flags: [.option])
    await settle(service)

    #expect(spy.starts == 0, "a key that is not the bound shortcut must do nothing")
  }

  /// Parity control. The same sequence on Right Option must behave identically, so
  /// a Globe-only regression is distinguishable from a change to the shared path.
  @Test("Right Option still behaves exactly as the Globe key does")
  func rightOptionParity() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)
    service.toggleKeyCode = ModifierKeyCodes.rightOption

    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightOption, flags: [.option])
    await settle(service)
    clock.advance(ms: 800)
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightOption, flags: [])
    await settle(service)

    #expect(spy.starts == 1)
    #expect(spy.stops == 1)
  }
}
