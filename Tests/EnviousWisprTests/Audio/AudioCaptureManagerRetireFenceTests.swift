@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// This suite uses AudioCaptureManager's `#if DEBUG` test seam
// (`installCapturedSourceForTesting`) and its `debugSourceIncarnation` oracle, so
// the whole suite is DEBUG-only — the Release test-target lane must not compile it.
#if DEBUG

  // MARK: - Heartpath 5b (#1520) — the zero-signal source-retirement fence.
  //
  // `retireCapturingSource(sessionID:)` must tear down ONLY the source that
  // captured the given session, and ONLY while it is still the running active
  // source. These tests exercise the REAL `AudioCaptureManager` fence (session-id
  // + retained-source `===` + running-state), not a `FakeAudioCapture` — the fake
  // is a pass-through recorder and would test itself, not the guards.
  //
  // State is installed via `installCapturedSourceForTesting` (DEBUG), the same
  // arm-without-hardware shortcut the other manager unit tests use — a stub source
  // cannot drive `beginCapturePhase`, which needs a real device format.
  // `debugSourceIncarnation` is the freshness oracle: it advances exactly once on a
  // real retire and never on a fenced no-op.
  @MainActor
  @Suite("AudioCaptureManager zero-signal retire fence (#1520)")
  struct AudioCaptureManagerRetireFenceTests {

    /// Minimal `AudioInputSource` stub: controllable running-state, records the
    /// destructive `rebuild()`. All other members are inert.
    final class StubSource: AudioInputSource {
      var onSamples: (@Sendable ([Float], Float) -> Void)?
      var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
      var onInterrupted: ((EngineInterruptionCause) -> Void)?
      var onLifecycleSignal: (@Sendable (String) -> Void)?
      var onCaptureStalled: ((CaptureStallContext) -> Void)?
      var captureGeneration: UInt64 = 0
      let captureSourceType = "stub"
      var running = true
      var isCapturing = false
      var isRunning: Bool { running }
      private(set) var rebuildCallCount = 0
      #if DEBUG
        var debugZeroFillController: DebugZeroFillController?
      #endif

      func prepare() async throws {}
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
      {
        true
      }
      func abortPrepare() {}
      func rebuild() {
        rebuildCallCount += 1
        running = false
      }
    }

    @Test("matching session + running captured source → retires once, one incarnation bump")
    func matchingSessionRetiresOnce() {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      manager.installCapturedSourceForTesting(stub, sessionID: 7)
      let base = manager.debugSourceIncarnation

      let result = manager.retireCapturingSource(sessionID: 7)

      #expect(result == .retired)
      #expect(stub.rebuildCallCount == 1)
      #expect(manager.debugSourceIncarnation == base + 1)
    }

    @Test("stale session id → no-op, captured source untouched, no bump")
    func staleSessionIsInert() {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      manager.installCapturedSourceForTesting(stub, sessionID: 7)
      let base = manager.debugSourceIncarnation

      let result = manager.retireCapturingSource(sessionID: 6)  // an older take's id

      #expect(result == .staleSession)
      #expect(stub.rebuildCallCount == 0)
      #expect(manager.debugSourceIncarnation == base)
    }

    @Test("captured source replaced by a newer active source → no-op, replacement untouched")
    func replacedSourceIsInert() {
      let manager = AudioCaptureManager()
      let captured = StubSource()
      let replacement = StubSource()
      // Same session id, but the ACTIVE source is now a different object than the
      // one that captured the session (the exact narrow window the retained-`===`
      // fence closes; the session-id fence alone would let this through).
      manager.installCapturedSourceForTesting(captured, active: replacement, sessionID: 7)

      let result = manager.retireCapturingSource(sessionID: 7)

      #expect(result == .sourceReplaced)
      #expect(captured.rebuildCallCount == 0)
      #expect(replacement.rebuildCallCount == 0)
    }

    @Test("active source already gone → no-op, captured source untouched")
    func activeSourceGoneIsInert() {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      manager.installCapturedSourceForTesting(stub, sessionID: 7)
      // Drop the live active source while keeping the retained capture source —
      // the only way to reach the `.activeSourceGone` branch.
      manager.clearActiveSourceForTesting()
      let base = manager.debugSourceIncarnation

      let result = manager.retireCapturingSource(sessionID: 7)

      #expect(result == .activeSourceGone)
      #expect(stub.rebuildCallCount == 0)
      #expect(manager.debugSourceIncarnation == base)
    }

    @Test("stopped captured source → no-op, no bump")
    func stoppedSourceIsInert() {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      stub.running = false  // e.g. an interruption already tore it down
      manager.installCapturedSourceForTesting(stub, sessionID: 7)
      let base = manager.debugSourceIncarnation

      let result = manager.retireCapturingSource(sessionID: 7)

      #expect(result == .sourceNotRunning)
      #expect(stub.rebuildCallCount == 0)
      #expect(manager.debugSourceIncarnation == base)
    }

    @Test("a real retire clears the retained source — a second retire is inert")
    func retireClearsRetainedSource() {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      manager.installCapturedSourceForTesting(stub, sessionID: 7)

      #expect(manager.retireCapturingSource(sessionID: 7) == .retired)
      #expect(stub.rebuildCallCount == 1)

      // The retire cleared `captureSessionSource`, so a repeat hits the
      // "captured source already gone" guard — proving no stale retain lingers
      // (the retain-release property, without exposing the private field).
      #expect(manager.retireCapturingSource(sessionID: 7) == .capturedSourceGone)
      #expect(stub.rebuildCallCount == 1)  // still 1, not 2
    }
  }

#endif
