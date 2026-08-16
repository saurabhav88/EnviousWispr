import EnviousWisprCore
import Foundation

/// Persists transcripts as JSON files in Application Support.
///
/// Privacy posture (V3 audit #561 / #562):
/// - Directory created at 0700 (owner-only access). Re-enforced at every init
///   in case a backup restore or user action loosened permissions.
/// - Each file written at 0600 by setting POSIX permissions immediately after
///   the atomic write succeeds.
/// - `.metadata_never_index` marker dropped at directory creation so Spotlight
///   does not index transcript text.
@MainActor
public final class TranscriptStore {
  private let directory: URL

  public init() {
    directory = AppConstants.appSupportURL
      .appendingPathComponent(AppConstants.transcriptsDir, isDirectory: true)
    Self.prepareDirectory(at: directory)
    Self.scheduleMigration(in: directory)
  }

  // Tests only. Reached via `@testable import EnviousWisprStorage`.
  // Production uses the default `init()` so the store always points at
  // `AppConstants.appSupportURL/transcripts`. Keeping this `internal`
  // means a production call site cannot mis-point the store. Periphery
  // scans `--exclude-tests` so this init appears unused from production;
  // the annotation suppresses that false positive.
  // periphery:ignore
  internal init(directory: URL) {
    self.directory = directory
    Self.prepareDirectory(at: directory)
    Self.scheduleMigration(in: directory)
  }

  /// Save a transcript to disk at 0600.
  ///
  /// Writes to a temp file at 0600 first via `Foundation.open(... 0o600)`
  /// then renames into place. Mirrors the pattern in `KeychainManager.store`
  /// and avoids the brief world-readable window that `Data.write(.atomic)`
  /// + post-write chmod creates.
  public func save(_ transcript: Transcript) throws {
    try Self.write(transcript, into: directory)
  }

  // MARK: - Pending (Escape Recovery) namespace — #2087
  //
  // Pending rows live in a CHILD directory rather than being flagged by a
  // field. That is the fail-closed property AND the rollback property:
  // `loadAll()` above enumerates one level and keeps only `.json` files, so a
  // subdirectory is invisible to it and to every build that predates this
  // feature. A malformed pending row therefore cannot leak into permanent
  // History; the worst it can do is be ignored and swept.

  private var pendingDirectory: URL {
    directory.appendingPathComponent(
      AppConstants.pendingTranscriptsDir, isDirectory: true)
  }

  /// Save a not-yet-permanent Escape Recovery row. Same 0600 temp-then-rename
  /// write as `save`, into the 0700 pending child.
  public func savePending(_ transcript: Transcript) throws {
    Self.prepareDirectory(at: pendingDirectory, dropSpotlightMarker: false)
    try Self.write(transcript, into: pendingDirectory)
  }

  /// Pending rows that are still restorable at `now`, newest first.
  ///
  /// FAIL-CLOSED, and deliberately not "whatever is on disk": the namespace
  /// makes a row pending, but this method decides whether it is still OFFERED.
  /// A row is admitted only when it carries a non-nil `escapeRecoveredAt`, that
  /// instant is not implausibly in the future, and the retention window has not
  /// elapsed. Missing, malformed and expired rows are never returned — so a
  /// stale sweep cannot make an expired row visible, and a corrupt one cannot
  /// impersonate a fresh one.
  public func loadPending(now: Date = Date()) async throws -> [Transcript] {
    let dir = pendingDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    let retention = AppConstants.pendingTranscriptRetention
    // `Task.detached` (task-detached-proof): a plain `Task` would inherit this
    // type's `@MainActor` isolation and run the directory walk plus one decode
    // per pending row on the main thread; `withTaskGroup` buys nothing for a
    // single unit of work; and `@concurrent` cannot apply because the method
    // belongs to a `@MainActor` class whose callers are main-actor UI code.
    // Every captured value is Sendable, matching the existing `loadAll` shape
    // directly above.
    return try await Task.detached(priority: .userInitiated) {
      Self.decodePending(in: dir, now: now, retention: retention)
        .compactMap(\.liveTranscript)
        .sorted { $0.createdAt > $1.createdAt }
    }.value
  }

  /// Every decodable pending row's recovery session id, expiry IGNORED (#2087).
  ///
  /// Exists for exactly one caller: crash-recovery de-duplication. A saved row
  /// proves its spool was already recovered, and that stays true forever — so
  /// filtering by expiry here would let a spool whose row aged out get replayed
  /// a second time, handing the user a duplicate dictation exactly 24 hours
  /// later. A bug that is correct for a day and then not is worse than one that
  /// is always wrong, because nothing in testing will catch it.
  ///
  /// Deliberately returns ONLY the ids, not the rows: this is a de-dup key
  /// source, and returning transcripts would invite a caller to render an
  /// expired row that `loadPending` exists to hide.
  public func pendingRecoverySessionIDs() async throws -> Set<String> {
    let dir = pendingDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    return try await Task.detached(priority: .userInitiated) {
      Self.decodeAnyPendingIdentities(in: dir)
    }.value
  }

  /// Every recovery session id this store has already turned into text, across
  /// BOTH namespaces (#2087).
  ///
  /// The de-dup authority for launch recovery, and it lives here rather than as
  /// a union assembled at the call site so that "already recovered" has one
  /// definition. A caller that remembered `loadAll` and forgot `pending/` would
  /// replay an escape-recovered spool a second time and hand the user the same
  /// dictation twice — and that omission is invisible in review, because the
  /// half-answer looks complete.
  public func allRecoveredSessionIDs() async throws -> Set<String> {
    let permanent = Set((try await loadAll()).compactMap(\.recoverySessionID))
    return try await permanent.union(pendingRecoverySessionIDs())
  }

  /// Make a pending row permanent.
  ///
  /// **Revalidates before writing.** A Keep press can arrive after the row has
  /// expired between render and click, so this repeats the admission check
  /// rather than trusting the caller — the same reason the plan requires Undo
  /// to be inert rather than merely harmless. A non-live row is silently
  /// ignored: it has already stopped being offered, so there is nothing to
  /// report to a user who can no longer see it.
  ///
  /// Ordering: the promoted copy is written to the root namespace FIRST, then
  /// the pending file is removed, so a crash between the two leaves the
  /// permanent row present rather than losing the text. Idempotent.
  public func promotePending(id: UUID, now: Date = Date()) throws {
    let pendingURL = pendingDirectory.appendingPathComponent("\(id.uuidString).json")
    guard
      let transcript = Self.decodeCandidate(
        at: pendingURL, now: now, retention: AppConstants.pendingTranscriptRetention
      ).liveTranscript
    else {
      // Already promoted, never existed, expired, or invalid. All are no-ops
      // for an idempotent operation.
      return
    }
    try save(transcript.promotedFromPending())
    try? FileManager.default.removeItem(at: pendingURL)
  }

  /// Sweep pending rows that are no longer live, and RETURN ONLY THE GENUINELY
  /// EXPIRED ONES THAT WERE ACTUALLY DELETED.
  ///
  /// Two distinctions this method exists to keep, both of which produce wrong
  /// telemetry if collapsed:
  ///
  /// - **Expired is not invalid.** A corrupt, unstamped, future-dated or
  ///   misnamed file is swept but produces no receipt, because
  ///   `escape_recovery.expired` means "the user let a real recovery lapse",
  ///   not "a file was unreadable".
  /// - **Deleted is not attempted.** Removal is best-effort, so a row is
  ///   reported only once its file is confirmed gone. Otherwise a failing
  ///   delete would re-emit the same expiry event on every future sweep,
  ///   forever.
  @discardableResult
  public func deleteExpiredPending(now: Date = Date()) throws -> [ExpiredPendingRow] {
    let dir = pendingDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
    let fm = FileManager.default
    var reported: [ExpiredPendingRow] = []
    for candidate in Self.decodePending(
      in: dir, now: now, retention: AppConstants.pendingTranscriptRetention)
    where !candidate.isLive {
      try? fm.removeItem(at: candidate.url)
      // Report only once the file is confirmed gone, so a failed removal is
      // retried on the next sweep instead of re-emitting the same expiry event
      // on every sweep forever.
      guard !fm.fileExists(atPath: candidate.url.path) else { continue }
      if let receipt = candidate.expiredReceipt { reported.append(receipt) }
    }
    return reported
  }

  /// Why a pending file is or is not still offered.
  ///
  /// Modelled as an enum with payloads rather than a struct plus a flag so an
  /// `.invalid` file **cannot carry a transcript at all**. An earlier revision
  /// fabricated a stand-in `Transcript` (with an invented UUID) for unreadable
  /// files; nothing consumed it, and a future consumer could have mistaken the
  /// invented identity for a real one. Making it unrepresentable is cheaper
  /// than remembering not to trust it.
  private nonisolated enum PendingCandidate {
    /// Decodes, correctly named, stamped, inside the retention window.
    case live(url: URL, transcript: Transcript)
    /// A valid row whose window elapsed. The ONLY case that earns a receipt.
    case expired(url: URL, transcript: Transcript)
    /// Unreadable, undecodable, unstamped, future-stamped, or filename/id
    /// mismatch. Swept, never offered, never reported as an expiry.
    case invalid(url: URL)

    var url: URL {
      switch self {
      case .live(let url, _), .expired(let url, _), .invalid(let url): return url
      }
    }

    var liveTranscript: Transcript? {
      if case .live(_, let transcript) = self { return transcript }
      return nil
    }

    /// Non-nil only for a genuinely expired row, which is what makes a false
    /// `escape_recovery.expired` event structurally impossible.
    var expiredReceipt: ExpiredPendingRow? {
      guard case .expired(_, let transcript) = self else { return nil }
      return ExpiredPendingRow(id: transcript.id, takeID: transcript.escapeRecoveryTakeID)
    }

    var isLive: Bool { liveTranscript != nil }
  }

  private nonisolated static func decodePending(
    in directory: URL, now: Date, retention: TimeInterval
  ) -> [PendingCandidate] {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return
      files
      .filter { $0.pathExtension == "json" }
      .map { decodeCandidate(at: $0, now: now, retention: retention) }
  }

  /// Recovery session ids of every pending file that DECODES, regardless of
  /// expiry, stamp validity or filename agreement (#2087).
  ///
  /// Deliberately more permissive than `decodeCandidate`. That function decides
  /// what may be OFFERED to the user and is fail-closed for good reason. This one
  /// answers a different question — "was this spool already recovered?" — where
  /// fail-closed points the OTHER way: a row we refuse to count here becomes a
  /// spool we replay again, which is a duplicate dictation. A row that decodes at
  /// all is proof enough that its audio was already turned into text.
  private nonisolated static func decodeAnyPendingIdentities(in directory: URL) -> Set<String> {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    // A BARE decoder, matching `write(_:into:)`'s bare `JSONEncoder()`. Setting
    // `.iso8601` here (copied from the marker code, where this type owns both
    // sides) made every row fail to decode and returned an empty set — which
    // reads exactly like "no pending rows" and would have silently restored the
    // duplicate-replay bug this function exists to fix.
    let decoder = JSONDecoder()
    var ids: Set<String> = []
    for url in files where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
        let transcript = try? decoder.decode(Transcript.self, from: data),
        let recoveryID = transcript.recoverySessionID
      else { continue }
      ids.insert(recoveryID)
    }
    return ids
  }

  private nonisolated static func decodeCandidate(
    at url: URL, now: Date, retention: TimeInterval
  ) -> PendingCandidate {
    // Unreadable-but-present is `.invalid`, NOT skipped. Returning nil here
    // meant such a file was never offered and never swept, so it accumulated
    // forever while the retention contract claimed otherwise.
    guard let data = try? Data(contentsOf: url) else { return .invalid(url: url) }
    guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
      return .invalid(url: url)
    }
    // The filename is the lookup key every other method uses, so a row whose
    // embedded id disagrees with its filename is unreachable by
    // `promotePending` and would sit forever being offered and never restorable.
    guard url.deletingPathExtension().lastPathComponent == transcript.id.uuidString else {
      return .invalid(url: url)
    }
    guard let stamped = transcript.escapeRecoveredAt else { return .invalid(url: url) }
    // #2087: the admission RULE lives in `PendingAdmission` so this and the
    // replayer's pre-ASR gate cannot drift. They did drift once — the replayer
    // checked elapsed time and forgot future skew.
    switch PendingAdmission.verdict(stampedAt: stamped, now: now, retention: retention) {
    case .corrupt: return .invalid(url: url)
    case .live: return .live(url: url, transcript: transcript)
    case .expired: return .expired(url: url, transcript: transcript)
    }
  }

  /// Shared 0600 temp-then-rename write used by `save` and `savePending`.
  private nonisolated static func write(_ transcript: Transcript, into directory: URL) throws {
    let url = directory.appendingPathComponent("\(transcript.id.uuidString).json")
    let data = try JSONEncoder().encode(transcript)
    let tmpURL = directory.appendingPathComponent(".\(transcript.id.uuidString).tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else {
        // #1167: preserve the POSIX errno so a best-effort caller can classify
        // disk-full / permission / read-only rather than collapsing them.
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try fh.write(contentsOf: data)
      try fh.close()
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
      } else {
        try fm.moveItem(at: tmpURL, to: url)
      }
    } catch {
      try? fm.removeItem(at: tmpURL)
      throw error
    }
  }

  /// Create the directory at 0700, optionally drop a `.metadata_never_index`
  /// Spotlight marker, and re-enforce permissions on every call. Soft-fails on
  /// any filesystem operation — better to lose a privacy guarantee than crash.
  private static func prepareDirectory(at directory: URL, dropSpotlightMarker: Bool = true) {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fm.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
    // The pending child inherits Spotlight exclusion from its parent, so it
    // does not need its own marker — and adding one would leave a stray file
    // that `decodePending` would have to learn to ignore.
    guard dropSpotlightMarker else { return }
    let marker = directory.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      fm.createFile(atPath: marker.path, contents: Data(), attributes: nil)
    }
  }

  /// Walk existing files and force them to 0600. Migrates installs that
  /// pre-date this hardening so a user with months of old transcripts is
  /// not left with world-readable files until each is rewritten.
  ///
  /// Dispatched off the main actor so an install with thousands of
  /// transcripts (founder's machine has 6,300+) does not stutter the UI
  /// at app launch. Each setAttributes call is fast individually, but the
  /// loop adds up.
  private static func scheduleMigration(in directory: URL) {
    Task.detached(priority: .utility) {
      let fm = FileManager.default
      guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
      for entry in entries where entry.hasSuffix(".json") {
        let path = directory.appendingPathComponent(entry).path
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
      }
    }
  }

  /// Load all transcripts, sorted by creation date (newest first).
  /// Heavy file IO is performed on a background thread to keep UI responsive.
  public func loadAll() async throws -> [Transcript] {
    let dir = directory
    guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

    // Move heavy IO to background thread
    let transcripts: [Transcript] = try await Task.detached(priority: .userInitiated) {
      let files = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil
      )

      let decoder = JSONDecoder()
      var result: [Transcript] = []
      for url in files where url.pathExtension == "json" {
        do {
          let data = try Data(contentsOf: url)
          let transcript = try decoder.decode(Transcript.self, from: data)
          result.append(transcript)
        } catch {
          // Log errors but don't block — corrupt files are skipped
          await AppLogger.shared.log(
            "Skipping corrupt transcript \(url.lastPathComponent): \(error)",
            level: .info, category: "TranscriptStore"
          )
        }
      }
      return result.sorted { $0.createdAt > $1.createdAt }
    }.value

    return transcripts
  }

  /// Delete a transcript by ID.
  public func delete(id: UUID) throws {
    let url = directory.appendingPathComponent("\(id.uuidString).json")
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }

  /// Delete all transcripts from disk atomically.
  /// Removes and recreates the directory with the same hardened permissions
  /// + Spotlight marker established at init.
  public func deleteAll() throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
    Self.prepareDirectory(at: directory)
  }
}

/// A pending Escape Recovery row that aged out un-restored (#2087).
///
/// Returned by `TranscriptStore.deleteExpiredPending` because expiry telemetry
/// needs one event per row carrying its originating take id, and by the time a
/// row is expired `loadPending` has already stopped returning it — the sweep is
/// the last place that can still name it.
public struct ExpiredPendingRow: Sendable, Equatable {
  public let id: UUID
  /// Nil when the row predates take-id persistence or could not be decoded.
  public let takeID: String?

  public init(id: UUID, takeID: String?) {
    self.id = id
    self.takeID = takeID
  }
}
