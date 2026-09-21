import EnviousWisprCore
import Foundation

// MARK: - Learn-from-edits proposal ledger (#996 §4)
//
// One JSON document, `correction-proposals.json`, holding every proposal and
// every rejection tombstone. Every write replaces the WHOLE file through the
// durable pattern `RecoverySpoolStore` established (#2207): private temporary
// file with owner-only permissions, `F_FULLFSYNC` of its bytes, atomic
// replacement, `F_FULLFSYNC` of the containing directory, and only then a
// report of success. The App coordinator owns which transitions are legal;
// this store owns that what it reports as saved is on disk.

/// Why a ledger is not trusted. Each kind is a telemetry token
/// (`learn_ledger_untrusted{kind}`); none carries file contents or exception
/// text.
package enum CorrectionLedgerUntrustedKind: String, Sendable, Equatable, CaseIterable {
  case unreadable, corrupt, unsupportedVersion, unknownStatus
  /// The file re-read fine after a failed write, but the directory sync that
  /// makes it durable still fails; writable trust is withheld until it passes.
  case durabilityUnconfirmed
}

/// What `load()` found. `empty` is ONLY a genuinely absent file (first
/// launch).
///
/// A DAMAGED document (corrupt, unsupported version, unknown status) is
/// `recovered`: the file is MOVED aside as evidence and the store starts
/// trusted and empty, the process `CustomWordsManager` already applies to the
/// words file (founder 2026-09-20, replacing §4's leave-in-place-and-pause:
/// there is no server to restore from, the waiting list is cheap to lose, and
/// the next fix the person makes is offered again). If the move fails the old
/// verdict stands: `untrusted`, evidence copied, original in place.
///
/// A file that cannot be READ (permissions, I/O) is `untrusted` with nothing
/// archived: its content is unknown, so nothing may replace it.
package enum CorrectionLedgerLoadOutcome: Sendable, Equatable {
  case empty
  case trusted(CorrectionProposalLedger)
  case recovered(kind: CorrectionLedgerUntrustedKind, archivedTo: URL)
  case untrusted(kind: CorrectionLedgerUntrustedKind, archivedTo: URL?)
}

package enum CorrectionProposalStoreError: Error, Equatable {
  /// No write is accepted while the last load was untrusted or before any load.
  case ledgerUntrusted
  case notLoaded
  /// A commit or directory sync failed after the file may have been replaced:
  /// memory no longer describes disk. `load()` again to recover.
  case recoveryRequired
  /// The document about to be written violates the ledger's own invariants
  /// (`CorrectionProposalLedger.validationProblems`): a caller defect.
  case invalidLedger([String])
  case unknownProposal(UUID)
  case encodingFailed
  case tempWriteFailed(Int32)
  case commitFailed
  case directorySyncFailed(Int32)
}

/// Durable ledger for learn-from-edits proposals. Not thread-safe by itself:
/// the App coordinator calls it from the main actor only.
package final class CorrectionProposalStore {
  package static let fileName = "correction-proposals.json"
  package static let retentionAfterResolution: TimeInterval = 30 * 24 * 60 * 60

  /// Injection seam for the write stages, so a test can fail each one and
  /// prove the on-disk and in-memory state after it (same shape as
  /// `RecoverySpoolStore.ReadinessRetryFileOps`).
  package struct FileOps: Sendable {
    package var read: @Sendable (URL) throws -> Data
    package var writeTemp: @Sendable (URL, Data) throws -> Void
    package var commit: @Sendable (URL, URL) throws -> Void
    package var syncDirectory: @Sendable (URL) throws -> Void
    package var cleanupTemp: @Sendable (URL) -> Void
    /// The recovery move's two stages (5g review r3): owner-only the damaged
    /// file IN PLACE, then rename it to the archive name. Injected so a test
    /// can fail each and prove neither escape reaches a trusted ledger.
    package var setOwnerOnly: @Sendable (URL) throws -> Void
    package var move: @Sendable (URL, URL) throws -> Void

    package init(
      read: @escaping @Sendable (URL) throws -> Data,
      writeTemp: @escaping @Sendable (URL, Data) throws -> Void,
      commit: @escaping @Sendable (URL, URL) throws -> Void,
      syncDirectory: @escaping @Sendable (URL) throws -> Void,
      cleanupTemp: @escaping @Sendable (URL) -> Void,
      setOwnerOnly: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      },
      move: @escaping @Sendable (URL, URL) throws -> Void = { from, to in
        try FileManager.default.moveItem(at: from, to: to)
      }
    ) {
      self.read = read
      self.writeTemp = writeTemp
      self.commit = commit
      self.syncDirectory = syncDirectory
      self.cleanupTemp = cleanupTemp
      self.setOwnerOnly = setOwnerOnly
      self.move = move
    }

    package static let live = FileOps(
      read: { url in try Data(contentsOf: url) },
      writeTemp: { tmpURL, data in
        let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CorrectionProposalStoreError.tempWriteFailed(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        if fcntl(fd, F_FULLFSYNC) == -1 {
          let code = errno
          try? handle.close()
          throw CorrectionProposalStoreError.tempWriteFailed(code)
        }
        try handle.close()
      },
      commit: { tmpURL, url in
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
          _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
        } else {
          try fm.moveItem(at: tmpURL, to: url)
        }
      },
      syncDirectory: { url in
        do {
          try RecoverySpoolStore.syncDirectory(containing: url)
        } catch let error as RecoverySpoolStoreError {
          if case .readinessRetryMarkerWriteFailed(let code) = error {
            throw CorrectionProposalStoreError.directorySyncFailed(code)
          }
          throw error
        }
      },
      cleanupTemp: { tmpURL in try? FileManager.default.removeItem(at: tmpURL) })
  }

  private enum State: Equatable {
    case notLoaded
    case trusted(CorrectionProposalLedger)
    case untrusted(CorrectionLedgerUntrustedKind)
    /// After a write failed past the point where disk may hold the new
    /// document: every mutation is refused until `load()` re-reads the file
    /// and confirms directory durability.
    case recoveryRequired
  }

  package let fileURL: URL
  private let fileOps: FileOps
  private let now: @Sendable () -> Date
  private var state: State = .notLoaded
  /// The durability obligation left by a write that failed past the temp
  /// stage. Independent of read/decode trust: an unreadable, corrupt or
  /// absent read in between must not clear it. Cleared ONLY by a `load()`
  /// that re-read (or confirmed absence), validated and synced the directory.
  private var recoveryPending = false

  /// Production location: `~/Library/Application Support/EnviousWispr/correction-proposals.json`.
  package convenience init() {
    self.init(
      directory: AppConstants.appSupportURL,
      fileOps: .live,
      now: { Date() })
  }

  /// Tests point the store at a temporary directory and may fail any stage.
  package init(
    directory: URL, fileOps: FileOps = .live, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.fileURL = directory.appendingPathComponent(Self.fileName)
    self.fileOps = fileOps
    self.now = now
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  // MARK: - Load

  /// The current ledger when the last load was trusted, else nil.
  package var ledger: CorrectionProposalLedger? {
    if case .trusted(let l) = state { return l }
    return nil
  }

  package var isTrusted: Bool { ledger != nil }

  /// Reads the file and classifies it (§4, amended 2026-09-20). A damaged
  /// document is MOVED to `correction-proposals.untrusted-<stamp>-<kind>.json`
  /// beside it and the store starts empty and trusted (`recovered`); an
  /// unreadable path, or a damaged document that cannot be moved, is
  /// `untrusted` and the original stays. Every exit of `load()` either
  /// restores trust through `trust(_:)` (which alone clears the recovery
  /// obligation, after the directory sync it requires) or leaves the
  /// obligation as it was.
  package func load() -> CorrectionLedgerLoadOutcome {
    let data: Data
    do {
      data = try fileOps.read(fileURL)
    } catch {
      // Only a CONFIRMED absence is a first launch. A path that cannot be
      // inspected (permissions, I/O) must never read as "nothing to remember".
      if Self.isNoSuchFile(error) {
        return trust(.empty, outcome: .empty)
      }
      return untrusted(.unreadable, evidence: nil)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // Version first, from the raw document, so an unsupported version is
    // named as such rather than reported as a decoding failure of its rows.
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["version"] as? Int
    else {
      return recover(.corrupt, evidence: data)
    }
    guard version == CorrectionProposalLedger.currentVersion else {
      return recover(.unsupportedVersion, evidence: data)
    }
    do {
      let ledger = try decoder.decode(CorrectionProposalLedger.self, from: data)
      guard ledger.validationProblems().isEmpty else {
        return recover(.corrupt, evidence: data)
      }
      return trust(ledger, outcome: .trusted(ledger))
    } catch let error as CorrectionProposalDecodingError {
      // JSONDecoder rethrows a custom error from a nested `init(from:)`
      // unwrapped, so an unknown status arrives here as itself.
      if case .unknownStatus = error { return recover(.unknownStatus, evidence: data) }
      return recover(.corrupt, evidence: data)
    } catch {
      return recover(.corrupt, evidence: data)
    }
  }

  /// Founder 2026-09-20: a damaged document is moved aside and the ledger
  /// starts fresh. The move is a rename, so the evidence is the original
  /// bytes and nothing is copied; a failed move (a name collision, a
  /// read-only directory) falls back to the untrusted verdict, because a
  /// document that cannot be moved must not be silently overwritten either.
  private func recover(_ kind: CorrectionLedgerUntrustedKind, evidence: Data)
    -> CorrectionLedgerLoadOutcome
  {
    let archive = archiveURL(for: kind)
    guard !FileManager.default.fileExists(atPath: archive.path) else {
      return untrusted(kind, evidence: evidence)
    }
    // The archive is evidence about the person's edits: owner-only, like every
    // document this store writes. Made so IN PLACE, before the rename, so a
    // failed chmod leaves the file exactly where and as it was, under the
    // untrusted verdict (review r3: a chmod after the move could fail, and the
    // next load, finding the original gone, would trust an empty ledger while
    // the archive stayed readable to others).
    do {
      try fileOps.setOwnerOnly(fileURL)
      try fileOps.move(fileURL, archive)
    } catch {
      return untrusted(kind, evidence: evidence)
    }
    // A rename is a directory change that is not durable until the directory
    // is synced, so the fresh ledger is trusted through the same gate a
    // recovered write passes (`trust` syncs while `recoveryPending`); a failed
    // sync leaves the store non-writable as `durabilityUnconfirmed`, archive
    // path retained, and the next load tries the sync again.
    recoveryPending = true
    switch trust(.empty, outcome: .recovered(kind: kind, archivedTo: archive)) {
    case .untrusted(let k, _): return .untrusted(kind: k, archivedTo: archive)
    case let outcome: return outcome
    }
  }

  private func archiveURL(for kind: CorrectionLedgerUntrustedKind) -> URL {
    let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(
      of: ":", with: "-")
    return fileURL.deletingLastPathComponent()
      .appendingPathComponent("correction-proposals.untrusted-\(stamp)-\(kind.rawValue).json")
  }

  /// The only way back to a writable ledger. While a recovery is pending the
  /// directory must be synced first, so what actually landed is durable
  /// before it becomes the base for the next replacement; a failing sync
  /// keeps the obligation and refuses trust.
  private func trust(_ ledger: CorrectionProposalLedger, outcome: CorrectionLedgerLoadOutcome) -> CorrectionLedgerLoadOutcome {
    if recoveryPending {
      do {
        try fileOps.syncDirectory(fileURL)
      } catch {
        state = .recoveryRequired
        return .untrusted(kind: .durabilityUnconfirmed, archivedTo: nil)
      }
      recoveryPending = false
    }
    state = .trusted(ledger)
    return outcome
  }

  /// `Data(contentsOf:)` reports a missing file as `CocoaError.fileReadNoSuchFile`
  /// (or POSIX `ENOENT`); anything else is an inability to look, not absence.
  static func isNoSuchFile(_ error: Error) -> Bool {
    if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoSuchFile.rawValue { return true }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
    return false
  }

  private func untrusted(_ kind: CorrectionLedgerUntrustedKind, evidence: Data?)
    -> CorrectionLedgerLoadOutcome
  {
    state = .untrusted(kind)
    var archived: URL? = nil
    if let evidence {
      let url = archiveURL(for: kind)
      if !FileManager.default.fileExists(atPath: url.path),
        FileManager.default.createFile(
          atPath: url.path, contents: evidence, attributes: [.posixPermissions: 0o600])
      {
        archived = url
      }
    }
    return .untrusted(kind: kind, archivedTo: archived)
  }

  // MARK: - Writes (every one replaces the whole document durably)

  /// Inserts or replaces the record with this id. The id and pairKey of an
  /// existing record are immutable: a replacement carrying a different
  /// pairKey for the same id is refused as a caller defect.
  package func upsert(_ proposal: CorrectionProposal) throws {
    var ledger = try trustedLedger()
    if let i = ledger.proposals.firstIndex(where: { $0.id == proposal.id }) {
      guard ledger.proposals[i].pairKey == proposal.pairKey else {
        throw CorrectionProposalStoreError.unknownProposal(proposal.id)
      }
      ledger.proposals[i] = proposal
    } else {
      ledger.proposals.append(proposal)
    }
    try persist(ledger)
  }

  /// Reject: the tombstone and the `rejected` status land in ONE replacement
  /// (§3.1 step 10), so no launch can find one without the other.
  package func reject(id: UUID, at time: Date) throws {
    var ledger = try trustedLedger()
    guard let i = ledger.proposals.firstIndex(where: { $0.id == id }) else {
      throw CorrectionProposalStoreError.unknownProposal(id)
    }
    var p = ledger.proposals[i]
    p.status = .rejected
    p.updatedAt = time
    p.resolvedAt = time
    p.acceptingIntent = nil
    ledger.proposals[i] = p
    if !ledger.isRejected(pairKey: p.pairKey) {
      ledger.rejectedPairs.append(
        CorrectionRejectedPair(pairKey: p.pairKey, rejectedAt: time, language: p.language))
    }
    try persist(ledger)
  }

  /// Drops `accepted`/`rejected` payloads thirty days after `resolvedAt`.
  /// Never touches `pending`/`accepting` records or rejection tombstones.
  /// Returns how many records were removed; a no-op writes nothing.
  @discardableResult
  package func prune(now time: Date) throws -> Int {
    var ledger = try trustedLedger()
    let before = ledger.proposals.count
    ledger.proposals.removeAll { p in
      guard p.status.isTerminal, let resolved = p.resolvedAt else { return false }
      return time.timeIntervalSince(resolved) >= Self.retentionAfterResolution
    }
    let removed = before - ledger.proposals.count
    if removed > 0 { try persist(ledger) }
    return removed
  }

  // MARK: - Mechanics

  private func trustedLedger() throws -> CorrectionProposalLedger {
    if recoveryPending { throw CorrectionProposalStoreError.recoveryRequired }
    switch state {
    case .trusted(let l): return l
    case .untrusted: throw CorrectionProposalStoreError.ledgerUntrusted
    case .notLoaded: throw CorrectionProposalStoreError.notLoaded
    case .recoveryRequired: throw CorrectionProposalStoreError.recoveryRequired
    }
  }

  /// Encode, write to a private temp file, fsync, replace, sync the
  /// directory; memory is updated only after the directory sync returns.
  private func persist(_ ledger: CorrectionProposalLedger) throws {
    let problems = ledger.validationProblems()
    guard problems.isEmpty else { throw CorrectionProposalStoreError.invalidLedger(problems) }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(ledger)
    } catch {
      throw CorrectionProposalStoreError.encodingFailed
    }
    let tmpURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
    do {
      try fileOps.writeTemp(tmpURL, data)
    } catch {
      fileOps.cleanupTemp(tmpURL)
      throw error
    }
    // From here the file MAY already hold the new document: a failure no
    // longer leaves memory describing disk, so the snapshot is invalidated
    // and every mutation is refused until `load()` re-reads and confirms
    // durability (Codex 5a round 1). Never resume from the pre-write copy.
    do {
      try fileOps.commit(tmpURL, fileURL)
    } catch {
      fileOps.cleanupTemp(tmpURL)
      recoveryPending = true
      state = .recoveryRequired
      throw CorrectionProposalStoreError.commitFailed
    }
    // The rename lives in the directory; until it is synced the replacement
    // can vanish on power loss, so success is reported only after this.
    do {
      try fileOps.syncDirectory(fileURL)
    } catch {
      recoveryPending = true
      state = .recoveryRequired
      throw error
    }
    state = .trusted(ledger)
  }
}
