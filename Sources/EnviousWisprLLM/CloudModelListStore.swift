import Foundation

/// #4353 D6: one validated cloud model list the app is using, and where it came from.
///
/// Immutable. A newer publication replaces the holder's value; a reader that captured an
/// earlier snapshot keeps a complete, validated list for as long as it holds it.
package struct CloudModelListSnapshot: Sendable, Equatable {
  package enum Source: String, Sendable, Equatable {
    /// Fetched and validated during this run.
    case fresh
    /// The last good fetched copy, read back from Application Support.
    case persisted
    /// The copy shipped inside the app.
    case bundled
  }

  package let list: CloudModelList
  package let source: Source
  /// Increases by one with every publication from one store, so a consumer can refuse a
  /// publication older than the one it already shows.
  package let sequence: UInt64
}

/// #4353 D6: decides which cloud model list the app uses.
///
/// Selection, in order (plan D6):
///
/// | Situation | Active list |
/// |---|---|
/// | A fetch this run returned a valid document | that document, whatever its `updated` |
/// | No valid fetch yet; persisted and bundled both valid | the newer `updated`; on equal dates the persisted copy (the last answer the server gave) |
/// | Only one of persisted and bundled is valid | that one |
/// | Neither is valid | none (readers keep the compiled rules) |
/// | A fetch fails, is cancelled or returns an invalid document | unchanged, and the persisted file is untouched |
/// | A valid fetch cannot be saved | the fetched list is still used this run; the previous file is untouched |
///
/// A missing, unreadable, oversized or invalid persisted file counts as absent. Only the exact
/// validated bytes are ever written, atomically, so the file is always a whole valid document.
///
/// Cadence: the first `refreshIfDue()` of a run always fetches (the launch fetch). Later calls
/// fetch only when 24 hours have passed since the previous ATTEMPT, successful or not, so an
/// offline Mac does not retry on every activation. The attempt time lives in memory, so a
/// relaunch fetches again. A clock moved backwards past the previous attempt makes a fetch due.
/// Concurrent callers share one fetch, and only that fetch can publish, so a late completion can
/// never overwrite a newer result.
///
/// `RemoteRulesStore` was considered but requires strictly increasing integer revisions. This
/// list permits same-date content revisions and valid server replacements, so it owns a separate
/// selection policy. Its client reuses the existing bounded transport.
package actor CloudModelListStore {
  package static let refreshInterval: TimeInterval = 24 * 60 * 60
  package static let persistedFileName = "cloud-models.json"

  package enum PersistResult: Equatable, Sendable {
    case written
    /// The file already holds these exact bytes.
    case alreadyCurrent
    case failed(String)
  }

  package enum RefreshResult: Equatable, Sendable {
    case notDue
    case fetched(PersistResult)
    case failed(String)
    case cancelled
  }

  package struct RefreshOutcome: Sendable, Equatable {
    /// The active snapshot after this refresh (unchanged unless the result is `.fetched`).
    package let snapshot: CloudModelListSnapshot?
    package let result: RefreshResult
  }

  /// What the launch read found, for one diagnostic log line.
  package struct LocalReport: Sendable, Equatable {
    package enum Copy: String, Sendable, Equatable { case valid, absent, invalid, tooLarge }
    package let bundled: Copy
    package let persisted: Copy
  }

  package typealias Fetch = @Sendable () async throws -> CloudModelList
  package typealias Write = @Sendable (_ data: Data, _ url: URL) throws -> Void

  /// The choice made from local copies when the store was built, available synchronously so
  /// launch-time readers never wait for the actor.
  package nonisolated let initialSnapshot: CloudModelListSnapshot?
  package nonisolated let localReport: LocalReport

  private var active: CloudModelListSnapshot?
  private var sequence: UInt64
  /// The revision of the valid document in the persisted file, or nil when it holds none.
  private var persistedRevision: String?
  private var lastAttempt: Date?
  private var inFlight: Task<RefreshOutcome, Never>?

  private let fetch: Fetch
  private let persistedURL: URL
  private let now: @Sendable () -> Date
  private let write: Write
  /// Called, synchronously, when a caller joins a fetch already in flight. Tests wait on it to
  /// know a second caller is parked (the `RemoteRulesStore.onJoinedRefresh` shape); the app
  /// passes nothing.
  private let onJoinedRefresh: (@Sendable () -> Void)?

  package init(
    bundled: Data?,
    persistedURL: URL,
    fetch: @escaping Fetch,
    now: @escaping @Sendable () -> Date = { Date() },
    write: @escaping Write = CloudModelListStore.atomicWrite,
    onJoinedRefresh: (@Sendable () -> Void)? = nil
  ) {
    let (bundledList, bundledCopy) = Self.validatedCopy(
      bundled.map { $0.count <= CloudModelList.maxDocumentBytes ? .bytes($0) : .tooLarge }
        ?? .absent)
    let (persistedList, persistedCopy) = Self.validatedCopy(Self.boundedRead(persistedURL))
    let initial = Self.localChoice(bundled: bundledList, persisted: persistedList).map {
      CloudModelListSnapshot(list: $0.list, source: $0.source, sequence: 1)
    }
    self.initialSnapshot = initial
    self.localReport = LocalReport(bundled: bundledCopy, persisted: persistedCopy)
    self.active = initial
    self.sequence = initial == nil ? 0 : 1
    self.persistedRevision = persistedList?.revision
    self.fetch = fetch
    self.persistedURL = persistedURL
    self.now = now
    self.write = write
    self.onJoinedRefresh = onJoinedRefresh
  }

  package var current: CloudModelListSnapshot? { active }

  // MARK: - Refresh

  package func refreshIfDue() async -> RefreshOutcome {
    if let inFlight {
      onJoinedRefresh?()
      return await inFlight.value
    }
    let time = now()
    if let lastAttempt, time >= lastAttempt,
      time.timeIntervalSince(lastAttempt) < Self.refreshInterval
    {
      return RefreshOutcome(snapshot: active, result: .notDue)
    }
    lastAttempt = time
    // Created and stored with no suspension between, so a second caller always joins it.
    let task = Task { await self.performRefresh() }
    inFlight = task
    return await task.value
  }

  private func performRefresh() async -> RefreshOutcome {
    defer { inFlight = nil }
    let list: CloudModelList
    do {
      list = try await fetch()
    } catch is CancellationError {
      return RefreshOutcome(snapshot: active, result: .cancelled)
    } catch {
      return RefreshOutcome(snapshot: active, result: .failed(String(describing: error)))
    }
    let persist = persist(list)
    publish(list, source: .fresh)
    return RefreshOutcome(snapshot: active, result: .fetched(persist))
  }

  private func persist(_ list: CloudModelList) -> PersistResult {
    guard list.revision != persistedRevision else { return .alreadyCurrent }
    do {
      try write(list.documentBytes, persistedURL)
      persistedRevision = list.revision
      return .written
    } catch {
      return .failed(String(describing: error))
    }
  }

  private func publish(_ list: CloudModelList, source: CloudModelListSnapshot.Source) {
    sequence += 1
    active = CloudModelListSnapshot(list: list, source: source, sequence: sequence)
  }

  // MARK: - Pure policy (production code, driven directly by tests)

  /// The choice between local copies: the newer `updated`, persisted on a tie.
  package nonisolated static func localChoice(
    bundled: CloudModelList?, persisted: CloudModelList?
  ) -> (list: CloudModelList, source: CloudModelListSnapshot.Source)? {
    switch (bundled, persisted) {
    case (nil, nil): return nil
    case (let bundled?, nil): return (bundled, .bundled)
    case (nil, let persisted?): return (persisted, .persisted)
    case (let bundled?, let persisted?):
      // `YYYY-MM-DD` strings order the same as the dates they name.
      return persisted.updated >= bundled.updated ? (persisted, .persisted) : (bundled, .bundled)
    }
  }

  /// What a bounded read of a local copy found.
  package enum LocalRead: Equatable, Sendable {
    case bytes(Data)
    case absent
    case tooLarge
  }

  /// Reads at most one byte more than a valid document may hold, so an oversized file is
  /// refused without loading it. A missing or unreadable file is absent.
  package nonisolated static func boundedRead(_ url: URL) -> LocalRead {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .absent }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: CloudModelList.maxDocumentBytes + 1) else {
      return .absent
    }
    return data.count <= CloudModelList.maxDocumentBytes ? .bytes(data) : .tooLarge
  }

  private nonisolated static func validatedCopy(_ read: LocalRead) -> (
    CloudModelList?, LocalReport.Copy
  ) {
    switch read {
    case .absent: return (nil, .absent)
    case .tooLarge: return (nil, .tooLarge)
    case .bytes(let bytes):
      switch CloudModelList.validated(from: bytes) {
      case .success(let list): return (list, .valid)
      case .failure: return (nil, .invalid)
      }
    }
  }

  /// Writes the whole file or nothing (`.atomic` writes a temporary file and renames it).
  package nonisolated static func atomicWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}
