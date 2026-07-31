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
    // Sequentially-measured buckets (the sweep above) span 2.85 … 4.41 across 14
    // samples. TIME-ADJACENT pairs, measured below, are tighter because load
    // that starts or stops between two distant measurements no longer leaks in:
    //
    //   idle                    median 3.84  (min 3.29, max 4.13, n=9)
    //   14-core busy-loop load  median 3.62  (min 2.82, max 3.97, n=9)
    //
    // The loaded run took 28 s against 13 s idle, so the contention was real and
    // the ratio still held. 4x the terms costs ~4x the time: linear. The
    // threshold of 8 sits at ~2x the worst paired ratio and at half of the 16x
    // an O(n^2) regression would produce, so it discriminates the thing the gate
    // exists for while staying unreachable by contention. If a future run ever
    // lands near 8 on unmodified main, widen the sample count instead of nudging
    // the bar — a drifting ratio IS the signal.
    // The two buckets above are measured SEQUENTIALLY, so load that starts or
    // stops between them does NOT divide out — a quiet 500-term measurement
    // followed by a contended 2000-term one inflates the ratio for reasons that
    // have nothing to do with the algorithm. Pair them in time instead:
    // alternate the two sizes round by round and take the MEDIAN ratio, so a
    // contention spike has to land on the same phase of most rounds to matter.
    let lookups500 = WordCorrector.buildLookups(words: personVocab(500))
    let lookups2000 = WordCorrector.buildLookups(words: personVocab(2000))
    _ = WordCorrector().correct(sentence, using: lookups500)  // warm
    _ = WordCorrector().correct(sentence, using: lookups2000)  // warm

    func timeOne(_ lookups: WordCorrector.Lookups) -> Double {
      let start = Date()
      _ = WordCorrector().correct(sentence, using: lookups)
      return Date().timeIntervalSince(start) * 1000.0
    }

    var pairedRatios: [Double] = []
    for _ in 0..<9 {
      // Adjacent in time, so both see the same machine.
      let small = timeOne(lookups500)
      let large = timeOne(lookups2000)
      if small > 0 { pairedRatios.append(large / small) }
    }

    if !pairedRatios.isEmpty {
      let sorted = pairedRatios.sorted()
      let growth = sorted[sorted.count / 2]
      print(
        String(
          format: "[#636 corrector-latency] paired growth 2000/500: median %.2fx "
            + "(min %.2f, max %.2f, n=%d, bar 8.0x)",
          growth, sorted[0], sorted[sorted.count - 1], sorted.count))
      #expect(
        growth < 8.0,
        """
        Corrector cost grew \(String(format: "%.2f", growth))x for 4x the vocabulary \
        (median of \(sorted.count) time-adjacent pairs). Worst measured on healthy \
        code is 4.41x; 16x would mean quadratic. Pairing the samples in time is what \
        makes this robust to contention, so a failure here is an algorithmic \
        regression rather than a busy machine.
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
