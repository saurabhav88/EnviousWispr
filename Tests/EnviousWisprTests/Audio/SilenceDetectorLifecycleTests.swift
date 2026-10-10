@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #1224: retention-lifecycle tests for the audio-service's now-persistent
/// `SilenceDetector`: the silence timeout's hangover length, and `reset()`
/// preserving the loaded model across sessions.
/// Reuses the `#905` `FakeStreamingVad` seam (declared in
/// `SilenceDetectorBoundaryTests.swift`) so no real CoreML model is needed.
@Suite("SilenceDetector lifecycle")
struct SilenceDetectorTests {

  /// Deterministic config: emaAlpha=1.0 means smoothed == raw input, so one
  /// loud chunk triggers speech and one quiet chunk starts the hangover
  /// countdown — the same shape as `SilenceDetectorBoundaryTests`'
  /// `lockingTestConfig`.
  private static func lockingConfig() -> SmoothedVADConfig {
    SmoothedVADConfig(
      emaAlpha: 1.0,
      onsetThreshold: 0.5,
      offsetThreshold: 0.4,
      onsetConfirmationChunks: 1,
      hangoverChunks: 3,
      prebufferChunks: 0,
      energyGateThreshold: 0.0
    )
  }

  /// Feeds one loud chunk (enters speech) then quiet chunks until
  /// `advanceStateMachine` reports auto-stop; returns how many quiet chunks
  /// it took.
  private func quietChunksUntilAutoStop(_ detector: SilenceDetector) async -> Int {
    _ = await detector.advanceStateMachine(
      rawProbability: 0.9, samplesInChunk: SilenceDetector.chunkSize)
    for i in 1...20 {
      let stopped = await detector.advanceStateMachine(
        rawProbability: 0.0, samplesInChunk: SilenceDetector.chunkSize)
      if stopped { return i }
    }
    return -1
  }

  @Test("the silence timeout sets how many quiet chunks pass before auto-stop")
  func silenceTimeoutSetsHangover() async throws {
    // silenceTimeout picked mid-interval (2.5 and 5.5 chunk-widths) so
    // ceil()'s result is unambiguous under floating-point error.
    func stopAt(timeout: TimeInterval) async throws -> Int {
      let fake = FakeStreamingVad()
      let detector = SilenceDetector(
        silenceTimeout: timeout, vadConfig: Self.lockingConfig(),
        makeStreamingVad: { fake }
      )
      try await detector.prepare()
      return await quietChunksUntilAutoStop(detector)
    }

    // effectiveHangoverChunks = max(3, ceil(0.64/0.256)) = 3 -> stop on the
    // 4th quiet chunk (3 countdown chunks + the one that hits zero).
    #expect(try await stopAt(timeout: 0.256 * 2.5) == 4)
    // effectiveHangoverChunks = max(3, ceil(1.408/0.256)) = 6 -> stop on the
    // 7th quiet chunk. A changed timeout reaches production through a NEW
    // detector: CaptureVADSignalSource.configureSession drops the retained one.
    #expect(try await stopAt(timeout: 0.256 * 5.5) == 7)
  }

  @Test("reset() clears streaming state but leaves the loaded model intact")
  func resetPreservesLoadedModel() async throws {
    let fake = FakeStreamingVad()
    let detector = SilenceDetector(
      vadConfig: Self.lockingConfig(),
      makeStreamingVad: { fake }
    )
    try await detector.prepare()
    #expect(await detector.isReady)

    // Leave some per-session state behind: a speech boundary and a
    // mid-hangover phase (via advanceStateMachine), then reset.
    await detector.applyStreamBoundary(VadStreamEvent(kind: .speechStart, sampleIndex: 4_096))
    _ = await detector.advanceStateMachine(
      rawProbability: 0.9, samplesInChunk: SilenceDetector.chunkSize)

    await detector.reset()

    // Streaming state cleared...
    #expect(await detector.speechSegments.isEmpty)
    #expect(await detector.speechDetected == false)
    // ...but the model is still loaded -- `prepare()` is idempotent and
    // would be a silent no-op if called again, and processChunk still routes
    // through the SAME fake instance (no reconstruction happened).
    #expect(await detector.isReady)
    try await detector.prepare()  // no-op if still ready; would re-throw if reconstruction had cleared vadManager
    #expect(await detector.isReady)
  }
}
