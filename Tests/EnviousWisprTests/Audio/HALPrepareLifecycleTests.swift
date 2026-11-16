#if DEBUG
  import CoreAudio
  import Foundation
  import Testing
  import os

  @testable import EnviousWisprAudio

  /// #4601 §§3.3-3.4, §5: the HAL source's cold open runs on the audio-unit lane. When these
  /// fail, the user sees a frozen app at record start, a microphone left open after a start that
  /// gave up, a stale unit committed over a newer one, or a crash at release. The native open is
  /// injected (no hardware); the lane, its timers and the source's own logic are real.
  @Suite("HAL prepare lifecycle — #4601", .tags(.productOutcome))
  @MainActor
  struct HALPrepareLifecycleTests {
    typealias Timers = AudioUnitLaneTests.ManualTimers
    typealias Signal = AudioUnitLaneTests.Signal
    typealias Gate = AudioUnitLaneTests.Gate

    /// Every finalized cold attempt the source reported.
    final class Attempts {
      var all: [FinalizedInputResolutionAttempt] = []
    }

    /// Blocks the calling (main) actor until `signal` fires; a plain function so it can be
    /// called from async test code. The 5 s timeout is only a hang guard.
    static func holdMainActor(until signal: DispatchSemaphore) -> Bool {
      // settle: deliberate main-actor hold; the timeout is a hang guard around a real signal.
      signal.wait(timeout: .now() + 5) == .success
    }

    final class Seen {
      var values: [Bool] = []
    }

    /// Native calls of fake resources, so a test can count retirements.
    final class Natives: Sendable {
      private let calls = OSAllocatedUnfairLock(initialState: [String]())
      var log: [String] { calls.withLock { $0 } }
      var disposals: Int { log.filter { $0 == "dispose" }.count }
      var nativeCalls: HALNativeCalls {
        HALNativeCalls(
          stop: { [calls] _ in
            calls.withLock { $0.append("stop") }
            return noErr
          },
          uninitialize: { _ in noErr },
          dispose: { [calls] _ in
            calls.withLock { $0.append("dispose") }
            return noErr
          },
          removeListener: { _, _, _, _ in noErr },
          storageReleased: {})
      }
    }

    nonisolated static let resolution = InputDeviceResolution(
      outcome: .selected(7, source: .systemDefault), defaultPresent: true,
      enumerationOutcome: .notAttempted, inputDeviceCount: nil, eligibleDeviceCount: nil,
      selectedTransport: nil)

    /// A successful native open result around fake resources.
    nonisolated static func opened(_ natives: Natives) -> HALUnitNative.OpenResult {
      var attempt = InputResolutionAttemptState()
      attempt.recordBind(succeeded: true)
      attempt.recordPrepareSucceeded()
      // One forwarder, as in production: the source and the render context share it.
      let forwarder = PreRollForwarder()
      return .opened(
        HALUnitNative.Opened(
          resources: HALUnitResources.makeForTesting(
            stage: .started, native: natives.nativeCalls, forwarder: forwarder),
          forwarder: forwarder,
          facts: HALUnitNative.Facts(
            deviceID: 7, deviceUID: "mic-7", transportLabel: "built_in",
            resolutionSource: "system_default", nativeChannelCount: 1, inputChannel: 0),
          resolution: resolution, attempt: attempt))
    }

    private func makeSource(
      _ timers: Timers, attempts: Attempts,
      work: @escaping @Sendable (HALUnitNative.OpenRequest) -> HALUnitNative.OpenResult
    ) -> (HALDeviceInputSource, AudioUnitLane) {
      let lane = AudioUnitLane(
        label: "test.hal.prepare", schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let source = HALDeviceInputSource()
      source.lane = lane
      source.startDeadline = AudioUnitLaneTests.base + .seconds(5)
      source.openWorkForTesting = work
      source.onInputResolutionAttemptFinalized = { attempts.all.append($0) }
      return (source, lane)
    }

    @Test("a current success commits the unit and reports the attempt once")
    func successCommits() async throws {
      let natives = Natives()
      let attempts = Attempts()
      let (source, lane) = makeSource(Timers(), attempts: attempts) { _ in Self.opened(natives) }

      let bound = try await source.prepare()

      #expect(bound.deviceID == 7)
      #expect(source.liveGenerationForTesting != nil)
      #expect(attempts.all.count == 1)
      #expect(attempts.all.first?.prepareOutcome == .succeeded)
      #expect(natives.disposals == 0)
      source.rebuild()
      await lane.drainForTesting()
    }

    @Test("a native failure keeps its own error, step and status")
    func nativeFailureKeepsItsError() async {
      let attempts = Attempts()
      let (source, _) = makeSource(Timers(), attempts: attempts) { _ in
        var state = InputResolutionAttemptState()
        state.recordBind(succeeded: true)
        let error = AudioError.formatCreationFailed(
          source: "HALDeviceInputSource.prepare.start", osStatus: 60)
        state.recordFailure(of: error)
        return .failed(
          HALUnitNative.Failure(
            error: error, resolution: Self.resolution, attempt: state, bindOutcome: true))
      }

      do {
        _ = try await source.prepare()
        Issue.record("expected a throw")
      } catch let error as AudioError {
        guard case .formatCreationFailed(let step, let status) = error else {
          Issue.record("unexpected \(error)")
          return
        }
        #expect(step == "HALDeviceInputSource.prepare.start")
        #expect(status == 60)
      } catch {
        Issue.record("unexpected \(error)")
      }
      #expect(attempts.all.count == 1)
      #expect(attempts.all.first?.failedStep == "HALDeviceInputSource.prepare.start")
      #expect(source.liveGenerationForTesting == nil)
    }

    @Test(
      "a start past its deadline answers not-responding at once and the late unit is retired once")
    func timeoutThrowsAndLateUnitIsRetired() async {
      let timers = Timers()
      let natives = Natives()
      let attempts = Attempts()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      let (source, lane) = makeSource(timers, attempts: attempts) { request in
        request.progress.publish(resolution: Self.resolution)
        entered.fire()
        gate.block()
        return Self.opened(natives)
      }

      let start = Task { try await source.prepare() }
      #expect(await entered.wait())
      #expect(await timers.scheduled(.seconds(5)))
      timers.fire(.seconds(5))
      let result = await start.result
      guard case .failure(let error as AudioError) = result,
        case .microphoneNotResponding(let step) = error
      else {
        Issue.record("expected microphoneNotResponding, got \(result)")
        return
      }
      #expect(step == "HALDeviceInputSource.prepare.timed_out")
      #expect(attempts.all.count == 1)
      #expect(attempts.all.first?.failedStep == "HALDeviceInputSource.prepare.timed_out")
      #expect(attempts.all.first?.resolution?.defaultPresent == true, "published facts survive")
      #expect(attempts.all.first?.bindOutcome == nil, "unpublished facts stay unknown")

      gate.open()
      await lane.drainForTesting()
      #expect(natives.disposals == 1)
      #expect(source.liveGenerationForTesting == nil)
      #expect(attempts.all.count == 1, "a late completion never re-reports")
    }

    @Test("a wedged lane refuses the start at once without running the open")
    func wedgedLaneRefuses() async {
      let timers = Timers()
      let attempts = Attempts()
      let ran = OSAllocatedUnfairLock(initialState: false)
      let (source, lane) = makeSource(timers, attempts: attempts) { _ in
        ran.withLock { $0 = true }
        return Self.opened(Natives())
      }
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      let stuck = Task {
        await lane.run("probe") { () -> Int in
          entered.fire()
          gate.block()
          return 0
        }
      }
      #expect(await entered.wait())
      #expect(await timers.scheduled(AudioUnitLane.readLimit))
      timers.fire(AudioUnitLane.readLimit)
      #expect(lane.isWedged)

      do {
        _ = try await source.prepare()
        Issue.record("expected a throw")
      } catch AudioError.microphoneNotResponding(let step) {
        #expect(step == "HALDeviceInputSource.prepare.lane_wedged")
      } catch {
        Issue.record("unexpected \(error)")
      }
      #expect(ran.withLock { $0 } == false)
      #expect(attempts.all.count == 1)
      gate.open()
      _ = await stuck.value
    }

    @Test("abort during the native open resumes the caller at once; the late unit is retired once")
    func abortDuringOpen() async {
      let timers = Timers()
      let natives = Natives()
      let attempts = Attempts()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      let (source, lane) = makeSource(timers, attempts: attempts) { _ in
        entered.fire()
        gate.block()
        return Self.opened(natives)
      }

      let start = Task { try await source.prepare() }
      #expect(await entered.wait())
      source.abortPrepare()
      let result = await start.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("expected CancellationError, got \(result)")
        return
      }
      #expect(attempts.all.count == 1)
      #expect(attempts.all.first?.failedStep == "HALDeviceInputSource.prepare.abandoned")

      gate.open()
      await lane.drainForTesting()
      #expect(natives.disposals == 1)
      #expect(source.liveGenerationForTesting == nil)
    }

    @Test("an abort after the lane handed over, before commit, retires the unit once")
    func abortAfterTransferBeforeCommit() async {
      let natives = Natives()
      let attempts = Attempts()
      let (source, lane) = makeSource(Timers(), attempts: attempts) { _ in Self.opened(natives) }
      source.afterOpenReturnedForTesting = { [weak source] in source?.abortPrepare() }

      let result = await Task { try await source.prepare() }.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("expected CancellationError, got \(result)")
        return
      }
      await lane.drainForTesting()
      #expect(natives.disposals == 1)
      #expect(source.liveGenerationForTesting == nil)
      #expect(attempts.all.count == 1)
    }

    @Test(
      "a start that timed out or was refused, then invalidated before main handled it, ends quietly",
      arguments: ["timeout", "wedged"])
    func invalidatedTerminalEndsAsAbandoned(how: String) async {
      let timers = Timers()
      let attempts = Attempts()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      let (source, lane) = makeSource(timers, attempts: attempts) { _ in
        entered.fire()
        gate.block()
        return Self.opened(Natives())
      }
      source.afterOpenReturnedForTesting = { [weak source] in source?.abortPrepare() }
      var stuck: Task<AudioUnitLane.Outcome<Int>, Never>?
      if how == "wedged" {
        let probeEntered = Signal()
        stuck = Task {
          await lane.run("probe") { () -> Int in
            probeEntered.fire()
            gate.block()
            return 0
          }
        }
        #expect(await probeEntered.wait())
        #expect(await timers.scheduled(AudioUnitLane.readLimit))
        timers.fire(AudioUnitLane.readLimit)
      }

      let start = Task { try await source.prepare() }
      if how == "timeout" {
        #expect(await entered.wait())
        #expect(await timers.scheduled(.seconds(5)))
        timers.fire(.seconds(5))
      }
      let result = await start.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("an invalidated start must end as CancellationError, got \(result)")
        return
      }
      #expect(attempts.all.count == 1)
      #expect(attempts.all.first?.failedStep == "HALDeviceInputSource.prepare.abandoned")
      gate.open()
      _ = await stuck?.value
      await lane.drainForTesting()
    }

    @Test("a start cancelled before the lane admits it runs no native work")
    func cancelledBeforeAdmissionRunsNothing() async {
      let attempts = Attempts()
      let ran = OSAllocatedUnfairLock(initialState: false)
      let (source, lane) = makeSource(Timers(), attempts: attempts) { _ in
        ran.withLock { $0 = true }
        return Self.opened(Natives())
      }
      source.beforeOpenForTesting = { [weak source] in source?.abortPrepare() }

      let result = await Task { try await source.prepare() }.result
      guard case .failure(let error) = result, error is CancellationError else {
        Issue.record("expected CancellationError, got \(result)")
        return
      }
      await lane.drainForTesting()
      #expect(ran.withLock { $0 } == false)
      #expect(attempts.all.count == 1)
    }

    @Test("facts published after the timeout was decided stay out of the report")
    func reportFreezesAtTheTerminalDecision() async {
      let timers = Timers()
      let attempts = Attempts()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      let published = DispatchSemaphore(value: 0)
      let (source, lane) = makeSource(timers, attempts: attempts) { request in
        entered.fire()
        gate.block()
        request.progress.publish(resolution: Self.resolution)
        request.progress.publish(bind: .succeeded)
        published.signal()
        return Self.opened(Natives())
      }

      let start = Task { try await source.prepare() }
      #expect(await entered.wait())
      #expect(await timers.scheduled(.seconds(5)))
      timers.fire(.seconds(5))
      gate.open()
      // settle: the main actor is held here on purpose so the worker publishes BEFORE prepare
      // resumes and reads the progress; the timeout is only a hang guard.
      #expect(Self.holdMainActor(until: published))
      _ = await start.result

      #expect(attempts.all.count == 1)
      #expect(attempts.all.first?.failedStep == "HALDeviceInputSource.prepare.timed_out")
      #expect(attempts.all.first?.resolution == nil, "published after the decision")
      #expect(attempts.all.first?.bindOutcome == nil, "published after the decision")
      await lane.drainForTesting()
    }

    @Test("a newer attempt abandons the older; the older's late success never commits")
    func newerAttemptWins() async throws {
      let timers = Timers()
      let oldNatives = Natives()
      let newNatives = Natives()
      let attempts = Attempts()
      let gate = Gate()
      defer { gate.open() }
      let entered = Signal()
      let calls = OSAllocatedUnfairLock(initialState: 0)
      let (source, lane) = makeSource(timers, attempts: attempts) { _ in
        let call = calls.withLock { count -> Int in
          count += 1
          return count
        }
        if call == 1 {
          entered.fire()
          gate.block()
          return Self.opened(oldNatives)
        }
        return Self.opened(newNatives)
      }

      let older = Task { try await source.prepare() }
      #expect(await entered.wait())
      let newer = Task { try await source.prepare() }
      let olderResult = await older.result
      guard case .failure(let error) = olderResult, error is CancellationError else {
        Issue.record("the older attempt must be abandoned, got \(olderResult)")
        return
      }
      gate.open()
      let bound = try await newer.value
      await lane.drainForTesting()

      #expect(bound.deviceID == 7)
      #expect(oldNatives.disposals == 1, "the older unit is retired by the lane")
      #expect(newNatives.disposals == 0, "the newer unit stays committed")
      #expect(source.liveGenerationForTesting != nil)
      #expect(attempts.all.count == 2, "each attempt reports exactly once")
      source.rebuild()
      await lane.drainForTesting()
    }

    @Test("release stops delivery even for a chunk already on its way to the forwarder")
    func releaseStopsInFlightDelivery() async throws {
      let natives = Natives()
      let attempts = Attempts()
      let handedOut = OSAllocatedUnfairLock<HALUnitResources?>(initialState: nil)
      let forwarded = OSAllocatedUnfairLock(initialState: 0)
      let (source, lane) = makeSource(Timers(), attempts: attempts) { _ in
        let result = Self.opened(natives)
        if case .opened(let opened) = result {
          handedOut.withLock { $0 = opened.resources }
          _ = opened.forwarder.activate(
            onSamples: { _, _ in forwarded.withLock { $0 += 1 } }, onBuffer: nil,
            continuation: nil, logPrefix: "test")
        }
        return result
      }
      _ = try await source.prepare()
      guard let resources = handedOut.withLock({ $0 }) else {
        Issue.record("no resources handed out")
        return
      }
      resources.renderAndDrainForTesting()
      let healthy = forwarded.withLock { $0 }
      #expect(healthy > 0, "control: a live unit forwards audio")

      // A consumer that already passed its stopped check and is about to route a chunk.
      let atRoute = Signal()
      let gate = Gate()
      defer { gate.open() }
      let drained = Signal()
      resources.setBeforeRouteForTesting {
        atRoute.fire()
        gate.block()
      }
      Thread {
        resources.renderAndDrainForTesting()
        drained.fire()
      }.start()
      #expect(await atRoute.wait(), "the consumer reached the routing point")
      // The lane is busy with an earlier job, so native retirement must wait its turn.
      let laneGate = Gate()
      defer { laneGate.open() }
      let laneBusy = Signal()
      lane.retire {
        laneBusy.fire()
        laneGate.block()
      }
      #expect(await laneBusy.wait())

      source.rebuild()
      #expect(source.liveGenerationForTesting == nil, "committed ownership cleared immediately")
      #expect(resources.stoppedFlagIsSetForTesting, "capture stopped at hand-off")
      #expect(natives.disposals == 0, "native retirement waits its turn on the lane")
      gate.open()
      #expect(await drained.wait())
      #expect(forwarded.withLock { $0 } == healthy, "the in-flight chunk was not delivered")
      laneGate.open()
      await lane.drainForTesting()
      #expect(natives.disposals == 1)
    }

    @Test("a listener callback from another unit is ignored; the current unit's is accepted")
    func listenerGenerationFence() async throws {
      let attempts = Attempts()
      let (source, lane) = makeSource(Timers(), attempts: attempts) { _ in Self.opened(Natives()) }
      _ = try await source.prepare()
      guard let current = source.liveGenerationForTesting else {
        Issue.record("no committed unit")
        return
      }
      let seen = Seen()
      let both = Signal()
      source.listenerDeliveryObserverForTesting = { accepted in
        seen.values.append(accepted)
        if seen.values.count == 2 { both.fire() }
      }

      source.deliverListenerForTesting(generation: current &+ 1000)
      source.deliverListenerForTesting(generation: current)
      #expect(await both.wait(), "both deliveries reached the main actor")

      #expect(seen.values.sorted { !$0 && $1 } == [false, true])
      source.rebuild()
      await lane.drainForTesting()
    }
  }
#endif
