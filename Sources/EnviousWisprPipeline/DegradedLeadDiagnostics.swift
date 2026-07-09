import Foundation

/// Degraded-lead trim-candidate computation for the ASR-empty salvage ladder
/// (#1434). Pure compute, sibling of `TailClipDiagnostics` — no state, no
/// side effects, consumed at exactly ONE site (the kernel's `.empty` branch,
/// AFTER a batch decode already returned empty despite speech evidence).
///
/// Background: a Bluetooth voice link that is still settling after mic-open
/// (AirPods A2DP→HFP renegotiation) can deliver 1-2 s of near-silence plus
/// packet-loss-concealment chirps before recovering. Parakeet's TDT decoder
/// collapses to an EMPTY transcript for the whole utterance when fed that
/// poisoned prefix — offline-proven on the founder's archived failures, where
/// trimming the degraded lead recovered near-complete sentences (#1434).
///
/// The detector finds the boundaries of leading "dead" regions and proposes
/// up to `maxCandidates` ascending trim points; the kernel retries the decode
/// at each and delivers the first non-empty transcript. All thresholds were
/// chosen empirically against the six archived failures + three passes of
/// 2026-07-09 (issue #1434 documents the harness recipe for re-validation).
enum DegradedLeadDiagnostics {

  /// Analysis window length. 50 ms at 16 kHz = 800 samples.
  static let windowSeconds = 0.05
  /// Window hop. 25 ms — 50% overlap.
  static let hopSeconds = 0.025
  /// Speech reference = this percentile of window RMS across the buffer.
  static let referencePercentile = 90.0
  /// Reference floor: below this the whole buffer is near-silent and salvage
  /// is pointless (there is nothing to recover).
  static let minimumReference: Float = 0.005
  /// A window is "dead" below reference / 16 (−24 dB).
  static let deadRatio: Float = 1.0 / 16.0
  /// A dead run must span at least this long to yield a candidate.
  static let minimumDeadRunSeconds = 0.4
  /// Strong-onset candidate: first window at ≥ reference/2 sustained this long.
  static let strongOnsetRatio: Float = 0.5
  static let strongOnsetSustainSeconds = 0.2
  /// Pad subtracted from the strong-onset candidate so the onset itself
  /// survives the trim.
  static let strongOnsetPadSeconds = 0.1
  /// Candidates closer than this to an earlier one are dropped (a retry at
  /// nearly the same point cannot change the decode).
  static let dedupeSpacingSeconds = 0.3
  /// A candidate must leave at least this much audio to be worth decoding.
  static let minimumRemainingSeconds = 0.7
  /// Ladder bound — also the retry bound in the kernel.
  static let maxCandidates = 3

  /// Compute ascending trim candidates (in SAMPLES into `samples`) for a
  /// buffer whose decode returned empty despite speech evidence. Empty result
  /// means "nothing to salvage" (buffer near-silent, no qualifying dead runs,
  /// or every candidate leaves too little audio).
  static func trimCandidates(samples: [Float], sampleRate: Double) -> [Int] {
    guard sampleRate > 0, !samples.isEmpty else { return [] }
    let window = max(1, Int(windowSeconds * sampleRate))
    let hop = max(1, Int(hopSeconds * sampleRate))
    guard samples.count > window else { return [] }

    // Window RMS profile.
    var rms: [Float] = []
    rms.reserveCapacity((samples.count - window) / hop + 1)
    var start = 0
    while start + window <= samples.count {
      var sum: Float = 0
      for i in start..<(start + window) {
        sum += samples[i] * samples[i]
      }
      rms.append((sum / Float(window)).squareRoot())
      start += hop
    }
    guard !rms.isEmpty else { return [] }

    // Speech reference (p90 of window RMS), with the near-silent-file guard.
    let sorted = rms.sorted()
    let refIndex = min(
      sorted.count - 1, Int((referencePercentile / 100.0) * Double(sorted.count - 1)))
    let reference = sorted[refIndex]
    guard reference >= minimumReference else { return [] }

    let deadThreshold = reference * deadRatio
    let minDeadWindows = max(1, Int(minimumDeadRunSeconds / hopSeconds))

    // Dead runs ≥ minimumDeadRunSeconds → candidate at each run's END.
    var runs: [(start: Int, end: Int)] = []  // window indices, end exclusive
    var runStart: Int?
    for (i, value) in rms.enumerated() {
      if value < deadThreshold {
        if runStart == nil { runStart = i }
      } else if let s = runStart {
        if i - s >= minDeadWindows { runs.append((s, i)) }
        runStart = nil
      }
    }
    if let s = runStart, rms.count - s >= minDeadWindows {
      runs.append((s, rms.count))
    }
    guard !runs.isEmpty else { return [] }

    var candidateSamples: [Int] = []
    func windowIndexToSample(_ index: Int) -> Int { index * hop }
    candidateSamples.append(windowIndexToSample(runs[0].end))
    if runs.count > 1 {
      candidateSamples.append(windowIndexToSample(runs[runs.count - 1].end))
    }

    // Strong sustained onset after the last dead run, minus a small pad.
    let sustainWindows = max(1, Int(strongOnsetSustainSeconds / hopSeconds))
    let strongThreshold = reference * strongOnsetRatio
    var i = runs[runs.count - 1].end
    while i + sustainWindows <= rms.count {
      if rms[i..<(i + sustainWindows)].allSatisfy({ $0 >= strongThreshold }) {
        let padded = windowIndexToSample(i) - Int(strongOnsetPadSeconds * sampleRate)
        candidateSamples.append(max(0, padded))
        break
      }
      i += 1
    }

    // Ascending, deduped, bounded, and each must leave enough audio.
    let spacing = Int(dedupeSpacingSeconds * sampleRate)
    let minRemaining = Int(minimumRemainingSeconds * sampleRate)
    var result: [Int] = []
    for candidate in candidateSamples.sorted() {
      guard candidate > 0 else { continue }
      guard samples.count - candidate >= minRemaining else { continue }
      if let last = result.last, candidate - last < spacing { continue }
      result.append(candidate)
      if result.count == maxCandidates { break }
    }
    return result
  }
}
