import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - #1434 degraded-lead trim-candidate detector
//
// Pure-compute tests over synthetic 16 kHz buffers shaped like the measured
// failure signature (healthy burst → near-zero window with faint residue →
// recovery). Thresholds under test are the empirically chosen constants in
// `DegradedLeadDiagnostics`; the real-audio validation lives in the issue's
// offline replay recipe (founder-voice corpus stays local, never committed).

@Suite("DegradedLeadDiagnostics — #1434")
struct DegradedLeadDiagnosticsTests {

  private let rate = 16000.0

  /// Constant-amplitude segment helper.
  private func seg(_ seconds: Double, _ amplitude: Float) -> [Float] {
    [Float](repeating: amplitude, count: Int(seconds * rate))
  }

  /// The measured failure shape: leading silence, one healthy burst, a long
  /// near-dead window (−24 dB+ below speech), then recovered speech.
  private func failureShapedBuffer(deadSeconds: Double) -> [Float] {
    seg(0.3, 0.001) + seg(0.2, 0.3) + seg(deadSeconds, 0.002) + seg(2.0, 0.25)
  }

  @Test("failure-shaped buffer yields ascending candidates inside the dead region's wake")
  func failureShapeYieldsCandidates() {
    let samples = failureShapedBuffer(deadSeconds: 1.2)
    let candidates = DegradedLeadDiagnostics.trimCandidates(samples: samples, sampleRate: rate)
    #expect(!candidates.isEmpty)
    #expect(candidates == candidates.sorted())
    #expect(candidates.count <= DegradedLeadDiagnostics.maxCandidates)
    // Every candidate must leave ≥ the minimum decodable remainder.
    for c in candidates {
      #expect(samples.count - c >= Int(DegradedLeadDiagnostics.minimumRemainingSeconds * rate))
      #expect(c > 0)
    }
    // The earliest candidate lands within the dead region or its immediate
    // wake — never inside the trailing recovered speech's back half.
    let speechStart = samples.count - Int(1.0 * rate)
    #expect(candidates[0] < speechStart)
  }

  @Test("dead-run boundary: a run just below the minimum yields nothing, just above yields")
  func deadRunBoundary() {
    // 0.35 s dead run < 0.4 s minimum → no candidate from it.
    let below = seg(0.5, 0.3) + seg(0.35, 0.002) + seg(1.5, 0.25)
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: below, sampleRate: rate).isEmpty)
    // 0.5 s dead run ≥ 0.4 s minimum → candidates appear.
    let above = seg(0.5, 0.3) + seg(0.5, 0.002) + seg(1.5, 0.25)
    #expect(!DegradedLeadDiagnostics.trimCandidates(samples: above, sampleRate: rate).isEmpty)
  }

  @Test("near-silent buffer (reference below floor) yields nothing — salvage is pointless")
  func nearSilentBufferGuard() {
    let samples = seg(4.0, 0.002)
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: samples, sampleRate: rate).isEmpty)
  }

  @Test("continuously loud buffer yields nothing — no dead run to trim")
  func allLoudBuffer() {
    let samples = seg(4.0, 0.25)
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: samples, sampleRate: rate).isEmpty)
  }

  @Test("candidate leaving too little audio is dropped")
  func minimumRemainingGuard() {
    // Dead run ends 0.5 s before the buffer's end — below the 0.7 s minimum
    // remainder, so the only would-be candidates are dropped.
    let samples = seg(0.5, 0.3) + seg(1.0, 0.002) + seg(0.5, 0.25)
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: samples, sampleRate: rate).isEmpty)
  }

  @Test("adversarial: a legit mid-dictation pause between loud speech DOES yield candidates")
  func legitPauseYieldsCandidates() {
    // matcher-set-adversarial-tests: the non-intended semantic class (a real
    // pause in healthy dictation) also matches the detector. That is BY
    // DESIGN — candidates are only ever consumed AFTER the decode already
    // returned empty (the kernel gate), so the assertion here locks the
    // detector's behavior, and KernelSalvageRetryTests locks the
    // only-consumed-post-empty contract.
    let samples = seg(1.5, 0.25) + seg(1.0, 0.002) + seg(1.5, 0.25)
    let candidates = DegradedLeadDiagnostics.trimCandidates(samples: samples, sampleRate: rate)
    #expect(!candidates.isEmpty)
  }

  @Test(
    "adversarial lead shapes: soft ramp / quiet first word / noisy floor never trim into sustained voice"
  )
  func adversarialLeadShapes() {
    // Soft-start ramp: rises from quiet to loud with no ≥0.4 s dead run at
    // −24 dB below p90 — no candidates.
    var ramp: [Float] = []
    for i in 0..<Int(2.0 * rate) {
      ramp.append(0.02 + 0.23 * Float(i) / Float(Int(2.0 * rate)))
    }
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: ramp, sampleRate: rate).isEmpty)

    // Quiet first word then loud: the quiet word (−12 dB, above the −24 dB
    // dead line) must NOT count as dead.
    let quietFirstWord = seg(0.6, 0.06) + seg(2.4, 0.25)
    #expect(
      DegradedLeadDiagnostics.trimCandidates(samples: quietFirstWord, sampleRate: rate).isEmpty)

    // High noise floor with weak speech: floor at half the speech level —
    // nothing is −24 dB below reference, so nothing trims.
    let noisy = seg(1.0, 0.1) + seg(2.0, 0.2)
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: noisy, sampleRate: rate).isEmpty)
  }

  @Test("candidates are deduped at the minimum spacing and capped")
  func dedupeAndCap() {
    // Multiple dead runs → multiple candidate sources; the result must stay
    // ascending, spaced ≥ dedupeSpacingSeconds, and ≤ maxCandidates.
    let samples =
      seg(0.3, 0.3) + seg(0.5, 0.002) + seg(0.4, 0.3) + seg(0.6, 0.002) + seg(2.0, 0.25)
    let candidates = DegradedLeadDiagnostics.trimCandidates(samples: samples, sampleRate: rate)
    #expect(candidates.count <= DegradedLeadDiagnostics.maxCandidates)
    let spacing = Int(DegradedLeadDiagnostics.dedupeSpacingSeconds * rate)
    for pair in zip(candidates, candidates.dropFirst()) {
      #expect(pair.1 - pair.0 >= spacing)
    }
  }

  @Test("empty and degenerate inputs yield nothing")
  func degenerateInputs() {
    #expect(DegradedLeadDiagnostics.trimCandidates(samples: [], sampleRate: rate).isEmpty)
    #expect(
      DegradedLeadDiagnostics.trimCandidates(samples: seg(0.01, 0.3), sampleRate: rate).isEmpty)
    #expect(
      DegradedLeadDiagnostics.trimCandidates(samples: seg(1.0, 0.3), sampleRate: 0).isEmpty)
  }
}
