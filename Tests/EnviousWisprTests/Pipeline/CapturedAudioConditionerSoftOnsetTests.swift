import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - CapturedAudioConditionerSoftOnsetTests (#843)
//
// Boundary coverage for soft-onset preservation: when the VAD filter would clip
// a soft leading word ("Actually", "Overall") the conditioner feeds the full
// raw capture to ASR instead. Per `matcher-set-adversarial-tests`, each of the
// three gates (dropped-fraction, first-segment-start, raw-length) is exercised
// just below and just above its threshold, plus the R3 zero-padding guard, the
// real audited takes, and #950 tail integrity.

@Suite("CapturedAudioConditioner soft-onset preservation (#843)")
struct CapturedAudioConditionerSoftOnsetTests {

  // 16 kHz: 8 s = 128_000 samples, 2 s = 32_000, 1 s (ASR minimum) = 16_000.
  private let maxRaw = 128_000
  private let maxFirstStart = 32_000

  private func seg(_ start: Int, _ end: Int) -> SpeechSegment {
    SpeechSegment(startSample: start, endSample: end)
  }

  private func shouldPreserve(raw: Int, filtered: Int, segs: [SpeechSegment]) -> Bool {
    CapturedAudioConditioner.shouldPreserveSoftOnset(
      rawCount: raw, filteredCount: filtered, vadSegments: segs)
  }

  // MARK: dropped-fraction gate (25%)

  @Test("drop exactly at 25% preserves (boundary inclusive)")
  func dropAtThresholdPreserves() {
    // raw 40_000, dropped 10_000 == 0.25 × 40_000 → preserve.
    #expect(shouldPreserve(raw: 40_000, filtered: 30_000, segs: [seg(5_000, 25_000)]))
  }

  @Test("drop just below 25% does NOT preserve")
  func dropJustBelowDoesNotPreserve() {
    // dropped 9_999 < 10_000 → keep filtered.
    #expect(!shouldPreserve(raw: 40_000, filtered: 30_001, segs: [seg(5_000, 25_000)]))
  }

  // MARK: first-segment-start gate (2.0 s)

  @Test("first segment starting just inside 2.0 s preserves")
  func segmentStartJustInsidePreserves() {
    #expect(shouldPreserve(raw: 40_000, filtered: 29_000, segs: [seg(maxFirstStart - 1, 39_000)]))
  }

  @Test("first segment starting at exactly 2.0 s does NOT preserve")
  func segmentStartAtBoundaryDoesNotPreserve() {
    // Guard is `< 32_000`, so 32_000 is a long pre-speech pause, not an onset.
    #expect(!shouldPreserve(raw: 40_000, filtered: 29_000, segs: [seg(maxFirstStart, 39_000)]))
  }

  // MARK: raw-length gate (8.0 s)

  @Test("raw length at exactly 8 s preserves (boundary inclusive)")
  func rawLengthAtBoundaryPreserves() {
    // 25%+ dropped, early start, raw == 128_000.
    #expect(shouldPreserve(raw: maxRaw, filtered: 90_000, segs: [seg(4_000, 100_000)]))
  }

  @Test("raw longer than 8 s does NOT preserve (legitimate silence trim)")
  func rawTooLongDoesNotPreserve() {
    // A long dictation dropping 30% is real trailing silence, not a clipped word.
    #expect(!shouldPreserve(raw: maxRaw + 1, filtered: 90_000, segs: [seg(4_000, 100_000)]))
  }

  // MARK: degenerate inputs

  @Test("no segments does NOT preserve")
  func noSegmentsDoesNotPreserve() {
    #expect(!shouldPreserve(raw: 40_000, filtered: 40_000, segs: []))
  }

  @Test("zero raw does NOT preserve")
  func zeroRawDoesNotPreserve() {
    #expect(!shouldPreserve(raw: 0, filtered: 0, segs: [seg(0, 0)]))
  }

  @Test("earliest of several unsorted segments is what counts")
  func earliestUnsortedSegmentCounts() {
    // Segments out of order; the earliest (5_000) is well inside 2 s → preserve.
    #expect(
      shouldPreserve(
        raw: 40_000, filtered: 26_000, segs: [seg(35_000, 39_000), seg(5_000, 20_000)]))
    // Earliest at 32_000 (== boundary) → not an onset.
    #expect(
      !shouldPreserve(
        raw: 40_000, filtered: 26_000, segs: [seg(35_000, 39_000), seg(maxFirstStart, 38_000)]))
  }

  // MARK: end-to-end condition()

  @Test("soft-onset fires end-to-end: full raw returned, not padded, reason rawSoftOnset")
  func conditionReturnsRawOnSoftOnset() {
    // 41_600 raw (2.6 s) with one early segment; the filter trims ~63% so the
    // soft-onset branch returns the full raw. Mirrors the audited "Actually,
    // let's go for dinner" take (1780524120277).
    let raw = [Float](repeating: 0.1, count: 41_600)
    let result = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(8_000, 20_000)])
    #expect(result.usedRawSoftOnsetPreservation)
    #expect(!result.usedRawFallbackAfterVAD)
    #expect(!result.samplesPaddedToMinimum)
    #expect(result.samples.count == 41_600)
    #expect(result.conditioningReason == "rawSoftOnset")
  }

  @Test("#950 tail integrity: preserved raw equals the original buffer exactly")
  func preservedRawIsByteForByteIdentical() {
    // Distinct ramp so any truncation/reorder is caught, not just a count match.
    var raw = [Float](repeating: 0, count: 41_600)
    for i in raw.indices { raw[i] = Float(i % 97) / 97.0 }
    let result = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(8_000, 20_000)])
    #expect(result.usedRawSoftOnsetPreservation)
    #expect(result.samples == raw)  // full tail preserved, no truncation
  }

  @Test("R3 guard: sub-minimum raw never soft-onset-preserves (no zero-padded raw)")
  func subMinimumRawDoesNotSoftOnsetPreserve() {
    // 12_000 raw (< 16_000 ASR minimum). The SHAPE otherwise qualifies — early
    // segment, ≥25% trim — yet soft-onset must NOT fire, because it would route a
    // sub-minimum buffer into the zero-padding step (the RNNT-loop hazard). The
    // pre-existing path runs instead and pads to the minimum.
    let raw = [Float](repeating: 0.1, count: 12_000)
    // The shape qualifies on its own (only the sub-minimum guard in condition()
    // blocks it):
    #expect(
      CapturedAudioConditioner.shouldPreserveSoftOnset(
        rawCount: 12_000, filteredCount: 8_000, vadSegments: [seg(5_000, 10_000)]))
    let result = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(5_000, 10_000)])
    #expect(!result.usedRawSoftOnsetPreservation)
    #expect(result.samplesPaddedToMinimum)
    #expect(result.samples.count == 16_000)
  }

  @Test("normal long take with small trim stays filtered")
  func longTakeStaysFiltered() {
    // 6 s raw, speech across most of it → filter drops < 25% and stays well above
    // the minimum → filtered audio used, soft-onset does not fire.
    let raw = [Float](repeating: 0.1, count: 96_000)
    let result = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(2_000, 92_000)])
    #expect(!result.usedRawSoftOnsetPreservation)
    #expect(result.conditioningReason == "filtered")
    #expect(result.samples.count < raw.count)  // it really did trim
  }
}
