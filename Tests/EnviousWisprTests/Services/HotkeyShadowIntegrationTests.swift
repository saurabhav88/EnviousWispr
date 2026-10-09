import EnviousWisprCore
import EnviousWisprServices
import AppKit
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

  #if DEBUG
    /// Both lanes fed the same physical events: the listener sink (shadow) and the monitor path
    /// (live), with the same event times.
    private func both(_ rig: Rig, _ flags: UInt64, at t: TimeInterval) throws {
      rig.clock.now = 500 + t
      let sink = try #require(rig.effects.keyboardListenerSink)
      _ = sink(KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: flags, timestamp: 500 + t))
      rig.service.handleInstalledMonitorFlagsChangedValues(
        keyCode: 61, flags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
        generation: rig.service.monitorGeneration, timestamp: 500 + t)
    }

    @Test("a calm push-to-talk double tap agrees on every record in both lanes")
    func calmDoubleTapAgrees() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.onStartRecording = { .recording("s1") }
      rig.service.onLockRequested = { _ in .published }
      rig.service.start()
      try both(rig, 0x80040, at: 0)
      try both(rig, 0, at: 0.125)
      try both(rig, 0x80040, at: 0.25)
      try both(rig, 0, at: 0.375)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.mappingErrors == 0)
      #expect(tally.ambiguities == 0)
      #expect(tally.incomplete == 0)
      #expect(tally.droppedRecords == 0)
      // 4 edges plus start, quick release, lock, the cancelled wait and the suppressed release.
      #expect(tally.agreements == 9)
      rig.service.stop()
    }

    @Test("listener events after stop never reach the shadow policy")
    func eventsAfterStopAreIgnored() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.start()
      let sink = try #require(rig.effects.keyboardListenerSink)
      rig.service.stop()
      _ = sink(KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: 0x80040, timestamp: 501))
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally == HotkeyShadowDiagnostics.Tally())
    }

    @Test("a binding change starts a comparison generation; arming a recording does not")
    func generationFollowsMeaningNotArming() {
      let rig = Rig()
      rig.service.start()
      let first = rig.service.shadowComparisonGenerationForTesting
      rig.service.setCancelHotkeyEnabled(true)
      rig.service.setCancelHotkeyEnabled(false)
      #expect(rig.service.shadowComparisonGenerationForTesting == first)
      rig.service.quickAddKeyCode = 14
      #expect(rig.service.shadowComparisonGenerationForTesting == first + 1)
      rig.service.quickAddKeyCode = 14  // unchanged assignment
      #expect(rig.service.shadowComparisonGenerationForTesting == first + 1)
      rig.service.stop()
    }

    @Test("a Carbon chord on a modifier key is counted out of scope, never compared")
    func chordRecordsAreOutOfScope() {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      // Right Option + Command: a modifier key code, but a chord that Carbon delivers.
      rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
      rig.service.toggleModifiers = [.command]
      rig.service.start()
      rig.clock.now = 500
      rig.service.handleCarbonHotkey(id: 1, isRelease: false, timestamp: 500)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.outOfScope >= 1)
      #expect(tally.agreements == 0)
      #expect(tally.mappingErrors == 0)
      rig.service.stop()
    }

    private static let snapshot = ShadowKeyboardPolicy.Snapshot(
      generation: 1, bindings: .shipped, mode: .pushToTalk, enabled: true, suspended: false,
      armed: [.record], available: [])

    private static func ingress(
      _ lane: ShadowRecord.Lane, _ i: Int, generation: UInt64 = 1
    ) -> ShadowRecord {
      ShadowRecord(
        lane: lane, generation: generation, sequence: UInt64(i + 1), category: .ingress,
        keyCode: 61, role: .record, phase: .press, outcome: .edge,
        rawOccurred: 500 + Double(i), acceptedOccurred: nil, handled: 500)
    }

    /// A diagnostics object with one active segment.
    private static func activeSegment(
      log: @escaping @Sendable (String) async -> Void = { _ in }, logCapacity: Int = 256
    ) -> (HotkeyShadowDiagnostics, HotkeyShadowDiagnostics.Segment) {
      let diagnostics = HotkeyShadowDiagnostics(
        clock: { 500 }, log: log, logCapacity: logCapacity)
      let segment = diagnostics.makeSegment(installation: 1, generation: 1, snapshot: snapshot)
      diagnostics.activate(segment)
      return (diagnostics, segment)
    }

    @Test("a full handoff drops and counts records, and the segment is no longer clean")
    func handoffOverflowIsReported() {
      let (diagnostics, segment) = Self.activeSegment()
      let extra = 76
      for i in 0..<(HotkeyShadowDiagnostics.Segment.handoffCapacity + extra) {
        diagnostics.submit(Self.ingress(.live, i))
      }
      let tally = segment.drainForTesting()
      #expect(tally.droppedRecords == extra)
      #expect(tally.clean == false)
    }

    @Test("records submitted while the worker holds a taken buffer are never lost")
    func submissionsDuringAHeldDrainAreKept() {
      let (diagnostics, segment) = Self.activeSegment()
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let first = OSAllocatedUnfairLock(initialState: true)
      segment.setDrainGateForTesting {
        guard first.withLock({ f in defer { f = false }; return f }) else { return }
        entered.signal()
        // deadline-fallback: bound the test's own release signal so a regression fails, not hangs.
        _ = release.wait(timeout: .now() + 5)
      }
      diagnostics.submit(Self.ingress(.live, 0))
      diagnostics.submit(Self.ingress(.shadow, 0))
      let drained = DispatchSemaphore(value: 0)
      DispatchQueue.global(qos: .userInitiated).async {
        _ = segment.drainForTesting()
        drained.signal()
      }
      // deadline-fallback: bound the worker's own signal.
      #expect(entered.wait(timeout: .now() + 5) == .success)
      // The producer finishes entirely while the worker holds the detached buffer.
      let pairs = 400
      for i in 1...pairs {
        diagnostics.submit(Self.ingress(.live, i))
        diagnostics.submit(Self.ingress(.shadow, i))
      }
      release.signal()
      #expect(drained.wait(timeout: .now() + 5) == .success)
      let total = segment.drainForTesting()
      #expect(total.droppedRecords == 0)
      #expect(total.agreements == pairs + 1)
    }

    @Test("a slow logger's overflow is counted, and releasing diagnostics cancels the logger")
    func slowLoggerOverflowIsReported() throws {
      let entered = DispatchSemaphore(value: 0)
      let cancelled = DispatchSemaphore(value: 0)
      let (parked, continuation) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
      defer { continuation.finish() }
      let log: @Sendable (String) async -> Void = { _ in
        entered.signal()
        for await _ in parked {}
        if Task.isCancelled { cancelled.signal() }
      }
      do {
        let (diagnostics, segment) = Self.activeSegment(log: log, logCapacity: 1)
        // Three same-attempt mapping errors: three lines for a channel that holds one.
        for i in 0..<3 {
          let t = 500 + Double(i)
          diagnostics.submit(
            ShadowRecord(
              lane: .live, generation: 1, sequence: UInt64(i + 1), category: .decision,
              keyCode: 61, role: .record, phase: .release, outcome: .gesture(.quickRelease),
              rawOccurred: nil, acceptedOccurred: t, handled: t, attemptStartOccurred: 499))
          diagnostics.submit(
            ShadowRecord(
              lane: .shadow, generation: 1, sequence: UInt64(i + 1), category: .decision,
              keyCode: 61, role: .record, phase: .release, outcome: .gesture(.holdStop),
              rawOccurred: nil, acceptedOccurred: t, handled: t, attemptStartOccurred: 499))
        }
        let tally = segment.drainForTesting()
        #expect(tally.mappingErrors == 3)
        #expect(tally.suppressedLines >= 1)
        #expect(tally.clean == false)
        // deadline-fallback: require the logger's own entry signal.
        try #require(entered.wait(timeout: .now() + 5) == .success)
      }
      // deadline-fallback: bound the logger's own cancellation signal.
      #expect(cancelled.wait(timeout: .now() + 5) == .success)
    }

    @Test("a segment's final lines refused by a finished channel make it unclean")
    func terminatedChannelIsNotClean() throws {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let first = OSAllocatedUnfairLock(initialState: true)
      var held: HotkeyShadowDiagnostics.Segment?
      do {
        let (diagnostics, segment) = Self.activeSegment()
        held = segment
        segment.setDrainGateForTesting {
          guard first.withLock({ f in defer { f = false }; return f }) else { return }
          entered.signal()
          // deadline-fallback: bound the test's own release signal.
          _ = release.wait(timeout: .now() + 5)
        }
        diagnostics.close(reason: "test")
        // deadline-fallback: require the worker's own entry signal.
        try #require(entered.wait(timeout: .now() + 5) == .success)
      }
      // The diagnostics owner is gone and its channel finished; the closing worker resumes.
      release.signal()
      let segment = try #require(held)
      let tally = segment.settledTallyForTesting()
      #expect(tally.suppressedLines >= 1)
      #expect(tally.clean == false)
    }

    @Test("one segment's loss is never charged to, or hidden by, another")
    func lossStaysInItsSegment() {
      let diagnostics = HotkeyShadowDiagnostics(clock: { 500 }, log: { _ in })
      let first = diagnostics.makeSegment(installation: 1, generation: 1, snapshot: Self.snapshot)
      diagnostics.activate(first)
      diagnostics.submit(Self.ingress(.live, 0))
      diagnostics.submit(Self.ingress(.shadow, 0))
      diagnostics.close(reason: "stop")
      let second = diagnostics.makeSegment(installation: 2, generation: 2, snapshot: Self.snapshot)
      diagnostics.activate(second)
      for i in 0..<(HotkeyShadowDiagnostics.Segment.handoffCapacity + 10) {
        diagnostics.submit(Self.ingress(.live, i, generation: 2))
      }
      // A late live record from the first installation's generation.
      diagnostics.submit(Self.ingress(.live, 9999, generation: 1))
      let closed = first.settledTallyForTesting()
      let open = second.drainForTesting()
      #expect(closed.clean)
      #expect(closed.agreements == 1)
      #expect(open.droppedRecords == 10)
      #expect(open.earlierGeneration == 1)
      #expect(open.clean == false)
    }

    @Test("a callback from an earlier installation never feeds the next one")
    func earlierInstallationCallbackIsIgnored() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.start()
      let oldSink = try #require(rig.effects.keyboardListenerSink)
      rig.service.stop()
      rig.service.start()
      _ = oldSink(KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: 0x80040, timestamp: 501))
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.agreements == 0)
      #expect(tally.mappingErrors == 0)
      // The live lane alone, for a press the shadow never admitted, is unmatched, not compared.
      try both(rig, 0x80040, at: 2)
      try both(rig, 0, at: 2.75)
      let after = rig.service.shadowDiagnostics.drainForTesting()
      #expect(after.mappingErrors == 0)
      #expect(after.agreements >= 4)
      rig.service.stop()
    }

    @Test("a key released while suspended does not swallow the next press")
    func releaseWhileSuspended() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.onStartRecording = { .recording("s") }
      rig.service.start()
      try both(rig, 0x80040, at: 0)  // held
      rig.service.suspend()  // released while suspended: neither lane sees it
      rig.service.resume()
      try both(rig, 0x80040, at: 2)
      try both(rig, 0, at: 2.75)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.mappingErrors == 0)
      #expect(tally.ambiguities == 0)
      #expect(tally.agreements >= 4)
      rig.service.stop()
    }

    @Test("stop retires both lanes' pending lone-tap waits")
    func stopRetiresPendingWaits() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.onStartRecording = { .recording("s") }
      rig.service.start()
      try both(rig, 0x80040, at: 0)
      try both(rig, 0, at: 0.125)
      // Live's wait is on the test scheduler; the shadow's runs on its segment's worker.
      #expect(rig.timers.pendingCount == 1)
      let segment = try #require(rig.service.shadowDiagnostics.currentSegmentForTesting)
      rig.service.stop()
      #expect(rig.timers.pendingCount == 0)
      // The closed segment compared the press and release and was left with nothing pending.
      let closed = segment.settledTallyForTesting()
      #expect(closed.incomplete == 0)
      #expect(closed.mappingErrors == 0)
    }

    @Test("a push-to-talk press reads the clock once, for the decision and its record")
    func oneClockReadPerPress() {
      let reads = OSAllocatedUnfairLock(initialState: 0)
      let effects = RecordingDesktopHotkeyEffects()
      let service = HotkeyService(
        effects: effects, telemetry: .noop,
        uptime: {
          reads.withLock { $0 += 1 }
          return 500
        }, scheduler: HotkeyTestScheduler(clock: HotkeyTestClock(500)).scheduler)
      service.recordingMode = .pushToTalk
      service.start()
      let before = reads.withLock { $0 }
      service.handleInstalledMonitorFlagsChangedValues(
        keyCode: 61, flags: .option, generation: service.monitorGeneration, timestamp: 500)
      #expect(reads.withLock { $0 } - before == 1)
      service.stop()
    }

    @Test("stop reads the listener's final health after removing it")
    func stopReadsHealthAfterRemoval() {
      let rig = Rig()
      rig.service.start()
      #expect(rig.effects.keyboardListenerHealthQueries == 0)
      rig.service.stop()
      #expect(rig.effects.keyboardListenerHealthQueries == 1)
    }

    @Test("a closing segment logs the listener's health and callback cost with its definition")
    func closeLogsHealth() throws {
      let seen = DispatchSemaphore(value: 0)
      let line = OSAllocatedUnfairLock<String?>(initialState: nil)
      let (diagnostics, _) = Self.activeSegment(log: { l in
        guard l.contains("listener_health") else { return }
        line.withLock { $0 = l }
        seen.signal()
      })
      diagnostics.close(
        reason: "stop",
        health: KeyboardListenerHealth(
          terminal: .disableStorm, disableEpisodes: 5, reenables: 4,
          cost: KeyboardListenerCost(
            samples: 1200, maxNanoseconds: 90_000, p99LowerNanoseconds: 8_192,
            p99UpperNanoseconds: 9_742, recordingNanoseconds: 40)))
      // deadline-fallback: bound the logger's own signal.
      try #require(seen.wait(timeout: .now() + 5) == .success)
      let text = try #require(line.withLock { $0 })
      #expect(text.contains("terminal=disableStorm"))
      #expect(text.contains("disable_episodes=5 reenables=4"))
      #expect(
        text.contains(
          "cost_subject=callback_entry_to_return_excluding_recording cost_unit=ns samples=1200"))
      #expect(text.contains("max=90000 p99_bucket=[8192,9742)"))
      #expect(text.contains("recording_uncontended_mean=40 complete=true"))
    }

    @Test("after a re-enable the shadow reconciles a release it missed, so the next press starts")
    func reenableReconcilesAMissedRelease() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.onStartRecording = { .recording("s") }
      rig.service.start()
      try both(rig, 0x80040, at: 0)
      // Held 1 s: live sees the release; the shadow's tap was off and missed it.
      rig.clock.now = 501
      rig.service.handleInstalledMonitorFlagsChangedValues(
        keyCode: 61, flags: [], generation: rig.service.monitorGeneration, timestamp: 501)
      rig.effects.keyStates.withLock { $0[61] = .up }
      let sink = try #require(rig.effects.keyboardListenerSink)
      _ = sink(KeyEventValue(kind: .tapReenabled, keyCode: 0, rawFlags: 0, timestamp: 501.5))
      try both(rig, 0x80040, at: 3)
      try both(rig, 0, at: 3.75)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.mappingErrors == 0)
      // The first press and edge, then the second press, its edge, release and its edge agree.
      #expect(tally.agreements >= 6)
      rig.service.stop()
    }

    @Test("a health report read while the listener was still owned is marked partial")
    func refusedRemovalHealthIsPartial() {
      let health = KeyboardListenerHealth(
        terminal: nil, disableEpisodes: 0, reenables: 0,
        cost: KeyboardListenerCost(
          samples: 3, maxNanoseconds: 5, p99LowerNanoseconds: 4, p99UpperNanoseconds: 6,
          recordingNanoseconds: 1))
      let line = HotkeyShadowDiagnostics.Segment.healthLine(
        installation: 7, health, complete: false)
      #expect(line.contains("complete=false"))
    }

    @Test("a refused health line leaves the closing summary unclean")
    func refusedHealthLineIsUnclean() throws {
      let entered = DispatchSemaphore(value: 0)
      let (parked, continuation) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
      defer { continuation.finish() }
      let (diagnostics, segment) = Self.activeSegment(
        log: { _ in
          entered.signal()
          for await _ in parked {}
        }, logCapacity: 1)
      // One mapping error each drain: the first line occupies the logger, the second the
      // one-line channel, so the health and summary lines that follow are refused.
      for i in 0..<2 {
        let t = 500 + Double(i)
        diagnostics.submit(
          ShadowRecord(
            lane: .live, generation: 1, sequence: UInt64(i + 1), category: .decision,
            keyCode: 61, role: .record, phase: .release, outcome: .gesture(.quickRelease),
            rawOccurred: nil, acceptedOccurred: t, handled: t, attemptStartOccurred: 499))
        diagnostics.submit(
          ShadowRecord(
            lane: .shadow, generation: 1, sequence: UInt64(i + 1), category: .decision,
            keyCode: 61, role: .record, phase: .release, outcome: .gesture(.holdStop),
            rawOccurred: nil, acceptedOccurred: t, handled: t, attemptStartOccurred: 499))
        _ = segment.drainForTesting()
        // deadline-fallback: require the logger's own entry signal before the second drain.
        if i == 0 { try #require(entered.wait(timeout: .now() + 5) == .success) }
      }
      let before = segment.drainForTesting().suppressedLines
      diagnostics.close(
        reason: "stop",
        health: KeyboardListenerHealth(terminal: nil, disableEpisodes: 0, reenables: 0, cost: nil))
      let settled = segment.settledTallyForTesting()
      #expect(settled.suppressedLines >= before + 2)
      #expect(settled.clean == false)
    }

    private func cancelGesture(_ rig: Rig) throws {
      let sink = try #require(rig.effects.keyboardListenerSink)
      for (flags, t) in [(UInt64(0x100010), 501.0), (0, 501.1)] {
        rig.clock.now = t
        _ = sink(KeyEventValue(kind: .flagsChanged, keyCode: 54, rawFlags: flags, timestamp: t))
        rig.service.handleInstalledMonitorFlagsChangedValues(
          keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
          generation: rig.service.monitorGeneration, timestamp: t)
      }
    }

    @Test("a consumed cancel release agrees after cancel disarms")
    func cancelTailAgrees() throws {
      let rig = Rig()
      rig.service.cancelKeyCode = ModifierKeyCodes.rightCommand
      rig.service.cancelModifiers = []
      rig.service.start()
      rig.service.setCancelHotkeyEnabled(true)
      try cancelGesture(rig)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.agreements == 4)
      #expect(tally.mappingErrors == 0)
      #expect(tally.ambiguities == 0)
      rig.service.stop()
    }

    @Test("cancel and Quick Add on one bare key: the consumed release is cancel's in both lanes")
    func sharedCancelQuickAddKeyAgrees() throws {
      let rig = Rig()
      rig.service.cancelKeyCode = ModifierKeyCodes.rightCommand
      rig.service.cancelModifiers = []
      rig.service.quickAddKeyCode = ModifierKeyCodes.rightCommand
      rig.service.quickAddModifiers = []
      rig.service.onQuickAdd = {}
      rig.service.start()
      rig.service.setCancelHotkeyEnabled(true)
      try cancelGesture(rig)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.agreements == 4)
      #expect(tally.mappingErrors == 0)
      #expect(tally.ambiguities == 0)
      rig.service.stop()
    }

    @Test("a stray key-up with no press seen agrees in both lanes")
    func strayReleaseAgrees() throws {
      let rig = Rig()
      rig.service.recordingMode = .pushToTalk
      rig.service.start()
      try both(rig, 0, at: 0)
      let tally = rig.service.shadowDiagnostics.drainForTesting()
      #expect(tally.agreements == 2)  // the edge and the ignored release
      #expect(tally.mappingErrors == 0)
      let closing = try #require(rig.service.shadowDiagnostics.currentSegmentForTesting)
      rig.service.stop()
      #expect(closing.settledTallyForTesting().incomplete == 0)
    }
  #endif
}
