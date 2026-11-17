import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// Test shorthands over the History tab API (#3147 PR2), so tests that used the retired single
/// search, filter and selection say the same thing through one tab's state.
extension TranscriptCoordinator {
  /// Sets `tab`'s search, leaving its other state alone.
  func setHistoryQuery(_ query: String, in tab: HistoryTab) {
    var state = requestedHistoryState(for: tab)
    state.query = query
    setHistoryState(state, for: tab)
  }

  /// Opens `id` on `tab`, as clicking its card does.
  func openHistoryItem(_ id: HistoryItemID?, in tab: HistoryTab) {
    var state = requestedHistoryState(for: tab)
    state.openItemID = id
    setHistoryState(state, for: tab)
  }

  /// The item open on `tab`, or nil when none is open.
  func openHistoryItemID(in tab: HistoryTab) -> HistoryItemID? {
    requestedHistoryState(for: tab).openItemID
  }
}

/// The production History path for tests (#4586): real transcript and meeting folders, a real
/// catalog session indexing them, and a coordinator wired to it as `WisprBootstrapper` wires it.
/// History lists rows only through this catalog; the in-memory list was test-only and is gone.
@MainActor
struct HistoryCatalogRig {
  let root: URL
  let changes: HistorySourceChanges
  let store: TranscriptStore
  let meetings: MeetingStore
  let session: HistoryCatalogSession
  let coordinator: TranscriptCoordinator

  var transcriptsDirectory: URL { root.appendingPathComponent("transcripts") }

  /// Saves `rows` (pending rows through `savePending`), builds the session and coordinator, runs
  /// `configure` on the coordinator (meeting closures, clock), starts the catalog and waits for
  /// its first pass. Call `remove()` when done.
  static func make(
    rows: [Transcript] = [], pending: [Transcript] = [],
    configure: (TranscriptCoordinator, MeetingStore) throws -> Void = { _, _ in }
  ) async throws -> HistoryCatalogRig {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let changes = HistorySourceChanges()
    let store = TranscriptStore(
      directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let meetings = MeetingStore(
      root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    for row in rows { try store.save(row) }
    for row in pending { try store.savePending(row) }
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    try configure(coordinator, meetings)
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    return HistoryCatalogRig(
      root: root, changes: changes, store: store, meetings: meetings, session: session,
      coordinator: coordinator)
  }

  /// Waits until every change made so far is indexed.
  func settle() async {
    await session.waitForIndexingForTesting()
  }

  /// Every item `tab` lists now under its search and filters, all pages, newest first, as the
  /// diary draws them (items the screen hides at render time are left out).
  func listed(_ tab: HistoryTab) async -> [HistoryListItem] {
    let key = coordinator.historyQueryKey(
      for: tab, state: coordinator.requestedHistoryState(for: tab))
    guard var result = await coordinator.historyResults(for: key) else { return [] }
    while result.newerContinuation != nil,
      let next = await coordinator.historyResults(for: key, extending: result, newer: true)
    {
      result = next
    }
    while result.continuation != nil,
      let next = await coordinator.historyResults(for: key, extending: result)
    {
      result = next
    }
    return result.items.filter { coordinator.canRenderHistoryItem($0) }
  }

  /// The identities `tab` lists now, all pages.
  func listedIDs(_ tab: HistoryTab) async -> [HistoryItemID] {
    await listed(tab).map(\.id)
  }

  /// The History row ids `tab` lists now (a meeting's row id when it has one), all pages.
  func listedRowIDs(_ tab: HistoryTab) async -> [UUID] {
    await listed(tab).compactMap { item in
      if case .catalog(let summary) = item { return summary.rowID }
      return item.row?.id
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

extension HistoryCatalogRig {
  /// Runs `change` (a write the catalog watches) and returns once the catalog has published the
  /// result of indexing it. `settle()` alone can return before a late change notice has queued
  /// its pass; the content revision moving is the signal that the pass finished. Only for a
  /// change that alters what is indexed: a write the catalog finds unchanged never advances it.
  func applying(_ change: () async throws -> Void) async rethrows {
    let before = session.revision
    try await change()
    while session.revision == before {
      await session.waitForChange(revision: before, notices: session.noticeCount)
    }
    await settle()
  }
}
