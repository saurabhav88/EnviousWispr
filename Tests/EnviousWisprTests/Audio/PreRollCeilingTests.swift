@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// DEBUG-only: reaches `AudioCaptureManager` through the same
// `installCapturedSourceForTesting` seam the other manager unit tests use, so the
// Release test-target lane must not compile it.
#if DEBUG

  /// #1810 — the all-zero abort bar must mean 1.0s of LIVE capture.
  ///
  /// `PreRollForwarder` drains up to 8,000 buffered samples (500ms) through
  /// `onSamples` at activation, and `AudioCaptureManager.feedDeadAirDetector` ingests
  /// that batch exactly like live audio. Before this change the ceiling was compared
  /// against a total that already included the drain, so a press whose pre-roll was
  /// itself silent lost that much of its budget — measured at 147-553ms on production
  /// takes, and observed firing at 498ms against a documented 1,000ms bar.
  ///
  /// Product Outcome: when these fail, a microphone is called dead sooner than the
  /// software promises and the user's words are lost.
  @MainActor
  @Suite(
    "Pre-roll must not be charged against the all-zero ceiling (#1810)",
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
          resolutionSource: "system_default")
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

    // MARK: - The bar is a bar on LIVE capture

    @Test("a capture that drained 8,000 silent pre-roll samples still gets a full 1.0s of live")
    func ceilingAddsTheDrain() {
      let base = AudioConstants.minimumTranscriptionSamples
      #expect(manager(drained: 0).allZeroCeilingSamples == base)
      #expect(manager(drained: 8_000).allZeroCeilingSamples == base + 8_000)
      // The production measurement that motivated this: an abort at 498ms against a
      // 1,000ms bar means ~502ms of the budget had gone on drained pre-roll.
      #expect(manager(drained: 8_032).allZeroCeilingSamples == base + 8_032)
    }

    /// The transport branch is `private(set)` from a test's point of view, so the
    /// Bluetooth half is asserted against the pure static authority plus the same
    /// offset. Spelled out because the number a reader guesses is wrong: with a full
    /// ring #1788's 3.0s bar is 48,000 + 8,000 = 56,000, not 80,000.
    @Test("the Bluetooth base is still 3.0s, and a full ring makes it 56,000 not 80,000")
    func bluetoothBaseIsUnchangedAndTheOffsetComposes() {
      let bluetoothBase = AudioCaptureManager.allZeroFromStartCeilingSamples(
        forEffectiveTransport: "bluetooth")
      #expect(bluetoothBase == AudioConstants.bluetoothAllZeroMidTakeCeilingSamples)
      #expect(bluetoothBase + 8_000 == 56_000)
      for wired in ["built_in", "usb", "unknown", nil] {
        #expect(
          AudioCaptureManager.allZeroFromStartCeilingSamples(forEffectiveTransport: wired)
            == AudioConstants.minimumTranscriptionSamples)
      }
    }

    /// The DEBUG override is a bar on LIVE capture too. If it were not, every local
    /// hardware measurement would be taken against a different rule from the one the
    /// fleet runs, which is the opposite of what the override exists for.
    /// `AudioCaptureManagerDeadAirLatchTests` already pins the override with no
    /// source installed; this pins the composition with one. Same `defer` cleanup
    /// pattern as that suite.
    @Test("the DEBUG ceiling override is also a live-capture bar")
    func debugOverrideAlsoAddsTheDrain() {
      defer { UserDefaults.standard.removeObject(forKey: "EWDebugAllZeroCeilingSamples") }
      UserDefaults.standard.set(160_000, forKey: "EWDebugAllZeroCeilingSamples")
      #expect(manager(drained: 8_000).allZeroCeilingSamples == 168_000)
      #expect(manager(drained: 0).allZeroCeilingSamples == 160_000)
      #expect(manager(drained: -8_000).allZeroCeilingSamples == 160_000)
    }

    // MARK: - The clamp

    /// The protocol member is typed `Int`. A negative would SHRINK the ceiling and
    /// make the abort fire EARLIER — the one direction this change promises is
    /// impossible — so the clamp is asserted, never assumed.
    @Test("a negative drain cannot shorten the bar")
    func negativeDrainIsClamped() {
      let base = AudioConstants.minimumTranscriptionSamples
      #expect(manager(drained: -1).allZeroCeilingSamples == base)
      #expect(manager(drained: -8_000).allZeroCeilingSamples == base)
      #expect(manager(drained: -8_000).drainedPreRollSampleCountForCeiling == 0)
    }

    @Test("no source installed falls back to the shipping bar, never to a shorter one")
    func noSourceIsTheShippingBar() {
      #expect(
        AudioCaptureManager().allZeroCeilingSamples
          == AudioConstants.minimumTranscriptionSamples)
    }

    /// The whole safety argument for shipping this is that it can only ever make the
    /// abort fire LATER. Asserted across the range rather than at a single point.
    @Test("the ceiling is non-decreasing in the drain and never below the shipping bar")
    func ceilingNeverShrinks() {
      let base = AudioConstants.minimumTranscriptionSamples
      var previous = 0
      for drain in stride(from: -2_000, through: 8_000, by: 500) {
        let ceiling = manager(drained: drain).allZeroCeilingSamples
        #expect(ceiling >= base)
        #expect(ceiling >= previous)
        previous = ceiling
      }
    }
  }
#endif
