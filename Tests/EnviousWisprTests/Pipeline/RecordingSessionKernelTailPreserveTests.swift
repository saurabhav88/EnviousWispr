import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - RecordingSessionKernelTailPreserveTests (#950)
//
// Boundary coverage for the tail-preserve recovery decision. Two pure statics
// plus one conditioner-append contiguity check:
//   - `tailVoicedFraction`: the hallucination guard. A single transient (desk
//     thump / keyboard clack) in an otherwise-silent tail must score a LOW
//     fraction so recovery is refused before the slice ever reaches ASR.
//   - `tailPreserveDecision`: the gate + refusal-reason taxonomy. Per
//     `matcher-set-adversarial-tests`, every guard is exercised at its boundary
//     and in its NON-intended class (the transient that must be refused), and the
//     first-failing-guard ordering is locked so the reason taxonomy can't drift.
//   - append: filtered + dropped-tail stays contiguous with the internal VAD gap
//     still excluded (surgical, not return-raw).

@Suite("RecordingSessionKernel tail-preserve (#950)")
struct RecordingSessionKernelTailPreserveTests {

  // Reuse the production dead-air window geometry (640 samples = 40 ms @ 16 kHz).
  private let window = RecordingSessionKernel.DeadAirFloor.windowSamples

  // A voiced window clears the window RMS floor (0.002); silence does not.
  private func voicedWindow() -> [Float] { [Float](repeating: 0.01, count: window) }
  private func silentWindow() -> [Float] { [Float](repeating: 0.0, count: window) }

  // MARK: tailVoicedFraction — the hallucination guard (tested FIRST)

  @Test("single loud window in an otherwise-silent 1 s tail scores well below 0.5")
  func singleTransientIsLowFraction() {
    // 1 s = 25 windows; one voiced → 1/25 = 0.04. The desk-thump / keyboard-clack
    // case the founder feared: energetic but NOT sustained voice.
    var slice = [Float](repeating: 0.0, count: 25 * window)
    for i in 0..<window { slice[i] = 0.01 }
    let f = RecordingSessionKernel.tailVoicedFraction(slice)
    #expect(f < 0.5)
    #expect(f == 1.0 / 25.0)
  }

  @Test("a fully-voiced tail scores 1.0")
  func allVoicedIsHighFraction() {
    #expect(
      RecordingSessionKernel.tailVoicedFraction([Float](repeating: 0.01, count: 10 * window)) == 1.0
    )
  }

  @Test("a fully-silent tail scores 0")
  func allSilentIsZero() {
    #expect(
      RecordingSessionKernel.tailVoicedFraction([Float](repeating: 0.0, count: 10 * window)) == 0.0)
  }

  @Test("a slice shorter than one window scores 0 (too short to assess)")
  func subWindowIsZero() {
    #expect(
      RecordingSessionKernel.tailVoicedFraction([Float](repeating: 0.01, count: window - 1)) == 0.0)
  }

  @Test("exactly half the windows voiced scores 0.5 (boundary)")
  func exactlyHalfIsBoundary() {
    // 4 windows, 2 voiced → 0.5, which clears the >= 0.5 gate.
    let slice = voicedWindow() + silentWindow() + voicedWindow() + silentWindow()
    #expect(RecordingSessionKernel.tailVoicedFraction(slice) == 0.5)
  }

  // MARK: tailPreserveDecision — gate + refusal-reason taxonomy

  private func decide(
    eligible: Bool = true, reason: String = "filtered",
    droppedSamples: Int = 6_400, droppedMs: Int = 400, fraction: Double = 0.9
  ) -> RecordingSessionKernel.TailPreserveDecision {
    RecordingSessionKernel.tailPreserveDecision(
      tailEligible: eligible, conditioningReason: reason,
      droppedTailSamples: droppedSamples, droppedTailMs: droppedMs, voicedFraction: fraction)
  }

  @Test("eligible, filtered, in-window, sustained voice → preserve")
  func happyPathPreserves() {
    #expect(decide(droppedMs: 400, fraction: 0.6) == .preserve)
  }

  @Test("floor boundary: 400 ms preserves, 399 ms refuses too_short")
  func floorBoundary() {
    #expect(decide(droppedMs: 400) == .preserve)
    #expect(decide(droppedMs: 399) == .refuse(reason: "too_short"))
  }

  @Test("cap boundary: 8000 ms preserves, 8001 ms refuses too_long")
  func capBoundary() {
    #expect(decide(droppedMs: 8_000) == .preserve)
    #expect(decide(droppedMs: 8_001) == .refuse(reason: "too_long"))
  }

  @Test("the transient case: in-window but fraction 0.3 refuses low_voiced_fraction")
  func transientRefused() {
    // The founder's #1 risk, at the decision layer: energetic but not sustained
    // voice → refused, never appended.
    #expect(decide(droppedMs: 1_000, fraction: 0.3) == .refuse(reason: "low_voiced_fraction"))
  }

  @Test("fraction boundary: exactly 0.5 preserves, just under refuses")
  func fractionBoundary() {
    #expect(decide(droppedMs: 1_000, fraction: 0.5) == .preserve)
    #expect(decide(droppedMs: 1_000, fraction: 0.4999) == .refuse(reason: "low_voiced_fraction"))
  }

  @Test("zero dropped tail refuses no_tail")
  func noTailRefused() {
    #expect(decide(droppedSamples: 0, droppedMs: 0, fraction: 0.0) == .refuse(reason: "no_tail"))
  }

  @Test("ineligible engine → notEvaluated (keeps usedTailPreservation nil)")
  func ineligibleNotEvaluated() {
    #expect(decide(eligible: false) == .notEvaluated)
  }

  @Test("non-filtered conditioner paths refuse not_filtered (no double-append on raw/padded)")
  func nonFilteredRefused() {
    for r in ["rawSoftOnset", "rawFallbackTooAggressive", "filteredPaddedToMinimum"] {
      #expect(decide(reason: r, droppedMs: 1_000) == .refuse(reason: "not_filtered"))
    }
  }

  // MARK: guard ORDER (first-failing-guard names the reason)

  @Test("ineligible wins over every later failure")
  func ineligibleWinsOrder() {
    // ineligible AND non-filtered AND zero-tail at once → notEvaluated.
    #expect(
      decide(
        eligible: false, reason: "rawSoftOnset", droppedSamples: 0, droppedMs: 0, fraction: 0.0)
        == .notEvaluated)
  }

  @Test("not_filtered wins over too_short")
  func notFilteredWinsOrder() {
    // eligible AND non-filtered AND too-short at once → not_filtered.
    #expect(
      decide(reason: "filteredPaddedToMinimum", droppedMs: 100) == .refuse(reason: "not_filtered"))
  }

  // MARK: append contiguity (surgical — internal VAD gap stays excluded)

  @Test("filtered + dropped tail is contiguous and the internal VAD gap stays trimmed")
  func appendContiguity() {
    // Two voiced segments with a 5000-sample internal gap, plus a long trailing
    // region the trim discards. Recovery = filtered + raw.suffix(dropped); it must
    // append exactly the trailing region while the internal gap + leading silence
    // stay excluded (the surgical property vs return-raw).
    let rawCount = 200_000
    var raw = [Float](repeating: 0, count: rawCount)
    for i in 0..<rawCount { raw[i] = Float(i % 257) * 0.001 }  // distinguishable per index
    let segs = [
      SpeechSegment(startSample: 40_000, endSample: 70_000),
      SpeechSegment(startSample: 75_000, endSample: 120_000),
    ]
    let cond = CapturedAudioConditioner.condition(rawSamples: raw, vadSegments: segs)
    let dropped = cond.droppedTailSampleCount
    #expect(dropped > 0)
    let tailSlice = Array(raw.suffix(dropped))
    let recovered = cond.samples + tailSlice
    // (1) append arithmetic.
    #expect(recovered.count == cond.samples.count + dropped)
    // (2) internal gap + leading silence stayed excluded → recovered shorter than raw.
    #expect(recovered.count < rawCount)
    // (3) head unchanged: the filtered buffer is the prefix, untouched by the append.
    #expect(Array(recovered.prefix(cond.samples.count)) == cond.samples)
    // (4) the appended region is exactly the raw trailing slice.
    #expect(Array(recovered.suffix(dropped)) == Array(raw[(rawCount - dropped)..<rawCount]))
  }
}
