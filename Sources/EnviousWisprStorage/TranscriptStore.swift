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
  ///
  /// - Returns: whether a row was actually promoted. The caller needs this: a
  ///   `Void` return makes "ignored because it expired" indistinguishable from
  ///   "promoted", and a UI that cleared its held marker on the strength of a
  ///   silent no-op would show an expired row as permanent — resurrecting on
  ///   screen exactly the text this method refused to write.
  @discardableResult
  public func promotePending(id: UUID, now: Date = Date()) throws -> Bool {
    let pendingURL = pendingDirectory.appendingPathComponent("\(id.uuidString).json")
    guard
      let transcript = Self.decodeCandidate(
        at: pendingURL, now: now, retention: AppConstants.pendingTranscriptRetention
      ).liveTranscript
    else {
      // Already promoted, never existed, expired, or invalid. All are no-ops
      // for an idempotent operation — but the caller is TOLD, so it can leave
      // its own state alone rather than assuming a promotion happened.
      return false
    }
    try save(transcript.promotedFromPending())
    try? FileManager.default.removeItem(at: pendingURL)
    return true
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
  /// ASYNC and detached, matching `loadPending` directly above.
  ///
  /// This enumerates a directory and decodes one JSON file per pending row. On
  /// a `@MainActor` type that work runs on the main thread unless it is
  /// explicitly moved off, and a caller doing it while opening History puts a
  /// filesystem walk in front of the window appearing.
  @discardableResult
  public func deleteExpiredPending(now: Date = Date()) async throws -> PendingSweepResult {
    // COALESCED, not skipped.
    //
    // `load()` and the expiry pulse can both reach this, and two overlapping
    // walks double-reported an expiry — one row counted twice in the funnel the
    // feature is judged by.
    //
    // Two attempts to elect a single winner at the DELETION both failed, and
    // the measurements are why this coalesces instead. Reporting on "the file
    // is now absent" cannot tell "I removed it" from "the other sweep did":
    // 5 rows produced 6 receipts. Reporting only on `removeItem` success was no
    // better — `FileManager` treats an already-absent file as the goal
    // achieved, so both callers succeed: still 6, a different row each run.
    // Switching to `unlink(2)` made it WORSE (7), and also broke sweeping of a
    // corrupt entry that is a DIRECTORY, which `unlink` cannot remove.
    //
    // A LATECOMER AWAITS THE WINNER AND THEN RUNS ITS OWN PASS.
    //
    // Returning immediately made `await deleteExpiredPending()` a lie: the
    // caller resumed while the sweep was still running, so `load()` could read
    // rows that were about to be deleted.
    //
    // Returning the winner's EMPTINESS was a second, quieter defect. The
    // latecomer carries its own, LATER clock. A row that crosses its deadline
    // while the winner is walking is classified live by that walk, so
    // discarding the latecomer's pass strands the file and its expiry receipt
    // — and `lapsedPendingCount` then reaches zero, stopping the pulse that
    // would have retried. The second pass is duplicate-safe: the winner's
    // deletions are already gone from disk, so it can only pick up rows that
    // lapsed since.
    while let existing = inFlightSweep {
      _ = await existing.value
    }
    let dir = pendingDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else {
      return PendingSweepResult(deletedIDs: [], expired: [])
    }
    let retention = AppConstants.pendingTranscriptRetention
    // The ROOT namespace, so the sweep can tell a genuinely expired row from a
    // shadow left behind by a promotion that already succeeded.
    let root = directory
    #if DEBUG
      let gate = Self.sweepGateForTesting
    #endif
    let walk = Task.detached(priority: .utility) {
      #if DEBUG
        // Held open by a test so the coalescing contract is observable: without
        // it, awaiting both callers cannot distinguish "the latecomer waited"
        // from "the winner finished first anyway".
        await gate?()
      #endif
      return Self.sweepExpired(
        in: dir, permanentDir: root, now: now, retention: retention)
    }
    sweepGeneration &+= 1
    let generation = sweepGeneration
    // The claim is released INSIDE this task, before it completes, so a waiter
    // resuming from `existing.value` can never see a stale one. Releasing it in
    // the caller's `defer` instead leaves a window between the walk finishing
    // and the caller resuming, and in that window the loop above reads a
    // COMPLETED task: awaiting it returns without suspending, so the loop spins
    // on the main actor and never yields to the caller that would clear it.
    let sweep = Task { @MainActor [weak self] in
      let result = await walk.value
      self?.releaseSweep(generation: generation)
      return result
    }
    inFlightSweep = sweep
    return await sweep.value
  }

  /// Releases the in-flight claim only if it is still ours.
  ///
  /// A generation check rather than an identity one, because a sweep cannot
  /// name its own task from inside its own closure. Clearing unconditionally
  /// would un-flag a NEWER sweep and let a third caller start an overlapping
  /// walk — the exact double-reporting this coalescing exists to prevent.
  private func releaseSweep(generation: UInt64) {
    guard sweepGeneration == generation else { return }
    inFlightSweep = nil
  }

  /// The sweep a latecomer coalesces onto.
  private var inFlightSweep: Task<PendingSweepResult, Never>?

  /// Names each claim so `releaseSweep` can tell its own from a successor's.
  private var sweepGeneration: UInt64 = 0

  #if DEBUG
    /// Blocks the detached walk so a test can observe sweep ordering.
    // periphery:ignore - test seam
    nonisolated(unsafe) static var sweepGateForTesting: (@Sendable () async -> Void)?
  #endif

  /// `nonisolated` so the walk genuinely leaves the main actor. A detached task
  /// calling back into an isolated method would hop straight back and block
  /// exactly what it was meant to protect.
  private nonisolated static func sweepExpired(
    in dir: URL, permanentDir: URL, now: Date, retention: TimeInterval
  ) -> PendingSweepResult {
    let fm = FileManager.default
    var reported: [ExpiredPendingRow] = []
    var deleted: Set<UUID> = []
    var unremovable = 0
    // An unreadable directory is reported as an INCOMPLETE walk, never as an
    // empty one. Swallowing it into `[]` produced `unremovable == 0`, which the
    // caller reads as proof the directory is clean — so it would drop the rows
    // that were its only other record and stop retrying, while the files it
    // could not even see remained.
    guard let candidates = pendingCandidates(in: dir, now: now, retention: retention) else {
      return PendingSweepResult(
        deletedIDs: [], expired: [], unremovable: 0, walkComplete: false)
    }
    for candidate in candidates where !candidate.isLive {
      // A SHADOW, not an expiry (cloud review). `promotePending` writes the
      // permanent row first and removes the pending file second, so a crash or a
      // failed removal in between leaves the stamped copy beside its permanent
      // twin. Twenty-four hours later this loop would see a stamped row past its
      // window and emit `escape_recovery.expired` for a dictation the user
      // pressed KEEP on — the text is safe either way, but the kept-versus-
      // expired ratio is the one number this funnel exists to produce, and it
      // would be wrong in the direction that makes the feature look worse.
      //
      // Deleted (it is litter) and NOT reported (nothing expired). Checked by
      // FILE rather than by loading the row: this runs off the main actor, and
      // existence is the whole question.
      if FileManager.default.fileExists(
        atPath: permanentDir.appendingPathComponent(
          candidate.url.lastPathComponent).path)
      {
        try? fm.removeItem(at: candidate.url)
        if fm.fileExists(atPath: candidate.url.path) {
          unremovable += 1
        } else if let id = UUID(
          uuidString: candidate.url.deletingPathExtension().lastPathComponent)
        {
          deleted.insert(id)
        }
        continue
      }
      // `removeItem`, NOT `unlink`. A corrupt entry can be a DIRECTORY named
      // `<uuid>.json` — `decodePending` classifies it `.invalid` and the sweep
      // must clear it or it accumulates forever. `unlink(2)` fails on a
      // directory, so switching to it silently stopped sweeping exactly the
      // case that motivated this branch; a chunk-1 test caught it.
      //
      // Reporting is safe on the existence check because sweeps cannot overlap
      // (see the flag in `deleteExpiredPending`). Without that guarantee this is
      // NOT a winner election: "the file is now absent" cannot distinguish "I
      // removed it" from "the other sweep did", and two sweeps both report.
      try? fm.removeItem(at: candidate.url)
      let id = UUID(uuidString: candidate.url.deletingPathExtension().lastPathComponent)
      // Report only once the file is confirmed gone, so a failed removal is
      // retried on the next sweep instead of re-emitting the same expiry event
      // on every sweep forever.
      //
      // A survivor is announced rather than passed over in silence. The caller
      // cannot see this from its own list — an in-memory row can outlive its
      // file — so silence here is what forced it to guess, and the guess it had
      // to make was "retry while memory still holds the row", which never ends.
      //
      // Counted WITHOUT consulting `id`: a corrupt entry whose name is not a
      // UUID has no identity to report, and keying this on identity stranded
      // exactly those files while reporting that the directory was clean.
      guard !fm.fileExists(atPath: candidate.url.path) else {
        unremovable += 1
        continue
      }
      // EVERY deletion, including the invalid rows that earn no receipt.
      // The caller evicts from memory on this set: reporting only the
      // telemetry-eligible rows left a future-skewed or corrupt row sitting
      // in memory after its file was gone, so the sweep trigger never
      // returned to zero and the directory was re-walked every minute.
      if let id { deleted.insert(id) }
      if let receipt = candidate.expiredReceipt { reported.append(receipt) }
    }
    // #2087, cloud review: an INTERRUPTED WRITE leaves the whole transcript on
    // disk under a name this sweep cannot see. `write` is temp-then-rename into
    // `.<id>.tmp`, and `pendingCandidates` filters `pathExtension == "json"`, so
    // a process killed between fill and rename strands a complete pending
    // transcript that no later sweep ever enumerates. It outlives the 24-hour
    // window indefinitely, which is precisely what the setting's copy and the
    // help centre both say does not happen. 0600 inside a 0700 directory, so it
    // is not exposed — but retained is retained, and the promise is about time.
    //
    // Age-gated by the RETENTION WINDOW rather than swept on sight, because a
    // `.tmp` is also what a healthy write in progress looks like: a live one is
    // seconds old, and nothing legitimate leaves one for a day. Using the same
    // constant as the rows themselves means there is one number to reason about.
    if let strays = try? fm.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
    {
      for stray in strays where stray.pathExtension == "tmp" {
        let modified = (try? stray.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
        // No readable date means no evidence it is stale, so it is left alone:
        // deleting a file that might be a write in flight is the worse error.
        guard let modified, now.timeIntervalSince(modified) >= retention else { continue }
        try? fm.removeItem(at: stray)
        if fm.fileExists(atPath: stray.path) { unremovable += 1 }
      }
    }
    return PendingSweepResult(deletedIDs: deleted, expired: reported, unremovable: unremovable)
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
      guard case .expired(_, let transcript) = self,
        let stamped = transcript.escapeRecoveredAt
      else { return nil }
      return ExpiredPendingRow(
        id: transcript.id, takeID: transcript.escapeRecoveryTakeID, stampedAt: stamped)
    }

    var isLive: Bool { liveTranscript != nil }
  }

  /// `nil` means the directory could NOT be read, which is not the same fact as
  /// "the directory is empty" and must not be flattened into it.
  ///
  /// A caller deciding whether cleanup is finished reads an unreadable directory
  /// as a clean one, stops retrying, and drops the rows that were its only other
  /// record — so the distinction has to survive as far as that decision.
  private nonisolated static func pendingCandidates(
    in directory: URL, now: Date, retention: TimeInterval
  ) -> [PendingCandidate]? {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return nil }
    return
      files
      .filter { $0.pathExtension == "json" }
      .map { decodeCandidate(at: $0, now: now, retention: retention) }
  }

  /// Visibility callers, for whom an unreadable directory and an empty one mean
  /// the same thing: show nothing. Only the sweep needs them distinguished.
  private nonisolated static func decodePending(
    in directory: URL, now: Date, retention: TimeInterval
  ) -> [PendingCandidate] {
    pendingCandidates(in: directory, now: now, retention: retention) ?? []
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

  /// Delete a transcript by ID, from BOTH namespaces (#2087).
  ///
  /// Deleting only the root copy would leave a held Escape Recovery row's file
  /// on disk, and the next launch would load it straight back — a recording the
  /// user explicitly deleted reappearing after a restart, with its countdown
  /// resumed. The id is unique across both namespaces (Keep moves a row from
  /// one to the other under the same id), so removing from each is the whole
  /// operation rather than a choice between them.
  ///
  /// **Not best-effort on the pending side, unlike the expiry sweep.** A swept
  /// row that survives deletion is still invisible, because expiry is decided
  /// at read time. A DELETED row is not: it is unexpired by definition, so a
  /// pending file left behind is loaded again at next launch and the recording
  /// the user deleted comes back with its countdown running. Both removals are
  /// attempted, then both paths are checked, and a file that is still there
  /// throws rather than reporting a delete that did not happen.
  ///
  /// `deleteAll` needs no equivalent — `pending/` is a child of the directory
  /// it removes wholesale.
  public func delete(id: UUID) throws {
    let url = directory.appendingPathComponent("\(id.uuidString).json")
    let pendingURL = pendingDirectory.appendingPathComponent("\(id.uuidString).json")
    // Attempt BOTH before inspecting either, so one failure cannot leave the
    // other copy in place.
    let failures = [url, pendingURL].compactMap { target -> Error? in
      do {
        try FileManager.default.removeItem(at: target)
        return nil
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
        return nil
      } catch {
        return FileManager.default.fileExists(atPath: target.path) ? error : nil
      }
    }
    if let failure = failures.first { throw failure }
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

/// What one sweep did (#2087).
///
/// Four fields because they answer four different questions. `deletedIDs` is
/// every file the sweep removed — expired AND invalid — and is what a caller
/// evicts from memory on. `expired` is only the rows a user genuinely let lapse,
/// and is what telemetry reports: a corrupt file is not a user letting a
/// recovery go, so it is a strict subset.
/// `unremovable` is the third: how many files this sweep decided must go and
/// could not remove. It is DISK truth, and it exists because the caller's only
/// other signal is its own in-memory list, which can outlive the file it
/// describes — so a caller that keeps retrying on memory alone retries forever.
///
/// A COUNT, deliberately not a set of ids. The caller needs to know whether work
/// remains, never which row it belongs to, and an identity-keyed version silently
/// dropped the cases that have no identity: a corrupt `garbage.json` whose name
/// is not a UUID cannot be named, so it reported nothing and was stranded — the
/// exact file the sweep exists to clear. Zero is the honest "this pass finished
/// its work", and is what lets the caller drop stale rows and stop.
/// `walkComplete` is the fourth, and it exists because `unremovable == 0` has
/// TWO causes: the sweep saw everything and cleared it, or the sweep could not
/// read the directory at all. Those are opposite facts and the second one masks
/// work rather than proving there is none. A caller that flattens them evicts
/// its own records and stops retrying precisely when it should not.
public struct PendingSweepResult: Sendable {
  public let deletedIDs: Set<UUID>
  public let expired: [ExpiredPendingRow]
  public let unremovable: Int
  /// False when the directory could not be enumerated. Nothing else about this
  /// result can be trusted as a statement about the directory's contents.
  public let walkComplete: Bool

  public init(
    deletedIDs: Set<UUID>, expired: [ExpiredPendingRow], unremovable: Int = 0,
    walkComplete: Bool = true
  ) {
    self.deletedIDs = deletedIDs
    self.expired = expired
    self.unremovable = unremovable
    self.walkComplete = walkComplete
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
  /// When the offer began (#2087).
  ///
  /// Carried so the expiry event reports the row's REAL age. Deriving it from
  /// the retention constant instead would emit a fixed 24h for every row and
  /// call it a measurement — and it would be wrong exactly when it matters: a
  /// Mac left off for three days sweeps rows that are 72 hours old, and that
  /// gap between deadline and sweep is the thing worth seeing.
  public let stampedAt: Date

  public init(id: UUID, takeID: String?, stampedAt: Date) {
    self.id = id
    self.takeID = takeID
    self.stampedAt = stampedAt
  }
}
