@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// DEBUG-only: reaches `AudioCaptureManager` through the same
// `installCapturedSourceForTesting` seam the other manager unit tests use, so the
// Release test-target lane must not compile it.
#if DEBUG

  /// #1810 / #4841 — drained pre-roll is never live capture.
  ///
  /// `PreRollForwarder` drains up to 8,000 buffered samples (500ms) through
  /// `onSamples` at activation, and `AudioCaptureManager.feedDeadAirDetector` ingests
  /// that batch exactly like live audio. The silent-mic notice (`exactZeroRun`) must
  /// subtract it: counted as live, a warm microphone's silent ring would bring the
  /// notice forward (measured drains: 147-553ms) and could make a take that spoke in
  /// its first second look "silent since start".
  ///
  /// Product Outcome: when these fail, the silent-mic notice fires on the wrong
  /// threshold, earlier than the 5 s / 6 s the product promises.
  @MainActor
  @Suite(
    "Pre-roll is never counted as live silence (#1810, #4841)",
    .tags(.productOutcome))
  struct PreRollCeilingTests {

    /// Inert `AudioInputSource`; the only interesting member is the drained count.
    /// Modelled on `AudioCaptureManagerRetireFenceTests.StubSource`.
    final class StubSource: AudioInputSource {
      var onSamples: (@Sendable ([Float], Float) -> Void)?
      var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
      var onInterrupted: ((EngineInterruptionCause) -> Void)?
      var onLifecycleSignal: (@Sendable (String) -> Void)?
      var onCaptureStalled: ((CaptureStallContext) -> Void)?
      var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?
      var captureGeneration: UInt64 = 0
      var drainedPreRollSampleCount: Int = 0
      let captureSourceType = "stub"
      var isCapturing = false
      var isRunning: Bool { true }
      #if DEBUG
        var debugZeroFillController: DebugZeroFillController?
        var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
          (nil, nil)
        }
      #endif
      func prepare() async throws -> BoundInputDevice {
        BoundInputDevice(
          deviceID: 1, deviceUID: "stub-uid", transportLabel: "stub",
          resolutionSource: "system_default", inputChannel: 0)
      }
      func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
      }
      func stop() async -> [Float] { [] }
      func deactivateCapture() {}
      func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
        -> Bool
      {
        true
      }
      func abortPrepare() {}
      func rebuild() {}
    }

    private func manager(drained: Int) -> AudioCaptureManager {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      stub.drainedPreRollSampleCount = drained
      manager.installCapturedSourceForTesting(stub, sessionID: 1)
      return manager
    }

    // MARK: - The live run excludes the drain

    @Test("a silent drained ring does not count toward the live run")
    func liveRunExcludesTheDrain() {
      // 8,000 drained + 16,000 live, all zero: the live run is 16,000, since start.
      let run = AudioCaptureManager.exactZeroRun(
        totalSampleCount: 24_000, consecutiveExactZeroSuffix: 24_000,
        drainedPreRollSampleCount: 8_000)
      #expect(run == ExactZeroRun(sampleCount: 16_000, sinceTakeStart: true))
    }

    @Test("speech in the drained ring does not make a silent live take look mid-take")
    func liveSilenceAfterNoisyRingIsSinceStart() {
      // The ring carried sound, then every live sample was zero: silent since the
      // take started, so the 6 s threshold applies, not the 5 s one.
      let run = AudioCaptureManager.exactZeroRun(
        totalSampleCount: 24_000, consecutiveExactZeroSuffix: 16_000,
        drainedPreRollSampleCount: 8_000)
      #expect(run == ExactZeroRun(sampleCount: 16_000, sinceTakeStart: true))
    }

    @Test("live sound then live silence is a mid-take run")
    func liveSoundThenSilenceIsMidTake() {
      let run = AudioCaptureManager.exactZeroRun(
        totalSampleCount: 24_000, consecutiveExactZeroSuffix: 10_000,
        drainedPreRollSampleCount: 8_000)
      #expect(run == ExactZeroRun(sampleCount: 10_000, sinceTakeStart: false))
    }

    @Test("before any live sample there is no run and nothing is since start")
    func noLiveSamplesNoRun() {
      let run = AudioCaptureManager.exactZeroRun(
        totalSampleCount: 8_000, consecutiveExactZeroSuffix: 8_000,
        drainedPreRollSampleCount: 8_000)
      #expect(run == ExactZeroRun(sampleCount: 0, sinceTakeStart: false))
    }

    @Test("a negative drain is treated as no drain")
    func negativeDrainInPureFormulaIsClamped() {
      let run = AudioCaptureManager.exactZeroRun(
        totalSampleCount: 16_000, consecutiveExactZeroSuffix: 16_000,
        drainedPreRollSampleCount: -500)
      #expect(run == ExactZeroRun(sampleCount: 16_000, sinceTakeStart: true))
    }

    @Test("the reading is nil outside active capture")
    func nilOutsideCapture() {
      #expect(AudioCaptureManager().exactZeroRun == nil)
    }

    // MARK: - The clamp

    /// The protocol member is typed `Int`. A negative would count pre-roll as live
    /// capture, so the clamp is asserted, never assumed.
    @Test("a negative drain reads as zero")
    func negativeDrainIsClamped() {
      #expect(manager(drained: -1).drainedPreRollSampleCount == 0)
      #expect(manager(drained: -8_000).drainedPreRollSampleCount == 0)
      #expect(manager(drained: 8_000).drainedPreRollSampleCount == 8_000)
    }

    /// THE cloud-review finding (PR #2200, P2). `stopCapture()`'s documented
    /// `activeSource == nil` early return — reachable when an engine interruption is
    /// followed by the user switching "Keep engine warm" off — used to leave the
    /// STOP-time reader with no drain at all. The manager caches the value, so the
    /// drain survives the source going away.
    @Test("#2200 review: the drain survives the source being torn down")
    func drainSurvivesSourceTeardown() {
      let manager = AudioCaptureManager()
      let stub = StubSource()
      stub.drainedPreRollSampleCount = 8_000
      manager.installCapturedSourceForTesting(stub, sessionID: 1)
      #expect(manager.drainedPreRollSampleCount == 8_000)
      // The source goes away exactly as the warm-engine-off teardown leaves it.
      manager.tearDownActiveSourceForTesting()
      #expect(
        manager.drainedPreRollSampleCount == 8_000,
        "the stop-time drain silently reverted to zero when the source went away")
    }
  }
#endif
