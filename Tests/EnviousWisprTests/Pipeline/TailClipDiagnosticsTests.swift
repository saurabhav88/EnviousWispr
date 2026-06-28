import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

@Suite("Tail-clip diagnostics (#1232) — classifier + compute boundaries")
struct TailClipDiagnosticsTests {

  // MARK: - clean

  @Test("Clean: trailing silence >= 150ms wins regardless of tail energy")
  func cleanBySilence() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 150, tailIsDeadAir: false, lastTokenGapMs: 0) == .clean)
  }

  @Test("Clean: dead-air tail even with zero trailing silence")
  func cleanByDeadAir() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 0, tailIsDeadAir: true, lastTokenGapMs: 0) == .clean)
  }

  // MARK: - suspected capture clip

  @Test("Capture clip: gate satisfied + token gap at the <=300 boundary")
  func clipByTokenGapBoundary() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 0, tailIsDeadAir: false, lastTokenGapMs: 300)
        == .suspectedCaptureClip)
  }

  @Test("Capture clip: gate satisfied at 40ms boundary + small token gap")
  func clipAtGateBoundary() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 40, tailIsDeadAir: false, lastTokenGapMs: 100)
        == .suspectedCaptureClip)
  }

  // MARK: - suspected ASR drop

  @Test("ASR drop: gate satisfied, token gap at the >=500 boundary")
  func dropByTokenGapBoundary() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 0, tailIsDeadAir: false, lastTokenGapMs: 500)
        == .suspectedASRDrop)
  }

  // MARK: - unknown

  @Test("Unknown: gate satisfied but token gap in the ambiguous (300,500) band")
  func unknownAmbiguousGap() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 0, tailIsDeadAir: false, lastTokenGapMs: 400) == .unknown)
  }

  @Test(
    "Unknown: energetic tail but no VAD segment (nil trailing silence) cannot establish the gate")
  func unknownNoGate() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: nil, tailIsDeadAir: false, lastTokenGapMs: 100)
        == .unknown)
  }

  @Test("Unknown: gate satisfied, energetic tail, but no token gap available")
  func unknownNoGap() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 0, tailIsDeadAir: false, lastTokenGapMs: nil) == .unknown)
  }

  @Test("Gate boundary: trailing silence just over the gate (41ms) with small gap is unknown")
  func gateJustAbove() {
    #expect(
      TailClipDiagnostics.classify(
        trailingSilenceMs: 41, tailIsDeadAir: false, lastTokenGapMs: 100)
        == .unknown)
  }

  // MARK: - compute()

  @Test("compute: trailing silence = (rawCount - lastVadEnd) / 16, and energetic tail")
  func computeTrailingSilence() {
    var raw = [Float](repeating: 0.03, count: 16000)  // 1000ms
    raw[15999] = 0.2
    let segs = [SpeechSegment(startSample: 0, endSample: 15040)]  // 960 samples tail = 60ms
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: segs, decodedInputSampleCount: 16000, lastTokenEndMs: nil)
    #expect(d.trailingSilenceMs == 60)
    #expect(d.tail200Peak > RecordingSessionKernel.DeadAirFloor.peak)
  }

  @Test("compute: token gap = inputDuration - lastTokenEnd; chunked threshold")
  func computeTokenGapAndChunk() {
    let raw = [Float](repeating: 0.0, count: 100)
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: [], decodedInputSampleCount: 320_000, lastTokenEndMs: 19000)
    #expect(d.asrInputDurationMs == 20000)
    #expect(d.asrLastTokenGapMs == 1000)
    #expect(d.asrChunked == true)
    #expect(d.trailingSilenceMs == nil)
  }

  @Test("compute: negative raw token gap is clamped to zero")
  func computeGapClamped() {
    let raw = [Float](repeating: 0.0, count: 100)
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: [], decodedInputSampleCount: 16000, lastTokenEndMs: 1100)
    #expect(d.asrLastTokenGapMs == 0)
  }

  @Test(
    "compute: non-authoritative decoded input (WhisperKit/streaming/padded) omits ASR-input fields")
  func computeOmitsAsrFieldsWhenNotAuthoritative() {
    let raw = [Float](repeating: 0.0, count: 100)
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: [], decodedInputSampleCount: nil, lastTokenEndMs: 5000)
    #expect(d.asrInputDurationMs == nil)
    #expect(d.asrChunked == nil)
    #expect(d.asrLastTokenGapMs == nil)
  }

  // Codex P2 regression: a faint last word concentrated in ONE 40ms window has
  // peak and whole-400ms-slice RMS below the dead-air floors, but its local
  // window RMS clears `windowRms` — so the shared #964 helper reports NOT
  // dead-air and the clip is no longer hidden as `.clean`. With the gate
  // satisfied and a small token gap, it classifies as a suspected capture clip.
  @Test("compute: faint last word in one window is NOT dead-air (window-RMS catch)")
  func computeFaintTailWindowRmsCatch() {
    // 400ms tail = 6400 samples, silent except the final 640-sample (40ms)
    // window at 0.003: window RMS 0.003 >= 0.002 floor; whole-slice RMS
    // ~0.00095 < 0.00125; peak 0.003 < 0.006 → only the window check trips.
    var raw = [Float](repeating: 0.0, count: 6400)
    for i in 5760..<6400 { raw[i] = 0.003 }
    let segs = [SpeechSegment(startSample: 0, endSample: 6400)]  // trailing silence 0 → gate satisfied
    let d = TailClipDiagnostics.compute(
      rawSamples: raw, vadSegments: segs, decodedInputSampleCount: 6400, lastTokenEndMs: 300)
    #expect(d.trailingSilenceMs == 0)
    // The scalar-only check (peak + whole-400ms RMS) would have called this
    // dead air — both clear the floor — yet the loudest-window RMS does not.
    #expect(d.tail400Peak < RecordingSessionKernel.DeadAirFloor.peak)
    #expect(d.tail400RMS < RecordingSessionKernel.DeadAirFloor.rms)
    #expect(d.asrLastTokenGapMs == 100)
    #expect(d.classification == .suspectedCaptureClip)
  }

  @Test("energy: empty slice returns zeros")
  func energyEmpty() {
    let (rms, peak) = TailClipDiagnostics.energy(of: [Float]().suffix(0))
    #expect(rms == 0)
    #expect(peak == 0)
  }
}
