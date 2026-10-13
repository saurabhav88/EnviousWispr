import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

/// #3517 — a Space pressed while the push-to-talk record key is held locks the running take into
/// hands-free, through the real path: the listener sink, the ingress, the engine and
/// `HotkeyService` main-side execution and publication.
///
/// Product Outcome: when this fails, a user who holds the record key and presses Space gets a
/// take that still stops when they let go, a lock published for a take that never started or that
/// joined someone else's recording, a pipeline that is still processing being locked, or a
/// follow-up press that cancels the take they just locked.
@MainActor
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct HotkeyHeldSpaceLockTests {

  private static let option = ModifierKeyCodes.rightOption

  /// Every `hotkey.pressed` row exactly as the sink received it.
  struct PressRow: Equatable {
    let trigger: String
    let mode: String
    let shape: String
    let identity: String
    let action: String
    let windowTiming: String?
  }

  @MainActor private final class Rig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let effects = RecordingDesktopHotkeyEffects()
    let driver = HotkeyHandsFreeLockGateTests.StartDriver()
    let service: HotkeyService
    let keyboard: ListenerKeyboard
    var rows: [PressRow] = []
    var lockDecisions: [(committed: Bool, reason: String)] = []
    var published: [String] = []
    var stops = 0
    var cancels = 0
    var processing = false

    var actions: [String] { rows.map(\.action) }

    init() {
      timers = HotkeyTestScheduler(clock: clock)
      final class Box { weak var rig: Rig? }
      let box = Box()
      service = HotkeyService(
        effects: effects,
        telemetry: HotkeyTelemetrySink(
          registrationFailed: { _, _, _, _ in },
          pressed: { trigger, mode, shape, identity, action, timing in
            box.rig?.rows.append(
              PressRow(
                trigger: trigger, mode: mode, shape: shape, identity: identity, action: action,
                windowTiming: timing))
          },
          lockResolved: { committed, reason in
            box.rig?.lockDecisions.append((committed, reason))
          }),
        uptime: clock.uptime, scheduler: timers.scheduler)
      keyboard = ListenerKeyboard(effects)
      box.rig = self
      service.recordingMode = .pushToTalk
      let driver = self.driver
      service.onStartResolvedForTesting = { driver.noteServiceResolved() }
      service.onStartRecording = driver.handler
      service.onLockRequested = { [weak self] sessionID in
        self?.published.append(sessionID)
        return .published
      }
      service.onStopRecording = { [weak self] in self?.stops += 1 }
      service.onCancelRecording = { [weak self] in self?.cancels += 1 }
      service.onIsProcessing = { [weak self] in self?.processing ?? false }
      service.start()
    }

    /// Move the handling clock and the event stamp together.
    func press(_ t: TimeInterval) async {
      clock.now = 500 + t
      await keyboard.press(HotkeyHeldSpaceLockTests.option, at: 500 + t)
    }
    func release(_ t: TimeInterval) async {
      clock.now = 500 + t
      await keyboard.release(HotkeyHeldSpaceLockTests.option, at: 500 + t)
    }
    func space(_ t: TimeInterval, _ kind: KeyEventValue.Kind = .keyDown) async
      -> KeyboardEventDisposition
    {
      clock.now = 500 + t
      return await keyboard.space(kind, at: 500 + t)
    }
  }

  @Test(
    "Space while held publishes the lock once the start is accepted; the release then keeps the take"
  )
  func spaceWhileHeldLocksAndTheReleaseDoesNotStop() async {
    let rig = Rig()
    await rig.press(0)
    await rig.driver.resolve(.recording("S1"))
    #expect(rig.published.isEmpty, "acceptance alone must not publish")
    #expect(await rig.space(1.5) == .consume)
    #expect(rig.published == ["S1"])
    #expect(rig.service.isRecordingLocked)
    #expect(rig.lockDecisions.map(\.reason) == ["published"])
    #expect(rig.actions == ["start", "lock_held"])
    await rig.release(2)
    #expect(rig.stops == 0, "letting go of a locked hold stopped the take")
    #expect(rig.cancels == 0)
    #expect(rig.service.isRecordingLocked)
  }

  @Test(
    "the lock_held row reports the push-to-talk record key it was decided under, with no window timing"
  )
  func lockHeldRowShape() async {
    let rig = Rig()
    await rig.press(0)
    await rig.driver.resolve(.recording("S1"))
    _ = await rig.space(1)
    #expect(
      rig.rows.last
        == PressRow(
          trigger: "ptt_hotkey", mode: "pushToTalk", shape: "modifier_only",
          identity: "right_option", action: "lock_held", windowTiming: nil))
  }

  @Test("a Space pressed before the start is accepted waits and publishes on acceptance")
  func spaceBeforeAcceptanceWaits() async {
    let rig = Rig()
    await rig.press(0)
    #expect(await rig.space(0.2) == .consume)
    #expect(rig.published.isEmpty, "published before the start was accepted")
    await rig.driver.resolve(.recording("S1"))
    #expect(rig.published == ["S1"])
    #expect(rig.service.isRecordingLocked)
  }

  @Test("a start that produced no recording never publishes a held-key lock")
  func refusedStartNeverPublishes() async {
    let rig = Rig()
    await rig.press(0)
    _ = await rig.space(0.3)
    await rig.driver.resolve(.noRecording)
    #expect(rig.published.isEmpty)
    #expect(!rig.service.isRecordingLocked)
    #expect(rig.lockDecisions.map(\.reason) == ["start_produced_no_recording"])
    #expect(rig.lockDecisions.first?.committed == false)
  }

  @Test("a take the controller will not lock is refused after the Space was consumed, and keeps recording")
  func publicationRefusalLeavesTheTakeRunning() async {
    for (result, reason) in [
      (HandsFreeLockRequestResult.notLockable, "not_lockable_at_publication"),
      (HandsFreeLockRequestResult.unavailable, "publication_unavailable"),
    ] {
      let rig = Rig()
      rig.service.onLockRequested = { [weak rig] sessionID in
        rig?.published.append(sessionID)
        return result
      }
      await rig.press(0)
      await rig.driver.resolve(.recording("S1"))
      #expect(await rig.space(1) == .consume, "accepted intent consumes the Space (plan 3.5)")
      #expect(rig.published == ["S1"])
      #expect(rig.lockDecisions.map(\.reason) == [reason])
      #expect(rig.lockDecisions.first?.committed == false)
      #expect(!rig.service.isRecordingLocked)
      #expect(rig.stops == 0 && rig.cancels == 0, "a refused lock must not stop the take")
    }
  }

  @Test("a press that is still being processed is refused, as a double tap is")
  func processingRefusesTheHeldLock() async {
    let rig = Rig()
    await rig.press(0)
    await rig.driver.resolve(.recording("S1"))
    rig.processing = true
    _ = await rig.space(1)
    #expect(rig.published.isEmpty)
    #expect(rig.actions == ["start", "ignored_processing"])
    #expect(!rig.service.isRecordingLocked)
  }

  @Test("a start the engine already knows joined a running recording is never locked by the held key")
  func joinedStartIsNeverLocked() async {
    let rig = Rig()
    await rig.press(0)
    // The start found a session already running and joined it, as the controller reports.
    rig.service.markExecutingStartJoined()
    await rig.driver.resolve(.recording("S1"))
    // The engine refuses a joined hold, so the Space is an ordinary key: it passes untouched.
    #expect(await rig.space(1) == .pass)
    #expect(rig.published.isEmpty, "locked a session the held key never started")
    #expect(rig.actions == ["start"])
    #expect(rig.lockDecisions.isEmpty)
    #expect(rig.stops == 0 && rig.cancels == 0, "the joined session was touched")
  }

  @Test("a start that joined after the Space was decided is refused at publication")
  func lateJoinIsRefusedAtPublication() async {
    let rig = Rig()
    await rig.press(0)
    _ = await rig.space(0.2)  // intent recorded, the start is still pending
    rig.service.markExecutingStartJoined()  // the controller then finds a running session
    await rig.driver.resolve(.recording("S1"))
    #expect(rig.published.isEmpty)
    #expect(rig.lockDecisions.map(\.reason) == ["not_lockable_at_publication"])
  }

  @Test("a start that joined while the engine had already moved on to a newer attempt is refused at execution")
  func lateJoinAfterTheEngineAdvancedIsRefused() async throws {
    let rig = Rig()
    await rig.press(0)  // attempt A: its start is parked in the driver
    for _ in 0..<50 where rig.driver.enteredCount < 1 { await ListenerKeyboard.mainTurn() }
    #expect(rig.driver.enteredCount == 1)
    let sink = try #require(rig.effects.keyboardListenerDispositionSink)
    func send(_ kind: KeyEventValue.Kind, _ key: UInt16, _ down: Bool, _ t: TimeInterval) {
      rig.clock.now = 500 + t
      let held = down ? Set([HotkeyHeldSpaceLockTests.option]) : []
      _ = sink(
        KeyEventValue(
          kind: kind, keyCode: key, rawFlags: ListenerKeyboard.rawFlags(held),
          timestamp: 500 + t))
    }
    // Everything below is decided by the engine on this turn; none of it runs on main until the
    // test yields, so main still owns attempt A when the engine already owns attempt B.
    send(.keyDown, 49, true, 0.25)  // the held Space: lock A
    send(.flagsChanged, HotkeyHeldSpaceLockTests.option, false, 0.375)  // release
    send(.flagsChanged, HotkeyHeldSpaceLockTests.option, true, 0.9)  // stops A (engine side)
    send(.keyUp, 49, false, 0.95)  // Space is up again, so B's start is not refused as typing
    send(.flagsChanged, HotkeyHeldSpaceLockTests.option, false, 1.0)
    send(.flagsChanged, HotkeyHeldSpaceLockTests.option, true, 1.2)  // starts B
    // A's start now finds a running session and joins it. The engine ignores this (it owns B);
    // main must remember it against A.
    rig.service.markExecutingStartJoined()
    await ListenerKeyboard.mainTurn()
    #expect(rig.published.isEmpty, "locked a session the held key never started")
    #expect(rig.lockDecisions.map(\.reason) == ["not_lockable_at_publication"])
    // Refusing A drops A's queued stop with it (attempt-scoped), so the joined session is not
    // stopped or cancelled by the held key's lock or by the press that would have stopped it.
    #expect(rig.actions == ["start", "lock_held", "start"])
    #expect(rig.stops == 0 && rig.cancels == 0)
    // The newer attempt is untouched and still starts normally.
    await rig.driver.resolve(call: 2, .recording("S2"))
    await rig.driver.resolve(call: 1, .noRecording)
    #expect(rig.published.isEmpty)
  }

  @Test(
    "after an early held lock, a record press inside the first press's window is a bounce, never a cancel"
  )
  func pressInsideTheFirstWindowAfterAHeldLockIsABounce() async {
    let rig = Rig()
    await rig.press(0)
    await rig.driver.resolve(.recording("S1"))
    _ = await rig.space(0.25)
    await rig.release(0.375)
    await rig.press(0.4375)
    #expect(rig.actions == ["start", "lock_held", "ignored_cooldown"])
    #expect(rig.cancels == 0, "a lock made while held was read as a triple-press cancel")
    #expect(rig.stops == 0)
  }

  @Test("a record press after the cooldown stops the locked take once")
  func pressAfterTheCooldownStops() async {
    let rig = Rig()
    await rig.press(0)
    await rig.driver.resolve(.recording("S1"))
    _ = await rig.space(0.25)
    await rig.release(0.375)
    await rig.press(1.0)
    #expect(rig.actions == ["start", "lock_held", "stop"])
    #expect(rig.stops == 1)
    #expect(rig.cancels == 0)
  }
}
