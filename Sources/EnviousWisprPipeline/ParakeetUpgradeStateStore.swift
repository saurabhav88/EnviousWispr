import EnviousWisprModelDelivery
import Foundation

/// The persisted Parakeet upgrade budget for ONE target identity (#3546, plan §3.4).
///
/// Missing state means a fresh target: no attempts spent, no refetch spent, not
/// exhausted, not declined. A newer Ultra revision is a new target with its own
/// files, so its budget starts clean (EG-1's revision-scoped decline precedent).
package struct ParakeetUpgradeState: Equatable, Sendable {
  package var attempts: Int
  package var refetchSpent: Bool
  package var exhausted: Bool
  package var declined: Bool

  package static let fresh = ParakeetUpgradeState(
    attempts: 0, refetchSpent: false, exhausted: false, declined: false)

  package init(attempts: Int, refetchSpent: Bool, exhausted: Bool, declined: Bool) {
    self.attempts = attempts
    self.refetchSpent = refetchSpent
    self.exhausted = exhausted
    self.declined = declined
  }
}

/// What a read of the store found.
package enum ParakeetUpgradeStateRead: Equatable, Sendable {
  case state(ParakeetUpgradeState)
  /// The files exist but cannot be trusted (unreadable, corrupt, not a regular
  /// file, or outside the metadata directory). Automatic upgrade work treats
  /// this as exhausted; an explicit Retry first proves the store can be
  /// written again.
  case unreadable(reason: String)
}

/// Thrown when the store cannot persist a field. The caller starts no Ultra
/// load and does not fall into another row (plan §3b failure isolation).
package struct ParakeetUpgradeStoreWriteError: Error, Equatable {
  package let field: String
  package init(field: String) { self.field = field }
}

/// File-backed state for one Ultra target (#3546, plan §3b).
///
/// Files live in the registration's app-owned `<data>/ModelDelivery/`, beside the
/// admission markers, named `parakeet-upgrade-<field>-<Ultra cacheKey>`, so the
/// state describes the same disk the markers do even though dev and production
/// builds use different defaults domains. `attempts` holds a decimal count; the
/// three flags are present-or-absent zero-byte files written like EG-1's markers.
/// Every write is atomic (temporary file, then rename) and contained.
package struct ParakeetUpgradeStateStore: Sendable {
  package enum Field: String, CaseIterable, Sendable {
    case attempts, refetchSpent, exhausted, declined
  }

  private let metadataDirectory: URL
  private let targetCacheKey: String
  private let writeData: @Sendable (Data, URL) throws -> Void
  private let removeItem: @Sendable (URL) throws -> Void

  package init(
    metadataDirectory: URL, targetCacheKey: String,
    writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    },
    removeItem: @escaping @Sendable (URL) throws -> Void = { try LegacyRetirement.clearMarker($0) }
  ) {
    self.metadataDirectory = metadataDirectory
    self.targetCacheKey = targetCacheKey
    self.writeData = writeData
    self.removeItem = removeItem
  }

  package func url(for field: Field) -> URL {
    metadataDirectory.appendingPathComponent(
      "parakeet-upgrade-\(field.rawValue)-\(targetCacheKey)", isDirectory: false)
  }

  package func read() -> ParakeetUpgradeStateRead {
    var state = ParakeetUpgradeState.fresh
    for field in Field.allCases {
      let url = url(for: field)
      guard LegacyRetirement.isContained(url, within: metadataDirectory) else {
        return .unreadable(reason: "\(field.rawValue):outside_metadata")
      }
      // Absent is the only "no state"; a lookup that FAILS is unreadable, never
      // a fresh budget, and a flag must be a regular file (not a directory or
      // a link of any kind).
      var info = stat()
      if lstat(url.path, &info) != 0 {
        let code = errno
        if code == ENOENT { continue }
        return .unreadable(reason: "\(field.rawValue):lookup_\(code)")
      }
      guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
        return .unreadable(reason: "\(field.rawValue):not_a_file")
      }
      switch field {
      case .attempts:
        guard let data = FileManager.default.contents(atPath: url.path) else {
          return .unreadable(reason: "attempts:unreadable")
        }
        guard let text = String(data: data, encoding: .utf8),
          let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          count >= 0
        else {
          return .unreadable(reason: "attempts:corrupt")
        }
        state.attempts = count
      case .refetchSpent: state.refetchSpent = true
      case .exhausted: state.exhausted = true
      case .declined: state.declined = true
      }
    }
    return .state(state)
  }

  /// Persists every field of `state`. Throws `ParakeetUpgradeStoreWriteError`
  /// naming the first field that could not be written.
  package func write(_ state: ParakeetUpgradeState) throws {
    try set(.attempts, present: state.attempts > 0, contents: Data("\(state.attempts)".utf8))
    try set(.refetchSpent, present: state.refetchSpent)
    try set(.exhausted, present: state.exhausted)
    try set(.declined, present: state.declined)
  }

  /// Proves the store can be written, without changing what it holds: an
  /// explicit Retry calls this before granting a recovery cycle.
  package func probeWritable() throws {
    let probe = metadataDirectory.appendingPathComponent(
      "parakeet-upgrade-probe-\(targetCacheKey)", isDirectory: false)
    guard LegacyRetirement.isContained(probe, within: metadataDirectory) else {
      throw ParakeetUpgradeStoreWriteError(field: "probe")
    }
    do {
      try writeData(Data(), probe)
      try removeItem(probe)
    } catch {
      throw ParakeetUpgradeStoreWriteError(field: "probe")
    }
  }

  private func set(_ field: Field, present: Bool, contents: Data = Data()) throws {
    let url = url(for: field)
    guard LegacyRetirement.isContained(url, within: metadataDirectory) else {
      throw ParakeetUpgradeStoreWriteError(field: field.rawValue)
    }
    do {
      if present {
        try writeData(contents, url)
      } else {
        try removeItem(url)
      }
    } catch {
      throw ParakeetUpgradeStoreWriteError(field: field.rawValue)
    }
  }
}
