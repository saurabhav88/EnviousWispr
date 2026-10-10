#if DEBUG
  import Foundation
  import Testing

  @testable import EnviousWisprDesktopEffects

  /// #3544 P2: the keyboard listener's callback-cost histogram.
  ///
  /// Harness Contract: P2's acceptance reads the listener's callback max and p99 from this
  /// histogram. When it fails, the cost report understates or loses samples, or names a p99 bucket
  /// that does not contain the p99.
  @Suite(.tags(.harnessContract))
  struct KeyboardListenerCostHistogramTests {

    @Test("every duration lands in a bucket whose bounds contain it")
    func bucketsContainTheirValues() {
      for ns: UInt64 in [1, 2, 7, 100, 1_500, 10_000, 123_456, 1_000_000, 50_000_000] {
        let b = CostHistogram.bucket(ns)
        #expect(CostHistogram.lowerBound(b) <= ns, "\(ns)")
        #expect(ns < CostHistogram.upperBound(b), "\(ns)")
      }
    }

    @Test("the p99 bounds hold the 99th percentile sample and the maximum is exact")
    func p99AndMaximum() {
      var h = CostHistogram()
      for _ in 0..<990 { h.record(1_000) }
      for _ in 0..<10 { h.record(1_000_000) }
      let (lower, upper) = h.percentileBounds(0.99)
      #expect(lower <= 1_000)
      #expect(1_000 < upper)
      #expect(upper < 1_000_000)
      #expect(h.maximum == 1_000_000)
      #expect(h.total == 1_000)
    }

    @Test("no sample is ever dropped, however many there are")
    func nothingIsDropped() {
      var h = CostHistogram()
      for i in 0..<100_000 { h.record(UInt64(i % 5_000)) }
      #expect(h.total == 100_000)
      #expect(h.counts.reduce(0, +) == 100_000)
    }
  }
#endif
