#if DEBUG
  import CoreAudio
  import Foundation
  import Testing
  import os

  @testable import EnviousWisprAudio

  /// #4601 §3.5: the HAL source's remaining hardware reads (running check, format
  /// stabilization, device-alive check) run on the audio-unit lane. When these fail, the user
  /// sees a frozen app mid-take, a healthy warm microphone thrown away, or a stale device check
  /// ending a newer take. Reads are injected; the lane and the source logic are real.
  @Suite("HAL source lane reads — #4601", .tags(.productOutcome))
  @MainActor
  struct HALSourceLaneReadTests {
    typealias Timers = AudioUnitLaneTests.ManualTimers
    typealias Signal = AudioUnitLaneTests.Signal
    typealias Gate = AudioUnitLaneTests.Gate
    typealias Natives = HALPrepareLifecycleTests.Natives

    final class Box<Value> {
      var value: Value
      init(_ value: Value) { self.value = value }
    }

    /// A source with a committed fake unit on its own lane.
    private func committedSource(_ timers: Timers) async throws -> (
      HALDeviceInputSource, AudioUnitLane
    ) {
      let lane = AudioUnitLane(
        label: "test.hal.reads", schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let source = HALDeviceInputSource()
      source.lane = lane
      source.startDeadline = AudioUnitLaneTests.base + .seconds(5)
      let natives = Natives()
      source.openWorkForTesting = { _ in HALPrepareLifecycleTests.opened(natives) }
      _ = try await source.prepare()
      return (source, lane)
    }

    /// Like `committedSource`, also returning the fake unit's native-call record.
    private func committedSourceCounting(_ timers: Timers) async throws -> (
      HALDeviceInputSource, AudioUnitLane, Natives
    ) {
      let lane = AudioUnitLane(
        label: "test.hal.quit", schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let source = HALDeviceInputSource()
      source.lane = lane
      source.startDeadline = AudioUnitLaneTests.base + .seconds(5)
      let natives = Natives()
      source.openWorkForTesting = { _ in HALPrepareLifecycleTests.opened(natives) }
      _ = try await source.prepare()
      return (source, lane, natives)
    }

    @Test("quit waits for a healthy microphone release within its deadline")
    func quitHealthyReleaseFinishes() async throws {
      let (source, lane, natives) = try await committedSourceCounting(Timers())

      let finished = source.stopSynchronously(deadline: AudioUnitLaneTests.base + .seconds(5))

      #expect(finished)
      #expect(natives.disposals == 1, "released before quit returned")
      await lane.drainForTesting()
    }

    @Test("quit stops waiting at its deadline and the queued release still runs later")
    func quitExpiredWaitKeepsTheRelease() async throws {
      let (source, lane, natives) = try await committedSourceCounting(Timers())
      let gate = Gate()
      defer { gate.open() }
      let busy = Signal()
      lane.retire {
        busy.fire()
        gate.block()
      }
      #expect(await busy.wait())

      // The lane's clock stands at `base`, so this deadline leaves a 20 ms wait.
      let finished = source.stopSynchronously(
        deadline: AudioUnitLaneTests.base + .milliseconds(20))

      #expect(finished == false)
      #expect(natives.disposals == 0, "storage kept: the release has not run")
      gate.open()
      await lane.drainForTesting()
      #expect(natives.disposals == 1, "the queued release ran once the lane was free")
    }

    /// Makes the lane wedged with a stuck read; returns the gate that releases it.
    private func wedge(_ lane: AudioUnitLane, _ timers: Timers) async -> Gate {
      let gate = Gate()
      let entered = Signal()
      Task {
        await lane.run("stuck") { () -> Int in
          entered.fire()
          gate.block()
          return 0
        }
      }
      _ = await entered.wait()
      _ = await timers.scheduled(AudioUnitLane.readLimit)
      timers.fire(AudioUnitLane.readLimit)
      return gate
    }

    @Test("the running check answers on the lane")
    func runningProbeAnswers() async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      var calls = HALNativeCalls.live
      calls.isRunning = { _ in true }
      source.nativeCalls = calls

      #expect(await source.isRunningOnLane(deadline: nil, attempt: nil))
      source.rebuild()
      await lane.drainForTesting()
    }

    @Test("a wedged lane answers not running without asking the unit")
    func runningProbeWedged() async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      let asked = OSAllocatedUnfairLock(initialState: false)
      var calls = HALNativeCalls.live
      calls.isRunning = { _ in
        asked.withLock { $0 = true }
        return true
      }
      source.nativeCalls = calls
      let gate = await wedge(lane, timers)
      defer { gate.open() }

      #expect(await source.isRunningOnLane(deadline: nil, attempt: nil) == false)
      #expect(asked.withLock { $0 } == false)
      gate.open()
      source.rebuild()
      await lane.drainForTesting()
    }

    @Test("a running answer for a unit released meanwhile counts as not running")
    func runningProbeStale() async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      var calls = HALNativeCalls.live
      calls.isRunning = { _ in
        entered.fire()
        gate.block()
        return true
      }
      source.nativeCalls = calls

      let probe = Task { await source.isRunningOnLane(deadline: nil, attempt: nil) }
      #expect(await entered.wait())
      source.rebuild()
      gate.open()
      #expect(await probe.value == false)
      await lane.drainForTesting()
    }

    @Test("a probe that reaches the lane after the unit's release does not query it")
    func runningProbeAfterRetirementSkipsTheUnit() async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      let asked = OSAllocatedUnfairLock(initialState: false)
      var calls = HALNativeCalls.live
      calls.isRunning = { _ in
        asked.withLock { $0 = true }
        return true
      }
      source.nativeCalls = calls
      // The release is queued AFTER the probe took its snapshot and BEFORE it asks the lane.
      source.probeSnapshotTakenForTesting = { [weak source] in source?.rebuild() }

      #expect(await source.isRunningOnLane(deadline: nil, attempt: nil) == false)
      #expect(asked.withLock { $0 } == false, "a disposed unit is never queried")
      await lane.drainForTesting()
    }

    @Test("quit during an open that already handed over its unit retires it within the deadline")
    func quitAfterHandoverBeforeCommit() async throws {
      let timers = Timers()
      let lane = AudioUnitLane(
        label: "test.hal.quit.handoff", schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let source = HALDeviceInputSource()
      source.lane = lane
      source.startDeadline = AudioUnitLaneTests.base + .seconds(5)
      let natives = Natives()
      source.openWorkForTesting = { _ in HALPrepareLifecycleTests.opened(natives) }
      let quitFinished = Box<Bool?>(nil)
      source.afterOpenReturnedForTesting = { [weak source] in
        // The unit was handed to this (main-actor) continuation and is not committed yet.
        quitFinished.value = source?.stopSynchronously(
          deadline: AudioUnitLaneTests.base + .seconds(5))
      }

      let result = await Task { try await source.prepare() }.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("expected CancellationError, got \(result)")
        return
      }
      #expect(quitFinished.value == true, "quit saw the release finish")
      #expect(natives.disposals == 1, "retired exactly once, before quit returned")
      #expect(source.liveGenerationForTesting == nil)
      await lane.drainForTesting()
    }

    @Test("quit during a stuck open returns at its deadline; the open's unit is retired once later")
    func quitDuringStuckOpen() async throws {
      let timers = Timers()
      let lane = AudioUnitLane(
        label: "test.hal.quit.stuck", schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let source = HALDeviceInputSource()
      source.lane = lane
      source.startDeadline = AudioUnitLaneTests.base + .seconds(5)
      let natives = Natives()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      source.openWorkForTesting = { _ in
        entered.fire()
        gate.block()
        return HALPrepareLifecycleTests.opened(natives)
      }
      let start = Task { try await source.prepare() }
      #expect(await entered.wait())

      let finished = source.stopSynchronously(deadline: AudioUnitLaneTests.base + .milliseconds(20))

      #expect(finished == false, "the open had not finished")
      let result = await start.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("expected CancellationError, got \(result)")
        return
      }
      gate.open()
      await lane.drainForTesting()
      #expect(natives.disposals == 1)
      #expect(source.liveGenerationForTesting == nil)
    }

    @Test("stabilization stops at once when a read used up the budget")
    func stabilizationStopsWhenBudgetIsGone() async {
      let passed = OSAllocatedUnfairLock(initialState: false)
      let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())

      let outcome = await HALDeviceInputSource.settleNativeRate(
        preparedRate: 48_000, maxWait: 1.5, pollInterval: 0.2,
        readRate: {
          passed.withLock { $0 = true }
          return 44_100
        },
        sleep: { nap in sleeps.withLock { $0.append(nap) } },
        remaining: { passed.withLock { $0 } ? .zero : .seconds(1) })

      #expect(outcome.settledRate == nil)
      #expect(outcome.polls == 0)
      #expect(sleeps.withLock { $0 }.isEmpty, "no sleep after the budget ran out")
    }

    @Test("a poll sleep is cut to the time left and stabilization ends at the deadline")
    func stabilizationSleepNeverCrossesTheDeadline() async {
      // An injected budget: 15 ms left; every sleep spends its own length.
      let left = OSAllocatedUnfairLock(initialState: Duration.milliseconds(15))
      let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
      let reads = OSAllocatedUnfairLock(initialState: 0)

      let outcome = await HALDeviceInputSource.settleNativeRate(
        preparedRate: 48_000, maxWait: 1.5, pollInterval: 0.2,
        readRate: {
          // Disagreeing reads, so nothing ever settles.
          reads.withLock { count -> Double in
            count += 1
            return count.isMultiple(of: 2) ? 48_000 : 44_100
          }
        },
        sleep: { nap in
          sleeps.withLock { $0.append(nap) }
          left.withLock { $0 -= nap }
        },
        remaining: { left.withLock { $0 } })

      #expect(outcome.settledRate == nil)
      #expect(sleeps.withLock { $0 } == [.milliseconds(10), .milliseconds(5)])
      #expect(outcome.polls == 1)
    }

    @Test("abort then quit after the open handed over its unit: retired once, before quit returns")
    func abortThenQuitAfterHandover() async throws {
      let timers = Timers()
      let lane = AudioUnitLane(
        label: "test.hal.abort.quit", schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let source = HALDeviceInputSource()
      source.lane = lane
      source.startDeadline = AudioUnitLaneTests.base + .seconds(5)
      let natives = Natives()
      source.openWorkForTesting = { _ in HALPrepareLifecycleTests.opened(natives) }
      let quitFinished = Box<Bool?>(nil)
      let disposalsAtQuit = Box<Int?>(nil)
      source.afterOpenReturnedForTesting = { [weak source] in
        source?.abortPrepare()  // clears the pending attempt first
        quitFinished.value = source?.stopSynchronously(
          deadline: AudioUnitLaneTests.base + .seconds(5))
        disposalsAtQuit.value = natives.disposals
      }

      let result = await Task { try await source.prepare() }.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("expected CancellationError, got \(result)")
        return
      }
      #expect(quitFinished.value == true)
      #expect(disposalsAtQuit.value == 1, "retired before quit returned")
      await lane.drainForTesting()
      #expect(natives.disposals == 1, "and only once")
    }

    @Test("stabilization on a wedged lane ends unstable without reading the device")
    func stabilizationWedged() async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      let read = OSAllocatedUnfairLock(initialState: false)
      source.nativeRateReader = { _ in
        read.withLock { $0 = true }
        return 48_000
      }
      let gate = await wedge(lane, timers)
      defer { gate.open() }

      let stable = await source.waitForFormatStabilization(maxWait: 0.05, pollInterval: 0.01)

      #expect(stable == false)
      #expect(read.withLock { $0 } == false)
      gate.open()
      source.rebuild()
      await lane.drainForTesting()
    }

    @Test(
      "the device-alive check runs on the lane; only a verified removal says disconnected",
      arguments: ["removed", "wedged"])
    func vanishCauseFollowsTheRead(how: String) async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      _ = try await source.startCapture()
      source.livenessReader = { _ in .removed }
      let cause = Box<EngineInterruptionCause?>(nil)
      source.onInterrupted = { cause.value = $0 }
      let handled = Signal()
      source.vanishHandledObserverForTesting = { _ in handled.fire() }
      var gate: Gate?
      if how == "wedged" { gate = await wedge(lane, timers) }
      defer { gate?.open() }
      guard let generation = source.liveGenerationForTesting else {
        Issue.record("no committed unit")
        return
      }

      source.deliverListenerForTesting(generation: generation)
      #expect(await handled.wait())

      #expect(cause.value == (how == "removed" ? .deviceRemoved : .engineLost))
      #expect(source.liveGenerationForTesting == nil, "teardown came before the interruption")
      gate?.open()
      await lane.drainForTesting()
    }

    @Test("a device-alive answer that arrives after the take ended interrupts nothing")
    func staleVanishReadIsIgnored() async throws {
      let timers = Timers()
      let (source, lane) = try await committedSource(timers)
      _ = try await source.startCapture()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      source.livenessReader = { _ in
        entered.fire()
        gate.block()
        return .removed
      }
      let interrupted = Box(false)
      source.onInterrupted = { _ in interrupted.value = true }
      let outcome = Box<Bool?>(nil)
      let handled = Signal()
      source.vanishHandledObserverForTesting = {
        outcome.value = $0
        handled.fire()
      }
      guard let generation = source.liveGenerationForTesting else {
        Issue.record("no committed unit")
        return
      }

      source.deliverListenerForTesting(generation: generation)
      #expect(await entered.wait())
      source.rebuild()  // the take and its unit end while the read is stuck
      gate.open()
      #expect(await handled.wait())

      #expect(outcome.value == false)
      #expect(interrupted.value == false)
      await lane.drainForTesting()
    }
  }
#endif
