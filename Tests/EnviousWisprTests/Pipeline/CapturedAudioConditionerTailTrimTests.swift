import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - CapturedAudioConditionerTailTrimTests (#950)
//
// Boundary coverage for the tail-trim diagnostic `droppedTrailingSamples` and the
// `ConditionedAudio.droppedTailSampleCount` field. The helper must MIRROR
// `SampleFilter.filter`'s no-op rules exactly (skip malformed segments; return 0
// when total valid voiced < 4800), else it would report a phantom drop the filter
// never made. All counts are 16 kHz mono scalar samples (1600 = 100 ms padding).

@Suite("CapturedAudioConditioner tail-trim diagnostic (#950)")
struct CapturedAudioConditionerTailTrimTests {

  private func seg(_ start: Int, _ end: Int) -> SpeechSegment {
    SpeechSegment(startSample: start, endSample: end)
  }

  private func dropped(_ raw: Int, _ segs: [SpeechSegment]) -> Int {
    CapturedAudioConditioner.droppedTrailingSamples(rawSampleCount: raw, vadSegments: segs)
  }

  // MARK: no-op mirrors (helper returns 0 where SampleFilter returns raw)

  @Test("no segments → 0")
  func noSegments() {
    #expect(dropped(100_000, []) == 0)
  }

  @Test("malformed-only segments (end <= start) → 0 (skipped, sub-4800)")
  func malformedOnly() {
    #expect(dropped(100_000, [seg(5_000, 5_000), seg(9_000, 4_000)]) == 0)
  }

  @Test("valid voiced just below 4800 → 0 (SampleFilter no-op gate)")
  func subThresholdVoiced() {
    // 4799 voiced < 4800 → filter returns raw → no drop.
    #expect(dropped(100_000, [seg(0, 4_799)]) == 0)
  }

  @Test("valid voiced exactly 4800 → drops (boundary inclusive)")
  func thresholdVoicedInclusive() {
    // voiced 4800 ≥ 4800; lastEnd 4800, padded 6400, dropped 100_000-6400.
    #expect(dropped(100_000, [seg(0, 4_800)]) == 93_600)
  }

  // MARK: tail math

  @Test("mid-buffer last segment, gap > padding → dropped = raw-(end+1600)")
  func midBufferDrop() {
    #expect(dropped(100_000, [seg(1_000, 50_000)]) == 48_400)
  }

  @Test("last segment ends at rawCount → 0 (padding clamps to rawCount)")
  func endsAtRaw() {
    #expect(dropped(50_000, [seg(1_000, 50_000)]) == 0)
  }

  @Test("padded end exceeds rawCount → 0 (clamp)")
  func paddedEndPastRaw() {
    // lastEnd 50_000, padded 51_600 > raw 51_000 → keptThrough clamps to raw.
    #expect(dropped(51_000, [seg(1_000, 50_000)]) == 0)
  }

  @Test("unsorted segments → uses max valid endSample, not last element")
  func unsortedUsesMaxEnd() {
    // Out-of-order; max end is 70_000 → dropped = 100_000-(70_000+1600).
    #expect(dropped(100_000, [seg(60_000, 70_000), seg(1_000, 50_000)]) == 28_400)
  }

  // MARK: condition() integration — the raw-keeping paths report 0

  @Test("soft-onset path → droppedTailSampleCount 0 (full raw kept)")
  func softOnsetReportsZero() {
    // raw 40_000 (≤8s), seg starts at 5_000 (<2s), filter drops ≥25% → soft-onset
    // fires, working = full raw → nothing dropped.
    let raw = [Float](repeating: 0.1, count: 40_000)
    let out = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(5_000, 25_000)])
    #expect(out.usedRawSoftOnsetPreservation)
    #expect(out.droppedTailSampleCount == 0)
  }

  @Test("too-aggressive raw fallback → droppedTailSampleCount 0 (full raw kept)")
  func rawFallbackReportsZero() {
    // raw 130_000 (>8s so soft-onset's maxRaw gate fails), tiny voiced segment so
    // filtered < 16_000 → raw fallback fires, working = full raw → nothing dropped.
    let raw = [Float](repeating: 0.1, count: 130_000)
    let out = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(1_000, 6_000)])
    #expect(out.usedRawFallbackAfterVAD)
    #expect(out.droppedTailSampleCount == 0)
  }

  @Test("normal long-dictation trim → droppedTailSampleCount is the trailing gap")
  func normalTrimReportsDrop() {
    // raw 200_000 (>8s, no soft-onset), filtered ≥ minimum (no fallback): the
    // genuine trailing-trim case the #950 diagnostic exists to catch.
    let raw = [Float](repeating: 0.1, count: 200_000)
    let out = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(1_000, 150_000)])
    #expect(!out.usedRawSoftOnsetPreservation)
    #expect(!out.usedRawFallbackAfterVAD)
    #expect(out.droppedTailSampleCount == 48_400)  // 200_000 - (150_000 + 1600)
  }
}
