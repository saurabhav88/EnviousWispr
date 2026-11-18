import os
import Foundation

/// One writer reconciles the catalog against the existing stores. This worker never mutates
/// those stores. Restart can reuse any projection whose complete source proof still matches.
package actor HistoryCatalogReconciliation {
  package struct Pass: Sendable {
    package let revision: String?
    package var unavailable: Int = 0
    /// Rows or source proofs changed in the catalog during this pass (#4598): the session
    /// publishes only real changes, so an unchanged re-check does not reload every view.
    package var changed = false
    /// A projected row or a removal changed (as opposed to source proofs only): the screen shows
    /// "Updating History…" only for this (#4586).
    package var changedRows = false
    /// The source revision this pass certified, captured with the worker's certificate. A new
    /// certificate for the same source revision is not a change worth publishing.
    package var certifiedSource: UInt64?
  }

  private let catalog: HistoryCatalog
  private let sources: HistoryCatalogSources
  private let project: @Sendable (HistoryCatalogSources.Saved) -> HistoryCatalog.Projection?
  /// The integration provides the revision of fully admitted canonical mutations. It returns
  /// nil while a source can change without a coherent publication fence.
  private let sourceRevision: @Sendable () -> UInt64?
  private struct CoverageState {
    var inFlight = false
    var certificate: (revision: String, source: UInt64)?
  }
  /// Written only from this actor; read by `currentCoverage` without queueing behind a pass.
  /// A full pass over a large History runs for seconds with no suspension point, and a page
  /// read that waited on the actor for its answer (always nil while a pass runs) kept the
  /// first saved cards off screen until the pass ended.
  private let coverageState = OSAllocatedUnfairLock(initialState: CoverageState())
  private var inFlight: Bool {
    get { coverageState.withLock { $0.inFlight } }
    set { coverageState.withLock { $0.inFlight = newValue } }
  }
  private var lastCertificate: (revision: String, source: UInt64)? {
    get { coverageState.withLock { $0.certificate } }
    set { coverageState.withLock { $0.certificate = newValue } }
  }
  private static let batchSize = 32
  /// One "HistorySpeed" track for every History signpost, shared with the app module.
  private static let signposter = OSSignposter(subsystem: "com.enviouswispr.app", category: "HistorySpeed")

  /// Recheck at query time. The storage token alone cannot authorize all-matching operations.
  package nonisolated func currentCoverage() -> String? {
    let state = coverageState.withLock { $0 }
    guard let certificate = state.certificate, certificate.source == sourceRevision(), !state.inFlight else { return nil }
    return certificate.revision
  }

  package init(
    catalog: HistoryCatalog, sources: HistoryCatalogSources,
    sourceRevision: @escaping @Sendable () -> UInt64? = { nil },
    project: @escaping @Sendable (HistoryCatalogSources.Saved) -> HistoryCatalog.Projection?
  ) {
    self.catalog = catalog
    self.sources = sources
    self.sourceRevision = sourceRevision
    self.project = project
  }

  /// A nil revision is expected while a pass is incomplete, interrupted, or overlaps a change.
  /// Callers can show individually validated cards during this interval.
  package func reconcile(
    now: Date = Date(), onProgress: @Sendable (Pass) async -> Void = { _ in }
  ) async throws -> Pass? {
    guard !inFlight else { return nil }
    inFlight = true
    lastCertificate = nil
    defer { inFlight = false }

    let beganAt = sourceRevision()
    var progress = KeyedProgress(try await catalog.sourceProgress())
    try await catalog.apply([])
    let requireMeetings = progress.entries.values.contains { sources.isMeetingPath($0.path) }
    let discovered = try sources.paths(requireMeetings: requireMeetings)
    let paths = Set(discovered.map(\.path))
    let ordered = Dictionary(discovered.map { url in
      (url.path, (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate))
    }, uniquingKeysWith: { first, _ in first }).values.sorted { lhs, rhs in
      let left = lhs.1 ?? .distantPast
      let right = rhs.1 ?? .distantPast
      if left != right { return left > right }
      return lhs.0.path < rhs.0.path
    }.map(\.0)
    // Full-pass source discovery is done (#4586 instruments): content-free, read in Instruments.
    Self.signposter.emitEvent("HistoryDiscoveryDone")

    var pending: [Update] = []
    var unavailable = 0
    var changed = false
    var changedRows = false
    for url in ordered {
      try Task.checkCancellation()
      let before = progress.entries[url.path]
      if let before, (try? before.versions.allSatisfy { try $0.stillMatches() }) == true {
        continue
      }
      do {
        let snapshot = try sources.snapshot(of: url, at: now)
        let projection = snapshot.saved.flatMap(project)
        let entry = HistoryCatalog.SourceProgress(
          path: url.path, versions: snapshot.versions, key: projection?.summary.key)
        pending.append(Update(entry: entry, projection: projection))
      } catch {
        unavailable += 1
        // Preserve the last known key/proof. It remains ineligible while the source is
        // unverified, and a later pass can still remove it if the file disappears.
      }
      if pending.count == Self.batchSize {
        let batch = try await commit(pending, tracking: &progress)
        pending.removeAll(keepingCapacity: true)
        if batch.saved > 0 {
          changed = true
          changedRows = changedRows || batch.changedRows
          await onProgress(Pass(revision: nil, changed: true, changedRows: batch.changedRows))
        }
      }
    }
    let tail = try await commit(pending, tracking: &progress)
    changed = changed || tail.saved > 0
    changedRows = changedRows || tail.changedRows

    try Task.checkCancellation()
    let currentPaths = Set(try sources.paths(requireMeetings: requireMeetings).map(\.path))
    let dropped = Set(progress.entries.keys).subtracting(currentPaths)
    let retainedKeys = Set(progress.entries.values.filter { currentPaths.contains($0.path) }.compactMap(\.key))
    let removed = Set(dropped.compactMap { progress.entries[$0]?.key }).subtracting(retainedKeys)
    for path in dropped { progress.remove(path) }
    if !dropped.isEmpty || !removed.isEmpty { changed = true }
    let revision: String?
    if let beganAt, currentPaths == paths, currentPaths == Set(progress.entries.keys),
      (try? progress.entries.values.allSatisfy { entry in
        try entry.versions.allSatisfy { try $0.stillMatches() }
      }) == true, sourceRevision() == beganAt
    {
      revision = UUID().uuidString
    } else {
      revision = nil
    }
    try await catalog.apply([], removing: Array(removed), certifiedRevision: revision,
      recording: [], dropping: Array(dropped))
    let currentRevision = beganAt == sourceRevision() ? revision : nil
    if currentRevision == nil, revision != nil { try await catalog.apply([]) }
    lastCertificate = currentRevision.flatMap { value in beganAt.map { (value, $0) } }
    let result = Pass(
      revision: currentRevision, unavailable: unavailable, changed: changed,
      changedRows: changedRows || !removed.isEmpty,
      certifiedSource: lastCertificate?.source)
    // The caller publishes the returned final pass; `onProgress` carries only mid-pass batches.
    return result
  }

  /// Re-certify only the scopes invalidated by installed writers. If there was no established
  /// inventory, or the source changed while checking, the caller schedules a fresh walk.
  package func refresh(
    _ delta: HistorySourceChanges.Delta, now: Date = Date()
  ) async throws -> Pass? {
    guard !inFlight else { return nil }
    inFlight = true
    defer { inFlight = false }
    // An incremental refresh is safe only for a scope whose writer notifications are
    // known to be complete. When any notification could have been missed, use reconcile.
    let previous = lastCertificate
    lastCertificate = nil
    let beganAt = sourceRevision()
    var progress = KeyedProgress(try await catalog.sourceProgress())
    var updates: [Update] = []
    var disappeared: [String] = []
    var unresolved = false
    var remaining = delta.scopes
    var examined: Set<HistorySourceChanges.Scope> = []
    while let scope = remaining.popFirst() {
      try Task.checkCancellation()
      guard examined.insert(scope).inserted else { continue }
      guard let path = sources.path(for: scope) else {
        unresolved = true
        continue
      }
      do {
        if try sources.isConfirmedAbsent(path) {
          disappeared.append(path.path)
        } else {
          let snapshot = try sources.snapshot(of: path, at: now)
          if let meetingID = snapshot.dependentMeeting { remaining.insert(.meeting(meetingID)) }
          let projection = snapshot.saved.flatMap(project)
          let entry = HistoryCatalog.SourceProgress(
            path: path.path, versions: snapshot.versions, key: projection?.summary.key)
          updates.append(Update(entry: entry, projection: projection))
        }
      } catch {
        unresolved = true
      }
    }
    let batch = try await commit(updates, tracking: &progress)
    let removedKeys = Set(disappeared.compactMap { progress.remove($0)?.key })
      .filter { progress.isUnreferenced($0) }
    let certified: Bool
    if let previous, let beganAt, beganAt == sourceRevision() {
      certified = delta.spans(after: previous.source, through: beganAt)
        && !unresolved && batch.saved == updates.count
    } else {
      certified = false
    }
    let token = certified ? UUID().uuidString : nil
    try await catalog.apply([], removing: Array(removedKeys), certifiedRevision: token,
      recording: [], dropping: disappeared)
    let current = beganAt == sourceRevision() ? token : nil
    if current == nil, token != nil { try await catalog.apply([]) }
    lastCertificate = current.flatMap { value in beganAt.map { (value, $0) } }
    return Pass(
      revision: current, unavailable: unresolved ? 1 : 0,
      changed: batch.saved > 0 || !removedKeys.isEmpty || !disappeared.isEmpty,
      changedRows: batch.changedRows || !removedKeys.isEmpty,
      certifiedSource: lastCertificate?.source)
  }

  private struct Update {
    let entry: HistoryCatalog.SourceProgress
    let projection: HistoryCatalog.Projection?
  }

  private func commit(
    _ pending: [Update], tracking progress: inout KeyedProgress
  ) async throws -> (saved: Int, changedRows: Bool) {
    try Task.checkCancellation()
    guard !pending.isEmpty else { return (0, false) }
    let verified = pending.filter { update in
      (try? update.entry.versions.allSatisfy { try $0.stillMatches() }) == true
    }
    let removed = progress.record(verified.map(\.entry))
    let projections = verified.compactMap(\.projection)
    try await catalog.apply(projections, removing: removed, recording: verified.map(\.entry))
    return (verified.count, !projections.isEmpty || !removed.isEmpty)
  }
}

extension HistoryCatalogReconciliation {
  /// The progress map plus how many entries name each catalog key (#4586 N4), so a commit asks
  /// "does any source still produce this key?" without rebuilding a set of every key.
  struct KeyedProgress {
    private(set) var entries: [String: HistoryCatalog.SourceProgress]
    private var references: [HistoryCatalog.Key: Int] = [:]

    init(_ entries: [String: HistoryCatalog.SourceProgress]) {
      self.entries = entries
      for key in entries.values.compactMap(\.key) { references[key, default: 0] += 1 }
    }

    func isUnreferenced(_ key: HistoryCatalog.Key) -> Bool { references[key] == nil }

    /// Stores a verified batch. Returns the keys its paths named before the batch that no source
    /// names now: the rows to delete. A key that appears and leaves within the batch is not one.
    mutating func record(_ batch: [HistoryCatalog.SourceProgress]) -> [HistoryCatalog.Key] {
      let before = Set(batch.compactMap { entries[$0.path]?.key })
      for entry in batch { set(entry) }
      return before.filter(isUnreferenced)
    }

    mutating func set(_ entry: HistoryCatalog.SourceProgress) {
      release(entries.updateValue(entry, forKey: entry.path)?.key)
      if let key = entry.key { references[key, default: 0] += 1 }
    }

    @discardableResult
    mutating func remove(_ path: String) -> HistoryCatalog.SourceProgress? {
      let removed = entries.removeValue(forKey: path)
      release(removed?.key)
      return removed
    }

    private mutating func release(_ key: HistoryCatalog.Key?) {
      guard let key, let count = references[key] else { return }
      references[key] = count > 1 ? count - 1 : nil
    }
  }
}
