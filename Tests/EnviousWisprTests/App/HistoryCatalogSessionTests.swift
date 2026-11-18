import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

@MainActor
@Suite("History catalog opens independently of the old diary reader", .tags(.productOutcome))
struct HistoryCatalogSessionTests {
  @Test("A session pages and selects saved History without fully hydrating it")
  func pagedSession() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = HistorySourceChanges()
    let store = TranscriptStore(directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let meetings = MeetingStore(root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    let date = Date(timeIntervalSinceReferenceDate: 750_000_000)
    for _ in 1...40 {
      try store.save(Transcript(text: "budget notes", processingTime: 0, backendType: .parakeet, createdAt: date))
    }
    let held = Transcript(text: "held until Undo", escapeRecoveredAt: Date())
    try store.savePending(held)
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    #expect(coordinator.restorableHeldRow(id: held.id)?.text == "held until Undo")
    try store.delete(id: held.id)
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    let count = try await session.itemCount(now: Date())
    #expect(count?.count == 40)

    let key = coordinator.historyQueryKey(for: .dictations, state: coordinator.requestedHistoryState(for: .dictations))
    let first = try #require(await coordinator.historyResults(for: key))
    #expect(first.items.count == 30)
    #expect(first.catalogDayCounts?.values.first == 40)
    let next = try #require(await coordinator.historyResults(for: key, extending: first))
    #expect(next.items.count == 40)
    let matching = try #require(await coordinator.matchingIDs(for: first))
    #expect(Set(matching).count == 40)
    let rowID: UUID
    switch try #require(first.items.first?.id) {
    case .transcript(let id): rowID = id
    case .meeting:
      Issue.record("Dictations returned a meeting")
      return
    }
    let loaded = try #require(await coordinator.loadCatalogDetail(rowID))
    #expect(loaded.text == "budget notes")
    var state = coordinator.requestedHistoryState(for: .dictations)
    let deep = try #require(next.items.last?.id)
    state.scrollAnchorID = deep
    coordinator.setHistoryState(state, for: .dictations)
    let deepKey = coordinator.historyQueryKey(for: .dictations, state: state)
    let restored = try #require(await coordinator.historyResults(for: deepKey))
    #expect(restored.items.first?.id == deep)
    #expect(restored.newerContinuation != nil)
    let upward = try #require(await coordinator.historyResults(for: deepKey, extending: restored, newer: true))
    #expect(upward.items.count == 31)
    #expect(upward.items.last?.id == deep)

    // A mutation to an unrelated row cannot cause a queued update to mistake this one for missing.
    let unrelated = Transcript(text: "new words", processingTime: 0, backendType: .parakeet)
    let imported = Transcript(text: "current import", importedFileName: "interview.m4a")
    try await coordinator.saveAndShow(imported)
    _ = try #require(await coordinator.loadCatalogDetail(imported.id))
    #expect(coordinator.textForDelivery(imported) == "current import")
    changes.begin()
    #expect(coordinator.currentRow(id: imported.id)?.text == "current import")
    changes.finish(.transcript(unrelated.id))
    try store.save(unrelated)
    #expect(coordinator.currentRow(id: imported.id)?.text == "current import")
    let current = try #require(await coordinator.loadCatalogDetail(rowID, authoritative: true))
    #expect(current.id == loaded.id)
    // Simulates an older writer replacing a previously loaded file without a newer app notice.
    try TranscriptStore(directory: root.appendingPathComponent("transcripts")).delete(id: loaded.id)
    #expect(coordinator.textForDelivery(loaded) == nil)
    let orphanID = UUID()
    let orphan = Transcript(text: "meeting transcript", meetingID: orphanID)
    try store.save(orphan)
    #expect(coordinator.rowIDs(ofMeeting: orphanID).isEmpty)
    #expect(try await coordinator.savedRowIDs(ofMeeting: orphanID) == [orphan.id])
    try await coordinator.removeRow(id: orphan.id)
    #expect(try await coordinator.savedRowIDs(ofMeeting: orphanID).isEmpty)
    let relocated = root.appendingPathComponent("transcripts-backup")
    try FileManager.default.moveItem(at: root.appendingPathComponent("transcripts"), to: relocated)
    do {
      _ = try store.historyRowReader()(loaded.id, Date())
      Issue.record("The per-ID reader reported absence while its namespace was unavailable")
    } catch is CocoaError {}
    #expect(coordinator.visibleTranscripts.map(\.id) == [imported.id])
    #expect(coordinator.historyReadFinished == false)
  }

  @Test("A payload a view holds survives browsing past the cache limit; released, it goes")
  func heldPayloadSurvivesEviction() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = HistorySourceChanges()
    let store = TranscriptStore(directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let meetings = MeetingStore(root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    let base = Date(timeIntervalSinceReferenceDate: 750_000_000)
    var ids: [UUID] = []
    for index in 0..<125 {
      let row = Transcript(
        text: "row \(index)", processingTime: 0, backendType: .parakeet,
        createdAt: base.addingTimeInterval(Double(index)))
      try store.save(row)
      ids.append(row.id)
    }
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()

    // The oldest row, never the latest dictation the cache always keeps.
    let open = ids[0]
    _ = try #require(await coordinator.loadCatalogDetail(open))
    let hold = Task { await coordinator.holdCatalogDetail(open) }
    await Task.yield()
    #expect(coordinator.catalogDetailHoldCountForTesting(open) == 1)
    var loaded = 0
    for id in ids.dropFirst() where await coordinator.loadCatalogDetail(id) != nil { loaded += 1 }
    #expect(loaded == 124)
    #expect(session.latestDictation != open)
    #expect(coordinator.currentRow(id: open)?.text == "row 0")

    hold.cancel()
    await hold.value
    #expect(coordinator.catalogDetailHoldCountForTesting(open) == 0)
    // Released, it is the oldest entry: the next new payload pushes it out.
    _ = try #require(await coordinator.loadCatalogDetail(ids[1]))
    #expect(coordinator.currentRow(id: open) == nil)
  }

  // MARK: - "Updating History…" stays quiet when nothing changed (#4586)

  private func sources(_ root: URL) -> (HistorySourceChanges, TranscriptStore, MeetingStore) {
    let changes = HistorySourceChanges()
    let store = TranscriptStore(directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let meetings = MeetingStore(root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    return (changes, store, meetings)
  }

  private func save(_ count: Int, into store: TranscriptStore, from start: Int = 0) throws {
    let base = Date(timeIntervalSinceReferenceDate: 750_000_000)
    for index in start..<(start + count) {
      try store.save(
        Transcript(
          text: "row \(index)", processingTime: 0, backendType: .parakeet,
          createdAt: base.addingTimeInterval(Double(index))))
    }
  }

  /// A first launch that certifies the catalog, then ends (its session is released).
  private func firstLaunch(_ root: URL, rows: Int) async throws {
    let (changes, store, meetings) = sources(root)
    try save(rows, into: store)
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    #expect(session.status == .ready)
  }

  /// A later launch over the same folders; returns the label's whole history through the launch
  /// re-check, from the session's opt-in observer. Every source write comes before `start()`.
  private func laterLaunch(
    _ root: URL, addRows: Int = 0
  ) async throws -> (status: HistoryCatalogSession.Status, trace: [(status: HistoryCatalogSession.Status, shows: Bool)]) {
    let (changes, store, meetings) = sources(root)
    if addRows > 0 { try save(addRows, into: store, from: 10_000) }
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    var trace: [(status: HistoryCatalogSession.Status, shows: Bool)] = []
    session.updatingStateForTesting = { trace.append(($0, $1)) }
    defer { session.updatingStateForTesting = nil }
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    return (session.status, trace)
  }

  /// Every sync at `.updating` shows the label: a certifying publish sets `.ready` before it clears
  /// the label, so no sync sees `.updating` with the label already off.
  private static func shownUntilCertified(_ trace: [(status: HistoryCatalogSession.Status, shows: Bool)]) -> Bool {
    trace.allSatisfy { $0.status != .updating || $0.shows }
  }

  private func root() -> URL {
    TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  @Test("Relaunching over a certified catalog with nothing changed never shows the updating label")
  func quietRelaunch() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try await firstLaunch(root, rows: 5)
    let launch = try await laterLaunch(root)
    #expect(launch.status == .ready)
    #expect(launch.trace.isEmpty == false)
    #expect(launch.trace.allSatisfy { $0.shows == false }, "the label never showed: \(launch.trace.map(\.shows))")
    // The authority status still goes updating then ready.
    #expect(launch.trace.first?.status == .updating)
    #expect(launch.trace.last?.status == .ready)
  }

  @Test("A missing catalog shows the label once detected until certified")
  func missingCatalogShows() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let (changes, store, meetings) = sources(root)
    try save(5, into: store)
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    var trace: [(status: HistoryCatalogSession.Status, shows: Bool)] = []
    session.updatingStateForTesting = { trace.append(($0, $1)) }
    defer { session.updatingStateForTesting = nil }
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    #expect(session.status == .ready)
    #expect(trace.first.map { $0.status == .updating && $0.shows } == true, "\(trace.map(\.shows))")
    #expect(Self.shownUntilCertified(trace), "shown until certified: \(trace.map(\.shows))")
    #expect(trace.last.map { $0.status == .ready && $0.shows == false } == true)
    #expect(session.showsUpdating == false)
  }

  @Test("Rows changed since the last launch show the label while they apply, then clear it")
  func changedRowsShow() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try await firstLaunch(root, rows: 5)
    let launch = try await laterLaunch(root, addRows: 33)
    #expect(launch.status == .ready)
    #expect(launch.trace.contains { $0.status == .updating && $0.shows }, "shown while rows apply: \(launch.trace.map(\.shows))")
    #expect(launch.trace.last.map { $0.status == .ready && $0.shows == false } == true)
  }

  @Test(
    "A new dictation saved after launch that certifies in one publish never shows the label",
    .timeLimit(.minutes(1)))
  func backgroundRefreshStaysQuiet() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let (changes, store, meetings) = sources(root)
    try save(5, into: store)
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    #expect(session.status == .ready)
    var trace: [(status: HistoryCatalogSession.Status, shows: Bool)] = []
    session.updatingStateForTesting = { trace.append(($0, $1)) }
    defer { session.updatingStateForTesting = nil }
    let revision = session.revision
    try save(1, into: store, from: 20_000)
    // Wait for a content publish (the admitted notice can wake a notice wait before the settled
    // one queues the pass), then for the pass to end.
    while session.revision == revision, !Task.isCancelled {
      await session.waitForChange(revision: revision, notices: session.noticeCount)
    }
    try #require(!Task.isCancelled, "the background refresh did not publish")
    await session.waitForIndexingForTesting()
    let count = try await session.itemCount(now: Date())
    #expect(count?.count == 6, "the new dictation reached the catalog")
    #expect(session.status == .ready)
    #expect(trace.isEmpty == false, "the background pass published")
    #expect(trace.allSatisfy { $0.shows == false }, "the label never showed: \(trace.map(\.shows))")
  }

  @Test(
    "An outside notice for a dictation that did not change never shows the label",
    .timeLimit(.minutes(1)))
  func unchangedNoticeStaysQuiet() async throws {
    let created = root()
    defer { try? FileManager.default.removeItem(at: created) }
    // Resolve the temporary folder's symlinked /var first: a scoped refresh names a file by the
    // path the notice carries, and its saved proof is keyed by the path the scan found.
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    // `resolvingSymlinksInPath` maps /private/var back to /var, so ask the system for the real path.
    let resolved = try #require(realpath(created.path, nil))
    defer { free(resolved) }
    let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    let (changes, store, meetings) = sources(root)
    try save(5, into: store)
    let known = Transcript(
      text: "known row", processingTime: 0, backendType: .parakeet,
      createdAt: Date(timeIntervalSinceReferenceDate: 751_000_000))
    try store.save(known)
    // Files written moments ago are re-read until they age (their proofs change while they are
    // fresh), which is real row work. Age every saved file so this notice names an unchanged one.
    let transcripts = root.appendingPathComponent("transcripts")
    let files = try FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
    for file in files {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: file.path)
    }
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    #expect(session.status == .ready)
    var trace: [(status: HistoryCatalogSession.Status, shows: Bool)] = []
    session.updatingStateForTesting = { trace.append(($0, $1)) }
    defer { session.updatingStateForTesting = nil }
    let notices = session.noticeCount
    // Another process "touched" the dictation without changing what History shows: it names the
    // row, but the scoped refresh finds the same key and the same source proof.
    changes.externalChange(.transcript(known.id))
    while session.noticeCount == notices, !Task.isCancelled {
      await session.waitForChange(revision: session.revision, notices: notices)
    }
    try #require(!Task.isCancelled, "the notice did not reach the session")
    await session.waitForIndexingForTesting()
    #expect(session.status == .ready)
    #expect(trace.isEmpty == false, "the scoped refresh ran and reported")
    #expect(trace.allSatisfy { $0.shows == false }, "the label never showed: \(trace.map(\.shows))")
  }

  @Test("One dictation restored while the app was closed shows the label before it is applied")
  func oneChangedRowShows() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try await firstLaunch(root, rows: 5)
    let launch = try await laterLaunch(root, addRows: 1)
    #expect(launch.status == .ready)
    #expect(launch.trace.contains { $0.status == .updating && $0.shows }, "shown before certification: \(launch.trace.map(\.shows))")
    #expect(launch.trace.last.map { $0.status == .ready && $0.shows == false } == true)
  }

  @Test(
    "A catalog found corrupt by a background pass shows the label during the repair, then clears it",
    .timeLimit(.minutes(1)))
  func corruptCatalogRepairShows() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let (changes, store, meetings) = sources(root)
    try save(5, into: store)
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    #expect(session.status == .ready)
    var trace: [(status: HistoryCatalogSession.Status, shows: Bool)] = []
    session.updatingStateForTesting = { trace.append(($0, $1)) }
    defer { session.updatingStateForTesting = nil }
    // Damage the database the open session holds, then let a background pass find it.
    let database = root.appendingPathComponent("catalog").appendingPathComponent("history.sqlite")
    let handle = try FileHandle(forWritingTo: database)
    try handle.write(contentsOf: Data(repeating: 0x41, count: 8_192))
    try handle.close()
    let revision = session.revision
    try save(1, into: store, from: 30_000)
    while session.revision == revision, !Task.isCancelled {
      await session.waitForChange(revision: revision, notices: session.noticeCount)
    }
    try #require(!Task.isCancelled, "the background pass did not publish")
    // The error schedules the repair a moment later; wait for the catalog to certify again.
    while session.status != .ready, !Task.isCancelled {
      await session.waitForChange(revision: session.revision, notices: session.noticeCount)
    }
    try #require(!Task.isCancelled, "the repair did not certify")
    await session.waitForIndexingForTesting()
    #expect(trace.contains { $0.status == .unavailable }, "the pass found the damage: \(trace.map(\.status))")
    #expect(
      trace.filter { $0.status == .unavailable }.allSatisfy { $0.shows },
      "the label shows through the repair: \(trace.map { "\($0.status) \($0.shows)" })")
    #expect(session.status == .ready)
    #expect(session.showsUpdating == false)
  }

  @Test("A damaged catalog is rebuilt with the label shown until certified")
  func damagedCatalogShows() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try await firstLaunch(root, rows: 5)
    let catalog = root.appendingPathComponent("catalog")
    for name in ["history.sqlite-wal", "history.sqlite-shm"] {
      try? FileManager.default.removeItem(at: catalog.appendingPathComponent(name))
    }
    try Data(repeating: 0x41, count: 4_096).write(to: catalog.appendingPathComponent("history.sqlite"))
    let launch = try await laterLaunch(root)
    #expect(launch.status == .ready)
    #expect(launch.trace.first.map { $0.status == .updating && $0.shows } == true, "\(launch.trace.map(\.shows))")
    #expect(Self.shownUntilCertified(launch.trace), "shown until certified: \(launch.trace.map(\.shows))")
    #expect(launch.trace.last.map { $0.status == .ready && $0.shows == false } == true)
  }
}
