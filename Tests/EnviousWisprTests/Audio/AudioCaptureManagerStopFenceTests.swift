@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// This suite uses AudioCaptureManager's `#if DEBUG` test seams
// (`installCapturedSourceForTesting`, `installSourceFactoryForTesting`), so the
// whole suite is DEBUG-only — the Release test-target lane must not compile it.
#if DEBUG

  // MARK: - #1579 — the armed-session identity fence on the terminal stop.
  //
  // `stopCapture(sessionID:)` must be a TOTAL no-op when the id names a session
  // that is no longer current, because every statement in its body mutates
  // session-scoped state: a stale stop would clear a newer take's accumulated
  // samples and deactivate its source. These tests drive the REAL
  // `AudioCaptureManager`, not a `FakeAudioCapture` — the fake is a pass-through
  // recorder and would test itself rather than the guard.
  //
  // Every test here is TWO-WAY on purpose (`validation-discipline.md`
  // RULE: a-guard-nothing-arms-is-not-a-guard): a fence that refuses EVERYTHING
  // passes a refusal-only test while disabling the product. The acceptance cases
  // are what make the refusal case mean anything.
  @MainActor
  @Suite("AudioCaptureManager stop identity fence (#1579)")
  struct AudioCaptureManagerStopFenceTests {

    /// Minimal `AudioInputSource` stub. Unlike the retire-fence suite's stub this
    /// one counts `deactivateCapture()`, which is the observable the stop path
    /// asserts on. Kept local rather than shared: the retire suite's stub is
    /// nested in its own suite and counting deactivations there would edit a file
    /// outside this chunk's scope.
    final class StubSource: AudioInputSource {
      var onSamples: (@Sendable ([Float], Float) -> Void)?
      var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
      var onInterrupted: ((EngineInterruptionCause) -> Void)?
      var onLifecycleSignal: (@Sendable (String) -> Void)?
      var onCaptureStalled: ((CaptureStallContext) -> Void)?
      var captureGeneration: UInt64 = 0

      /// #1810: stubs drain no pre-roll. A stored var rather than a literal so a
      /// test can set a value — including a negative, to prove the clamp.
      var drainedPreRollSampleCount: Int = 0
      let captureSourceType = "stub"
      var running = true
      var isCapturing = false
      var isRunning: Bool { running }
      private(set) var deactivateCallCount = 0
      private(set) var stopCallCount = 0
      private(set) var rebuildCallCount = 0
      #if DEBUG
        var debugZeroFillController: DebugZeroFillController?
        var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
          (nil, nil)
        }
      #endif

      /// #1714: the undefaulted protocol witness. This suite never fires it;
      /// declaring it explicitly is exactly what the undefaulted requirement is for.
      var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?
      var boundToReturn = BoundInputDevice(
        deviceID: 1, deviceUID: "stub-uid", transportLabel: "stub",
        resolutionSource: "system_default")
      private(set) var prepareCallCount = 0

      func prepare() async throws -> BoundInputDevice {
        prepareCallCount += 1
        return boundToReturn
      }
      func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
      }
      func stop() async -> [Float] {
        stopCallCount += 1
        running = false
        return []
      }
      func deactivateCapture() { deactivateCallCount += 1 }
      func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
        -> Bool
      {
        true
      }
      func abortPrepare() {}
      func rebuild() {
        rebuildCallCount += 1
        running = false
      }
    }

    /// Arm the manager with a live capture session WITHOUT hardware: install a
    /// stub as both the retained and active source at `sessionID`, flip the
    /// `internal(set)` capture flag, and accumulate real samples through the
    /// production ingest path.
    private func makeArmedManager(sessionID: UInt64, samples: [Float]) -> (
      AudioCaptureManager, StubSource
    ) {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      manager.installCapturedSourceForTesting(stub, sessionID: sessionID)
      manager.isCapturing = true
      manager.ingestSamples(samples, level: 0.5)
      return (manager, stub)
    }

    // MARK: - 1. A stale id changes nothing at all

    @Test("stale session id → total no-op: empty return, samples and source untouched")
    func staleSessionIsATotalNoOp() async {
      // Session 8 is live; an older take's cleanup arrives naming session 7.
      let (manager, stub) = makeArmedManager(sessionID: 8, samples: [1, 2, 3, 4])

      let result = await manager.stopCapture(sessionID: 7)

      #expect(result.samples.isEmpty, "a refused stop returns nothing")
      #expect(
        manager.capturedSamples == [1, 2, 3, 4],
        "THE point of the fence: the live take's audio must survive a stale stop")
      #expect(manager.isCapturing, "capture must still be running")
      #expect(stub.deactivateCallCount == 0, "the live source must not be deactivated")
      #expect(stub.stopCallCount == 0, "no teardown may be scheduled for the live source")
      #expect(manager.currentCaptureSessionID == 8, "the counter is not touched")
    }

    // MARK: - 2. Control: the current id still stops, exactly as before

    @Test("current session id → stop proceeds: samples returned, state cleared, source deactivated")
    func currentSessionStopsNormally() async {
      let (manager, stub) = makeArmedManager(sessionID: 8, samples: [1, 2, 3, 4])

      let result = await manager.stopCapture(sessionID: manager.currentCaptureSessionID)

      #expect(result.samples == [1, 2, 3, 4], "the take's audio comes back for transcription")
      #expect(manager.capturedSamples.isEmpty, "the live buffer is drained by an accepted stop")
      #expect(manager.isCapturing == false)
      #expect(stub.deactivateCallCount == 1, "the accepted stop deactivates its own source")
    }

    // MARK: - 3. Control: a prepared-but-never-armed engine is still stoppable
    //
    // The regression this test exists for: `beginCapturePhase` is what advances
    // the counter, so an engine that was PREPARED and then cancelled has session
    // id 0. An earlier draft of this fence keyed on "the id I got when I armed",
    // which does not exist on this path — it would have refused the cleanup and
    // left the prepared engine running. Reached through the real
    // `startEnginePhase()`, not by hand-installing the end state.

    @Test("prepared engine, capture never armed → stop with id 0 is ACCEPTED, not fenced out")
    func preparedButUnarmedEngineIsStoppable() async throws {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      manager.installSourceFactoryForTesting { _ in stub }
      // `.off` BEFORE preparation: setting it afterwards would trip
      // `reconcileWarmEnginePolicy()` and tear the engine down before the stop,
      // leaving this test asserting against a state it never reached.
      manager.warmEnginePolicy = .off

      try await manager.startEnginePhase()

      #expect(stub.prepareCallCount == 1, "the engine really was prepared through startEnginePhase")
      #expect(
        manager.currentCaptureSessionID == 0,
        "capture was never armed, so the counter has not advanced")

      let result = await manager.stopCapture(sessionID: 0)

      #expect(result.samples.isEmpty, "nothing was captured, so there is nothing to return")
      #expect(stub.deactivateCallCount == 1, "the stop was ACCEPTED, not fenced out")

      // And the prepared engine really is GONE, not merely deactivated. `.off`
      // clears `activeSource` synchronously inside the stop, before the async
      // `source.stop()`, so `beginCapturePhase` — which requires an active source
      // — now throws. This observes the torn-down end state without widening
      // production visibility (`activeSource` is private) and without waiting on
      // the teardown Task (banned by swift-patterns.md RULE:
      // tests-no-unconditional-continuation-await).
      await #expect(throws: AudioError.self) {
        _ = try await manager.beginCapturePhase()
      }
    }
  }

#endif
