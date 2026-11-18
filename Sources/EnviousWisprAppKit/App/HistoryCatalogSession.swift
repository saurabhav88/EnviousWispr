import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation
import os

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
  /// The CONTENT revision (#4586 H1): advances only when catalog rows or source proofs changed,
  /// the catalog was replaced, indexing failed after possibly committing rows, or a pass
  /// certified a source revision. A status-only change (`updating`, `ready`, `unavailable`)
  /// leaves it alone, so it never re-keys the History list or a detail read. Every write goes
  /// through `advanceContent()`, which also wakes `waitForChange`.
  private(set) var revision: UInt64 = 0
  /// Outside and in-process change notices seen by this session (#4586 N1), unobserved. The
  /// History list wakes on it to re-check a kept page's rows before any publish arrives.
  @ObservationIgnored private(set) var noticeCount: UInt64 = 0
  @ObservationIgnored private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Reset when a pass starts, so the first committed batch of each pass is marked once.
  @ObservationIgnored private var batchMarked = false
  private(set) var latestDictation: UUID?

  @ObservationIgnored private let changes: HistorySourceChanges
  @ObservationIgnored private let sources: HistoryCatalogSources
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var backend: Backend?
  @ObservationIgnored private var opening: Task<Backend, any Error>?
  @ObservationIgnored private var diskWatch: HistoryDiskWatch?
  /// The one in-flight watcher registration (#4598). Registration blocks on `fseventsd`, so it
  /// runs off the main actor; a second request while one runs is folded into `rewatchRequested`.
  @ObservationIgnored private var registration: Task<Void, Never>?
  @ObservationIgnored private var rewatchRequested = false
  /// Registrations started this session; one per start plus one per real root change (#4598).
  @ObservationIgnored private(set) var watcherRegistrations = 0
  /// What the screen last saw (#4598): publish only when rows, availability or the certified
  /// source revision change, and at most every `publishInterval` while a pass is mid-way.
  /// The certified source revision the screen last saw, cleared when a pass starts.
  @ObservationIgnored private var publishedCertifiedSource: UInt64?
  @ObservationIgnored private var publishedAt: ContinuousClock.Instant?
  @ObservationIgnored private var everCertified = false
  private static let publishInterval = Duration.milliseconds(250)
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
    registration?.cancel()
    observation?.cancel()
    indexing?.cancel()
    retry?.cancel()
    opening?.cancel()
  }

  func start() {
    guard observation == nil else { return }
    observation = Task { [weak self, changes] in
      for await event in changes.changes {
        guard let self else { return }
        // #4598: a notice only adds work. It never withdraws what the screen shows or
        // re-creates the watcher; a pass publishes when it actually changes something.
        pending.include(event)
        noticeCount &+= 1
        resumeChangeWaiters()
        indexIfNeeded()
      }
    }
    registerWatcher()
    pending.include(.unknown)
    indexIfNeeded()
  }

  /// Build the one folder watcher off the main actor. Registration is a coverage boundary:
  /// a change between an earlier scan and the stream's start would be in neither, so on success
  /// the source revision advances before the watcher becomes available, then one full pass is
  /// enqueued; only a pass that began after registration can restore coverage.
  private func registerWatcher() {
    guard registration == nil else {
      rewatchRequested = true
      return
    }
    watcherRegistrations += 1
    let directories = sources.watchedDirectories
    let scope: @Sendable (String) -> HistorySourceChanges.Scope? = { [sources] path in sources.scope(forPath: path) }
    let deliver: @Sendable (Set<HistoryDiskWatch.Event>) -> Void = { [weak self, changes] events in
      for event in events {
        switch event {
        case .scope(let scope): changes.externalChange(scope)
        case .rescan: changes.externalChange()
        case .rootChanged:
          changes.externalChange()
          Task { @MainActor [weak self] in self?.rootChanged() }
        }
      }
    }
    registration = Task { [weak self] in
      let watch = await Task.detached(priority: .utility) {
        HistoryDiskWatch(directories: directories, scope: scope, changed: deliver)
      }.value
      guard let self, !Task.isCancelled else { return }
      registration = nil
      if let watch {
        changes.advanceWithoutNotice()
        diskWatch = watch
        // The advance above makes any page read started before it come back empty, and at
        // launch that read is the first page of saved cards. Ask the screen to read again
        // now rather than after the full pass this enqueues.
        advanceContent()
        didUpdate?()
        pending.include(.unknown)
        indexIfNeeded()
      } else if status != .unavailable {
        // No watcher: coverage-dependent reads stay off; activation retries (sourceMayHaveChanged).
        // Status only (#4586 H1): no catalog row changed, so the list keeps its page.
        status = .unavailable
        didUpdate?()
      }
      if rewatchRequested {
        rewatchRequested = false
        rootChanged()
      }
    }
  }

  /// A watched root was created, moved, deleted or replaced: drop the stream and register again.
  private func rootChanged() {
    diskWatch = nil
    registerWatcher()
  }

  func sourceMayHaveChanged() {
    if diskWatch == nil, registration == nil { registerWatcher() }
    guard diskWatch == nil || status == .unavailable else { return }
    changes.externalChange()
  }

  func updateLatestDictation(_ id: UUID?) {
    latestDictation = id
  }

  private func invalidate() {
    status = .updating
    advanceContent()
  }

  private func advanceContent() {
    revision &+= 1
    resumeChangeWaiters()
  }

  private func resumeChangeWaiters() {
    guard !changeWaiters.isEmpty else { return }
    let waiting = changeWaiters
    changeWaiters.removeAll()
    for waiter in waiting.values { waiter.resume() }
  }

  /// Returns once the content revision differs from `revision` or a change notice arrived after
  /// `notices` was read, or when the calling task is cancelled (#4586 H1). It returns at once
  /// if either already moved. Cancellation before or after the wait registers is handled: the
  /// registration re-checks `Task.isCancelled` on the main actor, and the cancel path resumes
  /// the registered waiter on the main actor, so neither order loses a wake or leaks a waiter.
  func waitForChange(revision expected: UInt64, notices: UInt64) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
        if Task.isCancelled || revision != expected || noticeCount != notices {
          waiter.resume()
        } else {
          changeWaiters[id] = waiter
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.changeWaiters.removeValue(forKey: id)?.resume() }
    }
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
    let source = changes.revision
    guard source != nil else { return nil }
    let backend = try await open()
    #if DEBUG
      await beforePageCatalogForTesting?()
    #endif
    let coverage = diskWatch == nil ? nil : backend.worker.currentCoverage()
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
    #if DEBUG
      await beforePageFenceForTesting?()
    #endif
    // #4586 H1: the page fences on the source revision only. A content publish while it was
    // read (indexing progress, a new certificate) does not throw it away; the list reads again
    // after showing it, and a page read under an older content revision cannot authorize
    // selection or paging (`TranscriptCoordinator.isCurrentHistoryResult`).
    guard !Task.isCancelled, source == changes.revision else { return nil }
    return result
  }

  func matchingKeys(_ query: HistoryCatalog.Query) async throws -> [HistoryCatalog.Key]? {
    let id = revision
    let source = changes.revision
    guard source != nil else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = backend.worker.currentCoverage() else { return nil }
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
    guard diskWatch != nil, let coverage = backend.worker.currentCoverage() else { return nil }
    let count = try await backend.catalog.itemCount(now: now, sourceRevision: coverage)
    guard !Task.isCancelled, changes.revision == source else { return nil }
    return (count, source)
  }

  func appCounts(now: Date) async throws -> [(String?, Int)]? {
    let stamp = revision
    guard let source = changes.revision else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = backend.worker.currentCoverage() else { return nil }
    let counts = try await backend.catalog.appCounts(now: now, sourceRevision: coverage)
    return stamp == revision && source == changes.revision && !Task.isCancelled ? counts : nil
  }

  func activity(_ query: HistoryCatalog.Query) async throws -> [Date: Int]? {
    let stamp = revision
    guard let source = changes.revision else { return nil }
    let backend = try await open()
    guard diskWatch != nil, let coverage = backend.worker.currentCoverage() else { return nil }
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
        // Every pass withdraws the worker's certificate while it runs, so a page read meanwhile
        // has no exact totals or selection. A pass that ends certified must therefore publish
        // even for an unchanged source revision, or that page is never re-read (#4605 review).
        publishedCertifiedSource = nil
        batchMarked = false
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
          #if DEBUG
            await afterPassOpenForTesting?()
          #endif
          let pass: HistoryCatalogReconciliation.Pass?
          if delta.scopes.contains(.all) {
            #if DEBUG
              await beforeReconcileForTesting?()
            #endif
            pass = try await backend.worker.reconcile { [weak self] pass in
              await self?.publishProgress(pass)
            }
          } else {
            pass = try await backend.worker.refresh(delta)
          }
          if let pass { publishProgress(pass, final: true) }
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
          // Content, not only status (#4586 H1): batches committed before the error may have
          // had their publishes throttled, and the error withdrew coverage.
          advanceContent()
          if HistoryCatalog.needsRebuild(error) { rebuildRequested = true }
          scheduleRetry()
        }
      }
    }
  }

  /// #4598: publish only what the screen needs. Rows or source proofs changed, availability
  /// changed, or a pass certified a different source revision; a new certificate for the same
  /// revision is not a change. While a pass is mid-way, at most every `publishInterval`.
  private func publishProgress(_ pass: HistoryCatalogReconciliation.Pass, final: Bool = false) {
    let watcherFailed = diskWatch == nil && registration == nil
    let next: Status
    if pass.unavailable > 0 || watcherFailed {
      next = .unavailable
    } else if pass.revision != nil {
      next = .ready
      everCertified = true
    } else if everCertified, status == .ready {
      // A background re-check over a list that was certified: keep it as it is.
      next = .ready
    } else {
      next = .updating
    }
    let certified = pass.revision == nil ? nil : pass.certifiedSource
    let finished = final || pass.revision != nil || pass.unavailable > 0
    let newCertificate = certified != nil && certified != publishedCertifiedSource
    guard pass.changed || next != status || newCertificate else { return }
    let now = ContinuousClock.now
    if !finished, next == status, let publishedAt, now - publishedAt < Self.publishInterval { return }
    status = next
    if let certified { publishedCertifiedSource = certified }
    publishedAt = now
    if pass.changed, !batchMarked {
      batchMarked = true
      HistorySignpost.event("HistoryFirstBatchCommit")
    }
    // #4586 H1: only rows, proofs or a restored certificate (#4605) are content; a publish that
    // only moves the status leaves the list's key and every detail read alone.
    if Self.advancesContent(changed: pass.changed, newCertificate: newCertificate) { advanceContent() }
    didUpdate?()
  }

  /// Whether a publish is a content change (#4586 H1). Kept as one decision so a test can pin
  /// it without a staged indexing pass.
  nonisolated static func advancesContent(changed: Bool, newCertificate: Bool) -> Bool {
    changed || newCertificate
  }

  // periphery:ignore - The session integration test waits for the real indexing task.
  /// Waits until the watcher registration and every queued pass have finished, including
  /// feed events still in flight to the observation task.
  func waitForIndexingForTesting() async {
    var idleChecks = 0
    while idleChecks < 3 {
      if let registration {
        await registration.value
        idleChecks = 0
      } else if let indexing {
        await indexing.value
        idleChecks = 0
      } else {
        await Task.yield()
        idleChecks += 1
      }
    }
  }

  // periphery:ignore - Tests check the one watcher is installed (#4598).
  var watcherIsInstalledForTesting: Bool { diskWatch != nil }

  #if DEBUG
    /// Runs inside `page` after the read and before its fence (#4586 H1 tests).
    @ObservationIgnored var beforePageFenceForTesting: (@MainActor () async -> Void)?
    /// Runs inside `page` after the backend is open and before any catalog call (#4586 package I).
    @ObservationIgnored var beforePageCatalogForTesting: (@MainActor () async -> Void)?
    /// Runs in the indexing loop right after the backend is open (#4586 package I).
    @ObservationIgnored var afterPassOpenForTesting: (@MainActor () async -> Void)?
    /// Runs right before a full pass calls `reconcile` (#4586 package I).
    @ObservationIgnored var beforeReconcileForTesting: (@MainActor () async -> Void)?
    /// A content publish with no indexing pass behind it (#4586 H1 tests).
    func advanceContentForTesting() { advanceContent() }
    var changeWaiterCountForTesting: Int { changeWaiters.count }
  #endif

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
    let title = row.displayTitle
    let availableText = row.historyText
    let summary = HistoryCatalog.Summary(
      key: .init(tab: row.isImported ? .transcripts : .dictations, id: row.id),
      date: row.createdAt, appKey: row.isImported ? nil : row.metrics?.targetApp,
      title: title, preview: String(availableText.prefix(600)), sources: source.versions,
      expiresAt: row.escapeRecoveredAt?.addingTimeInterval(AppConstants.pendingTranscriptRetention),
      rowID: row.id, duration: row.duration,
      backendName: row.backendType.displayName, polishModel: row.llmModel, wasPolished: row.polishedText != nil,
      recovered: row.isRecovered, interrupted: row.inputDeviceWasRemoved,
      // #4611: a transcript card counts its speakers from this, as a meeting card does.
      meetingAnalysis: row.isImported ? HistoryTranscriptPresentation.catalogSpeakerAnalysis(row) : nil,
      dictation: row.isImported ? nil : HistoryDictationDisplay.catalogData(of: row))
    var fields = [availableText]
    // A renamed import is still found by its file name (#4611).
    if let customTitle = row.customTitle { fields.append(customTitle) }
    if let fileName = row.importedFileName { fields.append(fileName) }
    if let names = row.speakerNames { fields.append(contentsOf: names.values) }
    return .init(summary: summary, searchableFields: row.escapeRecoveredAt == nil ? fields : [])
  }
}

/// Content-free History timing marks for Instruments (#4586; names in the shared notes). They
/// carry names only, never row text, titles or ids.
enum HistorySignpost {
  nonisolated static let signposter = OSSignposter(subsystem: "com.enviouswispr.app", category: "HistorySpeed")

  nonisolated static func event(_ name: StaticString) {
    signposter.emitEvent(name)
  }
}
