@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprAudio

#if DEBUG

  /// #4601 §3.5 and §5: the manager's microphone choice at record start runs its hardware reads on
  /// the audio-unit lane and revalidates after every wait. When these fail, a stuck audio driver
  /// freezes the app at record start, or a press the user already replaced tears down or
  /// overwrites the microphone the newer press is using. Deadlines and clocks are the test's own.
  @MainActor
  @Suite("AudioCaptureManager source resolution on the lane — #4601", .tags(.productOutcome))
  struct AudioCaptureManagerResolutionTests {

    typealias Signal = AudioUnitLaneTests.Signal
    typealias Gate = AudioUnitLaneTests.Gate

    nonisolated private static let boundUID = "usb-interface-uid"
    nonisolated private static let boundDeviceID: AudioDeviceID = 77

    /// Counts route reads; the FIRST read signals `entered` and blocks on `gate`.
    final class FirstReadGate: Sendable {
      let gate = Gate()
      let entered = Signal()
      private let calls = OSAllocatedUnfairLock(initialState: 0)
      var callCount: Int { calls.withLock { $0 } }

      func resolver() -> CaptureRouteResolver {
        CaptureRouteResolver(
          defaultOutputDeviceID: { [self] in
            let call = calls.withLock { count -> Int in
              count += 1
              return count
            }
            if call == 1 {
              entered.fire()
              gate.block()
            }
            return nil
          },
          isBluetoothOutputDevice: { _ in false })
      }
    }

    /// Fires once the manager has minted its second resolution request.
    private static func secondRequestMinted(_ manager: AudioCaptureManager) -> Signal {
      let minted = Signal()
      var count = 0
      manager.onResolveRequestMintedForTesting = { _ in
        count += 1
        if count == 2 { minted.fire() }
      }
      return minted
    }

    private static func immediateResolver() -> CaptureRouteResolver {
      CaptureRouteResolver(defaultOutputDeviceID: { nil }, isBluetoothOutputDevice: { _ in false })
    }

    /// A warm HAL source on Auto, bound to the system default on channel 0. No `AudioUnit`
    /// exists; liveness is forced.
    private static func warmSource(lane: AudioUnitLane) -> HALDeviceInputSource {
      let source = HALDeviceInputSource()
      source.lane = lane
      source.targetDeviceUID = nil
      source.inputDeviceResolver = InputDeviceResolver(
        defaultInputDeviceID: { boundDeviceID },
        inputDeviceSnapshot: { .success(candidates: [], complete: true) },
        transportForDevice: { _ in nil })
      source.setBoundInputDeviceForTesting(
        BoundInputDevice(
          deviceID: boundDeviceID, deviceUID: boundUID, transportLabel: "usb",
          resolutionSource: "system_default", inputChannel: 0),
        nativeChannelCount: 1)
      source.isRunningOverrideForTesting = true
      return source
    }

    private static func makeManager(lane: AudioUnitLane, resolver: CaptureRouteResolver)
      -> AudioCaptureManager
    {
      let manager = AudioCaptureManager()
      manager.lane = lane
      manager.preferredInputDeviceIDOverride = ""
      manager.inputChannelByDeviceUID = [:]
      manager.installRouteResolverForTesting(resolver)
      return manager
    }

    // MARK: - Healthy paths

    @Test(
      "a healthy cold start builds the microphone on the manager's lane with the start deadline")
    func healthyColdResolution() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.cold")
      let manager = Self.makeManager(lane: lane, resolver: Self.immediateResolver())
      let deadline = ContinuousClock.now + .seconds(5)
      manager.startDeadline = deadline

      let resolved = try await manager.resolveSourceForTesting()

      let hal = try #require(resolved as? HALDeviceInputSource)
      #expect(hal.lane === lane)
      #expect(hal.startDeadline == deadline)
      #expect(manager.hasActiveSourceForTesting)
    }

    @Test("a healthy warm microphone is reused after its lane checks answer")
    func healthyWarmReuse() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.warm")
      let manager = Self.makeManager(lane: lane, resolver: Self.immediateResolver())
      let warm = Self.warmSource(lane: lane)
      manager.installCapturedSourceForTesting(warm, sessionID: 1)

      #expect(try await manager.resolveSourceForTesting() === warm)
    }

    @Test("a warm microphone for a different device is replaced, not reused")
    func incompatibleWarmIsReplaced() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.incompatible")
      let manager = Self.makeManager(lane: lane, resolver: Self.immediateResolver())
      let warm = Self.warmSource(lane: lane)
      manager.installCapturedSourceForTesting(warm, sessionID: 1)
      manager.preferredInputDeviceIDOverride = "some-other-microphone"

      let resolved = try await manager.resolveSourceForTesting()

      #expect(resolved !== warm)
      #expect((resolved as? HALDeviceInputSource)?.targetDeviceUID == "some-other-microphone")
    }

    // MARK: - A read that does not answer

    @Test("a route read that does not answer in time fails as microphone not responding")
    func routeReadTimeoutIsNotResponding() async throws {
      let timers = AudioUnitLaneTests.ManualTimers()
      let lane = AudioUnitLane(
        label: "test.manager.resolve.timeout",
        schedule: { delay, fire in timers.schedule(delay, fire) },
        now: { AudioUnitLaneTests.base })
      let reads = FirstReadGate()
      let manager = Self.makeManager(lane: lane, resolver: reads.resolver())
      manager.startDeadline = AudioUnitLaneTests.base + .milliseconds(500)

      let start = Task { () -> String? in
        do {
          _ = try await manager.resolveSourceForTesting()
          return "resolved"
        } catch AudioError.microphoneNotResponding(let source) {
          return source
        } catch {
          return "other: \(error)"
        }
      }
      #expect(await reads.entered.wait())
      #expect(await timers.scheduled(.milliseconds(500)))
      timers.fire(.milliseconds(500))

      #expect(await start.value == "AudioCaptureManager.route.timed_out")
      #expect(manager.hasActiveSourceForTesting == false, "no microphone may be installed")
      reads.gate.open()
      await lane.drainForTesting()
      #expect(reads.gate.didExpire == false)
    }

    // MARK: - A press the user already replaced

    @Test("a replaced start gives up quietly and installs nothing; the newer start wins")
    func supersededColdResolutionInstallsNothing() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.superseded")
      let reads = FirstReadGate()
      let manager = Self.makeManager(lane: lane, resolver: reads.resolver())
      let minted = Self.secondRequestMinted(manager)

      let older = Task { () -> String in
        do {
          _ = try await manager.resolveSourceForTesting()
          return "resolved"
        } catch is CancellationError {
          return "cancelled"
        } catch {
          return "other: \(error)"
        }
      }
      #expect(await reads.entered.wait())
      // The newer start's route read queues behind the older one on the serial lane.
      let newer = Task { (try await manager.resolveSourceForTesting()) is HALDeviceInputSource }
      #expect(await minted.wait(), "the newer request exists before the older read is released")
      reads.gate.open()

      #expect(await older.value == "cancelled", "a replaced start is abandonment, not an error")
      #expect(try await newer.value, "the newer start installs the production microphone source")
      #expect(manager.hasActiveSourceForTesting)
      #expect(reads.callCount == 2)
      #expect(reads.gate.didExpire == false)
    }

    @Test("a replaced start cannot tear down the warm microphone the newer start reuses")
    func supersededResolutionCannotRetireWarm() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.superseded-warm")
      let reads = FirstReadGate()
      let manager = Self.makeManager(lane: lane, resolver: reads.resolver())
      let warm = Self.warmSource(lane: lane)
      manager.installCapturedSourceForTesting(warm, sessionID: 1)
      let minted = Self.secondRequestMinted(manager)

      // The older start snapshots a different device, so on its own it would replace `warm`.
      manager.preferredInputDeviceIDOverride = "some-other-microphone"
      let older = Task { () -> String in
        do {
          _ = try await manager.resolveSourceForTesting()
          return "resolved"
        } catch is CancellationError {
          return "cancelled"
        } catch {
          return "other: \(error)"
        }
      }
      #expect(await reads.entered.wait())
      // The user goes back to Auto and presses again.
      manager.preferredInputDeviceIDOverride = ""
      let newer = Task { (try await manager.resolveSourceForTesting()) === warm }
      #expect(await minted.wait(), "the newer request exists before the older read is released")
      reads.gate.open()

      #expect(await older.value == "cancelled")
      #expect(try await newer.value, "the older start must not have torn `warm` down")
      #expect(reads.gate.didExpire == false)
    }

    @Test("giving up a start while its route read waits installs and prepares nothing")
    func abortDuringRouteReadInstallsNothing() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.abort")
      let reads = FirstReadGate()
      let manager = Self.makeManager(lane: lane, resolver: reads.resolver())
      var built = 0
      manager.installSourceFactoryForTesting { _ in
        built += 1
        return GatedSource(step: "never")
      }

      let start = Task { () -> String in
        do {
          try await manager.preWarm()
          return "prepared"
        } catch is CancellationError {
          return "cancelled"
        } catch {
          return "other: \(error)"
        }
      }
      #expect(await reads.entered.wait())
      manager.abortPreWarm()
      reads.gate.open()

      #expect(await start.value == "cancelled", "giving up is abandonment, not an error")
      #expect(built == 0, "no microphone source may be built")
      #expect(manager.hasActiveSourceForTesting == false)
      #expect(reads.gate.didExpire == false)
    }

    @Test("a settings change during the route read does not mix into the start already running")
    func settingsSnapshotHoldsAcrossTheWait() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.snapshot")
      let reads = FirstReadGate()
      let manager = Self.makeManager(lane: lane, resolver: reads.resolver())
      manager.preferredInputDeviceIDOverride = "first-microphone"
      manager.inputChannelByDeviceUID = ["first-microphone": 1]

      let start = Task { () -> [String] in
        let hal = try #require(try await manager.resolveSourceForTesting() as? HALDeviceInputSource)
        return [hal.targetDeviceUID ?? "nil", "\(hal.inputChannelByDeviceUID)"]
      }
      #expect(await reads.entered.wait())
      manager.preferredInputDeviceIDOverride = "second-microphone"
      manager.inputChannelByDeviceUID = ["second-microphone": 0]
      reads.gate.open()

      #expect(try await start.value == ["first-microphone", "\(["first-microphone": 1])"])
      #expect(reads.gate.didExpire == false)
    }

    // MARK: - Attribution of a replaced start

    /// A source whose `prepare()` waits for the test, then reports `attempt` and returns.
    final class GatedSource: AudioInputSource {
      var onSamples: (@Sendable ([Float], Float) -> Void)?
      var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
      var onInterrupted: ((EngineInterruptionCause) -> Void)?
      var onLifecycleSignal: (@Sendable (String) -> Void)?
      var onCaptureStalled: ((CaptureStallContext) -> Void)?
      var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?
      var captureGeneration: UInt64 = 0
      var drainedPreRollSampleCount: Int = 0
      let captureSourceType = "stub"
      var running = true
      var isCapturing = false
      var isRunning: Bool { running }
      private(set) var rebuildCallCount = 0
      #if DEBUG
        var debugZeroFillController: DebugZeroFillController?
        var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
          (nil, nil)
        }
      #endif

      let step: String
      let entered = Signal()
      let release = Signal()
      init(step: String) { self.step = step }

      func prepare() async throws -> BoundInputDevice {
        entered.fire()
        _ = await release.wait()
        onInputResolutionAttemptFinalized?(
          .unavailable(failure: .microphoneNotResponding(source: step)))
        return BoundInputDevice(
          deviceID: 1, deviceUID: "uid-\(step)", transportLabel: "stub",
          resolutionSource: step, inputChannel: 0)
      }
      func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
      }
      func stop() async -> [Float] {
        running = false
        return []
      }
      func deactivateCapture() {}
      func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
        -> Bool
      { true }
      func abortPrepare() {}
      func rebuild() {
        rebuildCallCount += 1
        running = false
      }
    }

    @Test(
      "a replaced start still reports its own attempt once but cannot overwrite the newer start's",
      .tags(.observabilityContract))
    func supersededAttemptEmitsOnceWithoutAdoption() async throws {
      let lane = AudioUnitLane(label: "test.manager.resolve.attribution")
      let manager = Self.makeManager(lane: lane, resolver: Self.immediateResolver())
      let older = GatedSource(step: "older")
      let newer = GatedSource(step: "newer")
      var built: [GatedSource] = [older, newer]
      manager.installSourceFactoryForTesting { _ in built.removeFirst() }
      var reported: [String?] = []
      manager.onFinalizedInputResolutionAttempt = { reported.append($0.prepareFailedStep) }

      let olderStart = Task { () -> String in
        do {
          try await manager.preWarm()
          return "prepared"
        } catch is CancellationError {
          return "cancelled"
        } catch {
          return "other: \(error)"
        }
      }
      #expect(await older.entered.wait())
      let newerStart = Task { try await manager.preWarm() }
      #expect(await newer.entered.wait())
      #expect(older.rebuildCallCount == 1, "the newer start released the older microphone")

      newer.release.fire()
      try await newerStart.value
      #expect(manager.currentInputResolutionSource == "newer")

      older.release.fire()
      #expect(await olderStart.value == "cancelled")
      #expect(reported == ["newer", "older"], "each attempt is reported exactly once")
      #expect(
        manager.currentInputResolutionSource == "newer",
        "the replaced start must not overwrite the newer start's attribution")
    }
  }

#endif
