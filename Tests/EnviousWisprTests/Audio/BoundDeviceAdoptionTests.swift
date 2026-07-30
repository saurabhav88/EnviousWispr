@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// This suite drives `AudioCaptureManager`'s `#if DEBUG` source-factory seam, so the
// whole suite is DEBUG-only — the Release test-target lane must not compile it
// (`swift-testing-debug-seam-needs-if-debug`; the trap that turned main red in
// #1520 / PR #1555).
#if DEBUG

  // MARK: - #1844 — the manager adopts the bind `prepare()` RETURNED.
  //
  // Before this change the manager froze a SETTINGS-DERIVED device one synchronous
  // turn BEFORE `prepare()` committed the bind. When the user's explicit microphone
  // was absent, HAL fell back to the system default and recorded fine, while the
  // health check either examined a microphone the session never opened or gave up
  // entirely — so a genuinely silent recording produced no message.
  //
  // These tests drive the REAL `AudioCaptureManager.startEnginePhase()` and
  // `preWarm()` against a stub source, so what is asserted is the manager's own
  // adoption, not a helper's return value. No real hardware, no CoreAudio, no log
  // file, no clock, no process global.
  @MainActor
  @Suite("AudioCaptureManager bound-device adoption — #1844")
  struct BoundDeviceAdoptionTests {

    /// Minimal `AudioInputSource` stub whose `prepare()` return is controllable.
    /// Everything else is inert — this suite is about what the MANAGER does with
    /// the returned value.
    final class StubSource: AudioInputSource {
      var onSamples: (@Sendable ([Float], Float) -> Void)?
      var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
      var onInterrupted: ((EngineInterruptionCause) -> Void)?
      var onLifecycleSignal: (@Sendable (String) -> Void)?
      var onCaptureStalled: ((CaptureStallContext) -> Void)?
      var captureGeneration: UInt64 = 0
      let captureSourceType = "stub"
      var running = false
      var isCapturing = false
      var isRunning: Bool { running }
      #if DEBUG
        var debugZeroFillController: DebugZeroFillController?
        /// #1788: this stub has no forwarder, so it measured no wake. Nil is the
        /// honest answer and the manager renders it as `unavailable` rather than
        /// inventing a 0ms wake. Matches the retire-fence stub's precedent.
        var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
          (nil, nil)
        }
      #endif

      /// The bind this stub publishes from `prepare()`. Mutate between attempts to
      /// model a retry that lands on a different device.
      var boundToReturn = BoundInputDevice(
        deviceID: 99, deviceUID: "stub-uid-99", transportLabel: "usb")
      /// When set, `prepare()` throws this instead of returning a bind.
      var prepareError: Error?
      private(set) var prepareCallCount = 0

      func prepare() async throws -> BoundInputDevice {
        prepareCallCount += 1
        if let prepareError { throw prepareError }
        return boundToReturn
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
      func rebuild() { running = false }
    }

    /// A manager wired to return `stub` from `resolveSource()`, with settings set so
    /// that any surviving settings-derived resolution would name something ELSE.
    private static func makeManager(
      _ stub: StubSource,
      preferredOverride: String = "a-microphone-that-does-not-exist",
      rememberedSelection: String = "a-different-remembered-microphone"
    ) -> AudioCaptureManager {
      let manager = AudioCaptureManager()
      manager.preferredInputDeviceIDOverride = preferredOverride
      manager.selectedInputDeviceUID = rememberedSelection
      manager.installSourceFactoryForTesting { stub }
      return manager
    }

    // MARK: - 1. The returned bind is what gets adopted

    @Test("the manager adopts the bind prepare() returned, not a settings-derived device")
    func adoptsTheReturnedBind() async throws {
      let stub = StubSource()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 99, deviceUID: "stub-uid-99", transportLabel: "usb")
      let manager = Self.makeManager(stub)

      try await manager.startEnginePhase()

      // WHOLE value: the UID is what the identity re-check depends on, so an
      // id-only assertion would pass a stale-UID adoption.
      #expect(manager.zeroSignalDiscriminatorDevice == stub.boundToReturn)
      #expect(stub.prepareCallCount == 1)
    }

    // MARK: - 2. Remembered selection is irrelevant

    @Test("adoption ignores selectedInputDeviceUID entirely")
    func adoptionIgnoresRememberedSelection() async throws {
      let stub = StubSource()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 7, deviceUID: "actually-bound-uid", transportLabel: "built_in")
      let manager = Self.makeManager(
        stub, rememberedSelection: "remembered-but-never-opened-uid")

      try await manager.startEnginePhase()

      #expect(manager.zeroSignalDiscriminatorDevice?.deviceUID == "actually-bound-uid")
      #expect(manager.zeroSignalDiscriminatorDevice?.deviceUID != "remembered-but-never-opened-uid")
    }

    // MARK: - 3. A throwing attempt must not leave the previous session's device

    @Test("a throwing prepare() leaves nil, never the prior session's device")
    func throwingPrepareLeavesNil() async throws {
      let stub = StubSource()
      let manager = Self.makeManager(stub)

      // Establish a real prior bind first, so nil cannot be trivially true.
      try await manager.startEnginePhase()
      #expect(manager.zeroSignalDiscriminatorDevice != nil)

      stub.prepareError = AudioError.noBuiltInMicrophoneFound
      await #expect(throws: (any Error).self) { try await manager.startEnginePhase() }

      #expect(
        manager.zeroSignalDiscriminatorDevice == nil,
        "a failed attempt must not leave a previous session's device observable")
    }

    // MARK: - 4. The FINAL successful attempt wins

    @Test("the final successful attempt wins across a rebuild retry")
    func finalAttemptWins() async throws {
      let stub = StubSource()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 99, deviceUID: "first-attempt-uid", transportLabel: "usb")
      let manager = Self.makeManager(stub)

      try await manager.startEnginePhase()
      #expect(manager.zeroSignalDiscriminatorDevice?.deviceID == 99)

      // The real manager rebuild path, then a second real attempt binding elsewhere.
      manager.rebuildEngine()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 42, deviceUID: "final-attempt-uid", transportLabel: "built_in")
      try await manager.startEnginePhase()

      #expect(manager.zeroSignalDiscriminatorDevice == stub.boundToReturn)
      #expect(manager.zeroSignalDiscriminatorDevice?.deviceID == 42)
      #expect(stub.prepareCallCount == 2)
    }

    // MARK: - 5. Pre-warm must not adopt

    @Test("preWarm() prepares hardware but adopts no health-check device")
    func preWarmDoesNotAdopt() async throws {
      let stub = StubSource()
      let manager = Self.makeManager(stub)

      try await manager.preWarm()

      #expect(stub.prepareCallCount == 1, "preWarm must really have prepared the source")
      #expect(
        manager.zeroSignalDiscriminatorDevice == nil,
        "pre-warm runs outside any session and must not publish a health-check device")
    }

    // MARK: - Fail-closed lives with the CONSUMER, not here
    //
    // A sixth case asserting "the invalidated bind is nil" was removed: it merely
    // repeated `throwingPrepareLeavesNil` above and never invoked a classification
    // path, so it proved invalidation twice and fail-closed not at all. The real
    // fail-closed policy is the kernel's eligibility guard, and it is now driven
    // directly — through the kernel's PRODUCTION closure rather than an injected
    // stand-in — by `KernelFrozenBindGuardTests` in the Pipeline suite.
  }

#endif
