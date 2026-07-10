import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - #1408 A3 — the hard sample-count backstop is a NORMAL stop

/// The manager's last-ditch cap (3660s of samples) used to fire
/// `onEngineInterrupted(.maxDurationReached)` — an interruption that stamped a
/// cause, floored terminals, and emitted loss telemetry for a recording that
/// ended normally. It now stops appending locally and fires
/// `onMaxDurationReached` exactly once, feeding the same typed `.maxDuration`
/// stop the graceful wall-clock cap uses.
///
/// The production threshold is 58,560,000 samples — unreachable in a unit test
/// — so `maxRecordingSamplesLimit` is instance-injectable (the seam grounded
/// review r1 demanded; a closure-level test cannot exercise the real check).
@MainActor
@Suite("AudioCaptureManager max-duration backstop (#1408 A3)")
struct AudioCaptureManagerMaxDurationBackstopTests {

  private func makeCappedManager(limit: Int) -> (
    manager: AudioCaptureManager, fired: () -> Int, interrupted: () -> Int
  ) {
    let manager = AudioCaptureManager()
    manager.maxRecordingSamplesLimit = limit
    var maxDurationFires = 0
    var interruptionFires = 0
    manager.onMaxDurationReached = { maxDurationFires += 1 }
    manager.onEngineInterrupted = { _ in interruptionFires += 1 }
    manager.isCapturing = true  // arm ingest without real hardware (internal(set))
    return (manager, { maxDurationFires }, { interruptionFires })
  }

  @Test("crossing the limit stops capture and fires onMaxDurationReached exactly once")
  func capFiresExactlyOnce() {
    let (manager, fired, interrupted) = makeCappedManager(limit: 8)

    manager.ingestSamples([Float](repeating: 0, count: 5), level: 0.4)
    #expect(fired() == 0, "below the limit nothing fires")
    #expect(manager.isCapturing)

    manager.ingestSamples([Float](repeating: 0, count: 5), level: 0.4)
    #expect(fired() == 1, "crossing the limit fires the normal-stop callback")
    #expect(!manager.isCapturing, "the backstop stops appending locally")
    #expect(manager.audioLevel == 0.0)

    // A straggler batch after the cap is ignored (the isCapturing guard is the
    // exactly-once mechanism, same as the production wiring closure's guard).
    manager.ingestSamples([Float](repeating: 0, count: 5), level: 0.4)
    #expect(fired() == 1, "no second fire after the cap")
    #expect(manager.capturedSamples.count == 10, "post-cap samples are not appended")

    #expect(interrupted() == 0, "the cap must NEVER fire the interruption channel")
  }

  @Test("the accumulated samples survive the cap and are returned by stopCapture")
  func samplesSurviveTheCap() async {
    let (manager, fired, _) = makeCappedManager(limit: 4)
    manager.ingestSamples([1, 2, 3, 4], level: 0.4)
    #expect(fired() == 1)

    // stopCapture has no isCapturing guard: the capped recording's audio is
    // still the user's words and still comes back for transcription.
    let result = await manager.stopCapture()
    #expect(result.samples == [1, 2, 3, 4])
  }

  @Test("ingest is inert while not capturing")
  func ingestRequiresCapturing() {
    let manager = AudioCaptureManager()
    manager.maxRecordingSamplesLimit = 2
    var fires = 0
    manager.onMaxDurationReached = { fires += 1 }

    manager.ingestSamples([1, 2, 3], level: 0.5)
    #expect(manager.capturedSamples.isEmpty)
    #expect(fires == 0)
  }

  /// The production threshold invariant: the backstop must sit strictly above
  /// the graceful wall-clock cap so the graceful stop always wins when healthy.
  /// (The primary freeze lives in `RecordingCapInvariantTests`; this pins the
  /// injectable seam's default to the production constant.)
  @Test("the injectable limit defaults to the production constant")
  func seamDefaultsToProduction() {
    let manager = AudioCaptureManager()
    #expect(manager.maxRecordingSamplesLimit == AudioCaptureManager.maxRecordingSamples)
  }
}
