import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P2: the keyboard listener installed beside today's record key, in shadow mode.
///
/// Product Outcome: when this fails, the listener is left running after the user stops or
/// suspends shortcuts (a tap holding their keys), two listeners run at once, a missing
/// Accessibility grant floods telemetry or never recovers, or the shadow listener triggers an
/// action the user did not ask for.
@MainActor
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct HotkeyShadowIntegrationTests {

  @MainActor private final class Rig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let effects = RecordingDesktopHotkeyEffects()
    let service: HotkeyService
    var failures: [(mechanism: String, kind: String, shape: String)] = []
    var presses = 0
    var actions = 0

    init() {
      timers = HotkeyTestScheduler(clock: clock)
      final class Box { weak var rig: Rig? }
      let box = Box()
      service = HotkeyService(
        effects: effects,
        telemetry: HotkeyTelemetrySink(
          registrationFailed: { mechanism, kind, _, shape in
            box.rig?.failures.append((mechanism, kind, shape))
          },
          pressed: { _, _, _, _, _, _ in box.rig?.presses += 1 }),
        uptime: clock.uptime, scheduler: timers.scheduler)
      box.rig = self
      service.onToggleRecording = { [weak self] in self?.actions += 1 }
      service.onStartRecording = { [weak self] in
        self?.actions += 1
        return .noRecording
      }
    }

    var listenerFailures: Int { failures.filter { $0.mechanism == "event_tap" }.count }
  }

  @Test("start installs one listener and stop removes it")
  func startAndStop() throws {
    let rig = Rig()
    rig.service.start()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    let token = try #require(rig.effects.keyboardListenerToken)
    rig.service.stop()
    #expect(rig.effects.removed.contains(token))
    #expect(rig.effects.keyboardListenerToken == nil)
    #expect(rig.listenerFailures == 0)
  }

  @Test("suspend removes the listener and resume installs a fresh one")
  func suspendAndResume() throws {
    let rig = Rig()
    rig.service.start()
    let first = try #require(rig.effects.keyboardListenerToken)
    let generation = rig.service.listenerGeneration
    rig.service.suspend()
    #expect(rig.effects.removed.contains(first))
    #expect(rig.effects.keyboardListenerToken == nil)
    rig.service.resume()
    #expect(rig.effects.keyboardListenerInstalls == 2)
    let second = try #require(rig.effects.keyboardListenerToken)
    #expect(second != first)
    #expect(rig.service.listenerGeneration > generation)
    rig.service.stop()
  }

  @Test("a shortcut restart replaces the listener exactly once")
  func restartReplacesOnce() {
    let rig = Rig()
    rig.service.start()
    rig.service.restartPreservingCancelArming()
    #expect(rig.effects.keyboardListenerInstalls == 2)
    #expect(rig.effects.keyboardListenerToken != nil)
    rig.service.stop()
  }

  @Test("a failed install is reported once and retried until it succeeds")
  func failedInstallReportsOnceAndRetries() async {
    let rig = Rig()
    let waiter = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onListenerRetryResolvedForTesting = { waiter.note() }
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    #expect(rig.listenerFailures == 1)
    #expect(rig.failures.first?.kind == ShortcutRole.record.telemetryKind)
    #expect(rig.failures.first?.shape == "modifier_only")
    #expect(rig.timers.requestedDelays == [TimingConstants.accessibilityPollIntervalSec])

    // Still failing: retried, not reported again.
    rig.clock.now += TimingConstants.accessibilityPollIntervalSec
    rig.timers.fireDue()
    await waiter.wait(until: 1)
    #expect(rig.effects.keyboardListenerInstalls == 2)
    #expect(rig.listenerFailures == 1)

    // Accessibility granted: the next retry installs and stops retrying.
    rig.effects.failKeyboardListenerInstall = false
    rig.clock.now += TimingConstants.accessibilityPollIntervalSec
    rig.timers.fireDue()
    await waiter.wait(until: 2)
    #expect(rig.effects.keyboardListenerInstalls == 3)
    #expect(rig.effects.keyboardListenerToken != nil)
    #expect(rig.timers.pendingCount == 0)
    #expect(rig.listenerFailures == 1)
    rig.service.stop()
  }

  @Test("a retry scheduled before stop never installs a listener after it")
  func staleRetryInstallsNothing() async {
    let rig = Rig()
    let waiter = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onListenerRetryResolvedForTesting = { waiter.note() }
    rig.effects.failKeyboardListenerInstall = true
    // A cancelled timer that fires anyway, as a handler already running would.
    let fires = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    let service = HotkeyService(
      effects: rig.effects, telemetry: .noop, uptime: rig.clock.uptime,
      scheduler: { _, fire in
        fires.withLock { $0.append(fire) }
        return RecordGestureEngine.TimerHandle(cancel: {})
      })
    service.onListenerRetryResolvedForTesting = { waiter.note() }
    service.start()
    service.stop()
    rig.effects.failKeyboardListenerInstall = false
    let installs = rig.effects.keyboardListenerInstalls
    fires.withLock { $0 }.first?()
    await waiter.wait(until: 1)
    #expect(rig.effects.keyboardListenerInstalls == installs)
    #expect(rig.effects.keyboardListenerToken == nil)
  }

  @Test("a refused removal keeps the old listener and no second one is installed")
  func refusedRemovalBlocksASecondListener() throws {
    let rig = Rig()
    rig.service.start()
    let token = try #require(rig.effects.keyboardListenerToken)
    rig.effects.refuseRemovals = true
    rig.service.suspend()
    rig.service.resume()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    #expect(rig.effects.keyboardListenerToken == token)
    rig.effects.refuseRemovals = false
    rig.service.stop()
  }

  @Test("the listener passes every event through and triggers no action or telemetry")
  func listenerIsShadowOnly() throws {
    let rig = Rig()
    rig.service.recordingMode = .pushToTalk
    rig.service.start()
    let sink = try #require(rig.effects.keyboardListenerSink)
    for (flags, t) in [(UInt64(0x80040), 0.0), (0, 0.1), (0x80040, 0.2), (0, 0.3)] {
      let verdict = sink(
        KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: flags, timestamp: 500 + t))
      #expect(verdict == .passThrough)
    }
    #expect(rig.actions == 0)
    #expect(rig.presses == 0)
    #expect(rig.service.isModifierHeld == false)
    rig.service.stop()
  }

  @Test("today's monitors and Carbon are still installed beside the listener")
  func existingIngressIsUnchanged() {
    let rig = Rig()
    rig.service.start()
    #expect(rig.effects.globalMonitorInstalls == 1)
    #expect(rig.effects.localMonitorInstalls == 1)
    #expect(rig.effects.carbonHandlerInstalls == 1)
    #expect(rig.effects.keyboardListenerInstalls == 1)
    rig.service.stop()
  }

  @Test("a stopped or suspended service installs no listener")
  func noListenerWhileStoppedOrSuspended() {
    let rig = Rig()
    rig.service.resume()  // not started: nothing
    #expect(rig.effects.keyboardListenerInstalls == 0)
    rig.service.start()
    rig.service.suspend()
    rig.service.reapplyCancelBinding()  // refused while suspended
    #expect(rig.effects.keyboardListenerInstalls == 1)
    #expect(rig.effects.keyboardListenerToken == nil)
    rig.service.stop()
  }

  @Test("a pending install retry does not keep a released service alive")
  func pendingRetryDoesNotRetainTheService() {
    let effects = RecordingDesktopHotkeyEffects()
    effects.failKeyboardListenerInstall = true
    let fires = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    weak var weakService: HotkeyService?
    do {
      let service = HotkeyService(
        effects: effects, telemetry: .noop, uptime: { 500 },
        scheduler: { _, fire in
          fires.withLock { $0.append(fire) }
          return RecordGestureEngine.TimerHandle(cancel: {})
        })
      weakService = service
      service.start()
      #expect(fires.withLock { $0.count } == 1)
    }
    #expect(weakService == nil)
  }

  @Test("a failed install of a chord record key reports the chord shape")
  func failedChordInstallReportsChord() {
    let rig = Rig()
    rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
    rig.service.toggleModifiers = [.command]
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    #expect(rig.listenerFailures == 1)
    #expect(rig.failures.last?.mechanism == "event_tap")
    #expect(rig.failures.last?.kind == ShortcutRole.record.telemetryKind)
    #expect(rig.failures.last?.shape == "chord")
    rig.service.stop()
  }
}
