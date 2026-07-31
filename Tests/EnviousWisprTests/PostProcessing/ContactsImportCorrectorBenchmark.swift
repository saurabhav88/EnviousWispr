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

  @Test("Corrector cost grows no worse than linearly in vocabulary size")
  func latencyAtScale() {
    let sentence = "loop in Surnamenum1500 on the SSO thread before standup with the team"
    let sizes = [0, 500, 1000, 2000]
    let iterations = 8
    var maxPerCallMs = 0.0
    var msBySize: [Int: Double] = [:]

    for size in sizes {
      let lookups = WordCorrector.buildLookups(words: personVocab(size))
      _ = WordCorrector().correct(sentence, using: lookups)  // warm
      let start = Date()
      for _ in 0..<iterations {
        _ = WordCorrector().correct(sentence, using: lookups)
      }
      let perCallMs = Date().timeIntervalSince(start) / Double(iterations) * 1000.0
      maxPerCallMs = max(maxPerCallMs, perCallMs)
      msBySize[size] = perCallMs
      print(
        String(
          format: "[#636 corrector-latency] +%4d person terms: %.3f ms/dictation", size, perCallMs))
    }

    // #1805 — the primary assertion is the GROWTH RATIO, not a wall-clock bound.
    //
    // The old assertion was `maxPerCallMs < 1500`, an absolute wall-clock bound
    // on a machine shared with ~4300 parallel tests. It went red on unmodified
    // main at 2836 ms while a heavily loaded machine (concurrent Codex reviews
    // and Xcode builds) ran the suite, then passed on every rerun — a false
    // alarm that cost a session and this issue.
    //
    // A ratio cannot be inflated by machine load: contention scales both
    // buckets together, so it divides out. Measured, rather than assumed:
    //
    //   idle, 10 paired samples   ratio 2000/500 = 2.85 … 3.93 (median 3.77)
    //   4 further idle runs                       3.55, 4.21, 4.41
    //   14-core busy-loop load                    3.65  (inside the idle range)
    //   inside a full 4346-test suite run         3.87
    //
    // 14 samples, full range 2.85 … 4.41. 4x the terms costs ~4x the time, i.e.
    // this is linear. The threshold of 8 sits at ~1.8x the worst observed ratio
    // and at half of the 16x an O(n^2) regression would produce, so it
    // discriminates the thing the gate exists for while staying unreachable by
    // contention. If a future run ever lands near 8 on unmodified main, widen
    // the sweep instead of nudging the bar — a drifting ratio IS the signal.
    let baseline = msBySize[500] ?? 0
    let atScale = msBySize[2000] ?? 0
    if baseline > 0 {
      let growth = atScale / baseline
      print(String(format: "[#636 corrector-latency] growth 2000/500: %.2fx (bar: 8.0x)", growth))
      #expect(
        growth < 8.0,
        """
        Corrector cost grew \(String(format: "%.2f", growth))x for 4x the vocabulary. \
        Worst measured is 3.93x; 16x would mean quadratic. This ratio is immune to \
        machine load, so a failure here is an algorithmic regression, not contention.
        """)
    }

    // Secondary net ONLY. A uniform constant-factor blowup leaves the ratio
    // unchanged, so one absolute bound is still needed — but set where load
    // cannot reach it. Worst ever observed is 3132 ms, on the pathological
    // machine that produced this issue; everything reproducible sits under
    // 550 ms. 10 s catches a ~20x constant-factor regression and nothing else.
    //
    // NOTE: this is deliberately NOT the 3000 ms WordCorrectionStep cap. Whether
    // a real user with a very large address book can approach that cap is a
    // PRODUCT question and is tracked separately; a load-sensitive test on a
    // shared machine cannot police it, and pretending otherwise is what made
    // this gate flaky in the first place.
    #expect(maxPerCallMs < 10000.0)
  }
}
