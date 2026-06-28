import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

@Suite("Tail-clip diagnostics (#1232/#1236) — recalibrated classifier + compute boundaries")
struct TailClipDiagnosticsTests {

  // MARK: - classify(): asr_complete

  @Test("asr_complete: token gap at the <=250 boundary, energetic")
  func completeAtBoundary() {
    #expect(
      TailClipDiagnostics.classify(lastTokenGapMs: 250, tailIsDeadAir: false) == .asrComplete)
  }

  @Test("asr_complete: a dead-air tail is complete even with a huge gap (user trailed off)")
  func completeByDeadAirDespiteGap() {
    #expect(
      TailClipDiagnostics.classify(lastTokenGapMs: 5000, tailIsDeadAir: true) == .asrComplete)
  }

  // MARK: - classify(): suspected_asr_drop

  @Test("asr_drop: token gap at the >=500 boundary, energetic")
  func dropAtBoundary() {
    #expect(
      TailClipDiagnostics.classify(lastTokenGapMs: 500, tailIsDeadAir: false) == .suspectedASRDrop)
  }

  @Test("asr_drop: real-clip magnitude (2825ms energetic tail) is a drop")
  func dropRealClipMagnitude() {
    #expect(
      TailClipDiagnostics.classify(lastTokenGapMs: 2825, tailIsDeadAir: false) == .suspectedASRDrop)
  }

  // MARK: - classify(): unknown

  @Test("unknown: energetic tail in the gray band (250,500)")
  func unknownGrayBand() {
    #expect(
      TailClipDiagnostics.classify(lastTokenGapMs: 400, tailIsDeadAir: false) == .unknown)
  }

  @Test("unknown: no authoritative token gap (nil — non-batch, raw-fed, padded) cannot be judged")
  func unknownNilGap() {
    #expect(TailClipDiagnostics.classify(lastTokenGapMs: nil, tailIsDeadAir: false) == .unknown)
    // nil dominates even if the tail looks dead-air — we still have no gap to judge.
    #expect(TailClipDiagnostics.classify(lastTokenGapMs: nil, tailIsDeadAir: true) == .unknown)
  }

  // MARK: - decodedTailIsVadConfirmed(): the kernel gate that nils the gap on raw-fed input

  @Test("vad-confirmed: genuine VAD trim (no raw-feeding flags, filtered < raw) → true")
  func vadConfirmedGenuineTrim() {
    #expect(
      TailClipDiagnostics.decodedTailIsVadConfirmed(
        usedRawFallbackAfterVAD: false, usedRawSoftOnsetPreservation: false,
        samplesPaddedToMinimum: false, filteredSampleCount: 12000, rawSampleCount: 16000) == true)
  }

  @Test("vad-confirmed: each raw-feeding path → false (fallback / soft-onset / padded / no-op)")
  func vadConfirmedRawFedPathsFalse() {
    // Too-aggressive raw fallback.
    #expect(
      TailClipDiagnostics.decodedTailIsVadConfirmed(
        usedRawFallbackAfterVAD: true, usedRawSoftOnsetPreservation: false,
        samplesPaddedToMinimum: false, filteredSampleCount: 12000, rawSampleCount: 16000) == false)
    // #843 soft-onset raw preservation.
    #expect(
      TailClipDiagnostics.decodedTailIsVadConfirmed(
        usedRawFallbackAfterVAD: false, usedRawSoftOnsetPreservation: true,
        samplesPaddedToMinimum: false, filteredSampleCount: 12000, rawSampleCount: 16000) == false)
    // Short-utterance padding (tail is silence).
    #expect(
      TailClipDiagnostics.decodedTailIsVadConfirmed(
        usedRawFallbackAfterVAD: false, usedRawSoftOnsetPreservation: false,
        samplesPaddedToMinimum: true, filteredSampleCount: 12000, rawSampleCount: 16000) == false)
    // SampleFilter no-op / fully-voiced: filtered == raw (conservatively not confirmed).
    #expect(
      TailClipDiagnostics.decodedTailIsVadConfirmed(
        usedRawFallbackAfterVAD: false, usedRawSoftOnsetPreservation: false,
        samplesPaddedToMinimum: false, filteredSampleCount: 16000, rawSampleCount: 16000) == false)
  }

  // MARK: - compute() (decodedInputSampleCount non-nil simulates the kernel having
  // decided the gap is authoritative + VAD-confirmed)

  @Test("compute: real drop — energetic tail, no trailing silence, large gap → suspected_asr_drop")
  func computeRealDrop() {
    let raw = [Float](repeating: 0.03, count: 16000)  // energetic to the end
    let segs = [SpeechSegment(startSample: 0, endSample: 16000)]  // trailing silence 0
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: segs, decodedInputSampleCount: 16000, lastTokenEndMs: 100)
    #expect(d.trailingSilenceMs == 0)
    #expect(d.asrLastTokenGapMs == 900)
    #expect(d.classification == .suspectedASRDrop)
  }

  @Test("compute: gap is NOT silence-corrected — raw trailing silence does not cancel a drop")
  func computeNoSilenceSubtraction() {
    // asrInput 1000ms, last token 300ms → gap 700ms on the decoded (filtered)
    // timeline; raw trailingSilence (500ms) must NOT be subtracted (Codex P2).
    let raw = [Float](repeating: 0.03, count: 16000)
    let segs = [SpeechSegment(startSample: 0, endSample: 8000)]
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: segs, decodedInputSampleCount: 16000, lastTokenEndMs: 300)
    #expect(d.trailingSilenceMs == 500)
    #expect(d.asrLastTokenGapMs == 700)
    #expect(d.classification == .suspectedASRDrop)
  }

  @Test("compute: dead-air tail is complete even with a large gap; chunked flag set")
  func computeDeadAirLargeGapChunked() {
    let raw = [Float](repeating: 0.0, count: 6400)  // silent tail → dead air
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: [], decodedInputSampleCount: 320_000, lastTokenEndMs: 19000)
    #expect(d.asrInputDurationMs == 20000)
    #expect(d.asrLastTokenGapMs == 1000)
    #expect(d.asrChunked == true)
    #expect(d.classification == .asrComplete)  // dead-air overrides the large gap
  }

  @Test("compute: negative raw token gap is clamped to zero")
  func computeGapClamped() {
    let raw = [Float](repeating: 0.0, count: 100)
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: [], decodedInputSampleCount: 16000, lastTokenEndMs: 1100)
    #expect(d.asrLastTokenGapMs == 0)
  }

  @Test("compute: nil decodedInputSampleCount (non-batch / raw-fed / padded) omits ASR fields")
  func computeOmitsAsrFieldsWhenNotAuthoritative() {
    let raw = [Float](repeating: 0.0, count: 100)
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: [], decodedInputSampleCount: nil, lastTokenEndMs: 5000)
    #expect(d.asrInputDurationMs == nil)
    #expect(d.asrChunked == nil)
    #expect(d.asrLastTokenGapMs == nil)
    #expect(d.classification == .unknown)
  }

  // Window-RMS catch (#964 helper) still matters: a faint last word concentrated in
  // one 40ms window stays below the whole-slice peak/RMS floors but lifts a local
  // window, so the tail is NOT dead-air → large gap routes to suspected_asr_drop.
  @Test("compute: faint last word in one window is NOT dead-air → energetic drop path")
  func computeFaintTailWindowRmsCatch() {
    var raw = [Float](repeating: 0.0, count: 16000)
    for i in 15360..<16000 { raw[i] = 0.003 }  // faint 40ms window at the very end
    let segs = [SpeechSegment(startSample: 0, endSample: 16000)]
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: segs, decodedInputSampleCount: 16000, lastTokenEndMs: 300)
    #expect(d.tail400Peak < RecordingSessionKernel.DeadAirFloor.peak)
    #expect(d.tail400RMS < RecordingSessionKernel.DeadAirFloor.rms)
    #expect(d.asrLastTokenGapMs == 700)
    #expect(d.classification == .suspectedASRDrop)
  }

  @Test("energy: empty slice returns zeros")
  func energyEmpty() {
    let (rms, peak) = TailClipDiagnostics.energy(of: [Float]().suffix(0))
    #expect(rms == 0)
    #expect(peak == 0)
  }
}
