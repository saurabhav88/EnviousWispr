import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprStorage

@Suite("History catalog pages and reopens saved projections", .tags(.productOutcome))
struct HistoryCatalogTests {
  @Test("Search, day counts and selected IDs cover all matches even when timestamps tie")
  func pagesAndMatches() async throws {
    let directory = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = try HistoryCatalog(directory: directory, projectionContext: "en|en_US")
    let day = Date(timeIntervalSinceReferenceDate: 750_000_000)
    let fixtures = (1...40).map { self.projection($0, date: day, text: "Client budget") }
    try await catalog.apply(fixtures, certifiedRevision: "complete")

    let query = HistoryCatalog.Query(tab: .dictations, search: "budg")
    let first = try await catalog.page(query, sourceRevision: "complete") { _ in true }
    #expect(first.summaries.count == 30)
    #expect(first.dayCounts?.values.first == 40)
    let after = try #require(first.continuation)
    let second = try await catalog.page(query, after: after, sourceRevision: "complete") { _ in true
    }
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
    let directory = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let day = Date(timeIntervalSinceReferenceDate: 750_000_000)
    let removed = projection(1, date: day, text: "first budget")
    let edited = projection(2, date: day, text: "second budget")
    do {
      let catalog = try HistoryCatalog(directory: directory, projectionContext: "en|en_US")
      try await catalog.apply([removed, edited], certifiedRevision: "old")
      let page = try await catalog.page(.init(tab: .dictations), sourceRevision: "old") {
        $0.key != removed.summary.key
      }
      #expect(page.summaries.map(\.key) == [edited.summary.key])
      #expect(page.dayCounts == nil)
      let replacement = projection(2, date: day, text: "café update")
      try await catalog.apply(
        [replacement], removing: [removed.summary.key], certifiedRevision: "current")
    }
    let reopened = try HistoryCatalog(directory: directory, projectionContext: "en|en_US")
    let result = try await reopened.page(.init(tab: .dictations, search: "budget")) { _ in true }
    #expect(result.summaries.isEmpty)
    let new = try await reopened.page(
      .init(tab: .dictations, search: "CAFÉ"), sourceRevision: "current"
    ) { _ in true }
    #expect(new.summaries.map(\.preview) == ["café update"])
    #expect(new.dayCounts?.values.first == 1)
  }

  @Test("A catalog localized for another language is rebuilt, never reused")
  func projectionContextChangeRebuilds() async throws {
    let directory = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let day = Date(timeIntervalSinceReferenceDate: 750_000_000)
    do {
      let english = try HistoryCatalog(directory: directory, projectionContext: "en|en_US")
      try await english.apply(
        [projection(1, date: day, text: "English preview")], certifiedRevision: "r1")
      try await english.closeDatabase()
    }
    var refusal: (any Error)?
    do {
      _ = try HistoryCatalog(directory: directory, projectionContext: "de|de_DE")
    } catch {
      refusal = error
    }
    let error = try #require(refusal)
    #expect(HistoryCatalog.needsRebuild(error))
    try HistoryCatalog.discardFiles(in: directory)
    let german = try HistoryCatalog(directory: directory, projectionContext: "de|de_DE")
    let page = try await german.page(.init(tab: .dictations)) { _ in true }
    #expect(page.summaries.isEmpty)
  }

  @MainActor
  @Test("Interrupted upgrade reopens with safe progress and picks up nested edits and deletes")
  func resumesRealSources() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptStore = TranscriptStore(directory: root.appendingPathComponent("transcripts"))
    let meetingStore = MeetingStore(root: root.appendingPathComponent("Meetings"))
    let meeting = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try meetingStore.create(meeting)
    try Data("first meeting note".utf8).write(
      to: meetingStore.notesURL(for: meeting.id), options: .atomic)
    let catalogFolder = root.appendingPathComponent("catalog")
    let rows = (1...36).map { index in
      Transcript(text: "budget " + String(index), processingTime: 0, backendType: .parakeet)
    }
    for row in rows { try transcriptStore.save(row) }
    let sources = transcriptStore.historyCatalogSources(meetings: meetingStore)
    let sourceRevision = OSAllocatedUnfairLock(initialState: UInt64(0))
    let project: @Sendable (HistoryCatalogSources.Saved) -> HistoryCatalog.Projection? = { source in
      if let record = source.meeting {
        let note = source.documents?.notes ?? ""
        return .init(
          summary: .init(
            key: .init(tab: .meetings, id: record.id), date: record.createdAt, preview: note,
            sources: source.versions), searchableFields: [note])
      }
      guard let row = source.transcript else { return nil }
      return .init(
        summary: .init(
          key: .init(tab: .dictations, id: row.id), date: row.createdAt, preview: row.text,
          sources: source.versions), searchableFields: [row.text])
    }
    let removed = try #require(rows.last)
    do {
      let initialCatalog = try HistoryCatalog(
        directory: catalogFolder, projectionContext: "en|en_US")
      let worker = HistoryCatalogReconciliation(
        catalog: initialCatalog, sources: sources,
        sourceRevision: { sourceRevision.withLock { $0 } },
        project: project)
      let interrupted = Task {
        try await worker.reconcile { pass in
          if pass.revision == nil, !pass.changed, pass.changedRows {
            do {
              let progress = try await initialCatalog.sourceProgress()
              #expect(progress.isEmpty, "row detection precedes the first committed batch")
            } catch {
              Issue.record("Could not inspect catalog progress at row detection: \(error)")
            }
          }
          // Only a committed batch counts: a detection signal (`changed == false`) comes first.
          if pass.revision == nil, pass.changed {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      }
      do {
        _ = try await interrupted.value
        Issue.record("The backfill completed after the first committed batch was interrupted")
      } catch is CancellationError {}
      let verified = try await initialCatalog.page(.init(tab: .dictations)) {
        try $0.sourcesStillMatch()
      }
      #expect(verified.summaries.isEmpty == false)
      #expect(verified.dayCounts == nil)
      #expect(
        FileManager.default.fileExists(atPath: meetingStore.notesDocumentURL(for: meeting.id).path)
          == false)
    }
    try transcriptStore.delete(id: removed.id)
    try Data("current budget note".utf8).write(
      to: meetingStore.notesURL(for: meeting.id), options: .atomic)
    let reopened = try HistoryCatalog(directory: catalogFolder, projectionContext: "en|en_US")
    let worker = HistoryCatalogReconciliation(
      catalog: reopened, sources: sources, sourceRevision: { sourceRevision.withLock { $0 } },
      project: project)
    let complete = try await worker.reconcile()
    let revision = try #require(complete?.revision)
    let keys = try await reopened.matchingKeys(.init(tab: .dictations), sourceRevision: revision)
    #expect(Set(keys.map(\.id)) == Set(rows.map(\.id)).subtracting([removed.id]))
    let old = try await reopened.page(
      .init(tab: .meetings, search: "first"), sourceRevision: revision
    ) {
      try $0.sourcesStillMatch()
    }
    #expect(old.summaries.isEmpty)
    let current = try await reopened.page(
      .init(tab: .meetings, search: "budg"), sourceRevision: revision
    ) {
      try $0.sourcesStillMatch()
    }
    #expect(current.summaries.map(\.preview) == ["current budget note"])
    let currentCoverage = worker.currentCoverage()
    #expect(currentCoverage == revision)
    sourceRevision.withLock { $0 += 1 }
    let invalidated = worker.currentCoverage()
    #expect(invalidated == nil)

    let moved = root.appendingPathComponent("saved-transcripts")
    try FileManager.default.moveItem(at: root.appendingPathComponent("transcripts"), to: moved)
    do {
      _ = try await worker.reconcile()
      Issue.record("A missing source was treated as a complete empty library")
    } catch is CocoaError {}
    let unverified = worker.currentCoverage()
    #expect(unverified == nil)
  }

  @MainActor
  @Test("Processing one of two settled saves cannot certify a stale archive")
  func completeChangeInterval() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = HistorySourceChanges()
    let stores = TranscriptStore(
      directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let sources = stores.historyCatalogSources(
      meetings: MeetingStore(root: root.appendingPathComponent("Meetings")))
    let catalog = try HistoryCatalog(
      directory: root.appendingPathComponent("catalog"), projectionContext: "en|en_US")
    let worker = HistoryCatalogReconciliation(
      catalog: catalog, sources: sources, sourceRevision: { changes.revision }
    ) {
      guard let row = $0.transcript else { return nil }
      return .init(
        summary: .init(
          key: .init(tab: .dictations, id: row.id), date: row.createdAt, preview: row.text,
          sources: $0.versions), searchableFields: [row.text])
    }
    let first = try await worker.reconcile()
    let established = try #require(first?.revision)
    #expect(worker.currentCoverage() == established)
    let one = Transcript(text: "first current record", processingTime: 0, backendType: .parakeet)
    let two = Transcript(text: "second current record", processingTime: 0, backendType: .parakeet)
    try stores.save(one)
    try stores.save(two)
    var notifications = changes.changes.makeAsyncIterator()
    var partial = HistorySourceChanges.Delta()
    for _ in 0..<2 {
      let event = await notifications.next()
      partial.include(try #require(event))
    }
    let incomplete = try await worker.refresh(partial)
    #expect(incomplete?.revision == nil)
    #expect(worker.currentCoverage() == nil)
    let completed = try await worker.reconcile()
    let revision = try #require(completed?.revision)
    let ids = try await catalog.matchingKeys(.init(tab: .dictations), sourceRevision: revision)
    #expect(Set(ids.map(\.id)) == [one.id, two.id])

    var delta = HistorySourceChanges.Delta()
    // Discard previously queued notifications. The new batch covers the complete change interval.
    for _ in 0..<2 { _ = await notifications.next() }
    let third = Transcript(text: "third current record", processingTime: 0, backendType: .parakeet)
    try stores.save(third)
    for _ in 0..<2 {
      let event = await notifications.next()
      delta.include(try #require(event))
    }
    let incremented = try await worker.refresh(delta)
    let next = try #require(incremented?.revision)
    let updated = try await catalog.matchingKeys(.init(tab: .dictations), sourceRevision: next)
    #expect(Set(updated.map(\.id)) == [one.id, two.id, third.id])
  }

  @MainActor
  @Test("An indexed meeting refreshes when only its transcript is edited")
  func meetingTranscriptDelta() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = HistorySourceChanges()
    let store = TranscriptStore(
      directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    // Keep the fixture setup out of the notification sequence for the tested mutation.
    let meetings = MeetingStore(root: root.appendingPathComponent("Meetings"))
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try meetings.create(record)
    let fixture = TranscriptStore(directory: root.appendingPathComponent("transcripts"))
    try fixture.save(Transcript(id: record.transcriptID, text: "before", meetingID: record.id))
    let catalog = try HistoryCatalog(
      directory: root.appendingPathComponent("catalog"), projectionContext: "en|en_US")
    let worker = HistoryCatalogReconciliation(
      catalog: catalog, sources: store.historyCatalogSources(meetings: meetings),
      sourceRevision: { changes.revision }
    ) { snapshot in
      guard let record = snapshot.meeting, let transcript = snapshot.transcript else { return nil }
      return .init(
        summary: .init(
          key: .init(tab: .meetings, id: record.id), date: record.createdAt,
          preview: transcript.text,
          sources: snapshot.versions), searchableFields: [transcript.text])
    }
    let first = try #require(try await worker.reconcile()?.revision)
    #expect(try await catalog.matchingKeys(.init(tab: .meetings), sourceRevision: first).count == 1)
    try store.save(Transcript(id: record.transcriptID, text: "after", meetingID: record.id))
    var iterator = changes.changes.makeAsyncIterator()
    var delta = HistorySourceChanges.Delta()
    for _ in 0..<2 {
      delta.include(try #require(await iterator.next()))
    }
    let revision = try #require(try await worker.refresh(delta)?.revision)
    let results = try await catalog.page(
      .init(tab: .meetings, search: "after"), sourceRevision: revision
    ) {
      try $0.sourcesStillMatch()
    }
    #expect(results.summaries.map(\.preview) == ["after"])
    #expect(results.summaries.first?.key.id == record.id)
  }

  #if DEBUG
    @MainActor
    @Test("Canonical writes share a fence without depending on the SQLite catalog")
    func canonicalWriters() async throws {
      let root = TestTemporaryDirectory.url.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let changes = HistorySourceChanges()
      let transcriptStore = TranscriptStore(
        directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
      let meetingStore = MeetingStore(
        root: root.appendingPathComponent("Meetings"), historyChanges: changes)
      let meeting = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      try meetingStore.create(meeting)
      let originalRevision = try #require(changes.revision)
      let direct = Transcript(text: "direct write", processingTime: 0, backendType: .parakeet)
      let durable = Transcript(text: "held open", processingTime: 0, backendType: .parakeet)
      let opened = DispatchSemaphore(value: 0)
      let close = DispatchSemaphore(value: 0)
      transcriptStore.durableWriteDidOpenForTesting = {
        opened.signal()
        close.wait()
      }
      let write = transcriptStore.durableWriter()
      let task = Task.detached { try write(durable) }
      do {
        defer { close.signal() }
        let didOpen = await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: opened.wait(timeout: .now() + 5) == .success)
          }
        }
        try #require(didOpen)
        #expect(changes.revision == nil)
        try transcriptStore.save(direct)
        try meetingStore.saveNotes("changed note", revision: 1, meeting: meeting.id)
        #expect(changes.revision == nil)
      }
      try await task.value
      #expect(changes.revision != originalRevision)
      #expect(try transcriptStore.rowReader()(direct.id)?.text == "direct write")
      try transcriptStore.delete(id: direct.id)
      let afterDelete = try #require(changes.revision)
      #expect(try transcriptStore.rowReader()(direct.id) == nil)
      try #require(throws: (any Error).self) { try meetingStore.create(meeting) }
      #expect(changes.revision != afterDelete)
      #expect(try meetingStore.historyDocuments(meeting: meeting.id).notes.contains("changed note"))
    }
  #endif

  private func projection(_ index: Int, date: Date, text: String) -> HistoryCatalog.Projection {
    let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index)))
    return HistoryCatalog.Projection(
      summary: .init(
        key: .init(tab: .dictations, id: id), date: date, preview: text,
        sources: [.init(name: "record", fingerprint: Data([UInt8(index)]))]),
      searchableFields: [text])
  }
}
