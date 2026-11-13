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

  // MARK: - #3147 §3.2 sample map through every conditioning path

  /// A ramp, so every sample is distinct and a mis-mapped stretch cannot match by accident.
  private func ramp(_ count: Int) -> [Float] { (0..<count).map { Float($0) } }

  @Test("filtered path: the map is the filter's, and rebuilds the decode samples exactly")
  func timelineFilteredPath() throws {
    let raw = ramp(200_000)
    let out = CapturedAudioConditioner.condition(
      rawSamples: raw, vadSegments: [seg(20_000, 60_000), seg(100_000, 140_000)])

    #expect(out.conditioningReason == "filtered")
    #expect(out.timeline.count == 2, "the VAD gap splits the decode into two stretches")
    #expect(out.timeline.last?.decodeRange.upperBound == out.samples.count)
    try expectTimelineReproducesDecode(decode: out.samples, recording: raw, timeline: out.timeline)
  }

  @Test("raw fallback and soft-onset paths map the whole capture from sample 0")
  func timelineRawPaths() throws {
    // Sparse voicing in a long take: the filtered audio is under the ASR minimum.
    let longRaw = ramp(150_000)
    let fallback = CapturedAudioConditioner.condition(
      rawSamples: longRaw, vadSegments: [seg(50_000, 55_000)])
    #expect(fallback.usedRawFallbackAfterVAD)
    #expect(
      fallback.timeline == [
        DictationAudioTimelineSpan(decodeRange: 0..<150_000, recordingStartSample: 0)
      ])

    // A short take whose filter drops an early-onset prefix keeps the raw capture.
    let shortRaw = ramp(40_000)
    let softOnset = CapturedAudioConditioner.condition(
      rawSamples: shortRaw, vadSegments: [seg(1_000, 20_000)])
    #expect(softOnset.usedRawSoftOnsetPreservation)
    try expectTimelineReproducesDecode(
      decode: softOnset.samples, recording: shortRaw, timeline: softOnset.timeline)
    #expect(softOnset.timeline.map(\.decodeRange) == [0..<40_000])
  }

  @Test("padding to the ASR minimum is never mapped onto the recording")
  func timelineExcludesPadding() throws {
    let raw = ramp(10_000)
    let out = CapturedAudioConditioner.condition(rawSamples: raw, vadSegments: [])

    #expect(out.samplesPaddedToMinimum)
    #expect(out.samples.count == AudioConstants.minimumTranscriptionSamples)
    #expect(
      out.timeline == [DictationAudioTimelineSpan(decodeRange: 0..<10_000, recordingStartSample: 0)])
    try expectTimelineReproducesDecode(decode: out.samples, recording: raw, timeline: out.timeline)
  }
}
