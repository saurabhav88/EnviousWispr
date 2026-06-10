import Testing

@testable import EnviousWisprAppKit

/// Boundary tests for the History split width clamp (#1024).
@Suite struct HistorySplitMetricsTests {
  // listMin 230 + dividerWidth 8 + detailMin 260 = 498 is the smallest
  // container that hosts both floors.
  private let bothFloors: Double = 498

  @Test func preferredWidthHeldWhenDetailHasRoom() {
    // 1000 - 260 - 8 = 732 hostable; preferred 260 within [230, 340].
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 260, available: 1000) == 260)
  }

  @Test func preferredClampedToListMax() {
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 900, available: 1000) == 340)
  }

  @Test func preferredClampedToListMin() {
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 10, available: 1000) == 230)
  }

  @Test func detailCompressesFirstThenListGivesWidth() {
    // available 520: maxHostable = 520 - 268 = 252 >= 230, so a 340 preference
    // compresses the list to 252 — the detail floor wins over preference.
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 340, available: 520) == 252)
  }

  @Test func justAboveBothFloorsListSitsAtItsMin() {
    #expect(
      HistorySplitMetrics.effectiveListWidth(preferred: 340, available: bothFloors + 1) == 231)
  }

  @Test func exactlyBothFloorsListSitsAtItsMin() {
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 340, available: bothFloors) == 230)
  }

  @Test func justBelowBothFloorsDegradesToListFloor() {
    // Below both floors the list keeps (at most) its floor; never negative.
    #expect(
      HistorySplitMetrics.effectiveListWidth(preferred: 340, available: bothFloors - 1) == 230)
  }

  @Test func degenerateTinyContainerNeverGoesNegative() {
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 340, available: 100) == 92)
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 340, available: 0) == 0)
    #expect(HistorySplitMetrics.effectiveListWidth(preferred: 340, available: 5) == 0)
  }
}
