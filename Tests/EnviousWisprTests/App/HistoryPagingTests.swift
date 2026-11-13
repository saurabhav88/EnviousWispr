import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4001 step 3a: what fails when these fail is a History list that hides the selected row,
/// loads two pages for one scroll, or forgets a page the user just loaded.
@Suite("History paging", .tags(.productOutcome))
struct HistoryPagingTests {
  private static func items(_ count: Int) -> [HistoryListItem] {
    (0..<count).map { .transcript(Transcript(text: "row \($0)")) }
  }

  private static let all = HistoryPaging.Context(tab: .dictations, query: "", filter: .none)
  private static let searching = HistoryPaging.Context(
    tab: .dictations, query: "contract", filter: .none)
  private static let otherTab = HistoryPaging.Context(tab: .transcripts, query: "", filter: .none)
  private static let filtered = HistoryPaging.Context(
    tab: .dictations, query: "", filter: HistoryListFilter(app: .named("Slack")))

  @Test("the window is the requested limit, or further to the selection's page boundary")
  func effectiveCountIncludesTheSelection() {
    let count = HistoryPaging.effectiveCount
    #expect(count(30, nil, 100) == 30)
    #expect(count(30, 0, 100) == 30)
    #expect(count(30, 29, 100) == 30)
    #expect(count(30, 30, 100) == 60)
    #expect(count(30, 59, 100) == 60)
    #expect(count(30, 60, 100) == 90)
    #expect(count(90, 5, 100) == 90)
    #expect(count(30, 95, 100) == 100)
    #expect(count(30, nil, 12) == 12)
    #expect(count(30, nil, 0) == 0)
  }

  @Test("a stored limit counts only for the context it was set for")
  func aNewContextStartsAtThirty() {
    let state = HistoryPaging.State(requested: 90, context: Self.all)
    #expect(HistoryPaging.requested(state, for: Self.all) == 90)
    #expect(HistoryPaging.requested(state, for: Self.searching) == 30)
    #expect(HistoryPaging.requested(HistoryPaging.State(), for: Self.all) == 30)
  }

  @Test("a selection kept through a widened search or filter is inside the window")
  func retainedSelectionAfterWidening() {
    let rows = Self.items(200)
    // Selected while searching, then the search is cleared: the row is now at position 75.
    let state = HistoryPaging.State(requested: 30, context: Self.all)
    let window = HistoryPaging.window(
      items: rows, context: Self.all, state: state, selected: rows[75].id)
    #expect(window.boundary == 90)
    #expect(rows.prefix(window.boundary).contains { $0.id == rows[75].id })
  }

  @Test("the same selected row moving from position 30 to 31 stays inside the window")
  func selectionPushedDownByANewRow() {
    var rows = Self.items(100)
    let selected = rows[29].id
    let state = HistoryPaging.State(requested: 30, context: Self.all)
    #expect(
      HistoryPaging.window(items: rows, context: Self.all, state: state, selected: selected)
        .boundary == 30)
    rows.insert(.transcript(Transcript(text: "new dictation")), at: 0)
    let after = HistoryPaging.window(
      items: rows, context: Self.all, state: state, selected: selected)
    #expect(after.boundary == 60)
    #expect(rows.prefix(after.boundary).contains { $0.id == selected })
  }

  @Test("the deletion neighbour beyond the window is inside it")
  func selectionAfterDeletion() {
    var rows = Self.items(100)
    let neighbour = rows[30].id
    rows.remove(at: 29)  // the selected row 29 is deleted; its neighbour is now at 29
    var window = HistoryPaging.window(
      items: rows, context: Self.all, state: HistoryPaging.State(), selected: neighbour)
    #expect(window.boundary == 30)
    // A neighbour further down (the previous one picked at the end) is included too.
    window = HistoryPaging.window(
      items: rows, context: Self.all, state: HistoryPaging.State(), selected: rows[64].id)
    #expect(window.boundary == 90)
  }

  @Test("the same request delivered twice loads exactly one page")
  func duplicateRequestAdvancesOnce() throws {
    let rows = Self.items(100)
    var state = HistoryPaging.State()
    let first = HistoryPaging.window(items: rows, context: Self.all, state: state, selected: nil)
    let request = try #require(HistoryPaging.request(for: first))
    for _ in 0..<2 {
      let live = HistoryPaging.window(items: rows, context: Self.all, state: state, selected: nil)
      state = HistoryPaging.load(request, state: state, current: live)
    }
    #expect(state == HistoryPaging.State(requested: 60, context: Self.all))
  }

  @Test(
    "a request from before a search, filter or tab change loads nothing",
    arguments: [Self.searching, Self.filtered, Self.otherTab])
  func staleRequestAfterAContextChange(newContext: HistoryPaging.Context) throws {
    let rows = Self.items(100)
    let old = HistoryPaging.window(
      items: rows, context: Self.all, state: HistoryPaging.State(), selected: nil)
    let request = try #require(HistoryPaging.request(for: old))
    let state = HistoryPaging.State(requested: 30, context: newContext)
    let live = HistoryPaging.window(items: rows, context: newContext, state: state, selected: nil)
    #expect(HistoryPaging.load(request, state: state, current: live) == state)
    #expect(HistoryPaging.accept(request, current: live) == nil)
  }

  @Test("a tab's stored count is its paging state, keyed by that tab and all its filters")
  func tabStateMapsToItsOwnContext() {
    var tabState = HistoryTabState()
    tabState.query = "contract"
    tabState.app = .named("Slack")
    tabState.speakerCount = 2...2
    tabState.requestedCount = 90
    let state = HistoryPaging.state(tabState, tab: .transcripts)
    #expect(state.requested == 90)
    let context = HistoryPaging.Context(
      tab: .transcripts, query: "contract",
      filter: HistoryListFilter(app: .named("Slack"), speakerCount: 2...2))
    #expect(state.context == context)
    #expect(HistoryPaging.requested(state, for: context) == 90)
    // The same search and filters on another tab, or one filter changed, start again at 30.
    #expect(
      HistoryPaging.requested(
        state, for: HistoryPaging.Context(tab: .dictations, state: tabState)) == 30)
    var narrowed = tabState
    narrowed.dateInterval = DateInterval(start: .distantPast, duration: 1)
    #expect(
      HistoryPaging.requested(
        state, for: HistoryPaging.Context(tab: .transcripts, state: narrowed)) == 30)
  }

  @Test("the last page is partial and then nothing more is offered")
  func finalPartialPage() throws {
    let rows = Self.items(70)
    var state = HistoryPaging.State(requested: 60, context: Self.all)
    let live = HistoryPaging.window(items: rows, context: Self.all, state: state, selected: nil)
    let request = try #require(HistoryPaging.request(for: live))
    state = HistoryPaging.load(request, state: state, current: live)
    #expect(state.requested == 70)
    let full = HistoryPaging.window(items: rows, context: Self.all, state: state, selected: nil)
    #expect(full.boundary == 70)
    #expect(!full.hasMore)
    #expect(HistoryPaging.request(for: full) == nil)
    #expect(
      HistoryPaging.window(
        items: [], context: Self.all, state: HistoryPaging.State(), selected: nil)
        == HistoryPaging.Window(context: Self.all, boundary: 0, tail: nil, total: 0))
  }
}
