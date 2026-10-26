import EnviousWisprCore
import EnviousWisprStorage
import Foundation

@MainActor final class HistoryDiskReconciler {
  private let store: TranscriptStore
  private let transactionExecutor: HistoryTransactionExecutor
  private var loadTask: Task<Void, Never>?
  /// #4001 H9: which read owns History's state. Bumped by every new read or reuse check, so a
  /// superseded one cannot publish rows, certify the cache or clear `loadInFlight`.
  private var loadRequestID: UInt64 = 0
  private var loadInFlight = false
  /// #4001 H9: whether the rows held now are the whole store as of `accepted`. Set only by a
  /// certified complete read; dropped by any read that starts, and by a reuse check that finds
  /// the folders changed.
  private enum HistoryCache: Equatable {
    case unread
    case reusable(TranscriptStoreFreshness)
  }
  private var historyCache: HistoryCache = .unread

  /// How many files the LAST sweep meant to remove and could not — disk truth,
  /// straight from `PendingSweepResult.unremovable`.
  ///
  /// The store promises a failed removal is retried on the next sweep, and this
  /// is what keeps that promise: without it the pulse stopped as soon as nothing
  /// was counting down, so the retry never came and the file plus its expiry
  /// event waited for History to reload.
  ///
  /// Deliberately NOT `lapsedPendingCount`. That reads this object's own list,
  /// which can outlive the file it describes — `load()` preserves in-memory rows
  /// absent from both namespaces — so retrying on it means retrying forever, a
  /// directory walk every minute for the life of the app. Only the sweep can say
  /// whether a file is still there.
  private var unremovablePendingCount = 0

  /// Rows still counting down ON DISK, from the last COMPLETE sweep (#2186).
  ///
  /// The countdown used to arm only from `livePendingCount`, which reads
  /// `transcripts`, which only `load()` fills — and `load()` is reached only from
  /// the History view. So a row carried over from a PREVIOUS session
  /// was invisible to the timer for the entire session: nothing deleted it at
  /// its moment, and it waited for a relaunch. Founder, 2026-08-20: "As long as
  /// the application is running, the timer should be ticking… and then it just
  /// deletes."
  ///
  /// Written only when `walkComplete`, because the store's count means nothing
  /// otherwise — a walk that could not enumerate the directory reports zero,
  /// which would read as "nothing is counting down" and stop the pulse on the
  /// one occasion it must keep running. An incomplete walk leaves this ALONE and
  /// `lastSweepIncomplete` keeps the pulse alive on its own.
  private var liveOnDiskPendingCount = 0

  /// Expired rows the last sweep KEPT because their spool survives (#2186).
  /// A retry owed, not a failure and not a countdown.
  private var pendingRetainedForSpool = 0

  /// Whether the last sweep failed to READ the directory, or threw.
  ///
  /// Separate from the count because it means the opposite of what the count
  /// would say on its own: a walk that never happened reports zero unremovable
  /// files, which is the same number a completely successful walk reports. Held
  /// so the pulse keeps retrying rather than concluding it is finished on the
  /// strength of a measurement that was never taken.
  private var lastSweepIncomplete = false

  /// Something may still need clearing: a lapsed row this object can see, a file
  /// the last sweep could not remove, or a sweep that could not look.
  ///
  /// The lapsed half is what makes the FIRST walk happen after a row ages out.
  /// It settles because a sweep that removes everything it can also drops any
  /// lapsed row it did not find, so this returns to zero after one pass.
  func pendingSweepIsDue(lapsedInMemory: Int, now: Date) -> Bool {
    lapsedInMemory > 0 || unremovablePendingCount > 0 || lastSweepIncomplete
      || liveOnDiskLapsedByNow(now: now) || pendingRetainedForSpool > 0
  }

  /// #2186: a disk row that has crossed its deadline SINCE the last sweep.
  ///
  /// `lapsedPendingCount` cannot see it — that reads `transcripts`, and a row
  /// carried over from a previous session is not in memory unless History
  /// loaded it. Without this the pulse would arm (because live rows exist on
  /// disk) and then never find anything due, so it would spin until it stopped
  /// and delete nothing at the moment it was supposed to.
  ///
  /// Deliberately time-based rather than a stored flag: the pulse's whole job is
  /// to notice a deadline passing while nothing else changes, and only a clock
  /// read can do that. The sweep it triggers is what corrects the count.
  private func liveOnDiskLapsedByNow(now: Date) -> Bool {
    guard liveOnDiskPendingCount > 0 else { return false }
    return now >= nextDiskExpiryDeadline ?? .distantFuture
  }

  /// When the soonest disk row is due, from the last complete sweep (#2186).
  private var nextDiskExpiryDeadline: Date?

  /// Whether the pulse has any reason to keep running.
  ///
  /// ONE authority for arming, for the in-loop stop and for `stopPulseIfIdle`,
  /// because three copies of this predicate drifting apart is exactly how the
  /// retry got stranded.
  ///
  /// A lapsed row in memory is deliberately NOT part of this, and the loop's
  /// order is what makes that safe: it sweeps first, then asks this. So a stale
  /// row costs exactly one walk — the sweep drops it — rather than keeping the
  /// pulse alive over a file that is already gone.
  func pendingPulseHasWork(liveInMemory: Int) -> Bool {
    liveInMemory > 0 || unremovablePendingCount > 0 || lastSweepIncomplete
      || liveOnDiskPendingCount > 0 || pendingRetainedForSpool > 0
  }

  /// Counts writes, so a disk read that began earlier can be told it is stale.
  ///
  /// `load()` prefers the DISK row whenever an id already exists, which is right for a
  /// launch and wrong for a write that landed while it was reading: an import's raw row read
  /// at the start of a load would replace the cleaned row saved a moment later, and History
  /// would show the unpolished version until something else refreshed it. Found by Codex.
  private var historyWriteRevision = 0
  private var writtenAtRevision: [UUID: Int] = [:]

  /// Stamps a locally persisted row when it is published in memory. Disk-load publication
  /// and fixture injection do not stamp rows. A newer stamp protects a local write from
  /// an older History snapshot (#4075 G9).
  func noteWritten(_ id: UUID) {
    historyWriteRevision += 1
    writtenAtRevision[id] = historyWriteRevision
  }

  /// Drops what this coordinator believes about the pending directory, and
  /// supersedes any walk already in flight over it.
  ///
  /// Both halves belong to one removal and are why this is a function rather
  /// than four assignments at the call site: zeroing without bumping leaves an
  /// older walk free to write its stale picture back, and bumping without
  /// zeroing leaves the removed row counting until the refresh lands.
  func invalidateDiskState() {
    liveOnDiskPendingCount = 0
    nextDiskExpiryDeadline = nil
    pendingRetainedForSpool = 0
    diskStateGeneration &+= 1
  }

  /// Bumped by every pending REMOVAL, and read by `sweepExpiredPending` across
  /// its one `await`, so a walk that started before a removal cannot write its
  /// picture of the directory over a newer one's.
  ///
  /// Cloud review, P2: the store serialises the walks, but each sweep writes its
  /// result back on the main actor AFTER resuming, and resumptions are not
  /// ordered — so without this, two quick removals can let the first walk's
  /// stale count land on top of the second walk's empty one and strand the pulse
  /// until a row that no longer exists reaches its former deadline.
  ///
  /// A generation rather than cancellation: the walk itself is still doing real
  /// work — it deletes files and its deletions must be recorded whoever wins —
  /// and only the four fields DESCRIBING the directory go stale. Those four are
  /// gated together rather than one at a time; they are one snapshot, and a
  /// partial application is a directory state that never existed.
  private var diskStateGeneration = 0

  struct ReadEffects {
    let rows: @MainActor () -> [Transcript]
    let applyRows: @MainActor ([Transcript], Set<UUID>) -> Void
    let didApplyRead: @MainActor () -> Void
    let sweepBeforeRead: @MainActor () async -> Void
    let didFinishCurrentRead: @MainActor () -> Void
  }

  init(store: TranscriptStore, transactionExecutor: HistoryTransactionExecutor) {
    self.store = store
    self.transactionExecutor = transactionExecutor
  }

  func invalidateReadCache() {
    historyCache = .unread
  }

  func sweep(now: Date) async throws -> PendingSweepResult {
    // No guard here: the STORE coalesces, so a second caller awaits the sweep
    // in flight and then runs its own pass with its own clock. A flag at this
    // layer would defeat both halves — `await` resuming before the work was
    // done, and a row that lapsed DURING the in-flight sweep never being
    // re-examined by the later clock that can see it.
    // Captured BEFORE the await, so a removal that lands while this walk is in
    // flight makes the walk stale by construction rather than by timing.
    let generation = diskStateGeneration
    do {
      let swept = try await store.deleteExpiredPending(now: now)
      #if DEBUG
        // The ONE window this guard exists for: the walk has finished and has
        // not yet written its result. A Live removal here is what makes the
        // result stale, and it cannot be staged from outside — the two tasks
        // resume in whatever order the runtime picks, so a test that raced them
        // would prove nothing on the run where it happened to win.
        onSweepWalkFinishedForTesting?()
      #endif
      // The four fields below DESCRIBE the directory, and this walk looked at a
      // directory a later removal has since changed — so its whole picture is
      // superseded, not merely its count. Applying any part of it writes a state
      // that never existed. The deletions and telemetry beneath this block are
      // FACTS about files that really went, so they are recorded either way, and
      // the newer walk arms the pulse from the state it actually finds.
      let describesCurrentDirectory = generation == diskStateGeneration
      // Replaced, never accumulated: this is the state of the directory after
      // the pass that just ran, so a file that finally went must stop counting.
      if describesCurrentDirectory {
        unremovablePendingCount = swept.unremovable
        lastSweepIncomplete = !swept.walkComplete
      }
      // #2186: DISK truth, and only from a walk that could actually look.
      // `walkComplete == false` means the store counted nothing, so its zero is
      // "I could not see" rather than "nothing is counting down" — writing it
      // here would stop the timer on the one occasion it must keep going.
      // `lastSweepIncomplete` above already keeps the pulse alive in that case.
      if swept.walkComplete, describesCurrentDirectory {
        liveOnDiskPendingCount = swept.remainingLive
        nextDiskExpiryDeadline = swept.nextLiveDeadline
      }
      // #2186: rows the sweep KEPT because their spool is still on disk. Not a
      // failure and not a live countdown — a retry owed. Without it the sweep
      // reads as finished (nothing deleted, nothing unremovable, walk complete),
      // the pulse stops, and the row waits for a relaunch instead of going on
      // the pass after recovery clears its spool. Same stranded retry the
      // `unremovable` count already exists to prevent, by a second route.
      if describesCurrentDirectory {
        pendingRetainedForSpool = swept.retainedForSpool
      }
      return swept
    } catch {
      // See TranscriptCoordinator.performSweep for the full failure and retry rationale.
      if generation == diskStateGeneration {
        lastSweepIncomplete = true
      }
      throw error
    }
  }

  /// History's open (#4001 H9). Joins a read already running, reuses the rows already held when
  /// the store's folders have not changed since the last complete read, and otherwise reads the
  /// store as `load()` does. Only a complete read sets what "unchanged" is measured against;
  /// every write, this app's included, changes a folder token, so the next open reads again.
  func loadIfNeeded(effects: ReadEffects) {
    guard !loadInFlight else { return }
    guard case .reusable(let accepted) = historyCache else {
      load(effects: effects)
      return
    }
    loadRequestID &+= 1
    let request = loadRequestID
    loadInFlight = true
    loadTask = Task {
      defer { finishLoad(request, effects: effects) }
      let current = await store.freshness()
      guard request == loadRequestID, !Task.isCancelled else { return }
      guard let current, current == accepted, case .reusable(accepted) = historyCache else {
        historyCache = .unread
        await readStore(request, effects: effects)
        return
      }
      #if DEBUG
        historyCacheHitsForTesting += 1
      #endif
      // Cleanup still runs on every open. A sweep that deletes a file changes the pending token,
      // so the open after it reads the store again.
      await effects.sweepBeforeRead()
    }
  }

  /// A full read of the store, replacing any read in flight. History's opens go through
  /// `loadIfNeeded()`.
  func load(effects: ReadEffects) {
    loadTask?.cancel()
    loadRequestID &+= 1
    let request = loadRequestID
    loadInFlight = true
    historyCache = .unread
    loadTask = Task {
      defer { finishLoad(request, effects: effects) }
      await readStore(request, effects: effects)
    }
  }

  /// Ends `request`'s hold on the in-flight flag, and only its own: a superseded read finishing
  /// late must not mark a newer read as done.
  private func finishLoad(_ request: UInt64, effects: ReadEffects) {
    if request == loadRequestID {
      loadInFlight = false
      effects.didFinishCurrentRead()
      #if DEBUG
        historyReadEndsForTesting += 1
      #endif
    }
  }

  private func readStore(_ request: UInt64, effects: ReadEffects) async {
    // #2087: sweep BEFORE reading, so the load cannot pick up a row this pass
    // is about to delete. Reclaims disk and produces the `expired` half of the
    // ratio that judges the feature.
    //
    // Placed here rather than at process launch deliberately: this is the
    // path that already does History disk I/O, and read-time expiry means an
    // unswept row is invisible regardless — so the sweep governs disk and
    // telemetry, never what the user can see. That is also why a missed sweep
    // is not a user-facing bug.
    await effects.sweepBeforeRead()
    guard request == loadRequestID, !Task.isCancelled else { return }
    do {
      // #2772: taken BEFORE the read, so a write that lands while it is in flight can be
      // recognised as newer than what the disk handed back.
      let revisionAtRead = historyWriteRevision
      // And the deletion generation, for the opposite race: a row DELETED while this read
      // was suspended is still in the picture the disk handed back, and the merge below
      // would reinstate it. For an import that is worse than a stale list, because the
      // cleanup's update then finds the row and rewrites its file — the deletion
      // `updateExistingRow` exists to respect. Every removal bumps this synchronously
      // (`invalidateDiskState`), so a mismatch means re-read rather than trust.
      let generationAtRead = diskStateGeneration
      let read = try await store.readHistory()
      #if DEBUG
        try historyReadDidFinishForTesting?(read)
      #endif
      guard request == loadRequestID, !Task.isCancelled else { return }
      // #4075 S1: applied as a queued command, so a write's disk success and its publication
      // are never split by it. The application rechecks this request itself.
      await transactionExecutor.admit { [self] in
        applyRead(
          read, request: request, revisionAtRead: revisionAtRead,
          generationAtRead: generationAtRead, effects: effects
        )
      }
    } catch is CancellationError {
      // A newer read replaced this one (#4075 G8); that read publishes.
    } catch {
      await AppLogger.shared.log(
        "Failed to load transcripts: \(error)",
        level: .info, category: "TranscriptCoordinator"
      )
    }
  }

  private func applyRead(
    _ read: TranscriptHistoryRead, request: UInt64, revisionAtRead: Int,
    generationAtRead: Int, effects: ReadEffects
  ) {
    var diskRows = read.permanent
    // Phase C union-by-ID merge. Preserve any in-memory rows whose IDs
    // are not yet on disk (append-during-load race window) in their
    // existing order, then append disk rows. Protects the newest-first
    // invariant under multiple concurrent completions while a slow
    // startup load is still running.
    // #2087: pending rows are ADDITIVE and never authoritative. Keep writes
    // the permanent copy before deleting the pending file, so a crash
    // between those two steps leaves the same id in both namespaces — root
    // wins, and the user sees the row they kept exactly once rather than a
    // permanent row shadowed by a copy still counting down.
    let pendingRows = read.pending
    // The source load's own identity, not the drain's cancellation: `load()` replaces a
    // request by moving `loadRequestID`.
    guard request == loadRequestID else { return }
    guard generationAtRead == diskStateGeneration else {
      // A later fresh read, started now and not awaited here.
      load(effects: effects)
      return
    }
    let transcripts = effects.rows()
    // #2772: a row written SINCE this read began is newer than the disk copy that came
    // back, and the merge below prefers the disk one whenever the id already exists. An
    // import writes twice under one id, so without this the raw version read at the
    // start of a load replaces the cleaned version saved a moment later, and History
    // shows unpolished words until something else refreshes it. Found by Codex.
    let newerRows = Dictionary(
      uniqueKeysWithValues:
        transcripts
        .filter { (writtenAtRevision[$0.id] ?? 0) > revisionAtRead }
        .map { ($0.id, $0) })
    diskRows = diskRows.map { newerRows[$0.id] ?? $0 }
    let rootIDs = Set(diskRows.map(\.id))
    let heldRows = pendingRows.filter { !rootIDs.contains($0.id) }
    let knownIDs = rootIDs.union(heldRows.map(\.id))
    // #4075 G9: a row missing from the disk is kept only when it was written after this read
    // began (its file can land after the scan passed it) or when the read skipped a file. A
    // row written earlier was on disk before the read, so a complete read that lacks it means
    // its file was deleted outside this coordinator, and keeping it left the deleted text in
    // History and offered by Paste Last.
    let inFlightRows = transcripts.filter {
      !knownIDs.contains($0.id)
        && (read.freshness == nil || (writtenAtRevision[$0.id] ?? 0) > revisionAtRead)
    }
    // Merged rather than re-sorted: all three inputs are already newest-first,
    // and re-sorting the combined list could reorder permanent rows that
    // share a `createdAt`. With no held or in-flight rows this returns
    // `diskRows` unchanged, so History is byte-identical for anyone who never
    // turns Escape Recovery on. In-flight rows are merged by date too, not put
    // first: a queued save can publish an older row than one this read found
    // (Codex review of the #4075 S7 fix). In-flight rows go second so they win ties, as
    // `append` and a save put a new row ahead of rows with the same date.
    let merged = Self.mergeNewestFirst(
      Self.mergeNewestFirst(heldRows, diskRows), inFlightRows)
    let mergedIDs = Set(merged.map(\.id))
    effects.applyRows(
      merged, Set(transcripts.lazy.map(\.id).filter { !mergedIDs.contains($0) }))
    // #4001 H9: reusable only when the read itself was certified. A read that skipped a file
    // it could not open, or that a write overlapped, leaves the next open to read again.
    historyCache = read.freshness.map(HistoryCache.reusable) ?? .unread
    #if DEBUG
      historyFullReadsForTesting += 1
    #endif
    effects.didApplyRead()
  }

  // periphery:ignore - test seam
  func waitForLoadForTesting() async {
    // A read that finds the store changed under it starts another one, so wait for the read
    // that is current once nothing replaces it, not only the one running when this was called.
    var awaited: Task<Void, Never>?
    while let running = loadTask, running != awaited {
      awaited = running
      await running.value
    }
  }

  /// Interleave two newest-first lists without disturbing either's order.
  ///
  /// On a TIE the permanent row goes first, deliberately: a held row is an
  /// unresolved offer, and an offer should not displace a dictation the user
  /// actually completed at the same instant.
  ///
  /// A plain `sorted` over the concatenation is the obvious alternative and is
  /// rejected for a narrower reason than it first appears. `Array.sorted` is
  /// NOT documented as stable, so its behaviour on tied `createdAt` values is
  /// unspecified — today's implementation happens to preserve input order, and
  /// nothing promises the next toolchain will. That makes the tie case a
  /// silent, toolchain-dependent reordering of shipped History, caused by an
  /// opt-in feature the user may never have turned on. This merge specifies the
  /// answer instead of inheriting it.
  ///
  /// Honest limit: because the current sort IS stable in practice, the two
  /// implementations differ observably only in which row wins a tie — which is
  /// exactly what `heldRowLosesATieWithAPermanentRow` pins.
  private static func mergeNewestFirst(
    _ held: [Transcript], _ permanent: [Transcript]
  ) -> [Transcript] {
    guard !held.isEmpty else { return permanent }
    var result: [Transcript] = []
    result.reserveCapacity(held.count + permanent.count)
    var h = 0
    var p = 0
    while h < held.count, p < permanent.count {
      if held[h].createdAt > permanent[p].createdAt {
        result.append(held[h])
        h += 1
      } else {
        result.append(permanent[p])
        p += 1
      }
    }
    result.append(contentsOf: held[h...])
    result.append(contentsOf: permanent[p...])
    return result
  }

  #if DEBUG
    /// #4001 H9: opens that reused the held rows, and full reads that completed. Counted apart so
    /// a test can tell reuse from a read that happened to return the same rows.
    private(set) var historyCacheHitsForTesting = 0
    private(set) var historyFullReadsForTesting = 0
    /// #4001 H12: reads that ended while still current, so a test can tell that a superseded read
    /// did not set `historyReadFinished`.
    private(set) var historyReadEndsForTesting = 0
    /// Runs after the disk snapshot returns and before it is reconciled, so tests can
    /// persist and append a row that the completed snapshot could not contain.
    var historyReadDidFinishForTesting:
      (@MainActor (TranscriptHistoryRead) throws -> Void)?
    /// #2186: the disk deadline the pulse waits for.
    ///
    /// A seam rather than a wall-clock wait. The production deadline comes from
    /// the store's own walk, and a test that made a row expire a fraction of a
    /// second in the future and let the loop spin until it did would be flaky by
    /// construction — the same defect `pulseSweepsOnDetection` records having
    /// already been fixed once in this file.
    // periphery:ignore - test seam
    func setDiskExpiryDeadlineForTesting(_ date: Date?) {
      nextDiskExpiryDeadline = date
    }

    // periphery:ignore - test seam
    var liveOnDiskPendingCountForTesting: Int { liveOnDiskPendingCount }

    /// Fired once the pending walk has finished and BEFORE its result is
    /// written back — the only window in which a removal can make that result
    /// stale. A seam rather than a raced pair of tasks: the two resume in an
    /// order the runtime picks, so a racing test proves nothing on the run where
    /// it happens to win.
    var onSweepWalkFinishedForTesting: (@MainActor () -> Void)?

    /// What a removal does to this coordinator's picture of the directory, with
    /// the refresh it would also arm left off — so a test can put a removal in
    /// the window above without a second walk racing in to correct the answer.
    // periphery:ignore - test seam
    func simulateRemovalDuringWalkForTesting() {
      invalidateDiskState()
    }
  #endif
}
