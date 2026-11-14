import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// Connects the shared source owners to a single derived catalog. The diary can open this
/// independently of legacy command hydration; catalog failure never changes a source write.
@MainActor @Observable
final class HistoryCatalogSession {
  enum Status: Equatable {
    case updating
    case ready
    case unavailable
  }

  private(set) var status: Status = .updating
  private(set) var revision: UInt64 = 0
  private(set) var latestDictation: UUID?

  @ObservationIgnored private let changes: HistorySourceChanges
  @ObservationIgnored private let sources: HistoryCatalogSources
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var backend: Backend?
  @ObservationIgnored private var opening: Task<Backend, any Error>?
  @ObservationIgnored private var diskWatch: HistoryDiskWatch?
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var indexing: Task<Void, Never>?
  @ObservationIgnored private var rebuildRequested = false
  @ObservationIgnored private var pending = HistorySourceChanges.Delta()
  @ObservationIgnored var didUpdate: (@MainActor () -> Void)?
  @ObservationIgnored var didRecoverSources: (@MainActor () -> Void)?

  private struct Backend: Sendable {
    let catalog: HistoryCatalog
    let worker: HistoryCatalogReconciliation
  }

  init(changes: HistorySourceChanges, sources: HistoryCatalogSources, directory: URL) {
    self.changes = changes
    self.sources = sources
    self.directory = directory
  }

  deinit {
    observation?.cancel()
    indexing?.cancel()
    retry?.cancel()
    opening?.cancel()
  }

  func start() {
    guard observation == nil else { return }
    startWatchingDisk()
    observation = Task { [weak self, changes] in
      for await event in changes.changes {
        guard let self else { return }
        invalidate()
        if case .unknown = event {
          startWatchingDisk()
        }
        pending.include(event)
        indexIfNeeded()
      }
    }
    pending.include(.unknown)
    indexIfNeeded()
  }

  private func startWatchingDisk() {
    // Watch the common parent as well so a missing or replaced child can be seen.
    diskWatch = HistoryDiskWatch(directories: sources.watchedDirectories) { [changes] in
      changes.externalChange()
    }
  }

  func sourceMayHaveChanged() {
    guard diskWatch == nil || status == .unavailable else { return }
    changes.externalChange()
  }

  func updateLatestDictation(_ id: UUID?) {
    latestDictation = id
  }

  private func invalidate() {
    status = .updating
    revision &+= 1
  }

  /// The interface language and locale this process localizes previews for. Both are fixed
  /// at launch (`AppLanguagePreference`), so one value serves the whole session.
  nonisolated static var projectionContext: String {
    Bundle.main.preferredLocalizations.joined(separator: ",") + "|" + Locale.current.identifier
  }

  private func open() async throws -> Backend {
    if let backend { return backend }
    if let opening { return try await opening.value }
    let opening = Task.detached(priority: .utility) { [changes, sources, directory] in
      let catalog: HistoryCatalog
      do {
        catalog = try HistoryCatalog(directory: directory, projectionContext: Self.projectionContext)
      } catch where HistoryCatalog.needsRebuild(error) {
        try HistoryCatalog.discardFiles(in: directory)
        catalog = try HistoryCatalog(directory: directory, projectionContext: Self.projectionContext)
      }
      let worker = HistoryCatalogReconciliation(
        catalog: catalog, sources: sources, sourceRevision: { changes.revision },
        project: Self.project)
      return Backend(catalog: catalog, worker: worker)
    }
    self.opening = opening
    defer { self.opening = nil }
    let opened = try await opening.value
    backend = opened
    return opened
  }

  func page(
    _ query: HistoryCatalog.Query, after cursor: HistoryCatalog.Cursor? = nil, restoring anchor: UUID? = nil, newer: Bool = false
  ) async throws -> HistoryCatalog.Page? {
    let id = revision
    let source = changes.revision
    guard source != nil else { return nil }
    let backend = try await open()
    let coverage = diskWatch == nil ? nil : await backend.worker.currentCoverage()
    let boundary: HistoryCatalog.Cursor?
    if let anchor, cursor == nil {
      boundary = try await backend.catalog.cursorBefore(anchor, query: query)
    } else {
      boundary = cursor
    }
    let result: HistoryCatalog.Page
    do {
      result = try await backend.catalog.page(query, after: boundary, newer: newer, sourceRevision: coverage) {
        (try? $0.sourcesStillMatch()) == true
      }
    } catch {
      if HistoryCatalog.needsRebuild(error) { requestRebuild() }
      throw error
    }
    guard !Task.isCancelled, id == revision, source == changes.revision else { return nil }
    return result
  }

  func matchingKeys(_ query: HistoryCatalog.Query) async throws -> [HistoryCatalog.Key]? {
    let id = revision
    let source = changes.revision
    guard source != nil else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = await backend.worker.currentCoverage() else { return nil }
    let result = try await backend.catalog.matchingKeys(query, sourceRevision: coverage)
    guard !Task.isCancelled, id == revision, source == changes.revision else { return nil }
    return result
  }

  var stableSourceRevision: UInt64? { changes.revision }

  func summary(for key: HistoryCatalog.Key) async throws -> HistoryCatalog.Summary? {
    let backend = try await open()
    guard let summary = try await backend.catalog.summary(for: key),
      try summary.sourcesStillMatch(), !Task.isCancelled else { return nil }
    return summary
  }

  func itemCount(now: Date) async throws -> (count: Int, source: UInt64)? {
    guard status == .ready, let source = changes.revision else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = await backend.worker.currentCoverage() else { return nil }
    let count = try await backend.catalog.itemCount(now: now, sourceRevision: coverage)
    guard !Task.isCancelled, changes.revision == source else { return nil }
    return (count, source)
  }

  func appCounts(now: Date) async throws -> [(String?, Int)]? {
    let stamp = revision
    guard let source = changes.revision else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = await backend.worker.currentCoverage() else { return nil }
    let counts = try await backend.catalog.appCounts(now: now, sourceRevision: coverage)
    return stamp == revision && source == changes.revision && !Task.isCancelled ? counts : nil
  }

  func activity(_ query: HistoryCatalog.Query) async throws -> [Date: Int]? {
    let stamp = revision
    guard let source = changes.revision else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = await backend.worker.currentCoverage() else { return nil }
    let result = try await backend.catalog.activity(query, sourceRevision: coverage)
    return stamp == revision && source == changes.revision && !Task.isCancelled ? result : nil
  }

  private func requestRebuild() {
    guard !rebuildRequested else { return }
    rebuildRequested = true
    invalidate()
    pending.include(.unknown)
    indexIfNeeded()
  }

  private func scheduleRetry() {
    guard retry == nil else { return }
    retry = Task(priority: .utility) { [weak self] in
      // Reconciliation owns this retry. View churn and tab switches cannot cancel repair.
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self else { return }
      retry = nil
      pending.include(.unknown)
      indexIfNeeded()
    }
  }

  private func indexIfNeeded() {
    guard indexing == nil, !pending.scopes.isEmpty else { return }
    indexing = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      defer { indexing = nil }
      while !pending.scopes.isEmpty {
        let delta = pending
        pending = HistorySourceChanges.Delta()
        do {
          if rebuildRequested {
            rebuildRequested = false
            if let backend {
              try await backend.catalog.closeDatabase()
              self.backend = nil
            }
            try HistoryCatalog.discardFiles(in: directory)
          }
          let backend = try await open()
          let pass: HistoryCatalogReconciliation.Pass?
          if delta.scopes.contains(.all) {
            pass = try await backend.worker.reconcile { [weak self] pass in
              await self?.publishProgress(pass)
            }
          } else {
            pass = try await backend.worker.refresh(delta)
          }
          if let pass { publishProgress(pass) }
          if pass?.revision == nil {
            // A failed record is different from a scan raced by a canonical writer.
            // Wait for the affected source to change or for an explicit recovery trigger.
            if pass?.unavailable != 0 {
              continue
            }
            if !delta.scopes.contains(.all) {
              pending.include(.unknown)
            }
          } else {
            if delta.scopes.contains(.all), status == .ready { didRecoverSources?() }
            retry?.cancel()
            retry = nil
          }
        } catch is CancellationError {
          return
        } catch {
          status = .unavailable
          revision &+= 1
          if HistoryCatalog.needsRebuild(error) { rebuildRequested = true }
          scheduleRetry()
        }
      }
    }
  }

  private func publishProgress(_ pass: HistoryCatalogReconciliation.Pass) {
    if pass.unavailable > 0 || diskWatch == nil {
      status = .unavailable
    } else {
      status = pass.revision == nil ? .updating : .ready
    }
    revision &+= 1
    didUpdate?()
  }

  // periphery:ignore - The session integration test waits for the real indexing task.
  func waitForIndexingForTesting() async {
    await indexing?.value
  }

  nonisolated private static func project(_ source: HistoryCatalogSources.Saved) -> HistoryCatalog.Projection? {
    if let meeting = source.meeting {
      return MeetingHistoryPresentation.catalogProjection(source, meeting: meeting)
    }
    guard let row = source.transcript else { return nil }
    if let meetingID = row.meetingID {
      // A recorded row whose original meeting folder is gone still has its distinct meeting ID.
      // There is no committed context proving which text may be displayed.
      return .init(summary: .init(
        key: .init(tab: .meetings, id: meetingID), date: row.createdAt,
        preview: "", sources: source.versions, rowID: row.id,
        backendName: row.backendType.displayName, meetingAnalysis: row.speakerAnalysis), searchableFields: [])
    }
    let title = row.importedFileName
    let availableText = row.historyText
    let summary = HistoryCatalog.Summary(
      key: .init(tab: row.isImported ? .transcripts : .dictations, id: row.id),
      date: row.createdAt, appKey: row.isImported ? nil : row.metrics?.targetApp,
      title: title, preview: String(availableText.prefix(600)), sources: source.versions,
      expiresAt: row.escapeRecoveredAt?.addingTimeInterval(AppConstants.pendingTranscriptRetention),
      rowID: row.id, duration: row.duration, speakerNames: HistoryTranscriptPresentation.speakerList(row),
      backendName: row.backendType.displayName, polishModel: row.llmModel, wasPolished: row.polishedText != nil,
      recovered: row.isRecovered, interrupted: row.inputDeviceWasRemoved)
    var fields = [availableText]
    if let title { fields.append(title) }
    if let names = row.speakerNames { fields.append(contentsOf: names.values) }
    return .init(summary: summary, searchableFields: row.escapeRecoveredAt == nil ? fields : [])
  }
}
