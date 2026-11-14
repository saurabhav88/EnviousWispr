import Foundation

/// One writer reconciles the catalog against the existing stores. This worker never mutates
/// those stores. Restart can reuse any projection whose complete source proof still matches.
package actor HistoryCatalogReconciliation {
  package struct Pass: Sendable {
    package let revision: String?
    package var unavailable: Int = 0
  }

  private let catalog: HistoryCatalog
  private let sources: HistoryCatalogSources
  private let project: @Sendable (HistoryCatalogSources.Saved) -> HistoryCatalog.Projection?
  /// The integration provides the revision of fully admitted canonical mutations. It returns
  /// nil while a source can change without a coherent publication fence.
  private let sourceRevision: @Sendable () -> UInt64?
  private var inFlight = false
  private var lastCertificate: (revision: String, source: UInt64)?
  private static let batchSize = 32

  /// Recheck at query time. The storage token alone cannot authorize all-matching operations.
  package func currentCoverage() -> String? {
    guard let certificate = lastCertificate, certificate.source == sourceRevision(), !inFlight else { return nil }
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
    var progress = try await catalog.sourceProgress()
    try await catalog.apply([])
    let requireMeetings = progress.values.contains { sources.isMeetingPath($0.path) }
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

    var pending: [Update] = []
    var unavailable = 0
    for url in ordered {
      try Task.checkCancellation()
      let before = progress[url.path]
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
        _ = try await commit(pending, tracking: &progress)
        pending.removeAll(keepingCapacity: true)
        await onProgress(Pass(revision: nil))
      }
    }
    _ = try await commit(pending, tracking: &progress)

    try Task.checkCancellation()
    let currentPaths = Set(try sources.paths(requireMeetings: requireMeetings).map(\.path))
    let dropped = Set(progress.keys).subtracting(currentPaths)
    let retainedKeys = Set(progress.values.filter { currentPaths.contains($0.path) }.compactMap(\.key))
    let removed = Set(dropped.compactMap { progress[$0]?.key }).subtracting(retainedKeys)
    for path in dropped { progress.removeValue(forKey: path) }
    let revision: String?
    if let beganAt, currentPaths == paths, currentPaths == Set(progress.keys),
      (try? progress.values.allSatisfy { entry in
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
    let result = Pass(revision: currentRevision, unavailable: unavailable)
    await onProgress(result)
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
    var progress = try await catalog.sourceProgress()
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
    let saved = try await commit(updates, tracking: &progress)
    let removedKeys = Set(disappeared.compactMap { progress.removeValue(forKey: $0)?.key })
      .subtracting(progress.values.compactMap(\.key))
    let certified: Bool
    if let previous, let beganAt, beganAt == sourceRevision() {
      certified = delta.spans(after: previous.source, through: beganAt)
        && !unresolved && saved == updates.count
    } else {
      certified = false
    }
    let token = certified ? UUID().uuidString : nil
    try await catalog.apply([], removing: Array(removedKeys), certifiedRevision: token,
      recording: [], dropping: disappeared)
    let current = beganAt == sourceRevision() ? token : nil
    if current == nil, token != nil { try await catalog.apply([]) }
    lastCertificate = current.flatMap { value in beganAt.map { (value, $0) } }
    return Pass(revision: current, unavailable: unresolved ? 1 : 0)
  }

  private struct Update {
    let entry: HistoryCatalog.SourceProgress
    let projection: HistoryCatalog.Projection?
  }

  private func commit(
    _ pending: [Update], tracking progress: inout [String: HistoryCatalog.SourceProgress]
  ) async throws -> Int {
    try Task.checkCancellation()
    guard !pending.isEmpty else { return 0 }
    let verified = pending.filter { update in
      (try? update.entry.versions.allSatisfy { try $0.stillMatches() }) == true
    }
    let oldKeys = Set(verified.compactMap { progress[$0.entry.path]?.key })
    for update in verified { progress[update.entry.path] = update.entry }
    let currentKeys = Set(progress.values.compactMap(\.key))
    try await catalog.apply(verified.compactMap(\.projection), removing: Array(oldKeys.subtracting(currentKeys)),
      recording: verified.map(\.entry))
    return verified.count
  }
}
