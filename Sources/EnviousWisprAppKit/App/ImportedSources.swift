import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Observation

/// The file work `ImportedSources` does, off the main actor. Replaceable so a test can hold a
/// lookup at a chosen step; production uses `.live`.
struct ImportedSourceIO: Sendable {
  struct Resolution: Sendable {
    let url: URL
    let isStale: Bool
  }

  /// Resolves a plain bookmark without any UI or volume mounting; nil when it does not resolve.
  var resolve: @Sendable (Data) -> Resolution?
  /// Whether a regular file is at `url` now.
  var fileExists: @Sendable (URL) -> Bool
  /// The file's `ImportedSourceIdentity` (plan §17 R2). Never writes.
  var identity: @Sendable (URL) async throws -> ImportedSourceIdentity
  /// A fresh plain bookmark for `url` (the same kind the import stores).
  var makeBookmark: @Sendable (URL) throws -> Data
  /// Opens `url` for windowed playback.
  var openAudio: @Sendable (URL) async throws -> ImportedFilePlaybackAudio

  static let live = ImportedSourceIO(
    resolve: { data in
      var stale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
          bookmarkDataIsStale: &stale)
      else { return nil }
      return Resolution(url: url, isStale: stale)
    },
    fileExists: { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    },
    identity: { url in try await ImportedSourceFingerprint.read(url: url) },
    makeBookmark: { url in
      try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    },
    openAudio: { url in try await ImportedFilePlaybackAudio.open(url: url) })
}

/// Why Locate original could not use the chosen file.
enum ImportedSourceError: Error, Equatable {
  /// The chosen file could not be read (no identity).
  case unreadable
  /// The row's stored fingerprint is a version this build cannot compare against.
  case unsupportedIdentity
}

/// Finds, checks, relinks and opens imports' original files for History (#3147 PR3, plan
/// §3.5, §17 R2). One per app, shared by every History window.
///
/// - Bookmarks are plain and resolved without UI. A stale bookmark is refreshed only after the
///   file opened and its identity matched the stored fingerprint, through the coordinator's
///   compare-and-set command (`setImportedSource`), and never while that row is playing (the
///   command stops its players).
/// - A known fingerprint must match, whatever the user confirms; a legacy row (no fingerprint)
///   adopts a file only with the user's confirmation.
/// - States are cached per row and source reference, so views read them from `.task`, never
///   from a body; `playbackSource` always re-checks the disk and re-checks identity after the
///   reader opens. A disk change seen there updates the cache and the row's revision.
/// - A lookup that began before a deletion, a Delete All, or a change of the row's source never
///   builds a player and never publishes a state (`PlaybackArbiter.deletionCount`,
///   `transcriptEpoch`).
/// - Nothing here writes to, copies or moves a source file.
@MainActor
@Observable
final class ImportedSources: ImportedSourceAccessing {
  @ObservationIgnored private let coordinator: TranscriptCoordinator
  @ObservationIgnored private weak var arbiter: PlaybackArbiter?
  @ObservationIgnored private let io: ImportedSourceIO

  private struct Entry {
    let reference: ImportedSourceReference
    let state: ImportedSourceState
  }

  /// What the arbiter said about a row, and the cache sweep, when a lookup began.
  private struct Fence: Equatable {
    let deletions: Int
    let epoch: Int
    let sweep: Int
  }

  private struct Lookup: Sendable {
    let state: ImportedSourceState
    /// A new bookmark for a stale one whose file matched its stored fingerprint.
    let refreshedBookmark: Data?
  }

  /// Bumped when a row's cached state changes, so its revision changes. Observed.
  private var generations: [UUID: Int] = [:]
  /// Bumped by `invalidateAll`. Observed.
  private var sweeps = 0
  @ObservationIgnored private var cache: [UUID: Entry] = [:]
  /// One shared lookup per row and reference, so two windows never hash one file twice.
  @ObservationIgnored private var inFlight: [UUID: (ImportedSourceReference, Task<Lookup, Never>)] =
    [:]
  /// Disk lookups started (shared ones count once).
  private(set) var lookupsStarted = 0
  /// Lookups that joined one already in flight for the same row and reference.
  private(set) var lookupsJoined = 0

  init(coordinator: TranscriptCoordinator, arbiter: PlaybackArbiter?, io: ImportedSourceIO = .live)
  {
    self.coordinator = coordinator
    self.arbiter = arbiter
    self.io = io
  }

  // MARK: - ImportedSourceAccessing

  func revision(for rowID: UUID) -> Int {
    var hasher = Hasher()
    hasher.combine(sweeps)
    hasher.combine(generations[rowID, default: 0])
    let row = coordinator.currentRow(id: rowID)
    hasher.combine(row == nil)
    hasher.combine(row?.sourceBookmark)
    hasher.combine(row?.sourceFingerprint)
    hasher.combine(row?.importAttemptID)
    if let arbiter {
      hasher.combine(arbiter.deletionCount(for: .transcript(rowID)))
      hasher.combine(arbiter.transcriptEpoch)
    }
    return hasher.finalize()
  }

  func state(for rowID: UUID) async -> ImportedSourceState {
    var last: ImportedSourceState = .missing
    // Each extra pass means the row's source or deletion state changed under the lookup.
    for _ in 0..<3 {
      guard let row = coordinator.currentRow(id: rowID) else { return removed(rowID) }
      guard row.isImported else { return .missing }
      let reference = ImportedSourceReference(row)
      if let cached = cache[rowID], cached.reference == reference { return cached.state }
      let fence = currentFence(rowID)
      let result = await sharedLookup(rowID: rowID, reference: reference)
      last = result.state
      if Task.isCancelled { return result.state }
      guard isUnchanged(rowID, reference: reference, fence: fence) else { continue }
      guard let fresh = result.refreshedBookmark, case .available(let resolved) = result.state
      else {
        store(rowID, reference: reference, state: result.state)
        return result.state
      }
      // Stale bookmark: cached only once the refreshed link is stored, so the next look retries.
      let refreshed = await refresh(resolved, with: fresh)
      // An `invalidateAll` during the refresh's write: look again rather than cache.
      guard fence.sweep == sweeps else { continue }
      if let refreshed {
        if coordinator.currentRow(id: rowID).map(ImportedSourceReference.init)
          == refreshed.reference
        {
          store(rowID, reference: refreshed.reference, state: .available(refreshed))
        }
        return .available(refreshed)
      }
      return result.state
    }
    return coordinator.currentRow(id: rowID) == nil ? removed(rowID) : last
  }

  func playbackSource(for rowID: UUID) async throws -> ImportedPlaybackSource? {
    guard let row = coordinator.currentRow(id: rowID) else {
      _ = removed(rowID)
      return nil
    }
    guard row.isImported else { return nil }
    let reference = ImportedSourceReference(row)
    var fence = currentFence(rowID)
    lookupsStarted += 1
    let first = await Self.lookup(rowID: rowID, reference: reference, io: io)
    try Task.checkCancellation()
    guard isUnchanged(rowID, reference: reference, fence: fence) else { return nil }
    guard case .available(var resolved) = first.state else {
      store(rowID, reference: reference, state: first.state)
      return nil
    }
    if let fresh = first.refreshedBookmark, let refreshed = await refresh(resolved, with: fresh) {
      resolved = refreshed
      // The refresh's own write stopped this row's players (one more deletion count); that is
      // not a deletion. Only that component moves: a Delete All or an invalidation during the
      // write still fences this lookup.
      fence = Fence(
        deletions: currentFence(rowID).deletions, epoch: fence.epoch, sweep: fence.sweep)
    }

    let audio: ImportedFilePlaybackAudio
    do {
      audio = try await io.openAudio(resolved.url)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if isUnchanged(rowID, reference: resolved.reference, fence: fence) {
        store(rowID, reference: resolved.reference, state: .unreadable)
      }
      return nil
    }
    // The file the reader opened must still be the original.
    lookupsStarted += 1
    let check = await Self.lookup(rowID: rowID, reference: resolved.reference, io: io)
    guard !Task.isCancelled else {
      audio.close()
      throw CancellationError()
    }
    guard isUnchanged(rowID, reference: resolved.reference, fence: fence) else {
      audio.close()
      return nil
    }
    guard case .available(let confirmed) = check.state, confirmed.identity == resolved.identity
    else {
      audio.close()
      store(rowID, reference: resolved.reference, state: check.state)
      return nil
    }
    store(rowID, reference: resolved.reference, state: .available(resolved))
    return ImportedPlaybackSource(source: resolved, durationMs: audio.durationMs, audio: audio)
  }

  func relocate(rowID: UUID, to url: URL, userConfirmed: Bool) async throws
    -> ImportedRelocationOutcome
  {
    guard let row = coordinator.currentRow(id: rowID), row.isImported else {
      _ = removed(rowID)
      return .removed
    }
    let expected = ImportedSourceReference(row)
    let stored = row.sourceFingerprint
    if let stored, !Self.isSupported(stored) { throw ImportedSourceError.unsupportedIdentity }
    if stored == nil, !userConfirmed { return .confirmationRequired }
    let fence = currentFence(rowID)
    let io = io
    let (identity, bookmark) = try await Self.identify(url, io: io)
    guard coordinator.currentRow(id: rowID) != nil else { return relocationRemoved(rowID) }
    guard isUnchanged(rowID, reference: expected, fence: fence) else { return .stale }
    if let stored, identity.match(stored) != .same { return .wrongFile }
    let fingerprint = stored ?? identity.fingerprint
    let linked = try await coordinator.setImportedSource(
      bookmark: bookmark, fingerprint: fingerprint, for: rowID, expected: expected,
      confirmedLegacy: stored == nil)
    guard linked else {
      return coordinator.currentRow(id: rowID) == nil ? relocationRemoved(rowID) : .stale
    }
    // Stored; but an `invalidateAll` during the save means the next look reads the disk afresh
    // rather than this earlier read (Codex lane-a r2).
    guard fence.sweep == sweeps else { return .linked }
    let reference = ImportedSourceReference(bookmark: bookmark, fingerprint: fingerprint)
    inFlight[rowID] = nil
    store(
      rowID, reference: reference,
      state: .available(
        ResolvedImportedSource(rowID: rowID, reference: reference, url: url, identity: identity)))
    return .linked
  }

  // MARK: - Beyond the protocol

  /// Forgets every cached state (for example when History comes to the front), so the next look
  /// re-reads the disk.
  func invalidateAll() {
    cache.removeAll()
    inFlight.removeAll()
    sweeps &+= 1
  }

  // MARK: - Internals

  private func currentFence(_ rowID: UUID) -> Fence {
    Fence(
      deletions: arbiter?.deletionCount(for: .transcript(rowID)) ?? 0,
      epoch: arbiter?.transcriptEpoch ?? 0, sweep: sweeps)
  }

  /// The row still holds `reference` and no deletion happened since `fence`.
  private func isUnchanged(_ rowID: UUID, reference: ImportedSourceReference, fence: Fence) -> Bool
  {
    guard fence == currentFence(rowID), let row = coordinator.currentRow(id: rowID) else {
      return false
    }
    return ImportedSourceReference(row) == reference
  }

  private func relocationRemoved(_ rowID: UUID) -> ImportedRelocationOutcome {
    _ = removed(rowID)
    return .removed
  }

  private func removed(_ rowID: UUID) -> ImportedSourceState {
    inFlight[rowID] = nil
    if cache.removeValue(forKey: rowID) != nil { generations[rowID, default: 0] &+= 1 }
    return .removed
  }

  private func store(_ rowID: UUID, reference: ImportedSourceReference, state: ImportedSourceState)
  {
    let previous = cache[rowID]?.state
    cache[rowID] = Entry(reference: reference, state: state)
    if previous != state { generations[rowID, default: 0] &+= 1 }
  }

  private func sharedLookup(rowID: UUID, reference: ImportedSourceReference) async -> Lookup {
    if let shared = inFlight[rowID], shared.0 == reference {
      lookupsJoined += 1
      return await shared.1.value
    }
    lookupsStarted += 1
    let io = io
    let task = Task { await Self.lookup(rowID: rowID, reference: reference, io: io) }
    inFlight[rowID] = (reference, task)
    let result = await task.value
    if let shared = inFlight[rowID], shared.0 == reference, shared.1 == task {
      inFlight[rowID] = nil
    }
    return result
  }

  /// Stores `bookmark` for a stale link whose file matched, unless that row is playing now.
  /// Returns the source under its new reference, or nil when nothing was stored.
  private func refresh(_ resolved: ResolvedImportedSource, with bookmark: Data) async
    -> ResolvedImportedSource?
  {
    guard let fingerprint = resolved.reference.fingerprint,
      arbiter?.isPlaying(.transcript(resolved.rowID)) != true
    else { return nil }
    guard
      (try? await coordinator.setImportedSource(
        bookmark: bookmark, fingerprint: fingerprint, for: resolved.rowID,
        expected: resolved.reference, confirmedLegacy: false)) == true
    else { return nil }
    return ResolvedImportedSource(
      rowID: resolved.rowID,
      reference: ImportedSourceReference(bookmark: bookmark, fingerprint: fingerprint),
      url: resolved.url, identity: resolved.identity)
  }

  nonisolated private static func isSupported(_ fingerprint: String) -> Bool {
    fingerprint.hasPrefix(ImportedSourceIdentity.version + ":")
  }

  /// A chosen file's identity and a bookmark for it, off the main actor.
  @concurrent
  nonisolated private static func identify(_ url: URL, io: ImportedSourceIO) async throws
    -> (ImportedSourceIdentity, Data)
  {
    let identity: ImportedSourceIdentity
    do {
      identity = try await io.identity(url)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ImportedSourceError.unreadable
    }
    try Task.checkCancellation()
    guard let bookmark = try? io.makeBookmark(url) else { throw ImportedSourceError.unreadable }
    return (identity, bookmark)
  }

  /// What the disk says about `reference` now. Off the main actor; never writes.
  @concurrent
  nonisolated private static func lookup(
    rowID: UUID, reference: ImportedSourceReference, io: ImportedSourceIO
  ) async -> Lookup {
    guard let bookmark = reference.bookmark else {
      return Lookup(state: .missing, refreshedBookmark: nil)
    }
    if let stored = reference.fingerprint, !isSupported(stored) {
      return Lookup(state: .unsupportedIdentity, refreshedBookmark: nil)
    }
    guard let resolution = io.resolve(bookmark), io.fileExists(resolution.url) else {
      return Lookup(state: .missing, refreshedBookmark: nil)
    }
    let identity: ImportedSourceIdentity
    do {
      identity = try await io.identity(resolution.url)
    } catch ImportedSourceFingerprint.ReadError.notRegularFile {
      return Lookup(state: .missing, refreshedBookmark: nil)
    } catch {
      // The file is there (checked above) and could not be read now.
      return Lookup(
        state: io.fileExists(resolution.url) ? .unreadable : .missing, refreshedBookmark: nil)
    }
    guard let stored = reference.fingerprint else {
      return Lookup(state: .unverifiable(resolution.url), refreshedBookmark: nil)
    }
    guard identity.match(stored) == .same else {
      return Lookup(state: .changed, refreshedBookmark: nil)
    }
    let resolved = ResolvedImportedSource(
      rowID: rowID, reference: reference, url: resolution.url, identity: identity)
    let refreshed = resolution.isStale ? try? io.makeBookmark(resolution.url) : nil
    return Lookup(state: .available(resolved), refreshedBookmark: refreshed)
  }
}
