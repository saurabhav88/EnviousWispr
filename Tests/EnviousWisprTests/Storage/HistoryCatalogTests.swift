import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@Suite("History catalog pages and reopens saved projections", .tags(.productOutcome))
struct HistoryCatalogTests {
  @Test("Search, day counts and selected IDs cover all matches even when timestamps tie")
  func pagesAndMatches() async throws {
    let directory = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = try HistoryCatalog(directory: directory)
    let day = Date(timeIntervalSinceReferenceDate: 750_000_000)
    let fixtures = (1...40).map { self.projection($0, date: day, text: "Client budget") }
    try await catalog.apply(fixtures, certifiedRevision: "complete")

    let query = HistoryCatalog.Query(tab: .dictations, search: "budg")
    let first = try await catalog.page(query, sourceRevision: "complete") { _ in true }
    #expect(first.summaries.count == 30)
    #expect(first.dayCounts?.values.first == 40)
    let after = try #require(first.continuation)
    let second = try await catalog.page(query, after: after, sourceRevision: "complete") { _ in true }
    #expect(second.summaries.count == 10)
    #expect(second.continuation == nil)
    let keys = try await catalog.matchingKeys(query, sourceRevision: "complete")
    #expect(Set(keys).count == 40)
    #expect((first.summaries + second.summaries).map(\.key) == keys)

    let short = try await catalog.page(.init(tab: .dictations, search: "bu")) { _ in true }
    #expect(short.summaries.count == 30)
    #expect(short.dayCounts == nil)
    do {
      _ = try await catalog.matchingKeys(query, sourceRevision: "unverified")
      Issue.record("An unverified catalog returned complete selection IDs")
    } catch HistoryCatalog.Failure.incompleteCoverage {
      // The source inventory has not certified these results.
    }
  }

  @Test("A stale source is withheld and only current replacements survive in the reopened catalog")
  func replacementAndRemoval() async throws {
    let directory = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let day = Date(timeIntervalSinceReferenceDate: 750_000_000)
    let removed = projection(1, date: day, text: "first budget")
    let edited = projection(2, date: day, text: "second budget")
    do {
      let catalog = try HistoryCatalog(directory: directory)
      try await catalog.apply([removed, edited], certifiedRevision: "old")
      let page = try await catalog.page(.init(tab: .dictations), sourceRevision: "old") {
        $0.key != removed.summary.key
      }
      #expect(page.summaries.map(\.key) == [edited.summary.key])
      #expect(page.dayCounts == nil)
      let replacement = projection(2, date: day, text: "café update")
      try await catalog.apply([replacement], removing: [removed.summary.key], certifiedRevision: "current")
    }
    let reopened = try HistoryCatalog(directory: directory)
    let result = try await reopened.page(.init(tab: .dictations, search: "budget")) { _ in true }
    #expect(result.summaries.isEmpty)
    let new = try await reopened.page(
      .init(tab: .dictations, search: "CAFÉ"), sourceRevision: "current"
    ) { _ in true }
    #expect(new.summaries.map(\.preview) == ["café update"])
    #expect(new.dayCounts?.values.first == 1)
  }

  private func projection(_ index: Int, date: Date, text: String) -> HistoryCatalog.Projection {
    let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index)))
    return HistoryCatalog.Projection(
      summary: .init(
        key: .init(tab: .dictations, id: id), date: date, preview: text,
        sources: [.init(name: "record", fingerprint: Data([UInt8(index)]))]),
      searchableFields: [text])
  }
}
