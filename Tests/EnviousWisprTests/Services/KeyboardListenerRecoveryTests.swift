import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P3: the keyboard listener recovers from a disable storm on its own, and reports its
/// health only when something went wrong.
///
/// Product Outcome: when this fails, a listener the OS kept disabling stays dead until the app
/// is relaunched (the record key goes silent), a replacement is installed while the old tap may
/// still be live (two listeners), a storm floods reinstalls, or listener health never reaches the
/// weekly release review.
@MainActor
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct KeyboardListenerRecoveryTests {

  @MainActor private final class Rig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let effects = RecordingDesktopHotkeyEffects()
    let service: HotkeyService
    var health: [HotkeyListenerHealthReport] = []
    /// Every `hotkey.pressed` row: trigger, mode, shape, identity, action.
    var pressed: [[String]] = []
    let retries = HotkeyGlobeKeyTests.CallbackWaiter()

    init() {
      timers = HotkeyTestScheduler(clock: clock)
      final class Box { weak var rig: Rig? }
      let box = Box()
      service = HotkeyService(
        effects: effects,
        telemetry: HotkeyTelemetrySink(
          registrationFailed: { _, _, _, _ in },
          pressed: { trigger, mode, shape, identity, action, _ in
            box.rig?.pressed.append([trigger, mode, shape, identity, action])
          },
          listenerHealth: { report in box.rig?.health.append(report) }),
        uptime: clock.uptime, scheduler: timers.scheduler)
      box.rig = self
      let retries = self.retries
      service.onListenerRetryResolvedForTesting = { retries.note() }
    }

    var engine: RecordGestureEngine { service.recordGestureEngineForTesting }

    func stormHealth() {
      effects.keyboardListenerHealthAnswer = KeyboardListenerHealth(
        terminal: .disableStorm, disableEpisodes: 5, reenables: 4, cost: nil)
    }

    /// The listener's own storm notice, from its thread, then the main turn it hops to.
    func storm(through sink: (@Sendable (KeyEventValue) -> Void)?) async {
      let sink = sink
      await Task.detached {
        sink?(KeyEventValue(kind: .stormStopped, keyCode: 0, rawFlags: 0, timestamp: nil))
      }.value
      await Self.mainTurn()
    }

    /// Wait for main to run everything queued on it before this call (FIFO).
    static func mainTurn() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
  }

  @Test("a storm removes the listener at once and installs a fresh one after the cooldown")
  func stormIsReplacedAfterTheCooldown() async throws {
    let rig = Rig()
    rig.service.start()
    defer { rig.service.stop() }
    let first = try #require(rig.effects.keyboardListenerToken)
    let firstInstallation = try #require(rig.engine.listenerInstallation)
    rig.stormHealth()
    await rig.storm(through: rig.effects.keyboardListenerSink)
    #expect(rig.effects.removed.contains(first))
    #expect(rig.effects.keyboardListenerToken == nil)
    #expect(rig.engine.listenerInstallation == nil)
    #expect(rig.health.count == 1)
    #expect(rig.health.first?.terminal == "disable_storm")
    #expect(rig.health.first?.reason == "storm")
    #expect(rig.health.first?.disableEpisodes == 5)
    // The reviewed bound, as an independent literal.
    #expect(rig.timers.requestedDelays.last == 60)
    // Not before the cooldown.
    rig.clock.now = 559.9
    rig.timers.fireDue()
    await Rig.mainTurn()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    // At the cooldown, a fresh installation with a fresh identity, without any key event.
    rig.effects.keyboardListenerHealthAnswer = KeyboardListenerHealth(
      terminal: nil, disableEpisodes: 0, reenables: 0, cost: nil)
    rig.clock.now = 560
    rig.timers.fireDue()
    await rig.retries.wait(until: 1)
    #expect(rig.effects.keyboardListenerInstalls == 2)
    let second = try #require(rig.effects.keyboardListenerToken)
    #expect(second != first)
    let secondInstallation = try #require(rig.engine.listenerInstallation)
    #expect(secondInstallation != firstInstallation)
  }

  /// A push-to-talk hold is live when the OS storms the listener. With no listener, only key state
  /// can show the key came up: the hold must end then, through the cooldown and through installs
  /// that keep failing, not at the replacement's first sweep or never.
  @Test("a record key let go while no listener is installed still stops the recording")
  func releaseDuringListenerDowntimeStops() async {
    let rig = Rig()
    rig.service.recordingMode = .pushToTalk
    rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
    rig.service.toggleModifiers = []
    var starts = 0
    var stops = 0
    let stopped = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onStartRecording = {
      starts += 1
      return .recording("s\(starts)")
    }
    rig.service.onStopRecording = {
      stops += 1
      stopped.note()
    }
    rig.service.start()
    defer { rig.service.stop() }
    let keys = ListenerKeyboard(rig.effects)
    await keys.press(ModifierKeyCodes.rightOption, at: 500)
    await rig.service.awaitInFlightStartForTesting()
    #expect(starts == 1)
    rig.effects.keyStates.withLock { $0[ModifierKeyCodes.rightOption] = .down }
    rig.stormHealth()
    await rig.storm(through: rig.effects.keyboardListenerSink)
    // Still held at the first check: nothing ends.
    rig.clock.now = 505
    rig.timers.fireDue()
    await Rig.mainTurn()
    #expect(stops == 0)
    // The replacement fails (Accessibility gone); the key is still held.
    rig.effects.failKeyboardListenerInstall = true
    rig.clock.now = 560
    rig.timers.fireDue()
    await rig.retries.wait(until: 1)
    await Rig.mainTurn()
    #expect(rig.effects.keyboardListenerToken == nil)
    #expect(stops == 0)
    // The key comes up unseen: one up reading is not enough; the second in a row ends the hold.
    rig.effects.keyStates.withLock { $0[ModifierKeyCodes.rightOption] = .up }
    rig.clock.now = 566
    rig.timers.fireDue()
    await Rig.mainTurn()
    #expect(stops == 0, "a single up reading ended the hold")
    rig.clock.now = 572
    rig.timers.fireDue()
    await stopped.wait(until: 1)
    #expect(stops == 1)
    #expect(rig.service.isModifierHeld == false)
    #expect(starts == 1, "the check started a recording")
  }

  /// `refused`: the OS refused the stormed listener's removal, so its token is still held; its
  /// input is no longer admitted, so the check must run all the same.
  @Test(
    "a record key let go during the storm cooldown stops the recording before the replacement",
    arguments: [false, true])
  func releaseDuringStormCooldownStops(refused: Bool) async {
    let rig = Rig()
    rig.service.recordingMode = .pushToTalk
    rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
    rig.service.toggleModifiers = []
    var stops = 0
    let stopped = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onStartRecording = { .recording("s") }
    rig.service.onStopRecording = {
      stops += 1
      stopped.note()
    }
    rig.service.start()
    defer { rig.service.stop() }
    let keys = ListenerKeyboard(rig.effects)
    await keys.press(ModifierKeyCodes.rightOption, at: 500)
    await rig.service.awaitInFlightStartForTesting()
    rig.stormHealth()
    rig.effects.refuseRemovals = refused
    await rig.storm(through: rig.effects.keyboardListenerSink)
    #expect((rig.effects.keyboardListenerToken != nil) == refused)
    rig.effects.keyStates.withLock { $0[ModifierKeyCodes.rightOption] = .up }
    rig.clock.now = 505
    rig.timers.fireDue()
    await Rig.mainTurn()
    #expect(stops == 0, "a single up reading ended the hold")
    rig.clock.now = 510
    rig.timers.fireDue()
    await stopped.wait(until: 1)
    #expect(stops == 1)
    #expect(rig.effects.keyboardListenerInstalls == 1, "ended only by the replacement")
    rig.effects.refuseRemovals = false
  }

  /// #3544 P4 C2: a record press with no side bits cannot be vouched for by the flags reader, so
  /// the orphaned-hold check never ends it, however often it reads up.
  @Test("the orphaned-hold check never ends an aggregate-only hold")
  func orphanedCheckSparesAggregateOnlyHold() async {
    let rig = Rig()
    rig.service.recordingMode = .pushToTalk
    rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
    rig.service.toggleModifiers = []
    var stops = 0
    rig.service.onStartRecording = { .recording("s") }
    rig.service.onStopRecording = { stops += 1 }
    rig.service.start()
    defer { rig.service.stop() }
    let keys = ListenerKeyboard(rig.effects)
    let family = UInt64(NSEvent.ModifierFlags.option.rawValue)
    await keys.deliver(ModifierKeyCodes.rightOption, raw: family, at: 500)
    await rig.service.awaitInFlightStartForTesting()
    #expect(rig.engine.ownedListenerPress?.recovery == .notReadable)
    rig.stormHealth()
    await rig.storm(through: rig.effects.keyboardListenerSink)
    rig.effects.keyStates.withLock { $0[ModifierKeyCodes.rightOption] = .up }
    for t in [505.0, 510, 515, 520] {
      rig.clock.now = t
      rig.timers.fireDue()
      await Rig.mainTurn()
    }
    #expect(stops == 0, "a reading ended an aggregate-only hold while no listener was installed")
    #expect(rig.engine.ownedListenerKey == ModifierKeyCodes.rightOption)
  }

  @Test("stopping during the cooldown cancels the replacement")
  func stopDuringCooldownInstallsNothing() async {
    let rig = Rig()
    rig.service.start()
    rig.stormHealth()
    await rig.storm(through: rig.effects.keyboardListenerSink)
    rig.service.stop()
    rig.clock.now = 560
    rig.timers.fireDue()
    await Rig.mainTurn()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    #expect(rig.effects.keyboardListenerToken == nil)
    #expect(rig.engine.listenerInstallation == nil)
  }

  @Test("suspending during the cooldown cancels it, and resuming installs at once")
  func suspendDuringCooldownThenResume() async throws {
    let rig = Rig()
    rig.service.start()
    defer { rig.service.stop() }
    rig.stormHealth()
    await rig.storm(through: rig.effects.keyboardListenerSink)
    rig.service.suspend()
    rig.clock.now = 560
    rig.timers.fireDue()
    await Rig.mainTurn()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    rig.service.resume()
    #expect(rig.effects.keyboardListenerInstalls == 2)
    _ = try #require(rig.effects.keyboardListenerToken)
  }

  @Test("a storm notice from an installation already replaced does nothing")
  func staleStormNoticeIsIgnored() async throws {
    let rig = Rig()
    rig.service.start()
    defer { rig.service.stop() }
    let oldSink = rig.effects.keyboardListenerSink
    rig.service.suspend()
    rig.service.resume()
    let current = try #require(rig.effects.keyboardListenerToken)
    let delays = rig.timers.requestedDelays.count
    rig.stormHealth()
    await rig.storm(through: oldSink)
    #expect(rig.effects.keyboardListenerToken == current)
    #expect(rig.effects.removed.contains(current) == false)
    #expect(rig.timers.requestedDelays.count == delays)
    #expect(rig.health.isEmpty)
  }

  @Test("a refused removal after a storm installs nothing until the old listener is gone")
  func refusedStormRemovalWaitsForTheOldListener() async throws {
    let rig = Rig()
    rig.service.start()
    defer { rig.service.stop() }
    let first = try #require(rig.effects.keyboardListenerToken)
    rig.stormHealth()
    rig.effects.refuseRemovals = true
    await rig.storm(through: rig.effects.keyboardListenerSink)
    // Still owned, so not yet accounted and not replaced.
    #expect(rig.effects.keyboardListenerToken == first)
    #expect(rig.health.isEmpty)
    #expect(rig.engine.listenerInstallation == nil)
    rig.effects.refuseRemovals = false
    rig.clock.now = 560
    rig.timers.fireDue()
    await rig.retries.wait(until: 1)
    #expect(rig.effects.removed.filter { $0 == first }.count == 2)
    #expect(rig.effects.keyboardListenerInstalls == 2)
    // Its final health is accounted once, when its removal finally succeeded.
    #expect(rig.health.count == 1)
    #expect(rig.health.first?.terminal == "disable_storm")
    #expect(rig.health.first?.reason == "reinstall")
  }

  @Test("a healthy installation reports nothing; one the OS disabled reports once at its end")
  func healthIsReportedOnlyForTroubledInstallations() {
    let rig = Rig()
    rig.service.start()
    rig.service.stop()
    #expect(rig.health.isEmpty)
    rig.service.start()
    rig.effects.keyboardListenerHealthAnswer = KeyboardListenerHealth(
      terminal: .removed, disableEpisodes: 2, reenables: 2, cost: nil)
    rig.service.stop()
    rig.service.stop()
    #expect(rig.health.count == 1)
    #expect(rig.health.first?.terminal == "removed")
    #expect(rig.health.first?.reason == "stop")
    #expect(rig.health.first?.disableEpisodes == 2)
    #expect(rig.health.first?.reenables == 2)
  }

  @Test("failed installs are counted, and the success after them reports once with the totals")
  func failedInstallsThenSuccessAreCounted() async {
    let rig = Rig()
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    defer { rig.service.stop() }
    // Two retries at the Accessibility poll cadence fail; nothing reported yet.
    for retry in 1...2 {
      rig.clock.now += TimingConstants.accessibilityPollIntervalSec
      rig.timers.fireDue()
      await rig.retries.wait(until: retry)
    }
    #expect(rig.effects.keyboardListenerInstalls == 3)
    #expect(rig.health.isEmpty)
    // Access granted: the next retry installs, with no key input at all.
    rig.effects.failKeyboardListenerInstall = false
    rig.clock.now += TimingConstants.accessibilityPollIntervalSec
    rig.timers.fireDue()
    await rig.retries.wait(until: 3)
    #expect(
      rig.health == [
        HotkeyListenerHealthReport(
          terminal: "none", reason: "installed_after_failures", disableEpisodes: 0, reenables: 0,
          installAttempts: 4, installFailures: 3, installs: 1)
      ])
    // A later healthy reinstall reports nothing more.
    rig.service.suspend()
    rig.service.resume()
    #expect(rig.health.count == 1)
  }

  @Test("installs that never succeed report once when shortcuts stop, and only once")
  func failuresReportedAtStop() async {
    let rig = Rig()
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    for retry in 1...2 {
      rig.clock.now += TimingConstants.accessibilityPollIntervalSec
      rig.timers.fireDue()
      await rig.retries.wait(until: retry)
    }
    #expect(rig.effects.keyboardListenerInstalls == 3)
    #expect(rig.health.isEmpty)
    rig.service.stop()
    rig.service.stop()
    #expect(
      rig.health == [
        HotkeyListenerHealthReport(
          terminal: "start_failed", reason: "stop", disableEpisodes: 0, reenables: 0,
          installAttempts: 3, installFailures: 3, installs: 0)
      ])
  }

  @Test("each failure episode reports once: one ended by success, a later one by suspend")
  func successiveFailureEpisodes() async {
    let rig = Rig()
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    defer { rig.service.stop() }
    rig.effects.failKeyboardListenerInstall = false
    rig.clock.now += TimingConstants.accessibilityPollIntervalSec
    rig.timers.fireDue()
    await rig.retries.wait(until: 1)
    #expect(rig.health.map(\.reason) == ["installed_after_failures"])
    // Access lost later: a reinstall fails, then the recorder suspends shortcuts.
    rig.effects.failKeyboardListenerInstall = true
    rig.service.suspend()
    rig.service.resume()
    rig.service.suspend()
    #expect(rig.health.map(\.reason) == ["installed_after_failures", "suspend"])
    #expect(rig.health.last?.terminal == "start_failed")
    #expect(rig.health.last?.installAttempts == 3)
    #expect(rig.health.last?.installFailures == 2)
    #expect(rig.health.last?.installs == 1)
    rig.service.resume()
  }

  // MARK: - Secure Input (plan A2)

  /// A Secure Input change from the listener's thread, through the given sink.
  private func secureInput(
    _ sink: (@Sendable (KeyEventValue) -> Void)?, enabled: Bool, pid: Int32?
  ) async {
    let sink = sink
    await Task.detached {
      sink?(
        KeyEventValue(
          kind: .secureInputChanged, keyCode: 0, rawFlags: 0, timestamp: nil,
          secureInput: SecureInputObservation(enabled: enabled, ownerPID: pid)))
    }.value
    await Rig.mainTurn()
  }

  @Test("a Secure Input change is logged and changes no recording or gesture state")
  func secureInputIsLoggedOnly() async throws {
    let rig = Rig()
    rig.service.recordingMode = .pushToTalk
    rig.service.start()
    defer { rig.service.stop() }
    var logged: [SecureInputObservation] = []
    rig.service.onSecureInputLoggedForTesting = { logged.append($0) }
    var actions = 0
    rig.service.onStartRecording = {
      actions += 1
      return .recording("s")
    }
    rig.service.onCancelRecording = { actions += 1 }
    await secureInput(rig.effects.keyboardListenerSink, enabled: true, pid: 812)
    await secureInput(rig.effects.keyboardListenerSink, enabled: false, pid: nil)
    #expect(logged == [.init(enabled: true, ownerPID: 812), .init(enabled: false, ownerPID: nil)])
    #expect(actions == 0)
    #expect(rig.service.isModifierHeld == false)
    #expect(rig.service.isRecordingLocked == false)
    #expect(rig.effects.keyboardListenerToken != nil)
  }

  // MARK: - Secure Input notice (#3544 P4, D4)

  /// A push-to-talk service on bare Right Option whose starts record, counting notices.
  @MainActor private final class NoticeRig {
    let rig = Rig()
    var notices: [String] = []
    var starts = 0
    /// What the presentation answers (false: the session was no longer running).
    var accept = true
    let keys: ListenerKeyboard
    init(mode: RecordingMode = .pushToTalk) {
      keys = ListenerKeyboard(rig.effects)
      rig.service.recordingMode = mode
      rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
      rig.service.toggleModifiers = []
      rig.service.onStartRecording = { [unowned self] in
        starts += 1
        return .recording("s\(starts)")
      }
      rig.service.onToggleRecording = {}
      rig.service.onStopRecording = {}
      rig.service.onSecureInputPausedKeyFeatures = { [unowned self] in
        notices.append($0)
        return accept
      }
      rig.service.start()
    }
    func dictate(at t: TimeInterval) async {
      rig.clock.now = 500 + t
      await keys.press(ModifierKeyCodes.rightOption, at: 500 + t)
      await rig.service.awaitInFlightStartForTesting()
      rig.clock.now = 501.5 + t
      await keys.release(ModifierKeyCodes.rightOption, at: 501.5 + t)
      await rig.service.awaitInFlightStartForTesting()
    }
  }

  @Test("a bare push-to-talk start under Secure Input is told once per Secure Input period")
  func secureInputNoticeOncePerPeriod() async {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    await n.dictate(at: 0)
    #expect(n.notices.isEmpty, "a notice without Secure Input")
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    #expect(n.notices.isEmpty, "Secure Input alone, with no dictation, produced a notice")
    await n.dictate(at: 10)
    await n.dictate(at: 20)
    #expect(n.notices == ["s2"], "not exactly once, on the start that met Secure Input")
    // A repeated on sample is not a new period.
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    await n.dictate(at: 30)
    #expect(n.notices == ["s2"])
    // Off, then on again: a new period, told again.
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: false, pid: nil)
    await n.dictate(at: 40)
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    await n.dictate(at: 50)
    #expect(n.notices == ["s2", "s6"], "notices \(n.notices), starts \(n.starts)")
    #expect(n.starts == 6, "a notice changed what was recorded")
    // #3544 P6: one health row per notice shown, and nothing else.
    let rows = n.rig.health.map { [$0.terminal, $0.reason] }
    #expect(rows == [["none", "secure_input_notice"], ["none", "secure_input_notice"]])
    #expect(n.rig.health.allSatisfy { $0.disableEpisodes == 0 && $0.staleKind == nil })
  }

  // MARK: - Field health (#3544 P6)

  @Test("a start refused for a held key sends one pressed row with the press's key and mode")
  func refusedStartIsReported() async {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    let sink = n.rig.effects.keyboardListenerSink
    n.rig.clock.now = 500
    await Task.detached {
      sink?(KeyEventValue(kind: .keyDown, keyCode: 0, rawFlags: 0, timestamp: 500))
    }.value
    await n.keys.press(ModifierKeyCodes.rightOption, at: 500.2)
    await n.keys.release(ModifierKeyCodes.rightOption, at: 500.4)
    await Rig.mainTurn()
    #expect(n.starts == 0)
    #expect(
      n.rig.pressed == [
        ["ptt_hotkey", "pushToTalk", "modifier_only", "right_option", "refused_key_held"]
      ], "\(n.rig.pressed)")
    #expect(n.rig.health.isEmpty, "a refusal sent a health row")
  }

  @Test("a held record key two sweeps release sends one stale_key_cleared modifier row")
  func staleModifierIsReported() async {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    n.rig.clock.now = 500
    await n.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await n.rig.service.awaitInFlightStartForTesting()
    n.rig.effects.keyStates.withLock { $0[ModifierKeyCodes.rightOption] = .up }
    for t in [505.0, 510.0] {
      n.rig.clock.now = t
      n.rig.timers.fireDue()
      await Rig.mainTurn()
    }
    await Rig.mainTurn()
    #expect(n.rig.health.count == 1, "\(n.rig.health)")
    let row = n.rig.health.first
    #expect(row?.terminal == "none")
    #expect(row?.reason == "stale_key_cleared")
    #expect(row?.staleKind == "modifier")
    #expect(row?.disableEpisodes == 0 && row?.reenables == 0)
    #expect(row?.installs == 1, "launch totals ride the row")
  }

  @Test("the first tap re-enable of an installation sends one tap_reenabled row at once")
  func tapReenableIsReported() async {
    let rig = Rig()
    rig.service.start()
    defer { rig.service.stop() }
    let sink = rig.effects.keyboardListenerSink
    for _ in 0..<2 {
      await Task.detached {
        sink?(KeyEventValue(kind: .tapReenabled, keyCode: 0, rawFlags: 0, timestamp: nil))
      }.value
      await Rig.mainTurn()
    }
    #expect(rig.health.map { [$0.terminal, $0.reason] } == [["none", "tap_reenabled"]])
    #expect(rig.health.first?.disableEpisodes == 0 && rig.health.first?.staleKind == nil)
  }

  @Test("a start that resolves after the other-key window shows no notice and keeps it owed")
  func lateStartGetsNoNotice() async {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    let clock = n.rig.clock
    var slow = true
    n.rig.service.onStartRecording = { [unowned n] in
      n.starts += 1
      if slow { clock.now += 2 }  // the start took two seconds
      return .recording("s\(n.starts)")
    }
    await n.dictate(at: 0)
    #expect(n.notices.isEmpty, "a notice after the other-key window had passed")
    slow = false
    await n.dictate(at: 10)
    #expect(n.notices == ["s2"])
  }

  @Test("a notice the presentation refused leaves the period's notice for the next valid take")
  func refusedNoticeIsNotCounted() async {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    n.accept = false
    await n.dictate(at: 0)
    n.accept = true
    await n.dictate(at: 10)
    #expect(n.notices == ["s1", "s2"], "a refused notice consumed the period")
    await n.dictate(at: 20)
    #expect(n.notices == ["s1", "s2"])
    // #3544 P6: only the notice that was shown is reported.
    #expect(n.rig.health.map(\.reason) == ["secure_input_notice"])
  }

  @Test("Secure Input observed inside a take's first second notices it; later in the take it does not")
  func secureInputEnteredDuringATake() async {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    // Observed 0.5 s into the hold: the other-key rule still applies to this take.
    n.rig.clock.now = 500
    await n.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await n.rig.service.awaitInFlightStartForTesting()
    n.rig.clock.now = 500.5
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    #expect(n.notices == ["s1"])
    n.rig.clock.now = 502
    await n.keys.release(ModifierKeyCodes.rightOption, at: 502)
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: false, pid: nil)
    // Observed 2 s into a hold: the rule no longer applies, so nothing is paused for this take.
    n.rig.clock.now = 510
    await n.keys.press(ModifierKeyCodes.rightOption, at: 510)
    await n.rig.service.awaitInFlightStartForTesting()
    n.rig.clock.now = 512
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    #expect(n.notices == ["s1"], "a notice for a take the rule no longer protects")
    n.rig.clock.now = 513
    await n.keys.release(ModifierKeyCodes.rightOption, at: 513)
    // The period's notice is still owed: the next start tells it.
    await n.dictate(at: 20)
    #expect(n.notices == ["s1", "s3"])
  }

  @Test("a start superseded while pending never notices; the take that replaced it does")
  func supersededStartNeverNotices() async throws {
    let n = NoticeRig()
    defer { n.rig.service.stop() }
    var gate: CheckedContinuation<Void, Never>?
    let entered = HotkeyGlobeKeyTests.CallbackWaiter()
    var calls = 0
    n.rig.service.onStartRecording = {
      calls += 1
      if calls == 1 {
        entered.note()
        await withCheckedContinuation { gate = $0 }
        return .recording("stale")
      }
      return .recording("fresh")
    }
    await secureInput(n.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    n.rig.clock.now = 500
    await n.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await entered.wait(until: 1)
    n.rig.clock.now = 501.5
    await n.keys.release(ModifierKeyCodes.rightOption, at: 501.5)
    n.rig.clock.now = 505
    await n.keys.press(ModifierKeyCodes.rightOption, at: 505)
    await n.rig.service.awaitInFlightStartForTesting()
    try #require(gate).resume()
    await Rig.mainTurn()
    #expect(n.notices == ["fresh"], "the superseded start's session was noticed")
  }

  @Test("no Secure Input notice where the other-key rule does not apply, or from a replaced listener")
  func secureInputNoticeOnlyWhereItMatters() async {
    // Toggle mode: the other-key rule is push-to-talk only.
    let toggle = NoticeRig(mode: .toggle)
    defer { toggle.rig.service.stop() }
    await secureInput(toggle.rig.effects.keyboardListenerSink, enabled: true, pid: nil)
    await toggle.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await toggle.keys.release(ModifierKeyCodes.rightOption, at: 500.1)
    await Rig.mainTurn()
    #expect(toggle.notices.isEmpty)
    // A stale installation's observation: replaced by suspend and resume, then a dictation.
    let stale = NoticeRig()
    defer { stale.rig.service.stop() }
    let oldSink = stale.rig.effects.keyboardListenerSink
    stale.rig.service.suspend()
    stale.rig.service.resume()
    await secureInput(oldSink, enabled: true, pid: nil)
    await stale.dictate(at: 0)
    #expect(stale.notices.isEmpty, "a replaced listener's Secure Input produced a notice")
  }

  @Test("a Secure Input change from a replaced installation is not logged")
  func staleSecureInputIsIgnored() async {
    let rig = Rig()
    rig.service.start()
    defer { rig.service.stop() }
    var logged: [SecureInputObservation] = []
    rig.service.onSecureInputLoggedForTesting = { logged.append($0) }
    let oldSink = rig.effects.keyboardListenerSink
    rig.service.suspend()
    rig.service.resume()
    await secureInput(oldSink, enabled: true, pid: 812)
    #expect(logged.isEmpty)
  }

  @Test("an ordinary key event carries no Secure Input payload")
  func keyEventsCarryNoSecureInput() {
    let event = KeyEventValue(
      kind: .flagsChanged, keyCode: 61, rawFlags: 0x80040, timestamp: 1,
      secureInput: SecureInputObservation(enabled: true, ownerPID: 812))
    #expect(event.secureInput == nil)
  }

  @Test("after a storm replacement, the next bare Copy Last and Paste Last presses act afresh")
  func bareActionHoldsAreRetiredByAReplacement() async throws {
    let rig = Rig()
    var copies = 0
    var pastePresses = 0
    var pastes = 0
    rig.service.copyLastKeyCode = ModifierKeyCodes.rightCommand
    rig.service.copyLastModifiers = []
    rig.service.pasteLastKeyCode = ModifierKeyCodes.leftOption
    rig.service.pasteLastModifiers = []
    rig.service.onCopyLast = { copies += 1 }
    rig.service.onPasteLast = { pastes += 1 }
    rig.service.onPasteLastPressed = { pastePresses += 1 }
    rig.service.start()
    defer { rig.service.stop() }
    let before = ListenerKeyboard(rig.effects)
    await before.press(ModifierKeyCodes.rightCommand)
    await before.press(ModifierKeyCodes.leftOption)
    #expect(copies == 1)
    #expect(pastePresses == 1)
    // The OS storms the listener while both are held; their releases go unseen.
    rig.stormHealth()
    await rig.storm(through: rig.effects.keyboardListenerSink)
    rig.effects.keyboardListenerHealthAnswer = KeyboardListenerHealth(
      terminal: nil, disableEpisodes: 0, reenables: 0, cost: nil)
    rig.clock.now = 560
    rig.timers.fireDue()
    await rig.retries.wait(until: 1)
    #expect(pastes == 0, "a retired hold must not fire")
    let after = ListenerKeyboard(rig.effects)
    await after.press(ModifierKeyCodes.rightCommand)
    #expect(copies == 2, "the first Copy Last after recovery did nothing")
    await after.press(ModifierKeyCodes.leftOption)
    #expect(pastePresses == 2, "Paste Last did not take a fresh target")
    await after.release(ModifierKeyCodes.leftOption)
    #expect(pastes == 1)
  }

  /// Paste Last on bare Right Command is held, reset to its default chord without suspending, and
  /// the chord pressed before Right Command comes up. The old key's release keeps its listener route,
  /// so it reaches main; it must not end the chord's hold and paste before V is released.
  @Test("the release of a key from before a rebind does not end the new shortcut's hold")
  func oldKeyReleaseDoesNotEndANewHold() async {
    let rig = Rig()
    var pastePresses = 0
    var pastes = 0
    rig.service.pasteLastKeyCode = ModifierKeyCodes.rightCommand
    rig.service.pasteLastModifiers = []
    rig.service.onPasteLast = { pastes += 1 }
    rig.service.onPasteLastPressed = { pastePresses += 1 }
    rig.service.start()
    defer { rig.service.stop() }
    let keys = ListenerKeyboard(rig.effects)
    await keys.press(ModifierKeyCodes.rightCommand)
    #expect(pastePresses == 1)
    rig.service.pasteLastKeyCode = ShortcutRole.pasteLast.defaultKeyCode
    rig.service.pasteLastModifiers = ShortcutRole.pasteLast.defaultModifiers
    rig.service.reapplyAppShortcutBinding(.pasteLast)
    let pasteLastID: UInt32 = 5
    rig.service.handleCarbonHotkey(id: pasteLastID, isRelease: false)
    #expect(pastePresses == 2, "the new chord's press did not take a fresh target")
    await keys.release(ModifierKeyCodes.rightCommand)
    #expect(pastes == 0, "the old key's release pasted before the chord was released")
    rig.service.handleCarbonHotkey(id: pasteLastID, isRelease: true)
    #expect(pastes == 1)
  }
}
