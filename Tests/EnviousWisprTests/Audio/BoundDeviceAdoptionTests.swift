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

      /// #1810: stubs drain no pre-roll. A stored var rather than a literal so a
      /// test can set a value — including a negative, to prove the clamp.
      var drainedPreRollSampleCount: Int = 0
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
        deviceID: 99, deviceUID: "stub-uid-99", transportLabel: "usb",
        resolutionSource: "system_default")
      /// When set, `prepare()` throws this instead of returning a bind.
      var prepareError: Error?
      private(set) var prepareCallCount = 0

      /// #1714: the undefaulted protocol witness. Explicit rather than inherited
      /// so a conformer cannot silently report no attribution.
      var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?

      /// When set, `prepare()` fires this SYNCHRONOUSLY before returning or
      /// throwing, modelling a real cold attempt. Nil models warm reuse, which
      /// finalises nothing.
      var finalizedAttemptToFire: FinalizedInputResolutionAttempt?

      func prepare() async throws -> BoundInputDevice {
        prepareCallCount += 1
        if let finalizedAttemptToFire {
          onInputResolutionAttemptFinalized?(finalizedAttemptToFire)
        }
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
      manager.installSourceFactoryForTesting { _ in stub }
      return manager
    }

    // MARK: - 1. The returned bind is what gets adopted

    @Test("the manager adopts the bind prepare() returned, not a settings-derived device")
    func adoptsTheReturnedBind() async throws {
      let stub = StubSource()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 99, deviceUID: "stub-uid-99", transportLabel: "usb",
        resolutionSource: "system_default")
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
        deviceID: 7, deviceUID: "actually-bound-uid", transportLabel: "built_in",
        resolutionSource: "system_default")
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
        deviceID: 99, deviceUID: "first-attempt-uid", transportLabel: "usb",
        resolutionSource: "system_default")
      let manager = Self.makeManager(stub)

      try await manager.startEnginePhase()
      #expect(manager.zeroSignalDiscriminatorDevice?.deviceID == 99)

      // The real manager rebuild path, then a second real attempt binding elsewhere.
      manager.rebuildEngine()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 42, deviceUID: "final-attempt-uid", transportLabel: "built_in",
        resolutionSource: "system_default")
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

    // MARK: - 6. #1714 attribution lifetime
    //
    // The manager is the LIFETIME owner because a THROWING cold attempt returns
    // no bind at all — without retention, a resolution or bind failure could
    // never be attributed, and the previous session's answer would still be
    // sitting there looking current.

    /// A finalised cold attempt that SELECTED a device but failed later, so its
    /// source is non-nil and distinguishable from any earlier one.
    private static func finalizedAttempt(
      _ source: InputResolutionSource, bind: InputBindOutcome = .succeeded
    ) -> FinalizedInputResolutionAttempt {
      var state = InputResolutionAttemptState()
      state.recordBind(succeeded: bind == .succeeded)
      return state.finalized(
        resolution: InputDeviceResolution(
          outcome: .selected(42, source: source),
          defaultPresent: source == .systemDefault,
          enumerationOutcome: source == .systemDefault ? .notAttempted : .succeeded,
          inputDeviceCount: nil,
          eligibleDeviceCount: nil,
          selectedTransport: nil))
    }

    @Test("a successful prepare with NO cold callback still exposes the returned bind's source")
    func warmSuccessExposesReturnedBindSource() async throws {
      // Warm reuse fires no finalisation but returns a bind carrying the
      // ORIGINAL source, so the returned bind is the only authority here.
      let stub = StubSource()
      stub.finalizedAttemptToFire = nil
      stub.boundToReturn = BoundInputDevice(
        deviceID: 30, deviceUID: "fallback-uid", transportLabel: "built_in",
        resolutionSource: "list_fallback")
      let manager = Self.makeManager(stub)

      try await manager.startEnginePhase()

      #expect(manager.currentInputResolutionSource == "list_fallback")
    }

    @Test("on success the RETURNED BIND wins over the cold callback's provisional value")
    func returnedBindWinsOverCallback() async throws {
      // Deliberately disagreeing values. #1844's rule is that the bind
      // `prepare()` returned is the authority; the callback is provisional
      // because it fires before the attempt is known to have succeeded.
      let stub = StubSource()
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.systemDefault)
      stub.boundToReturn = BoundInputDevice(
        deviceID: 30, deviceUID: "fallback-uid", transportLabel: "built_in",
        resolutionSource: "list_fallback")
      let manager = Self.makeManager(stub)

      try await manager.startEnginePhase()

      #expect(manager.currentInputResolutionSource == "list_fallback")
    }

    @Test("a throwing cold attempt exposes THIS attempt's source, never the previous one")
    func throwingAttemptReplacesPriorSource() async throws {
      let stub = StubSource()
      // First attempt succeeds on the system default.
      stub.boundToReturn = BoundInputDevice(
        deviceID: 42, deviceUID: "default-uid", transportLabel: "built_in",
        resolutionSource: "system_default")
      let manager = Self.makeManager(stub)
      try await manager.startEnginePhase()
      #expect(manager.currentInputResolutionSource == "system_default")

      // Second attempt resolves to the FALLBACK, then throws after the bind.
      // Two distinct non-nil sources, so replacement is proven by the value
      // changing rather than by comparing nil with nil.
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.listFallback)
      stub.prepareError = AudioError.formatCreationFailed(source: "test.after_bind")

      await #expect(throws: AudioError.self) { try await manager.startEnginePhase() }

      #expect(manager.currentInputResolutionSource == "list_fallback")
    }

    @Test("a throwing attempt that finalises NOTHING clears the prior source")
    func throwingAttemptWithoutFinalisationClearsSource() async throws {
      // Proves the clear happens BEFORE prepare, so stale attribution cannot
      // survive an attempt that never got far enough to report anything.
      let stub = StubSource()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 42, deviceUID: "default-uid", transportLabel: "built_in",
        resolutionSource: "system_default")
      let manager = Self.makeManager(stub)
      try await manager.startEnginePhase()
      #expect(manager.currentInputResolutionSource == "system_default")

      stub.finalizedAttemptToFire = nil
      stub.prepareError = AudioError.noBuiltInMicrophoneFound

      await #expect(throws: AudioError.self) { try await manager.startEnginePhase() }

      #expect(manager.currentInputResolutionSource == nil)
    }

    @Test("successful preWarm attributes without publishing a health-check device")
    func preWarmAttributesWithoutAdopting() async throws {
      // Pre-warm is where cold resolution normally happens, so attributing only
      // on the recording's own prepare would report almost nothing.
      let stub = StubSource()
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.listFallback)
      stub.boundToReturn = BoundInputDevice(
        deviceID: 30, deviceUID: "fallback-uid", transportLabel: "built_in",
        resolutionSource: "list_fallback")
      let manager = Self.makeManager(stub)

      try await manager.preWarm()

      #expect(manager.currentInputResolutionSource == "list_fallback")
      #expect(
        manager.zeroSignalDiscriminatorDevice == nil,
        "pre-warm still must not publish a health-check device")
    }

    @Test("a throwing preWarm retains the new attempt's source before rethrowing")
    func throwingPreWarmRetainsSource() async throws {
      let stub = StubSource()
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.listFallback, bind: .failed)
      stub.prepareError = AudioError.formatCreationFailed(source: "test.prewarm")
      let manager = Self.makeManager(stub)

      await #expect(throws: AudioError.self) { try await manager.preWarm() }

      #expect(manager.currentInputResolutionSource == "list_fallback")
      #expect(manager.zeroSignalDiscriminatorDevice == nil)
    }

    // MARK: - 7. #1714 outbound telemetry projection

    @Test("a cold attempt forwards ONE projection built from the retained attempt")
    func coldAttemptForwardsOneProjection() async throws {
      let stub = StubSource()
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.listFallback)
      stub.boundToReturn = BoundInputDevice(
        deviceID: 30, deviceUID: "fallback-uid", transportLabel: "built_in",
        resolutionSource: "list_fallback")
      let manager = Self.makeManager(stub)

      var forwarded: [InputResolutionAttemptTelemetry] = []
      manager.onFinalizedInputResolutionAttempt = { forwarded.append($0) }

      try await manager.startEnginePhase()

      #expect(forwarded.count == 1, "exactly one projection per cold attempt")
      #expect(forwarded.first?.inputResolutionSource == "list_fallback")
      #expect(forwarded.first?.bindOutcome == "succeeded")
      #expect(forwarded.first?.prepareOutcome == "failed", "the attempt was finalised pre-success")
      #expect(forwarded.first?.defaultPresent == false)
    }

    @Test("a WARM success forwards nothing — a reused bind is not a new resolution")
    func warmSuccessForwardsNothing() async throws {
      let stub = StubSource()
      stub.finalizedAttemptToFire = nil
      stub.boundToReturn = BoundInputDevice(
        deviceID: 30, deviceUID: "fallback-uid", transportLabel: "built_in",
        resolutionSource: "list_fallback")
      let manager = Self.makeManager(stub)

      var forwarded: [InputResolutionAttemptTelemetry] = []
      manager.onFinalizedInputResolutionAttempt = { forwarded.append($0) }

      try await manager.startEnginePhase()

      #expect(forwarded.isEmpty)
      // Attribution still updates from the returned bind.
      #expect(manager.currentInputResolutionSource == "list_fallback")
    }

    @Test("a THROWING cold attempt still forwards before the throw escapes")
    func throwingColdAttemptStillForwards() async throws {
      let stub = StubSource()
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.listFallback, bind: .failed)
      stub.prepareError = AudioError.formatCreationFailed(source: "test.set_device")
      let manager = Self.makeManager(stub)

      var forwarded: [InputResolutionAttemptTelemetry] = []
      manager.onFinalizedInputResolutionAttempt = { forwarded.append($0) }

      await #expect(throws: AudioError.self) { try await manager.startEnginePhase() }

      // The failing population is the one #1714 exists to measure, so it must
      // still be reported.
      #expect(forwarded.count == 1)
      #expect(forwarded.first?.bindOutcome == "failed")
      #expect(forwarded.first?.prepareOutcome == "failed")
    }

    @Test("nil counts survive the projection as nil, never as zero")
    func nilCountsSurviveProjection() async throws {
      // The attempt fixture uses a not-attempted enumeration, whose counts are
      // unknown. Flattening them to 0 here would claim the machine listed no
      // input devices.
      let stub = StubSource()
      stub.finalizedAttemptToFire = Self.finalizedAttempt(.systemDefault)
      let manager = Self.makeManager(stub)

      var forwarded: [InputResolutionAttemptTelemetry] = []
      manager.onFinalizedInputResolutionAttempt = { forwarded.append($0) }

      try await manager.startEnginePhase()

      #expect(forwarded.first?.inputDeviceCount == nil)
      #expect(forwarded.first?.eligibleDeviceCount == nil)
      #expect(forwarded.first?.enumerationOutcome == "not_attempted")
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
