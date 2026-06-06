import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

/// #636 §3a — corrector latency at import scale. The per-dictation cost is
/// `WordCorrector.correct(using:)` over a prebuilt `Lookups`; the live ceiling
/// is the 3-second whole-step Word-Correction timeout (`WordCorrectionStep`).
/// This reports per (vocab-size) bucket and asserts a generous floor well under
/// that cap — the printed numbers are the signal; the assert is a regression
/// backstop, not a tight bound (timeout-numbers-need-distribution-evidence).
@Suite("Corrector latency at import scale (#636 §3a)")
struct ContactsImportCorrectorBenchmark {
  /// Worst case for the fuzzy passes: distinctive single-token person canonicals
  /// (each becomes an exact self-entry AND a single-token fuzzy candidate).
  private func personVocab(_ n: Int) -> [CustomWord] {
    (0..<n).map {
      CustomWord(canonical: "Surnamenum\($0)", category: .person, priority: 10)
    }
  }

  @Test("Per-dictation correct(using:) stays well under the 3s step cap at +2000 terms")
  func latencyAtScale() {
    let sentence = "loop in Surnamenum1500 on the SSO thread before standup with the team"
    let sizes = [0, 500, 1000, 2000]
    let iterations = 8
    var maxPerCallMs = 0.0

    for size in sizes {
      let lookups = WordCorrector.buildLookups(words: personVocab(size))
      _ = WordCorrector().correct(sentence, using: lookups)  // warm
      let start = Date()
      for _ in 0..<iterations {
        _ = WordCorrector().correct(sentence, using: lookups)
      }
      let perCallMs = Date().timeIntervalSince(start) / Double(iterations) * 1000.0
      maxPerCallMs = max(maxPerCallMs, perCallMs)
      print(
        String(
          format: "[#636 corrector-latency] +%4d person terms: %.3f ms/dictation", size, perCallMs))
    }

    // Step cap is 3000 ms; a regression would have to be ~3x before the user
    // ever sees a graceful skip. 1500 ms floor is a catastrophic-regression
    // backstop, not a measured bound.
    #expect(maxPerCallMs < 1500.0)
  }
}
