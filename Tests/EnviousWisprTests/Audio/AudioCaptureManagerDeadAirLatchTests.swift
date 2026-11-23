import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - #4841 — exact zeros never end a take
//
// The manager feeds authoritative captured samples into a
// `DeadAirStreamingDetector` on the MainActor through `ingestSamples`. Since
// #4841 that detector only observes: no exact-zero run, at the start or mid-take,
// on any transport, raises a capture stall. The silent-mic notice reads
// `exactZeroRun`; STOP classifies the whole buffer. The counter math is covered by
// `DeadAirStreamingDetectorTests`; this suite pins the manager wiring.
@MainActor
@Suite("AudioCaptureManager exact zeros never end a take (#4841)")
struct AudioCaptureManagerDeadAirLatchTests {

  /// A manager armed to ingest without real hardware. No `startEnginePhase`, so
  /// the frozen discriminator device is `nil`.
  private func armedManager() -> AudioCaptureManager {
    let manager = AudioCaptureManager()
    manager.isCapturing = true  // internal(set): arm ingest without hardware
    return manager
  }

  private static func zeros(_ n: Int) -> [Float] { [Float](repeating: 0, count: n) }

  @Test("a long all-zero start raises no stall and keeps every sample")
  func allZeroStartRaisesNoStall() {
    let manager = armedManager()
    var stalls: [CaptureStallContext] = []
    manager.onCaptureStalled = { stalls.append($0) }

    manager.ingestSamples(Self.zeros(160_000), level: 0)

    #expect(stalls.isEmpty, "10 s of exact zeros must not end the take")
    #expect(manager.isCapturing)
    #expect(manager.capturedSamples.count == 160_000)
    #expect(manager.exactZeroRun == ExactZeroRun(sampleCount: 160_000, sinceTakeStart: true))
  }

  @Test("speech, a long silent pause, then speech: no stall, every sample captured")
  func pauseAndResumeRaisesNoStall() {
    let manager = armedManager()
    var stalls: [CaptureStallContext] = []
    manager.onCaptureStalled = { stalls.append($0) }

    manager.ingestSamples([Float](repeating: 0.5, count: 8_000), level: 0.5)
    manager.ingestSamples(Self.zeros(96_000), level: 0)
    #expect(manager.exactZeroRun == ExactZeroRun(sampleCount: 96_000, sinceTakeStart: false))
    manager.ingestSamples([Float](repeating: 0.25, count: 8_000), level: 0.25)

    #expect(stalls.isEmpty)
    #expect(manager.capturedSamples.count == 112_000)
    #expect(manager.capturedSamples.last == 0.25, "the resumed speech reached capture")
    #expect(manager.exactZeroRun == ExactZeroRun(sampleCount: 0, sinceTakeStart: false))
  }
}

#if DEBUG
  // Real session paths: both need the manager's `#if DEBUG` source-factory seam,
  // so this suite is DEBUG-only — the Release lane strips the seam and must not
  // try to compile against it (the trap that turned main red in #1520).
  //
  // The stub source is the one `BoundDeviceAdoptionTests` already maintains for
  // exactly this purpose. A second copy would be a second thing to keep true.
  @MainActor
  @Suite("AudioCaptureManager exact zeros — real session paths (#4841)")
  struct AudioCaptureManagerRefusalSessionTests {

    private static func zeros(_ n: Int) -> [Float] { [Float](repeating: 0, count: n) }

    private static func makeManager(_ stub: BoundDeviceAdoptionTests.StubSource)
      -> AudioCaptureManager
    {
      let manager = AudioCaptureManager()
      manager.installSourceFactoryForTesting { _ in stub }
      return manager
    }

    /// A manager in a real session bound to the stub with `transport`.
    private static func boundSession(transport: String) async throws -> (
      AudioCaptureManager, BoundDeviceAdoptionTests.StubSource
    ) {
      let stub = BoundDeviceAdoptionTests.StubSource()
      stub.boundToReturn = BoundInputDevice(
        deviceID: 99, deviceUID: "stub-uid-99", transportLabel: transport,
        resolutionSource: "system_default", inputChannel: 0)
      let manager = Self.makeManager(stub)
      try await manager.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))
      _ = try await manager.beginCapturePhase()
      try #require(manager.zeroSignalDiscriminatorDevice?.transportLabel == transport)
      return (manager, stub)
    }

    /// When this fails, a user's take ends because they paused, or because they
    /// thought for a second before speaking — the #4841 report. A 3.5 s silent
    /// start (past the deleted 3.0 s Bluetooth ceiling), then signal, a 2 s zero
    /// run, and resumed signal, on every transport.
    @Test(
      "no transport ends a take on startup or mid-take zero runs",
      arguments: ["built_in", "bluetooth", "usb", "unknown"])
    func noTransportEndsATakeOnZeros(transport: String) async throws {
      let (manager, _) = try await Self.boundSession(transport: transport)
      var stalls: [CaptureStallContext] = []
      manager.onCaptureStalled = { stalls.append($0) }

      let batches: [[Float]] = [
        Self.zeros(56_000),
        [Float](repeating: 0.5, count: 8_000),
        Self.zeros(32_000),
        [Float](repeating: 0.25, count: 8_000),
      ]
      for batch in batches { manager.ingestSamples(batch, level: 0) }

      #expect(stalls.isEmpty, "a \(transport) zero run must not end the take")
      #expect(manager.isCapturing == true)
      #expect(manager.capturedSamples.count == 104_000, "every batch was captured")
      #expect(manager.capturedSamples.last == 0.25, "the resumed speech reached capture")
    }

    @Test("starting a new session resets the live zero run")
    func sessionStartResetsTheRun() async throws {
      let stub = BoundDeviceAdoptionTests.StubSource()
      let manager = Self.makeManager(stub)
      manager.isCapturing = true
      manager.ingestSamples(Self.zeros(32_000), level: 0)
      #expect(manager.exactZeroRun?.sampleCount == 32_000, "precondition: a run exists")

      try await manager.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))
      _ = try await manager.beginCapturePhase()

      #expect(manager.exactZeroRun?.sampleCount ?? 0 == 0)
    }

    /// Exact zeros must not consume the stall latch: a genuine no-buffer stall from
    /// the source in the same take still reaches the consumer.
    @Test("a genuine no-buffer stall still forwards after a long zero run")
    func noBufferStallStillForwardsAfterZeros() async throws {
      let (manager, stub) = try await Self.boundSession(transport: "bluetooth")
      var stalls: [CaptureStallContext] = []
      manager.onCaptureStalled = { stalls.append($0) }

      manager.ingestSamples(Self.zeros(32_000), level: 0)
      #expect(stalls.isEmpty, "precondition: zeros raised nothing")

      stub.onCaptureStalled?(
        CaptureStallContext(
          sessionID: manager.currentCaptureSessionID,
          armedAtUptimeNs: 0,
          firedAtUptimeNs: 1,
          route: "stub",
          sourceType: "stub",
          engineStartedSuccessfully: true,
          tapInstalled: true,
          formatMismatchObserved: false,
          inputDeviceUIDPreferred: nil,
          inputDeviceUIDSystemDefault: nil,
          failureMode: .noBuffers))

      #expect(stalls.count == 1)
      #expect(stalls.first?.failureMode == .noBuffers)
    }
  }

  /// The wake instrument's honesty rule (#1788, cloud review r5-r7). SEVEN review
  /// rounds on this one diagnostic all reduced to reading a quantity over an interval
  /// it does not describe, so the rule deciding `stream_measured` vs `floor` is
  /// frozen here as pure logic rather than left inside the emitter where each round
  /// found it again. Both failure modes UNDER-report, so the safe label is `floor`.
  ///
  /// Note the label is `stream_measured`, not `exact`: no sample-derived wake can be
  /// exact with respect to press-to-audio, because a callback-free startup is
  /// invisible to a sample clock (r7). These tests pin the delivered-stream claim,
  /// which is the only claim the instrument makes.
  @Suite("AudioCaptureManager — wake measurement basis (#1788)")
  struct AudioCaptureManagerWakeExactnessTests {

    @Test("a measured zero prefix is what makes a wake stream-measured")
    func measuredPrefixMakesItExact() {
      // Samples were routed while the link was still silent, so the interval is
      // observed rather than inferred.
      #expect(AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 9591))
      #expect(AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 1))
    }

    @Test("a zero wake is ALWAYS a floor, never stream-measured")
    func zeroWakeIsNeverExact() {
      // THE r5/r6 CASE. A wake of 0 means the first sample that ever existed was
      // already non-zero, so an already-awake link and one that woke during a
      // callback-free startup are indistinguishable. r6 caught the previous version
      // of this suite ASSERTING THE OPPOSITE for a pre-roll latch at index 0 — the
      // bug was written into its own oracle, which is why the rule is now expressed
      // over the wake itself rather than over a proxy field.
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 0))
    }

    @Test("gaps and a measured prefix are both required")
    func exactRequiresBothConditions() {
      #expect(AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 8000))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 1, wakeSamples: 8000))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 0))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 3, wakeSamples: 0))
    }

    @Test("an unreadable gap count or wake fails CLOSED, never as zero")
    func unknownInputsAreNotExact() {
      // A measurement authority that cannot read its own inputs must not print the
      // confident label. nil gaps = the source offered no stop metadata; nil wake =
      // the stream position could not be reconstructed at all.
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: nil, wakeSamples: 8000))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: nil))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: nil, wakeSamples: nil))
    }
  }
#endif
