import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// What fails when this fails is a History page read for one tab, search or filter being applied
/// to another. The in-memory window/request/accept/load functions are gone (#4586: the catalog
/// pages by cursor, covered by HistoryCatalogSessionTests and Storage/HistoryCatalogTests).
@Suite("History paging", .tags(.productOutcome))
struct HistoryPagingTests {
  @Test("a page's context is keyed by its tab and all its filters")
  func contextIsKeyedByTabAndFilters() {
    var tabState = HistoryTabState()
    tabState.query = "contract"
    tabState.app = .named("Slack")
    let context = HistoryPaging.Context(tab: .transcripts, state: tabState)
    #expect(
      context
        == HistoryPaging.Context(
          tab: .transcripts, query: "contract", filter: HistoryListFilter(app: .named("Slack"))))
    // The same search and filters on another tab, or one filter changed, are another context.
    #expect(context != HistoryPaging.Context(tab: .dictations, state: tabState))
    var narrowed = tabState
    narrowed.dateInterval = DateInterval(start: .distantPast, duration: 1)
    #expect(context != HistoryPaging.Context(tab: .transcripts, state: narrowed))
    var searching = tabState
    searching.query = "other"
    #expect(context != HistoryPaging.Context(tab: .transcripts, state: searching))
  }
}
