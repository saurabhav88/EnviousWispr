import EnviousWisprCore
import Foundation

/// The dictionary file's one owner (#4086): where `custom-words.json` lives, its
/// on-disk schema, the lock-free read, the locked repair cascade, the single
/// cross-process lock authority, every locked load-transform-save, the pre-import
/// backup and the durable write. Extracted verbatim from `CustomWordsManager`; the
/// manager keeps word policy (built-ins, merge, authoring, import, enrichment, usage)
/// and calls in here for every disk touch.
final class CustomWordsFileStore {
  let fileURL: URL

  init() {
    guard
      let baseURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      // Application Support is always available on macOS, but guard defensively.
      let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(
        "EnviousWispr", isDirectory: true)
      Self.prepareAppSupportDirectory(at: fallback)
      fileURL = fallback.appendingPathComponent("custom-words.json")
      Self.tightenFileIfPresent(at: fileURL)
      return
    }
    let appSupport = baseURL.appendingPathComponent("EnviousWispr", isDirectory: true)
    Self.prepareAppSupportDirectory(at: appSupport)
    fileURL = appSupport.appendingPathComponent("custom-words.json")
    Self.tightenFileIfPresent(at: fileURL)
  }

  /// Test seam (#648): inject an explicit file URL so unit tests can hit a
  /// per-test temp file instead of the production Application Support path.
  /// Production code always uses the zero-arg `init()`. Bible §9.3 disk
  /// round-trip coverage was missing from Phase 3b; this seam closes it.
  // periphery:ignore - test seam
  init(fileURL: URL) {
    self.fileURL = fileURL
    let directory = fileURL.deletingLastPathComponent()
    Self.prepareAppSupportDirectory(at: directory)
    Self.tightenFileIfPresent(at: fileURL)
  }

  /// Create the EnviousWispr Application Support directory at 0700 and drop a
  /// `.metadata_never_index` Spotlight marker. Re-enforced on every init in
  /// case a backup restore or user action loosened permissions. Soft-fails on
  /// any filesystem operation. (V3 audit #561 / #562.)
  private static func prepareAppSupportDirectory(at url: URL) {
    DurableJSONFile.prepareDirectory(at: url)
  }

  /// Force `custom-words.json` to 0600 if it already exists. Migrates installs
  /// that pre-date this hardening.
  private static func tightenFileIfPresent(at url: URL) {
    DurableJSONFile.tightenFileIfPresent(at: url)
  }

  // MARK: - Schema

  /// Versioned wrapper for the custom words file.
  struct CustomWordsFile: Codable, Sendable {
    var version: Int = 1
    var builtinsVersion: Int = 1
    var deletedBuiltinIds: [String] = []
    var words: [CustomWord] = []
    /// Durable bulk-import-enrichment total (#1701 Chunk 2) — the progress
    /// card's denominator. `nil` = no run in progress. A missing key on a
    /// pre-#1701 file decodes as `nil` automatically: this is a stored
    /// `Optional` property with no explicit `CodingKeys` on this type, so
    /// synthesized `Decodable` already treats an absent key as `nil`, exactly
    /// the correct legacy behavior (no run can possibly be "in progress" in a
    /// library persisted before this feature existed).
    var pendingEnrichmentBatchTotal: Int?
  }

  /// `loadFileWhileLocked()`'s result (#1646) — distinguishes the three
  /// conditions the old `CustomWordsFile?` collapsed into one `nil`, so
  /// callers can fail closed instead of treating every failure as "the
  /// library is empty".
  private enum CustomWordsLoadResult {
    case missing  // path does not exist — legitimate first-run state
    case loaded(CustomWordsFile)  // decoded (current or migrated legacy format)
    case unreadable(underlying: Error)  // exists, but the I/O read itself failed
    case corrupted  // exists, readable, undecodable — archived aside
  }

  /// `load()`'s lock-free classification (#1690) — distinguishes only
  /// "definitely fine as-is" from "hand this to the locked repair cascade".
  /// It never makes the finer legacy-vs-corrupted distinction itself; that
  /// stays the real cascade's job, decided fresh under the lock.
  private enum ReadOnlyLoadResult {
    case missing
    case loaded(CustomWordsFile)  // decodes as current format — no write ever needed
    case unreadable(underlying: Error)  // I/O read itself failed — no write ever needed
    case needsRepair  // readable bytes exist but aren't current-format
  }

  /// Why the most recent `load()` returned nil; nil after a successful load
  /// or a legitimate first run (#1646). The coordinator reads this once at
  /// launch to show an honest banner instead of a silent empty list.
  private(set) var lastLoadFailure: CustomWordsInitialLoadFailure?

  /// Test seam: fires once, immediately after `loadFileReadOnly()` confirms
  /// the canonical file exists but before it attempts to read it — lets a
  /// test deterministically simulate a sibling process's file vanishing in
  /// that exact window (#1690 cloud review), which no other seam in this
  /// file can reach since this fast path is deliberately lock-free.
  /// Production never sets this.
  var afterFileExistsCheckForTesting: (() -> Void)?

  /// Classifies the current on-disk state without ever creating/opening the
  /// lock file, migrating, saving, quarantining, moving, or otherwise
  /// mutating disk (#1690). Missing, current-format, and unreadable are the
  /// fast path `load()` returns from immediately, with no lock involved at
  /// all. `.needsRepair` is the rare signal that legacy migration or
  /// corruption quarantine may be needed — decided for real only under the
  /// lock, by `loadFileWhileLocked()`'s existing cascade, never duplicated
  /// here.
  private func loadFileReadOnly() -> ReadOnlyLoadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
    afterFileExistsCheckForTesting?()
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      // The file existed a moment ago but reading it just failed. If it has
      // now vanished entirely, a sibling process's quarantine (or some other
      // deletion) raced this read; that ambiguity must be resolved under the
      // lock like any other needs-repair case, never silently reported as a
      // stable first-run state that could mask a corruption signal a moment
      // later (#1690 cloud review).
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return .needsRepair
      }
      return .unreadable(underlying: error)
    }
    if let file = try? JSONDecoder().decode(CustomWordsFile.self, from: data) {
      return .loaded(file)
    }
    return .needsRepair
  }

  /// Shared resolution behind `load()` and `loadSnapshot()` (#1701 Chunk 2) —
  /// one cascade, so the two callers can never disagree about what "the
  /// current file" is. Sets `lastLoadFailure` exactly as the pre-#1701
  /// `load()` body did; returns nil on the same unrecoverable conditions.
  func resolveCurrentFile() -> CustomWordsFile? {
    switch loadFileReadOnly() {
    case .missing:
      lastLoadFailure = nil
      return CustomWordsFile()
    case .loaded(let file):
      lastLoadFailure = nil
      return file
    case .unreadable:
      lastLoadFailure = .unreadable
      return nil
    case .needsRepair:
      // Rare path: migration or quarantine. `loadFileWhileLocked()` requires
      // an already-held companion lock, acquired here BLOCKING — the
      // deliberate exception to every other caller's non-blocking policy
      // (#1690). Once the lock is acquired, the existing cascade re-reads
      // the current truth in one shot and returns exactly the right one of
      // its four outcomes, matching pre-#1690 single-process behavior
      // exactly, now guaranteed to only ever run while the lock is held.
      // There is no cross-call retry state to track.
      do {
        let result = try withExclusiveFileLock(blocking: true) { loadFileWhileLocked() }
        switch result {
        case .missing:
          // This same call already observed readable, non-current-format
          // bytes moments ago (that is why we are in the `.needsRepair` branch
          // at all). The app never deletes the canonical file except during
          // quarantine, so a fresh `.missing` result here, under the lock,
          // means a sibling process completed quarantine while we waited —
          // never a clean first run.
          lastLoadFailure = .corrupted
          return nil
        case .loaded(let file):
          lastLoadFailure = nil
          return file
        case .unreadable:
          lastLoadFailure = .unreadable
          return nil
        case .corrupted:
          lastLoadFailure = .corrupted
          return nil
        }
      } catch {
        // Only a genuine lock-file-open or flock-syscall failure reaches
        // here — blocking acquisition never fails with "busy," it only ever
        // waits. Reuses the existing `.unreadable` contract on purpose: the
        // coordinator already treats it as "leave the current list
        // untouched, return false" / "fall back to an empty list," exactly
        // what this rare failure needs.
        lastLoadFailure = .unreadable
        return nil
      }
    }
  }

  /// The strict read every explicit mutation uses (#1646), now exclusively
  /// through `performLockedTransaction` (#1690). `.missing` is a legitimate
  /// first run (fresh empty file); an unreadable or corrupted existing file
  /// throws so the mutation writes nothing and the caller's in-memory list
  /// stays untouched. Lock-free internally — the caller MUST already hold
  /// the companion-file lock before calling this.
  private func loadFileForMutationWhileLocked() throws -> CustomWordsFile {
    switch loadFileWhileLocked() {
    case .missing:
      return CustomWordsFile()
    case .loaded(let file):
      return file
    case .unreadable:
      throw CustomWordsPersistenceError.unreadableExistingFile
    case .corrupted:
      throw CustomWordsPersistenceError.corruptedExistingFile
    }
  }

  // MARK: - Cross-Process Locking (#1690)

  /// Test seam: the `flock` acquisition syscall, injectable so a test can
  /// force a non-contention failure (e.g. `errno = EIO`) without needing a
  /// real second process. Production code always uses the real syscall.
  var lockSyscall: (Int32, Int32) -> Int32 = { flock($0, $1) }

  /// The single cross-process lock authority for every disk mutation. Opens
  /// a stable companion file next to `fileURL` and takes `flock` on it,
  /// never on `fileURL` itself.
  ///
  /// Non-blocking by default so explicit mutations fail closed rather than
  /// freezing this `@MainActor` class. Blocking acquisition is reserved for
  /// the approved repair-aware load path.
  private func withExclusiveFileLock<T>(
    blocking: Bool = false, _ body: () throws -> T
  ) throws -> T {
    // The companion-file `flock` mechanism moved to `DurableJSONFile.withExclusiveLock` when
    // #628 gave a second user-owned store the same need. Still exactly ONE declaration here,
    // and this function keeps what is genuinely this type's: the mapping onto
    // `CustomWordsPersistenceError`, which callers throughout this file catch by case.
    do {
      return try DurableJSONFile.withExclusiveLock(
        on: fileURL, blocking: blocking, lockSyscall: lockSyscall, body)
    } catch DurableJSONFile.LockFailure.busy {
      throw CustomWordsPersistenceError.libraryBusy
    } catch DurableJSONFile.LockFailure.unavailable {
      throw CustomWordsPersistenceError.coordinationUnavailable
    }
  }

  /// Wraps an explicit mutation's load-transform-save in one non-blocking
  /// lock hold. `transform` returns whether the result actually needs a
  /// disk write, so a transform that made no change (e.g. an all-skip
  /// batch or import) can correctly skip the write, matching pre-lock
  /// behavior. Every one of the six ordinary CRUD mutations, the automatic
  /// usage flush, and the import commit route through this (#1690).
  func performLockedTransaction<T>(
    _ transform: (inout CustomWordsFile) throws -> (value: T, shouldSave: Bool)
  ) throws -> T {
    try withExclusiveFileLock {
      var file = try loadFileForMutationWhileLocked()
      let outcome = try transform(&file)
      if outcome.shouldSave {
        try saveFileWhileLocked(file)
      }
      return outcome.value
    }
  }

  /// Timestamped copy of the current file before a changing commit. Purely a
  /// convenience recovery path — failures are logged, never fatal. No retention
  /// policy in v1; an accumulating set of backups is an accepted, named scope cut.
  ///
  /// Never overwrites an existing backup. Two commits inside the same second
  /// would otherwise collide on the filename, and destroying the earlier
  /// pre-import state is the one thing this recovery path must not do.
  func writePreImportBackup() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let directory = fileURL.deletingLastPathComponent()
    var backupURL = directory.appendingPathComponent("custom-words.backup-\(stamp).json")
    var suffix = 2
    while fm.fileExists(atPath: backupURL.path), suffix < 1000 {
      backupURL = directory.appendingPathComponent(
        "custom-words.backup-\(stamp)-\(suffix).json")
      suffix += 1
    }
    do {
      try fm.copyItem(at: fileURL, to: backupURL)
    } catch {
      Task {
        await AppLogger.shared.log(
          "CustomWordsManager: pre-import backup failed: \(error.localizedDescription)",
          level: .info, category: "CustomWords"
        )
      }
    }
  }

  // MARK: - Private File I/O

  /// Single read path — normalizes legacy formats to CustomWordsFile. The
  /// result distinguishes missing / loaded / unreadable / corrupted (#1646)
  /// so callers can fail closed instead of treating every failure as
  /// "empty". Lock-free internally and must never call
  /// `withExclusiveFileLock` itself — every caller MUST already hold the
  /// companion-file lock before calling this (#1690): `load()`'s rare
  /// repair path (acquired blocking) and `loadFileForMutationWhileLocked()`
  /// (reached only through the non-blocking `performLockedTransaction`).
  private func loadFileWhileLocked() -> CustomWordsLoadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to read custom words file — failing closed to prevent data loss",
          level: .info, category: "CustomWords"
        )
      }
      return .unreadable(underlying: error)
    }

    // Try new versioned wrapper first
    if let file = try? JSONDecoder().decode(CustomWordsFile.self, from: data) {
      return .loaded(file)
    }

    // Migrate from old [CustomWord] array format
    if let oldWords = try? JSONDecoder().decode([CustomWord].self, from: data) {
      let file = CustomWordsFile(words: oldWords)
      try? saveFileWhileLocked(file)
      Task {
        await AppLogger.shared.log(
          "Migrated \(oldWords.count) custom words from [CustomWord] to versioned format",
          level: .info, category: "CustomWords"
        )
      }
      return .loaded(file)
    }

    // Migrate from old [String] array format
    if let oldStrings = try? JSONDecoder().decode([String].self, from: data) {
      let migrated =
        oldStrings
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { CustomWord(canonical: $0) }
      let file = CustomWordsFile(words: migrated)
      try? saveFileWhileLocked(file)
      Task {
        await AppLogger.shared.log(
          "Migrated \(oldStrings.count) custom words from [String] to versioned format",
          level: .info, category: "CustomWords"
        )
      }
      return .loaded(file)
    }

    // Corrupted — archive to a unique sidecar so the next read starts fresh.
    // `.corrupted` is reported only when the archive actually succeeded; a
    // failed archive leaves the original bytes in place, so the caller keeps
    // failing closed (`.unreadable`) instead of being promised a self-heal
    // that can't happen. Unique name: a second, later corruption event must
    // not collide with an earlier sidecar (#1646).
    let backup = fileURL.deletingLastPathComponent()
      .appendingPathComponent("custom-words.json.corrupted-\(UUID().uuidString)")
    do {
      try FileManager.default.moveItem(at: fileURL, to: backup)
    } catch {
      Task {
        await AppLogger.shared.log(
          "Custom words file corrupted and archive failed — failing closed",
          level: .info, category: "CustomWords"
        )
      }
      return .unreadable(underlying: error)
    }
    Task {
      await AppLogger.shared.log(
        "Custom words file corrupted, backed up to \(backup.lastPathComponent)",
        level: .info, category: "CustomWords"
      )
    }
    return .corrupted
  }

  /// Persist the custom-words file at 0600.
  ///
  /// Writes to a temp file at 0600 first via `Foundation.open(... 0o600)`
  /// then renames into place. Mirrors `KeychainManager.store` to avoid the
  /// brief world-readable window that `Data.write(.atomic)` + post-write
  /// chmod creates. (V3 audit #561.)
  ///
  /// The guard set here is `CustomWordsExportWriter`'s, ported whole rather
  /// than piecemeal (#1690). That writer had already paid for each one; this
  /// one kept an older shape on the belief — written into that file's own
  /// header — that "the live custom-words.json has exactly one writer, so a
  /// fixed .tmp sibling is safe there." Two instances of the app break that,
  /// and the cost is the user's entire vocabulary:
  ///
  ///  - **Unique temp name**, not a fixed `.custom-words.json.tmp`. With a
  ///    shared name plus `O_TRUNC`, a second writer wipes the first's partial
  ///    bytes and whichever publish lands last wins. That is not a torn file;
  ///    it is one instance's library silently replacing another's, which is
  ///    exactly what the artifact quarantined on 2026-07-19 looked like —
  ///    valid JSON containing one word that did not belong there.
  ///  - **`O_EXCL`**, so a colliding temp fails loudly instead of truncating
  ///    somebody else's write in progress.
  ///  - **One `rename(2)`** instead of `fileExists` then
  ///    `replaceItemAt`/`moveItem`. That branch was check-then-act, and
  ///    `replaceItemAt` also preserves the DESTINATION's metadata, so a live
  ///    file that had become 0644 would stay world-readable through every
  ///    subsequent save. `rename` is atomic, refuses a directory by the kernel
  ///    (EISDIR), and keeps the temp file's own 0600.
  ///
  /// Lock-free internally and must never acquire the lock itself (#1690) —
  /// every caller MUST already hold the companion-file lock: the non-blocking
  /// `performLockedTransaction` and the two legacy migrations inside
  /// `loadFileWhileLocked()` (reached only while a caller of THAT holds the
  /// lock).
  private func saveFileWhileLocked(_ file: CustomWordsFile) throws {
    // The write sequence — unique temp, 0600, F_FULLFSYNC, atomic rename, best-effort
    // directory sync — moved to `DurableJSONFile` when #628 added a second user-owned store.
    // Same primitive, same order, same reasoning; it lives in one place so the next fix lands
    // once. `DurableJSONFile`'s header carries the reasoning that used to sit here.
    try DurableJSONFile.write(file, to: fileURL, tempPrefix: ".custom-words.json")
  }
}
