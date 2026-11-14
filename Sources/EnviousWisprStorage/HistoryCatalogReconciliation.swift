import Foundation

/// One writer reconciles the catalog against the existing stores. This worker never mutates
/// those stores. Restart can reuse any projection whose complete source proof still matches.
package actor HistoryCatalogReconciliation {
  package struct Pass: Sendable {
    package let revision: String?
    package let completed: Int
    package let total: Int
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
    var completed = 0
    for url in ordered {
      try Task.checkCancellation()
      let before = progress[url.path]
      if let before, (try? before.versions.allSatisfy { try $0.stillMatches() }) == true {
        completed += 1
        continue
      }
      do {
        let snapshot = try sources.snapshot(of: url, at: now)
        let projection = snapshot.saved.flatMap(project)
        let entry = HistoryCatalog.SourceProgress(
          path: url.path, versions: snapshot.versions, key: projection?.summary.key)
        pending.append(Update(entry: entry, projection: projection))
      } catch {
        // Preserve the last known key/proof. It remains ineligible while the source is
        // unverified, and a later pass can still remove it if the file disappears.
      }
      if pending.count == Self.batchSize {
        completed += try await commit(pending, tracking: &progress)
        pending.removeAll(keepingCapacity: true)
        await onProgress(Pass(revision: nil, completed: completed, total: paths.count))
      }
    }
    completed += try await commit(pending, tracking: &progress)

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
    let result = Pass(revision: currentRevision, completed: min(completed, currentPaths.count), total: currentPaths.count)
    await onProgress(result)
    return result
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
