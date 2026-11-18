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
  /// Shows while History needs a build or has committed row changes awaiting certification
  /// (#4586). Display only: `status` and every reader of it keep their meaning. A launch
  /// re-check over a certified catalog that finds no row work stays false. It can be true while
  /// `status` is `.ready` (a background pass changing rows). Set only through
  /// `syncShowsUpdating`, so it adds no publish of its own.
  private(set) var showsUpdating = false
  @ObservationIgnored private var needsFullBuild = false
  @ObservationIgnored private var passCommittedRows = false
  /// A rebuild or repair of a damaged or replaced catalog is under way: the label shows even
  /// while `status` is `.unavailable` (the person is waiting on the repair, not on a failure).
  @ObservationIgnored private var repairing = false
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
  /// Page reads in flight (#4586 package I): an ordinary full pass lets the reads already
  /// waiting when it has its backend reach the catalog first.
  @ObservationIgnored private let pageReads = HistoryPageReads()
  /// Waiters resumed whenever the registration or indexing task ends (`waitForTaskEnd`): a page
  /// read waiting for the watcher, and `waitForIndexingForTesting`.
  @ObservationIgnored private var taskEndWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// True while the indexing loop holds a full pass that has not yet called `reconcile`
  /// (#4586 package I). The worker reads the source revision when `reconcile` begins, so a
  /// watcher registration landing now is covered by that pass and queues no second one.
  @ObservationIgnored private var fullPassAwaitingStart = false
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
      #if DEBUG
        await beforeWatcherInstallForTesting?()
      #endif
      registration = nil
      defer { resumeTaskEndWaiters() }
      if let watch {
        changes.advanceWithoutNotice()
        diskWatch = watch
        HistorySignpost.event("HistoryWatcherReady")
        // A first page read across this install is shown as not current (its source differs
        // from the one now stable) and the list reads again; an extension read across it is
        // refused. Ask the screen to read again now rather than after the full pass this
        // enqueues.
        advanceContent()
        didUpdate?()
        // #4586 package I: a full pass that has not reached `reconcile` yet reads the source
        // revision after this advance, so it already restores coverage; a second full scan
        // would repeat it. A pass already reconciling, or none, still gets one queued.
        if !fullPassAwaitingStart {
          pending.include(.unknown)
          indexIfNeeded()
        }
      } else if status != .unavailable {
        // No watcher: coverage-dependent reads stay off; activation retries (sourceMayHaveChanged).
        // Status only (#4586 H1): no catalog row changed, so the list keeps its page.
        status = .unavailable
        syncShowsUpdating()
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
    syncShowsUpdating()
    advanceContent()
  }

  /// Recomputes `showsUpdating` from `status` and the two reasons to show it. Call it right
  /// after every write to `status` or either reason. Only a certifying publish ends the reasons
  /// (`publishProgress`).
  private func syncShowsUpdating() {
    let next = repairing || (status != .unavailable && (needsFullBuild || passCommittedRows))
    if showsUpdating != next { showsUpdating = next }
    #if DEBUG
      updatingStateForTesting?(status, showsUpdating)
    #endif
  }

  private func markCatalogBuildNeeded(repair: Bool = false) {
    needsFullBuild = true
    if repair { repairing = true }
    syncShowsUpdating()
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
    let opening = Task.detached(priority: .utility) { [weak self, changes, sources, directory] in
      // A missing catalog file is a first build: show it before the (possibly slow) create.
      if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.sqlite").path) {
        await self?.markCatalogBuildNeeded()
      }
      let catalog: HistoryCatalog
      do {
        catalog = try HistoryCatalog(directory: directory, projectionContext: Self.projectionContext)
      } catch where HistoryCatalog.needsRebuild(error) {
        await self?.markCatalogBuildNeeded(repair: true)
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
    // A missing, rebuilt or unfinished catalog has nothing to show yet; one certified at open
    // is only re-checked, so the screen stays quiet unless the pass changes rows.
    if opened.catalog.wasCertifiedAtOpen == false { needsFullBuild = true }
    syncShowsUpdating()
    return opened
  }

  /// One atomic read of the source counter and whether a writer is open (see
  /// `HistorySourceChanges.admission`). A first page samples it once and passes it to `page`.
  func admission() -> (revision: UInt64, settled: Bool) { changes.admission }

  /// `admitted` marks a first page (`cursor == nil`) whose caller stamps the result with the
  /// admission it sampled: the source revision gates display no longer, only authority, so such
  /// a read neither refuses a nil source at the start nor a moved source at the end. Coverage
  /// is used only when the admission was settled and the watcher is installed. An extension
  /// (`cursor != nil`) and callers without an admission keep both refusals.
  func page(
    _ query: HistoryCatalog.Query, after cursor: HistoryCatalog.Cursor? = nil, restoring anchor: UUID? = nil, newer: Bool = false,
    admitted: (revision: UInt64, settled: Bool)? = nil
  ) async throws -> HistoryCatalog.Page? {
    let readID = beginPageRead()
    defer { endPageRead(readID) }
    guard !Task.isCancelled else { return nil }
    let admittedFirstPage = cursor == nil ? admitted : nil
    let source = changes.revision
    if admittedFirstPage == nil { guard source != nil else { return nil } }
    let backend = try await open()
    #if DEBUG
      await beforePageCatalogForTesting?()
    #endif
    let coverage: String?
    if let admittedFirstPage {
      coverage = admittedFirstPage.settled && diskWatch != nil ? backend.worker.currentCoverage() : nil
    } else {
      coverage = diskWatch == nil ? nil : backend.worker.currentCoverage()
    }
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
    // #4586 H1: a content publish while the page was read (indexing progress, a new
    // certificate) does not throw it away; the list reads again after showing it, and a page
    // read under an older content revision cannot authorize selection or paging
    // (`TranscriptCoordinator.isCurrentHistoryResult`).
    if admittedFirstPage != nil { return Task.isCancelled ? nil : result }
    guard !Task.isCancelled, source == changes.revision else { return nil }
    return result
  }

  /// Registers a page read in flight (#4586 package I); pair with `endPageRead` on every exit.
  /// A caller that captures a source revision and builds a result around `page` holds its own
  /// registration across both, so a full pass lets the whole first page go first.
  func beginPageRead() -> UInt64 { pageReads.begin() }

  func endPageRead(_ id: UInt64) { pageReads.end(id) }

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
    needsFullBuild = true
    repairing = true
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
      defer {
        indexing = nil
        // A drained queue or a cancelled task ends the repair label; the status is untouched.
        if Task.isCancelled || !rebuildRequested {
          // A drained queue ends the active repair only. A pass that could not certify keeps
          // its row and build reasons, so a list still missing a row keeps its label.
          repairing = false
          if Task.isCancelled {
            needsFullBuild = false
            passCommittedRows = false
          }
          syncShowsUpdating()
        }
        resumeTaskEndWaiters()
      }
      while !pending.scopes.isEmpty {
        let delta = pending
        pending = HistorySourceChanges.Delta()
        fullPassAwaitingStart = delta.scopes.contains(.all)
        defer { fullPassAwaitingStart = false }
        // Every pass withdraws the worker's certificate while it runs, so a page read meanwhile
        // has no exact totals or selection. A pass that ends certified must therefore publish
        // even for an unchanged source revision, or that page is never re-read (#4605 review).
        publishedCertifiedSource = nil
        batchMarked = false
        do {
          // Recovery keeps precedence: a rebuild iteration never waits for page reads.
          var rebuilding = false
          if rebuildRequested {
            rebuilding = true
            rebuildRequested = false
            markCatalogBuildNeeded(repair: true)
            if let backend {
              try await backend.catalog.closeDatabase()
              self.backend = nil
            }
            try HistoryCatalog.discardFiles(in: directory)
          }
          let backend = try await open()
          #if DEBUG
            afterPassOpenForTesting?()
          #endif
          let pass: HistoryCatalogReconciliation.Pass?
          if delta.scopes.contains(.all) {
            // #4586 package I: the pass and the first page read resume together from `open()`
            // and compete for the catalog actor, which is not FIFO; the pass's first steps
            // (every source's progress) then held the first page for 130-240 ms on the M5. The
            // reads already waiting now go first; later reads never join this snapshot. This
            // bounds who is waited for, not how long. Scoped refreshes do not wait.
            if !rebuilding, await pageReads.waitForActive() {
              HistorySignpost.event("HistoryPassWaitedForReads")
            }
            try Task.checkCancellation()
            // A read that waited may have found the catalog damaged and asked for a rebuild:
            // recovery keeps precedence, so this pass becomes the rebuild iteration instead.
            if !rebuilding, rebuildRequested {
              pending.include(.unknown)
              continue
            }
            #if DEBUG
              beforeReconcileForTesting?()
            #endif
            fullPassAwaitingStart = false
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
          // A damaged catalog starts its repair label in the same turn as the error (#4586); a
          // failed repair hands the line back to the error during the retry backoff.
          let needsRebuild = HistoryCatalog.needsRebuild(error)
          let justDetectedDamage = needsRebuild && !repairing
          if needsRebuild {
            rebuildRequested = true
            needsFullBuild = true
          }
          repairing = justDetectedDamage
          passCommittedRows = false
          status = .unavailable
          syncShowsUpdating()
          // Content, not only status (#4586 H1): batches committed before the error may have
          // had their publishes throttled, and the error withdrew coverage.
          advanceContent()

          scheduleRetry()
        }
      }
    }
  }

  /// #4598: publish only what the screen needs. Rows or source proofs changed, availability
  /// changed, or a pass certified a different source revision; a new certificate for the same
  /// revision is not a change. While a pass is mid-way, at most every `publishInterval`.
  private func publishProgress(_ pass: HistoryCatalogReconciliation.Pass, final: Bool = false) {
    // The detection signal is display-only: it never writes `status` or publishes content.
    if !final, pass.revision == nil, !pass.changed, pass.changedRows {
      passCommittedRows = true
      syncShowsUpdating()
      return
    }
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
    // Row work drives the label before any throttle, and only a certifying publish clears it.
    if next == .ready, pass.revision != nil, !rebuildRequested {
      needsFullBuild = false
      passCommittedRows = false
      repairing = false
    } else if pass.changedRows {
      passCommittedRows = true
    }
    guard pass.changed || next != status || newCertificate else {
      syncShowsUpdating()
      return
    }
    let now = ContinuousClock.now
    if !finished, next == status, let publishedAt, now - publishedAt < Self.publishInterval {
      syncShowsUpdating()
      return
    }
    status = next
    syncShowsUpdating()
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
  /// Ends early when the calling task is cancelled (#4586 package I), so a stalled pass fails a
  /// test at its time limit instead of hanging it: it waits on a continuation the registration
  /// and indexing tasks resume when they end, never on their `value`.
  func waitForIndexingForTesting() async {
    var idleChecks = 0
    while idleChecks < 3, !Task.isCancelled {
      if registration != nil || indexing != nil {
        await waitForTaskEnd { registration == nil && indexing == nil }
        idleChecks = 0
      } else {
        await Task.yield()
        idleChecks += 1
      }
    }
  }

  /// Returns at once when `done()` holds or the caller is cancelled; otherwise when the
  /// registration or indexing task next ends (callers re-check `done` in a loop). Cancellation
  /// before or after the wait registers is handled as in `waitForChange`.
  private func waitForTaskEnd(_ done: @MainActor () -> Bool) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
        if Task.isCancelled || done() {
          waiter.resume()
        } else {
          taskEndWaiters[id] = waiter
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.taskEndWaiters.removeValue(forKey: id)?.resume() }
    }
  }

  private func resumeTaskEndWaiters() {
    guard !taskEndWaiters.isEmpty else { return }
    let waiting = taskEndWaiters
    taskEndWaiters.removeAll()
    for waiter in waiting.values { waiter.resume() }
  }

  // periphery:ignore - Tests check the one watcher is installed (#4598).
  var watcherIsInstalledForTesting: Bool { diskWatch != nil }

  #if DEBUG
    /// Opt-in: called with the status and label value at every `syncShowsUpdating` (#4586 tests).
    @ObservationIgnored var updatingStateForTesting: (@MainActor (Status, Bool) -> Void)?
    /// Runs inside `page` after the read and before its fence (#4586 H1 tests).
    @ObservationIgnored var beforePageFenceForTesting: (@MainActor () async -> Void)?
    /// Runs inside `page` after the backend is open and before any catalog call (#4586 package I).
    @ObservationIgnored var beforePageCatalogForTesting: (@MainActor () async -> Void)?
    /// Runs in the indexing loop right after the backend is open (#4586 package I). Synchronous,
    /// so observing adds no suspension before the read snapshot.
    @ObservationIgnored var afterPassOpenForTesting: (@MainActor () -> Void)?
    /// Runs right before a full pass calls `reconcile` (#4586 package I). Synchronous, so it adds
    /// no suspension after the cancellation check.
    @ObservationIgnored var beforeReconcileForTesting: (@MainActor () -> Void)?
    /// Runs in the watcher registration after the stream is built and before it is installed
    /// (#4586 package I), so a test can hold a registration in progress.
    @ObservationIgnored var beforeWatcherInstallForTesting: (@MainActor () async -> Void)?
    /// A content publish with no indexing pass behind it (#4586 H1 tests).
    func advanceContentForTesting() { advanceContent() }
    /// A full re-check with no source change, as the launch pass and the retry ask for one.
    func requestFullPassForTesting() {
      pending.include(.unknown)
      indexIfNeeded()
    }
    /// The watched-root-changed path: drop the stream and register again.
    func rewatchForTesting() { rootChanged() }
    var fullPassAwaitingStartForTesting: Bool { fullPassAwaitingStart }
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

/// The History page reads in flight (#4586 package I). A full re-check waits for the reads that
/// were active when it asked, and only those: a read that starts later never joins that wait, so
/// the set waited for is finite (its duration is not bounded). Main actor only.
@MainActor
final class HistoryPageReads {
  private var nextID: UInt64 = 0
  private var active: Set<UInt64> = []
  private var waiters: [UUID: Waiter] = [:]

  private struct Waiter {
    var remaining: Set<UInt64>
    let continuation: CheckedContinuation<Void, Never>
  }

  /// Registers a read; pair with `end(_:)` on every exit.
  func begin() -> UInt64 {
    nextID &+= 1
    active.insert(nextID)
    return nextID
  }

  func end(_ id: UInt64) {
    active.remove(id)
    for (key, waiter) in waiters {
      var waiter = waiter
      waiter.remaining.remove(id)
      if waiter.remaining.isEmpty {
        waiters[key] = nil
        waiter.continuation.resume()
      } else {
        waiters[key] = waiter
      }
    }
  }

  /// Waits until every read active now has ended, or the calling task is cancelled. Returns
  /// whether there was anything to wait for. Cancellation before or after the wait registers is
  /// handled the same way as `HistoryCatalogSession.waitForChange`.
  func waitForActive() async -> Bool {
    let snapshot = active
    guard !snapshot.isEmpty else { return false }
    let key = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let remaining = snapshot.intersection(active)
        if Task.isCancelled || remaining.isEmpty {
          continuation.resume()
        } else {
          waiters[key] = Waiter(remaining: remaining, continuation: continuation)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: key)?.continuation.resume() }
    }
    return true
  }

  #if DEBUG
    var waiterCountForTesting: Int { waiters.count }
  #endif
}

