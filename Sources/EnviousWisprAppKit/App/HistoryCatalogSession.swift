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

  @ObservationIgnored private let changes: HistorySourceChanges
  @ObservationIgnored private let sources: HistoryCatalogSources
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var backend: Backend?
  @ObservationIgnored private var opening: Task<Backend, any Error>?
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored private var indexing: Task<Void, Never>?
  @ObservationIgnored private var pending = HistorySourceChanges.Delta()

  private struct Backend: Sendable {
    let catalog: HistoryCatalog
    let worker: HistoryCatalogReconciliation
  }

  init(changes: HistorySourceChanges, sources: HistoryCatalogSources, directory: URL) {
    self.changes = changes
    self.sources = sources
    self.directory = directory
  }

  func start() {
    guard observation == nil else { return }
    observation = Task { [weak self, changes] in
      for await event in changes.changes {
        guard let self else { return }
        invalidate()
        pending.include(event)
        indexIfNeeded()
      }
    }
    pending.include(.unknown)
    indexIfNeeded()
  }

  func sourceMayHaveChanged() {
    invalidate()
    pending.include(.unknown)
    indexIfNeeded()
  }

  private func invalidate() {
    status = .updating
    revision &+= 1
  }

  private func open() async throws -> Backend {
    if let backend { return backend }
    if let opening { return try await opening.value }
    let opening = Task.detached(priority: .utility) { [changes, sources, directory] in
      let catalog: HistoryCatalog
      do {
        catalog = try HistoryCatalog(directory: directory)
      } catch HistoryCatalog.Failure.incompatibleSchema {
        try HistoryCatalog.discardFiles(in: directory)
        catalog = try HistoryCatalog(directory: directory)
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
    _ query: HistoryCatalog.Query, after cursor: HistoryCatalog.Cursor? = nil
  ) async throws -> HistoryCatalog.Page? {
    let id = revision
    let source = changes.revision
    guard source != nil else { return nil }
    let backend = try await open()
    let coverage = await backend.worker.currentCoverage()
    let result = try await backend.catalog.page(query, after: cursor, sourceRevision: coverage) {
      (try? $0.sourcesStillMatch()) == true
    }
    guard !Task.isCancelled, id == revision, source == changes.revision else { return nil }
    return result
  }

  func matchingKeys(_ query: HistoryCatalog.Query) async throws -> [HistoryCatalog.Key]? {
    let id = revision
    let source = changes.revision
    guard source != nil else { return nil }
    let backend = try await open()
    guard let coverage = await backend.worker.currentCoverage() else { return nil }
    let result = try await backend.catalog.matchingKeys(query, sourceRevision: coverage)
    guard !Task.isCancelled, id == revision, source == changes.revision else { return nil }
    return result
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
          if !delta.scopes.contains(.all), pass?.revision == nil {
            pending.include(.unknown)
          }
        } catch is CancellationError {
          return
        } catch {
          status = .unavailable
          revision &+= 1
        }
      }
    }
  }

  private func publishProgress(_ pass: HistoryCatalogReconciliation.Pass) {
    status = pass.revision == nil ? .updating : .ready
    revision &+= 1
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
        preview: "", sources: source.versions), searchableFields: [])
    }
    let title = row.importedFileName
    let availableText = row.historyText
    let summary = HistoryCatalog.Summary(
      key: .init(tab: row.isImported ? .transcripts : .dictations, id: row.id),
      date: row.createdAt, appKey: row.isImported ? nil : row.metrics?.targetApp,
      title: title, preview: String(availableText.prefix(600)), sources: source.versions,
      expiresAt: row.escapeRecoveredAt?.addingTimeInterval(AppConstants.pendingTranscriptRetention))
    var fields = [availableText]
    if let title { fields.append(title) }
    if let names = row.speakerNames { fields.append(contentsOf: names.values) }
    return .init(summary: summary, searchableFields: row.escapeRecoveredAt == nil ? fields : [])
  }
}
