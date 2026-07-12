import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - RecordingSessionKernelDeadAirFloorTests (#964)
//
// Boundary coverage for `RecordingSessionKernel.rawAudioIsDeadAir`, the
// energy floor that decides whether a `.confirmedNoSpeech` (zero VAD segments)
// capture is genuinely silent (skip ASR) or faint speech to recover (fall
// through to Parakeet). Per `matcher-set-adversarial-tests`, each of the three
// thresholds (peak / whole-buffer RMS / loudest-40 ms-window RMS) is exercised
// just-below and just-above, plus the realistic faint-whisper and dead-air
// shapes the floor was tuned against.

@Suite("RecordingSessionKernel dead-air floor (#964)")
struct RecordingSessionKernelDeadAirFloorTests {

  /// Mirror the kernel's own peak input (`rawPeakAudioLevel` = max abs sample).
  private func peak(_ samples: [Float]) -> Float {
    samples.reduce(Float(0)) { max($0, abs($1)) }
  }

  private func isDeadAir(_ samples: [Float]) -> Bool {
    RecordingSessionKernel.rawAudioIsDeadAir(samples, peak: peak(samples))
  }

  // MARK: Peak threshold (0.006)

  @Test("uniform sub-floor buffer is dead air")
  func uniformSubFloorIsDeadAir() {
    // 0.001 < every threshold → dead air.
    #expect(isDeadAir([Float](repeating: 0.001, count: 16_000)))
  }

  @Test("a single sample just above the peak floor is NOT dead air")
  func peakJustAboveIsNotDeadAir() {
    // One loud sample (0.0061 ≥ 0.006) in otherwise-silent audio → recover.
    var samples = [Float](repeating: 0.0, count: 16_000)
    samples[8_000] = 0.0061
    #expect(!isDeadAir(samples))
  }

  // MARK: Whole-buffer RMS threshold (0.00125)

  @Test("uniform amplitude just below the RMS floor is dead air")
  func rmsJustBelowIsDeadAir() {
    // 0.0011 < peak floor, < RMS floor, < window floor → dead air.
    #expect(isDeadAir([Float](repeating: 0.0011, count: 16_000)))
  }

  @Test("uniform amplitude above the RMS floor (but below peak) is NOT dead air")
  func rmsJustAboveIsNotDeadAir() {
    // 0.0013: peak 0.0013 < 0.006, but RMS 0.0013 > 0.00125 → recover.
    #expect(!isDeadAir([Float](repeating: 0.0013, count: 16_000)))
  }

  // MARK: Loudest-window RMS threshold (0.002) — the faint-word case

  @Test("a faint word inside silence is recovered (window RMS above floor)")
  func faintWordInSilenceIsNotDeadAir() {
    // Whole-buffer RMS stays tiny, but a 40 ms (640-sample) burst at 0.003
    // raises a local window above the 0.002 window floor → recover. This is the
    // headline #964 case: a soft leading word the whole-buffer average hides.
    // The burst is aligned to the 640-sample tile grid (3840 = 6 × 640) so it
    // fully occupies one window.
    var samples = [Float](repeating: 0.0, count: 16_000)
    for i in 3_840..<4_480 { samples[i] = 0.003 }
    // Sanity: peak and whole-buffer RMS are both below their floors here, so
    // ONLY the window check can save this buffer.
    #expect(peak(samples) < RecordingSessionKernel.DeadAirFloor.peak)
    #expect(!isDeadAir(samples))
  }

  @Test("a window just below the window floor is still dead air")
  func windowJustBelowIsDeadAir() {
    // 0.0019 burst: peak/whole-RMS tiny, window RMS 0.0019 < 0.002 → dead air.
    var samples = [Float](repeating: 0.0, count: 16_000)
    for i in 3_840..<4_480 { samples[i] = 0.0019 }
    #expect(isDeadAir(samples))
  }

  @Test("a window just above the window floor is NOT dead air")
  func windowJustAboveIsNotDeadAir() {
    // 0.0021 burst: window RMS 0.0021 > 0.002 → recover.
    var samples = [Float](repeating: 0.0, count: 16_000)
    for i in 3_840..<4_480 { samples[i] = 0.0021 }
    #expect(!isDeadAir(samples))
  }

  // MARK: Degenerate + realistic shapes

  @Test("empty buffer is dead air")
  func emptyBufferIsDeadAir() {
    #expect(RecordingSessionKernel.rawAudioIsDeadAir([], peak: 0))
  }

  @Test("a buffer shorter than one window falls back to RMS-vs-window-floor")
  func subWindowBufferUsesRmsFallback() {
    // 320 samples (< 640-sample window) at 0.001 → RMS 0.001 < 0.002 → dead air.
    #expect(isDeadAir([Float](repeating: 0.001, count: 320)))
    // 320 samples at 0.0025 → peak 0.0025 < 0.006, but RMS 0.0025 > 0.00125
    // → recover (RMS gate fires before the sub-window fallback).
    #expect(!isDeadAir([Float](repeating: 0.0025, count: 320)))
  }

  @Test("a realistic faint whisper (peak ~0.011) is NOT dead air")
  func realisticFaintWhisperIsNotDeadAir() {
    // The measured faint-whisper peak (0.0109) sits above the peak floor — the
    // exact speech #964 must stop dropping.
    var samples = [Float](repeating: 0.0, count: 16_000)
    for i in 2_000..<10_000 { samples[i] = (i % 2 == 0) ? 0.011 : -0.011 }
    #expect(!isDeadAir(samples))
  }

  @Test("realistic room-tone dead air stays gated")
  func realisticRoomToneIsDeadAir() {
    // Low-level room tone: peak 0.004 < floor, with tiny broadband RMS.
    var samples = [Float](repeating: 0.0, count: 16_000)
    for i in samples.indices { samples[i] = (i % 7 == 0) ? 0.0008 : 0.0002 }
    #expect(peak(samples) < RecordingSessionKernel.DeadAirFloor.peak)
    #expect(isDeadAir(samples))
  }

  // MARK: - trailingZeroSuffixCount (#1317 fast-follow)

  @Test("trailingZeroSuffixCount: no trailing zero is 0")
  func trailingZeroSuffixCountNoZeroIsZero() {
    #expect(RecordingSessionKernel.trailingZeroSuffixCount([0.1, 0.2, 0.3]) == 0)
  }

  @Test("trailingZeroSuffixCount: counts only the trailing run, not an interior zero")
  func trailingZeroSuffixCountStopsAtFirstNonZeroFromEnd() {
    #expect(RecordingSessionKernel.trailingZeroSuffixCount([0.1, 0, 0.2, 0, 0]) == 2)
  }

  @Test("trailingZeroSuffixCount: an all-zero buffer counts every sample")
  func trailingZeroSuffixCountAllZero() {
    #expect(
      RecordingSessionKernel.trailingZeroSuffixCount([Float](repeating: 0, count: 100)) == 100)
  }

  @Test("trailingZeroSuffixCount: an empty buffer is 0")
  func trailingZeroSuffixCountEmpty() {
    #expect(RecordingSessionKernel.trailingZeroSuffixCount([]) == 0)
  }

  // MARK: - classifyZeroSignalAtStop dilution guard (#1317 fast-follow)
  //
  // Cloud review's own example: "16k samples around 0.0013" — an amplitude
  // that clears the whole-buffer RMS floor (0.00125) ALONE (see
  // `rmsJustAboveIsNotDeadAir` above) but, once diluted by an appended
  // exact-zero suffix, drags the combined whole-buffer RMS below the floor,
  // falling through to the loudest-window check — which this same amplitude
  // (0.0013 < the 0.002 window floor) ALSO fails. That is the reported bug:
  // a real quiet utterance silently discarded once the mic-glitch's zero
  // tail is averaged in. `classifyZeroSignalAtStop` must still recognize
  // this shape (it evaluates the prefix alone); the trim (proven below and
  // exercised end-to-end in ZeroSignalRecoveryTests) is what keeps the
  // no-speech gate from re-diluting it downstream.

  @Test(
    "classifyZeroSignalAtStop: a quiet prefix that clears the RMS floor alone still classifies as becameZeroMidCapture"
  )
  func classifyZeroSignalAtStopRecognizesQuietPrefix() {
    var samples = [Float](repeating: 0.0013, count: 16_000)
    samples.append(contentsOf: [Float](repeating: 0, count: 16_000))
    #expect(RecordingSessionKernel.classifyZeroSignalAtStop(samples) == .becameZeroMidCapture)
  }

  @Test(
    "the zero-suffix dilution is real (whole buffer reads dead air) and trimming to the prefix fixes it"
  )
  func wholeBufferDilutionIsRealAndTrimFixesIt() {
    var samples = [Float](repeating: 0.0013, count: 16_000)
    samples.append(contentsOf: [Float](repeating: 0, count: 16_000))
    // Before the trim: the kernel's no-speech gate sees this whole buffer —
    // dead air, incorrectly (the reported bug).
    #expect(isDeadAir(samples))
    // After the trim the fast-follow now applies before that gate runs: the
    // same prefix alone is NOT dead air — the words survive.
    let suffixCount = RecordingSessionKernel.trailingZeroSuffixCount(samples)
    let trimmed = Array(samples.dropLast(suffixCount))
    #expect(!isDeadAir(trimmed))
  }

  // MARK: - clampSegments (#1317 fast-follow, Grounded Review r1)

  @Test("clampSegments: an in-range segment passes through unchanged")
  func clampSegmentsInRangePassesThrough() {
    let result = RecordingSessionKernel.clampSegments(
      [SpeechSegment(startSample: 0, endSample: 8_000)], to: 24_000)
    #expect(result.count == 1)
    #expect(result[0].startSample == 0)
    #expect(result[0].endSample == 8_000)
  }

  @Test(
    "clampSegments: an open segment finalized at the original full sample count is clamped to the trim boundary"
  )
  func clampSegmentsClampsOpenSegmentPastTrimBoundary() {
    // Mirrors SilenceDetector.finalizeSegments closing an open segment at
    // the ORIGINAL raw sample count when the zero-signal reactive detector's
    // 1s confidence window fires before VAD's own 1.5s silence timeout ever
    // closes the segment (Grounded Review r1).
    let result = RecordingSessionKernel.clampSegments(
      [SpeechSegment(startSample: 0, endSample: 24_000)], to: 8_000)
    #expect(result.count == 1)
    #expect(result[0].startSample == 0)
    #expect(result[0].endSample == 8_000)
  }

  @Test("clampSegments: a segment starting entirely past the trim boundary is dropped")
  func clampSegmentsDropsSegmentEntirelyPastBoundary() {
    let result = RecordingSessionKernel.clampSegments(
      [SpeechSegment(startSample: 20_000, endSample: 24_000)], to: 8_000)
    #expect(result.isEmpty)
  }
}
