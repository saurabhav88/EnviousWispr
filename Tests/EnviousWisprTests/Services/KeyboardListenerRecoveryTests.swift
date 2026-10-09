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
    let retries = HotkeyGlobeKeyTests.CallbackWaiter()

    init() {
      timers = HotkeyTestScheduler(clock: clock)
      final class Box { weak var rig: Rig? }
      let box = Box()
      service = HotkeyService(
        effects: effects,
        telemetry: HotkeyTelemetrySink(
          registrationFailed: { _, _, _, _ in }, pressed: { _, _, _, _, _, _ in },
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
    func storm(through sink: (@Sendable (KeyEventValue) -> ListenerVerdict)?) async {
      let sink = sink
      await Task.detached {
        _ = sink?(KeyEventValue(kind: .stormStopped, keyCode: 0, rawFlags: 0, timestamp: nil))
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
    _ sink: (@Sendable (KeyEventValue) -> ListenerVerdict)?, enabled: Bool, pid: Int32?
  ) async {
    let sink = sink
    await Task.detached {
      _ = sink?(
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
