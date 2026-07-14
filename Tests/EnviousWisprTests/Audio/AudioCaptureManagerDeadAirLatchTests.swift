import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - #1317 / #1543 — the reactive dead-air "ineligible" latch, ported
// in-process from the former capture proxy.
//
// The manager feeds the authoritative captured samples into a
// `DeadAirStreamingDetector` on the MainActor (via `ingestSamples`). When an
// all-zero run crosses the confidence threshold AND the frozen input device is
// ineligible (muted, or — as in these unit tests — never frozen, so `nil`), the
// manager latches `zeroSignalDiscriminatorSawIneligible`. The latch is scoped to
// the CURRENT trailing zero-run: a non-zero sample that breaks the run clears
// it, so a muted-then-unmuted stretch cannot blind the kernel's STOP-time
// backstop to a later, unrelated genuine failure. The detector's own tile/zero
// math is covered by `DeadAirStreamingDetectorTests`; this pins the manager's
// latch wiring.
@MainActor
@Suite("AudioCaptureManager dead-air ineligible latch (#1317/#1543)")
struct AudioCaptureManagerDeadAirLatchTests {

  /// A manager armed to ingest without real hardware. No `startEnginePhase`, so
  /// the frozen discriminator device is `nil` — the "ineligible" state a real
  /// muted device produces, driving the fail-closed latch path.
  private func armedManager() -> AudioCaptureManager {
    let manager = AudioCaptureManager()
    manager.isCapturing = true  // internal(set): arm ingest without hardware
    return manager
  }

  @Test("an all-zero run with an ineligible device latches saw-ineligible")
  func allZeroLatchesWhenIneligible() {
    let manager = armedManager()
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)

    // Exactly-zero samples past the minimum-transcription threshold ⇒
    // `isAllZeroFromStart`. Device is nil ⇒ ineligible ⇒ latch sets.
    manager.ingestSamples(
      [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples), level: 0)
    #expect(manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("a non-zero sample breaks the trailing zero-run and clears the latch")
  func nonZeroClearsTheLatch() {
    let manager = armedManager()
    manager.ingestSamples(
      [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples), level: 0)
    #expect(manager.zeroSignalDiscriminatorSawIneligible, "precondition: latched")

    // The muted-then-unmuted negative: real audio breaks the trailing zero-run,
    // so the earlier ineligible result must no longer stick.
    manager.ingestSamples([0.5], level: 0.5)
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("meaningful signal from the start never latches saw-ineligible")
  func realSignalNeverLatches() {
    let manager = armedManager()
    manager.ingestSamples(
      [Float](repeating: 0.5, count: AudioConstants.minimumTranscriptionSamples), level: 0.5)
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)
  }
}
