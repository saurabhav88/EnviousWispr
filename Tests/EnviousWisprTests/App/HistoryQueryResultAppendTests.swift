import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #4586 H5: loading the next History page appends to the list already shown instead of laying
/// the whole list out again, and the result is built off the main actor. The appended list must
/// draw exactly what laying out all of its items at once draws: same rows, headings, day counts
/// and places.
@Suite(
  "History adds a page exactly as if the whole list were laid out again", .tags(.productOutcome))
struct HistoryQueryResultAppendTests {
  /// A small deterministic generator, so every case is reproducible from its seed.
  private struct Seeded {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
  }

  private struct Shape: Equatable {
    let id: HistoryDiaryLayout.EntryID
    let position: Int
    let dayCount: Int?
  }

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }()

  private static func key() -> TranscriptCoordinator.HistoryQueryKey {
    .init(
      revision: 1, pulse: 0, context: .init(tab: .dictations, query: "", filter: .none),
      echoShown: [], locale: "en_US", localizations: ["en"], calendar: calendar)
  }

  private static func summary(at date: Date) -> HistoryCatalog.Summary {
    .init(key: .init(tab: .dictations, id: UUID()), date: date, preview: "", sources: [])
  }

  /// Items newest first across a handful of days, some days long enough to cross pages.
  private static func items(seed: UInt64) -> [HistoryCatalog.Summary] {
    var random = Seeded(state: seed)
    let start = Date(timeIntervalSinceReferenceDate: 780_000_000)
    var date = start
    var result: [HistoryCatalog.Summary] = []
    for _ in 0..<(40 + random.next(60)) {
      // Mostly minutes apart, sometimes a jump of one to three days.
      let step =
        random.next(10) == 0
        ? Double(86_400 * (1 + random.next(3))) : Double(60 * (1 + random.next(90)))
      date = date.addingTimeInterval(-step)
      result.append(summary(at: date))
    }
    return result
  }

  private static func counts(_ summaries: [HistoryCatalog.Summary]) -> [Date: Int] {
    summaries.reduce(into: [:]) { $0[calendar.startOfDay(for: $1.date), default: 0] += 1 }
  }

  private static func shapes(_ result: HistoryQueryResult, through boundary: Int) -> [Shape] {
    result.entries(through: boundary).map {
      Shape(id: $0.id, position: $0.position, dayCount: $0.dayCount)
    }
  }

  private static func expectSame(
    _ appended: HistoryQueryResult, _ whole: HistoryQueryResult, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      appended.items.map(\.id) == whole.items.map(\.id), "\(label): items",
      sourceLocation: sourceLocation)
    #expect(
      appended.positions == whole.positions, "\(label): positions", sourceLocation: sourceLocation)
    #expect(appended.ids == whole.ids, "\(label): ids", sourceLocation: sourceLocation)
    #expect(
      appended.catalogDayCounts == whole.catalogDayCounts, "\(label): counts",
      sourceLocation: sourceLocation)
    for boundary in 0...appended.items.count {
      #expect(
        shapes(appended, through: boundary) == shapes(whole, through: boundary),
        "\(label): rows through \(boundary)", sourceLocation: sourceLocation)
    }
    for item in whole.items {
      #expect(
        appended.anchor(for: .item(item.id)) == whole.anchor(for: .item(item.id)),
        sourceLocation: sourceLocation)
      let day = calendar.startOfDay(for: item.createdAt)
      #expect(
        appended.anchor(for: .day(day)) == whole.anchor(for: .day(day)),
        sourceLocation: sourceLocation)
    }
  }

  private static func cursor(after summary: HistoryCatalog.Summary?) -> HistoryCatalog.Cursor? {
    summary.map { HistoryCatalog.Cursor(date: $0.date, id: $0.key.id) }
  }

  @Test(
    "Pages appended one by one equal the whole list laid out at once",
    arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
  func appendedEqualsWhole(seed: UInt64) async throws {
    let all = Self.items(seed: seed)
    var random = Seeded(state: seed &* 31)
    let main = OSAllocatedUnfairLock(initialState: [Bool]())
    let probe: @Sendable (Bool) -> Void = { onMain in main.withLock { $0.append(onMain) } }
    var start = 0
    var result: HistoryQueryResult?
    var pages = 0
    // The expectation is built from the pages as supplied, never from the result under test.
    var expectedItems: [HistoryCatalog.Summary] = []
    var expectedCounts: [Date: Int]?
    while start < all.count {
      // Pages of 0 to 35 items, sometimes repeating the previous page's last item.
      let overlap = start > 0 && random.next(4) == 0 ? 1 : 0
      let size = random.next(36)
      let from = start - overlap
      let end = min(all.count, from + size)
      let summaries = Array(all[from..<end])
      // Certified pages carry the counts of every day they show; a few lose certification.
      let certified = random.next(6) != 0
      let pageCounts = certified ? Self.counts(Array(all[0..<end])) : nil
      let continuation = end < all.count ? Self.cursor(after: summaries.last ?? all[max(from - 1, 0)]) : nil
      let page = HistoryCatalog.Page(
        summaries: summaries, continuation: continuation, newerContinuation: nil, dayCounts: pageCounts)
      result = await TranscriptCoordinator.buildResult(
        key: Self.key(), page: page, previous: result, newer: false, source: 7, onMainThread: probe)
      pages += 1
      for summary in summaries where expectedItems.contains(where: { $0.key == summary.key }) == false {
        expectedItems.append(summary)
      }
      expectedCounts = pageCounts.map { (pages == 1 ? [:] : expectedCounts ?? [:]).merging($0) { _, new in new } }
      let step = try #require(result, "seed \(seed), page \(pages)")
      #expect(step.items.map(\.id) == expectedItems.map { HistoryListItem.catalog($0).id }, "seed \(seed), page \(pages): rows")
      #expect(step.continuation == continuation, "seed \(seed), page \(pages): continuation")
      #expect(step.catalogDayCounts == expectedCounts, "seed \(seed), page \(pages): counts")
      let whole = try HistoryQueryResult(
        key: Self.key(), items: expectedItems.map(HistoryListItem.catalog), continuation: continuation,
        newerContinuation: nil, catalogSourceRevision: 7, catalogDayCounts: expectedCounts)
      Self.expectSame(step, whole, "seed \(seed), page \(pages)")
      start = max(end, start + (size == 0 ? 1 : 0))
    }
    // Every build ran off the main actor.
    #expect(main.withLock { $0 }.allSatisfy { $0 == false })
    #expect(main.withLock { $0 }.count == pages)
  }

  @Test("A page that continues the last shown day joins that day's heading")
  func continuesLastDay() async throws {
    let day = Date(timeIntervalSinceReferenceDate: 780_000_000)
    let first = (0..<3).map { Self.summary(at: day.addingTimeInterval(Double(-60 * $0))) }
    let second = (3..<6).map { Self.summary(at: day.addingTimeInterval(Double(-60 * $0))) }
    let one = try #require(
      await TranscriptCoordinator.buildResult(
        key: Self.key(),
        page: .init(
          summaries: first, continuation: Self.cursor(after: first.last), newerContinuation: nil,
          dayCounts: Self.counts(first + second)),
        previous: nil, newer: false, source: 7))
    let two = try #require(
      await TranscriptCoordinator.buildResult(
        key: Self.key(),
        page: .init(
          summaries: second, continuation: nil, newerContinuation: nil,
          dayCounts: Self.counts(first + second)),
        previous: one, newer: false, source: 7))
    let headings = Self.shapes(two, through: two.items.count).filter {
      if case .day = $0.id { return true }
      return false
    }
    #expect(headings.count == 1)
    #expect(headings.first?.dayCount == 6)
    #expect(two.continuation == nil)
  }
}
