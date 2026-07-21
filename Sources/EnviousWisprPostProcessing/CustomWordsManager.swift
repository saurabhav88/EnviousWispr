import EnviousWisprCore
import Foundation

/// A built-in default word shipped with the app. Identified by a stable string ID
/// for tombstone tracking across app updates.
public struct BuiltinWord: Sendable {
  public let id: String
  public let word: CustomWord

  /// Stamps `source: .builtin` centrally (#1680), so a built-in cannot ship
  /// untagged no matter how its `CustomWord` was written. Export filters on
  /// `source == .user`; an untagged built-in would silently export as if the
  /// user had authored it. Tagging at the one construction point makes the
  /// correct thing automatic rather than a rule every future entry must
  /// remember — the tag is not spelled at any call site, so it cannot be
  /// forgotten at one.
  ///
  /// Runtime-only: `source` is excluded from `CustomWord.CodingKeys`, and
  /// decode always yields `.user`. Nothing on disk changes.
  public init(id: String, word: CustomWord) {
    self.id = id
    self.word = CustomWord(
      id: word.id,
      canonical: word.canonical,
      aliases: word.aliases,
      category: word.category,
      priority: word.priority,
      forceReplace: word.forceReplace,
      caseSensitive: word.caseSensitive,
      source: .builtin,
      frequencyUsed: word.frequencyUsed,
      lastUsed: word.lastUsed,
      minSimilarityOverride: word.minSimilarityOverride
    )
  }
}

/// Thrown by the CRUD mutation methods when an EXISTING custom-words file
/// cannot be read (#1646). Failing closed here is what prevents a mutation
/// from silently substituting an empty library and writing it over the
/// user's real one.
package enum CustomWordsPersistenceError: LocalizedError, Sendable, Equatable {
  case unreadableExistingFile
  case corruptedExistingFile
  case unusableValue

  package var errorDescription: String? {
    switch self {
    case .unreadableExistingFile:
      return "Your saved words could not be read. Nothing was changed. Try again."
    case .corruptedExistingFile:
      return
        "Your saved words file was damaged and moved aside for recovery. No edit or import was applied."
    case .unusableValue:
      return
        "That word or spelling can't be saved. It may be too long, or contain characters that aren't part of a word."
    }
  }
}

/// Why the launch-time `load()` came back nil (#1646), exposed so the
/// coordinator can show an honest banner instead of a silent empty list.
/// `.unreadable` means the file is intact but temporarily unreadable;
/// `.corrupted` means it was undecodable and archived aside for recovery.
package enum CustomWordsInitialLoadFailure: Sendable, Equatable {
  case unreadable
  case corrupted
}

/// Persists custom words to disk with a two-tier architecture:
/// - **Built-in defaults**: hardcoded in the app, updatable via app updates
/// - **User words**: persisted to `custom-words.json`
///
/// Runtime merge produces the effective word list. User deletions of built-ins
/// are tracked as tombstones so they don't resurface after updates.
@MainActor
public final class CustomWordsManager {
  private let fileURL: URL

  /// Where the live word list is kept.
  ///
  /// Exposed so the export path can refuse to write ONTO it (#1686). Choosing
  /// it as an export destination would atomically replace the app's own
  /// storage with the transfer-document schema; the next load would find a
  /// file it cannot parse, archive it as corrupt, and the user would have
  /// destroyed their dictionary by exporting it.
  /// `nonisolated`: this is a path computation with no state, and the export
  /// writer runs off the main actor.
  nonisolated package static var liveFileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("EnviousWispr", isDirectory: true)
      .appendingPathComponent("custom-words.json")
  }

  /// This instance's file, so a test-injected manager can be guarded too.
  package var storageURL: URL { fileURL }

  public init() {
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
  package init(fileURL: URL) {
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
    let fm = FileManager.default
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    try? fm.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
    let marker = url.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      fm.createFile(atPath: marker.path, contents: Data(), attributes: nil)
    }
  }

  /// Force `custom-words.json` to 0600 if it already exists. Migrates installs
  /// that pre-date this hardening.
  private static func tightenFileIfPresent(at url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // MARK: - Built-in Defaults

  public static let builtinDefaults: [BuiltinWord] = [
    BuiltinWord(
      id: "enviouswispr",
      word: CustomWord(
        canonical: "EnviousWispr",
        aliases: ["envious whisper", "envious wisper", "envious whispr"],
        category: .brand
      )),
    BuiltinWord(
      id: "enviouslabs",
      word: CustomWord(
        canonical: "Envious Labs",
        aliases: ["envious laps"],
        category: .brand
      )),
    BuiltinWord(
      id: "macos",
      word: CustomWord(
        canonical: "macOS",
        aliases: ["mac OS", "Mack OS"],
        category: .brand
      )),
    BuiltinWord(
      id: "ios",
      word: CustomWord(
        canonical: "iOS",
        aliases: ["I OS", "eye OS"],
        category: .brand
      )),
    BuiltinWord(
      id: "github",
      word: CustomWord(
        canonical: "GitHub",
        aliases: ["git hub", "get hub"],
        category: .brand
      )),
    BuiltinWord(
      id: "chatgpt",
      word: CustomWord(
        canonical: "ChatGPT",
        aliases: ["chat GPT", "chat G P T"],
        category: .brand
      )),
    BuiltinWord(
      id: "openai",
      word: CustomWord(
        canonical: "OpenAI",
        aliases: ["open AI", "open A I"],
        category: .brand
      )),
    BuiltinWord(
      id: "claude",
      word: CustomWord(
        canonical: "Claude",
        aliases: ["clod", "clawed"],
        category: .brand
      )),
    BuiltinWord(
      id: "api",
      word: CustomWord(
        canonical: "API",
        aliases: ["A P I"],
        category: .acronym
      )),
    BuiltinWord(
      id: "cli",
      word: CustomWord(
        canonical: "CLI",
        aliases: ["C L I"],
        category: .acronym
      )),
    BuiltinWord(
      id: "vscode",
      word: CustomWord(
        canonical: "VS Code",
        aliases: ["vs code", "vscode", "V S code"],
        category: .brand
      )),
  ]

  // MARK: - Schema

  /// Versioned wrapper for the custom words file.
  private struct CustomWordsFile: Codable, Sendable {
    var version: Int = 1
    var builtinsVersion: Int = 1
    var deletedBuiltinIds: [String] = []
    var words: [CustomWord] = []
  }

  /// `loadFile()`'s result (#1646) — distinguishes the three conditions the
  /// old `CustomWordsFile?` collapsed into one `nil`, so callers can fail
  /// closed instead of treating every failure as "the library is empty".
  private enum CustomWordsLoadResult {
    case missing  // path does not exist — legitimate first-run state
    case loaded(CustomWordsFile)  // decoded (current or migrated legacy format)
    case unreadable(underlying: Error)  // exists, but the I/O read itself failed
    case corrupted  // exists, readable, undecodable — archived aside
  }

  // MARK: - Public API

  /// Why the most recent `load()` returned nil; nil after a successful load
  /// or a legitimate first run (#1646). The coordinator reads this once at
  /// launch to show an honest banner instead of a silent empty list.
  package private(set) var lastLoadFailure: CustomWordsInitialLoadFailure?

  /// Load the effective word list: built-in defaults (minus tombstones) + user words.
  /// Returns nil only on unrecoverable I/O failure or a corrupted (archived)
  /// file — `lastLoadFailure` says which (#1646).
  public func load() -> [CustomWord]? {
    switch loadFile() {
    case .missing:
      lastLoadFailure = nil
      return mergedWords(file: CustomWordsFile())
    case .loaded(let file):
      lastLoadFailure = nil
      return mergedWords(file: file)
    case .unreadable:
      lastLoadFailure = .unreadable
      return nil
    case .corrupted:
      lastLoadFailure = .corrupted
      return nil
    }
  }

  /// The strict read every explicit CRUD mutation uses (#1646). `.missing` is
  /// a legitimate first run (fresh empty file); an unreadable or corrupted
  /// existing file throws so the mutation writes nothing and the caller's
  /// in-memory list stays untouched.
  private func loadFileForMutation() throws -> CustomWordsFile {
    switch loadFile() {
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

  /// Phase 3b (#631): debounced writer that bumps `frequencyUsed` and
  /// `lastUsed` on each source `CustomWord`. Bible §9.3.
  ///
  /// Debounce policy:
  /// - Aggregate increments in `pendingIncrements` (per UUID).
  /// - Flush sync when total pending count >= 50.
  /// - Otherwise schedule a 30s timer flush (cancel + reschedule on each call).
  /// - On flush: load file → bump frequencyUsed and set lastUsed for each
  ///   pending UUID found in `file.words` → save → clear pending.
  ///
  /// IDs not found in `file.words` (rare: file edited concurrently, built-in
  /// term not yet in file) are skipped silently. Errors during save are
  /// logged + the pending state is cleared (best-effort writer; the next
  /// correction will start a fresh accumulator).
  public func recordReplacements(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    let now = Date()
    for id in ids {
      var entry = pendingIncrements[id] ?? PendingIncrement(count: 0, lastTimestamp: now)
      entry.count += 1
      entry.lastTimestamp = now
      pendingIncrements[id] = entry
    }
    let totalPending = pendingIncrements.values.reduce(0) { $0 + $1.count }
    if totalPending >= Self.flushCountThreshold {
      flushPendingIncrements()
    } else {
      schedulePendingFlush()
    }
  }

  /// Phase 3b (#631): test seam — synchronously flush any pending increments.
  /// Production code never calls this; tests use it to validate the writer
  /// without waiting for the 30s debounce timer.
  // periphery:ignore - test seam
  package func flushPendingIncrementsForTesting() {
    flushPendingIncrements()
  }

  private struct PendingIncrement {
    var count: Int
    var lastTimestamp: Date
  }

  private static let flushCountThreshold = 50
  private static let flushDebounceSeconds: Double = 30

  private var pendingIncrements: [UUID: PendingIncrement] = [:]
  private var pendingFlushTask: Task<Void, Never>?

  private func schedulePendingFlush() {
    pendingFlushTask?.cancel()
    pendingFlushTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.flushDebounceSeconds))
      guard !Task.isCancelled, let self else { return }
      self.flushPendingIncrements()
    }
  }

  private func flushPendingIncrements() {
    pendingFlushTask?.cancel()
    pendingFlushTask = nil
    let snapshot = pendingIncrements
    pendingIncrements.removeAll()
    guard !snapshot.isEmpty else { return }

    var file: CustomWordsFile
    switch loadFile() {
    case .missing:
      file = CustomWordsFile()
    case .loaded(let loaded):
      file = loaded
    case .unreadable, .corrupted:
      // Best-effort writer (#1646): requeue instead of dropping so the
      // increments survive to the next flush attempt — and reschedule the
      // debounce timer, since this method already cancelled it on entry;
      // without that, a quiet session would strand the requeued increments
      // in memory until app exit (cloud review, PR #1647).
      for (id, increment) in snapshot {
        var entry =
          pendingIncrements[id]
          ?? PendingIncrement(count: 0, lastTimestamp: increment.lastTimestamp)
        entry.count += increment.count
        entry.lastTimestamp = max(entry.lastTimestamp, increment.lastTimestamp)
        pendingIncrements[id] = entry
      }
      schedulePendingFlush()
      Task {
        await AppLogger.shared.log(
          "CustomWordsManager: flush skipped — words file unreadable; increments requeued",
          level: .info, category: "CustomWords"
        )
      }
      return
    }
    var changed = false
    for (id, increment) in snapshot {
      guard let idx = file.words.firstIndex(where: { $0.id == id }) else { continue }
      file.words[idx].frequencyUsed += increment.count
      file.words[idx].lastUsed = increment.lastTimestamp
      changed = true
    }
    guard changed else { return }
    do {
      try saveFile(file)
    } catch {
      Task {
        await AppLogger.shared.log(
          "CustomWordsManager: recordReplacements flush failed: \(error.localizedDescription)",
          level: .info, category: "CustomWords"
        )
      }
    }
  }

  public func add(canonical: String, to words: inout [CustomWord]) throws {
    try add(word: CustomWord(canonical: canonical), to: &words)
  }

  public func add(word: CustomWord, to words: inout [CustomWord]) throws {
    let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // The same rule importing enforces, applied where words are AUTHORED, so
    // the library can never hold what export refuses (cloud review, #1683).
    //
    // THROWS rather than returning, unlike the batch doors below. A user typed
    // this one value and is watching for the result: a silent return dismisses
    // the sheet on a nil error, so the app reports a save it did not make. The
    // batch doors keep skipping because per-item skip IS their contract.
    guard Self.isStorable(trimmed) else { throw CustomWordsPersistenceError.unusableValue }
    guard Self.everyAliasIsStorable(word.aliases) else {
      throw CustomWordsPersistenceError.unusableValue
    }
    guard
      !words.contains(where: {
        $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
      })
    else { return }

    var file = try loadFileForMutation()

    // If this matches a deleted built-in, restore it instead of adding a user word
    if let builtin = Self.builtinDefaults.first(where: {
      $0.word.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
    }) {
      file.deletedBuiltinIds.removeAll { $0 == builtin.id }
      try saveFile(file)
      words = mergedWords(file: file)
      return
    }

    var sanitized = word
    sanitized.canonical = trimmed
    sanitized.aliases = Self.sanitizeAliases(sanitized.aliases)
    file.words.append(sanitized)
    try saveFile(file)
    words = mergedWords(file: file)
  }

  /// Bulk-insert custom words with a single file read + write. Mirrors
  /// `add(word:to:)` per word — canonical trim, reject-empty, case-insensitive
  /// de-dupe (against existing terms AND earlier entries in this same batch),
  /// alias sanitize, and the tombstoned-built-in restore branch — but collapses
  /// the O(n) per-word `loadFile`/`saveFile` into one of each so a large import
  /// (thousands of names) never rewrites the file per word.
  ///
  /// Returns the UUIDs of the user words this call actually appended, in input
  /// order. De-duplicated inputs and tombstoned-built-in restores are NOT in the
  /// returned set: the caller (contacts import) treats the result as the
  /// import's owned set for bulk-removal, and a restored built-in is not
  /// import-owned.
  public func addBatch(_ incoming: [CustomWord], to words: inout [CustomWord]) throws
    -> [UUID]
  {
    var file = try loadFileForMutation()
    // Seed dedupe from BOTH the in-memory merged list and the on-disk file so a
    // stale `words` snapshot can't produce a duplicate at batch scale.
    var seen = Set(words.map { $0.canonical.lowercased() })
    seen.formUnion(file.words.map { $0.canonical.lowercased() })
    var createdIDs: [UUID] = []

    for word in incoming {
      let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isStorable(trimmed) else { continue }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { continue }

      // Tombstoned-built-in restore (mirrors the built-in branch of add(word:)).
      // A LIVE built-in is already in `seen` (it is in merged `words`), so a
      // built-in match here means it was tombstoned: un-delete it instead of
      // adding a duplicate user word. Restored built-ins are not in createdIDs.
      if let builtin = Self.builtinDefaults.first(where: {
        $0.word.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
      }) {
        file.deletedBuiltinIds.removeAll { $0 == builtin.id }
        seen.insert(key)
        continue
      }

      var sanitized = word
      sanitized.canonical = trimmed
      sanitized.aliases = Self.sanitizeAliases(sanitized.aliases)
      file.words.append(sanitized)
      createdIDs.append(sanitized.id)
      seen.insert(key)
    }

    try saveFile(file)
    words = mergedWords(file: file)
    return createdIDs
  }

  public func remove(id: UUID, from words: inout [CustomWord]) throws {
    let word = words.first { $0.id == id }
    var file = try loadFileForMutation()

    // If this matches a built-in, tombstone it
    if let word = word,
      let builtin = Self.builtinDefaults.first(where: {
        $0.word.canonical.lowercased() == word.canonical.lowercased()
      })
    {
      if !file.deletedBuiltinIds.contains(builtin.id) {
        file.deletedBuiltinIds.append(builtin.id)
      }
    }

    file.words.removeAll { $0.id == id }
    try saveFile(file)
    words = mergedWords(file: file)
  }

  /// Bulk-remove by ID with a single file read + write. Mirrors `remove(id:)`
  /// per ID — including tombstoning a built-in whose canonical matches a removed
  /// word — but collapses to one `loadFile`/`saveFile`. IDs not present are
  /// skipped. Used by the contacts-import bulk-remove pill (#636) to avoid an
  /// O(n) per-word rewrite when clearing a large import.
  public func removeBatch(ids: [UUID], from words: inout [CustomWord]) throws {
    guard !ids.isEmpty else { return }
    let idSet = Set(ids)
    var file = try loadFileForMutation()

    // Tombstone any built-ins whose canonical matches a removed word (mirror
    // remove(id:)). Import-created words are user words, so this is normally
    // inert for the import path, but keeps batch semantics identical to single.
    for id in ids {
      guard let word = words.first(where: { $0.id == id }) else { continue }
      if let builtin = Self.builtinDefaults.first(where: {
        $0.word.canonical.lowercased() == word.canonical.lowercased()
      }), !file.deletedBuiltinIds.contains(builtin.id) {
        file.deletedBuiltinIds.append(builtin.id)
      }
    }

    file.words.removeAll { idSet.contains($0.id) }
    try saveFile(file)
    words = mergedWords(file: file)
  }

  // MARK: - Import commit (#1665, epic #1619 PR-F2b)

  /// Apply a reviewed import — additions AND replacements — in ONE atomic
  /// write, or write nothing at all. Built on PR-P0's strict loader: an
  /// existing-but-unreadable file fails closed, touching neither disk nor the
  /// caller's list.
  ///
  /// Every key comparison here is a PERSISTENCE question, so it uses
  /// `importPersistenceKey` (this type's own `trimmed.lowercased()` dedup
  /// rule), never the compare engine's stronger matching key (PR-F2a).
  package func commitImport(
    _ plan: CustomWordsImportCommitPlan, to words: inout [CustomWord]
  ) throws -> CustomWordsImportCommitReceipt {
    // (1) Strict read — fail closed on an unreadable/corrupted existing file.
    var file: CustomWordsFile
    do {
      file = try loadFileForMutation()
    } catch {
      throw CustomWordsImportCommitError.unreadableLibrary
    }

    // (2) Stale check against the EFFECTIVE list Review was built from.
    let effective = mergedWords(file: file)
    guard plan.baseline.semanticallyMatches(effective) else {
      throw CustomWordsImportCommitError.staleLibrary
    }

    // An all-Skip confirm changes nothing: no backup, no write.
    guard !plan.isEmpty else {
      return CustomWordsImportCommitReceipt(
        addedIDs: [], replacedIDs: [], droppedAliasCollisions: [])
    }

    // (3) Replacements. `existingID` may name a built-in, which lives in
    // `builtinDefaults` rather than `file.words`.
    //
    // Two replacements aimed at the SAME existing word are rejected, not
    // silently resolved: both would apply against the original entry and the
    // later one would quietly win, so the user would get an import they did
    // not approve while the receipt claimed both landed.
    guard Set(plan.replacements.map(\.existingID)).count == plan.replacements.count else {
      throw CustomWordsImportCommitError.invalidPlan
    }
    var replacedIDs: [UUID] = []
    for replacement in plan.replacements {
      guard let existing = effective.first(where: { $0.id == replacement.existingID }) else {
        throw CustomWordsImportCommitError.invalidPlan
      }
      let merged = Self.applyReplace(existing: existing, candidate: replacement.candidate)
      guard !merged.canonical.isEmpty else { throw CustomWordsImportCommitError.invalidPlan }

      // A built-in stays hidden only while some user word still carries its
      // canonical, so a Replace that MOVES the canonical away has to retire the
      // built-in too — otherwise it reappears beside the replacement and the
      // user gets two words where they approved one.
      //
      // This is checked before the branch on purpose: it applies whether the
      // override is being created now (built-in never edited) or already exists
      // in `file.words` (built-in edited earlier, which is why the canonical
      // still matches). Guarding only the create case leaves the identical bug
      // reachable through the update case.
      if let builtin = Self.builtinDefaults.first(where: {
        $0.word.canonical.caseInsensitiveCompare(existing.canonical) == .orderedSame
      }),
        builtin.word.canonical.caseInsensitiveCompare(merged.canonical) != .orderedSame,
        !file.deletedBuiltinIds.contains(builtin.id)
      {
        file.deletedBuiltinIds.append(builtin.id)
      }

      if let index = file.words.firstIndex(where: { $0.id == existing.id }) {
        file.words[index] = merged
      } else {
        file.words.append(merged)
      }
      replacedIDs.append(existing.id)
    }

    // (4) Additions — fresh UUID each; unspecified fields take type defaults,
    // since there is no existing word to preserve from.
    var addedIDs: [UUID] = []
    for candidate in plan.additions {
      let word = Self.makeAddition(from: candidate)
      guard !word.canonical.isEmpty else { throw CustomWordsImportCommitError.invalidPlan }
      file.words.append(word)
      addedIDs.append(word.id)
    }

    let touchedIDs = Set(addedIDs + replacedIDs)

    // (5) Canonical uniqueness, and no imported canonical may land on an alias
    // held by a different word this import did not replace. F2c never offers a
    // decision that produces either shape, so reaching here means a bad plan.
    var resulting = mergedWords(file: file)
    var seenCanonicals: [String: UUID] = [:]
    for word in resulting {
      let key = Self.importPersistenceKey(word.canonical)
      if let owner = seenCanonicals[key], owner != word.id {
        throw CustomWordsImportCommitError.invalidPlan
      }
      seenCanonicals[key] = word.id
    }
    for word in resulting where touchedIDs.contains(word.id) {
      let canonicalKey = Self.importPersistenceKey(word.canonical)
      for other in resulting where other.id != word.id && !touchedIDs.contains(other.id) {
        if other.aliases.contains(where: { Self.importPersistenceKey($0) == canonicalKey }) {
          throw CustomWordsImportCommitError.invalidPlan
        }
      }
    }

    // (6) Alias enforcement on the APPLIED result, so two replacements in one
    // plan are covered, not just additions. Only words this import touched can
    // lose an alias — an untouched word is not this import's to edit.
    // Touched words are resolved in APPLY order (replacements in plan order,
    // then additions), not the merged library's own order — otherwise which of
    // two claimants keeps a shared alias would depend on incidental storage
    // order rather than on the plan the user approved.
    let (filtered, dropped) = Self.enforceAliases(
      on: resulting, touchedOrder: replacedIDs + addedIDs)
    for word in filtered where touchedIDs.contains(word.id) {
      if let index = file.words.firstIndex(where: { $0.id == word.id }) {
        file.words[index].aliases = word.aliases
      }
    }

    // (7) Best-effort backup, then ONE save. A backup failure logs and
    // proceeds: correctness comes from the atomic write and the strict loader,
    // not from the backup existing.
    writePreImportBackup()
    try saveFile(file)

    // (8) Publish only after the write succeeded.
    resulting = mergedWords(file: file)
    words = resulting
    return CustomWordsImportCommitReceipt(
      addedIDs: addedIDs, replacedIDs: replacedIDs, droppedAliasCollisions: dropped)
  }

  /// This type's own dedup rule, named so the import path cannot accidentally
  /// reach for the compare engine's stronger matching key (PR-F2a).
  static func importPersistenceKey(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Field-level Replace, per the adopted plan's table. `id`, `frequencyUsed`,
  /// and `lastUsed` are always preserved; `canonical` is always taken; every
  /// other field is taken ONLY when the source actually supplied it, so a
  /// source with no opinion can never blank hand-tuned configuration.
  /// `suggestedAliases` are never applied on Replace — a machine guess must
  /// not overwrite hand-tuned aliases.
  static func applyReplace(
    existing: CustomWord, candidate: CustomWordsImportCandidate
  ) -> CustomWord {
    func supplied<Value>(_ field: CustomWordsImportField<Value>, else fallback: Value) -> Value {
      if case .supplied(let value) = field { return value }
      return fallback
    }
    let aliases = supplied(candidate.aliases, else: existing.aliases)
    return CustomWord(
      id: existing.id,
      canonical: candidate.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
      aliases: Self.sanitizeAliases(aliases),
      category: supplied(candidate.category, else: existing.category),
      priority: supplied(candidate.priority, else: existing.priority),
      forceReplace: supplied(candidate.forceReplace, else: existing.forceReplace),
      caseSensitive: supplied(candidate.caseSensitive, else: existing.caseSensitive),
      source: .user,
      frequencyUsed: existing.frequencyUsed,
      lastUsed: existing.lastUsed,
      minSimilarityOverride: supplied(
        candidate.minSimilarityOverride, else: existing.minSimilarityOverride)
    )
  }

  /// A new word from a candidate. Unspecified fields fall back to the type's
  /// own defaults — there is no existing word to preserve from. Add is the ONE
  /// place AI `suggestedAliases` are persisted, after the source's own spellings.
  static func makeAddition(from candidate: CustomWordsImportCandidate) -> CustomWord {
    func supplied<Value>(_ field: CustomWordsImportField<Value>, else fallback: Value) -> Value {
      if case .supplied(let value) = field { return value }
      return fallback
    }
    let sourceAliases = supplied(candidate.aliases, else: [])
    var union = sanitizeAliases(sourceAliases)
    var seen = Set(union.map(importPersistenceKey))
    for suggestion in sanitizeAliases(candidate.suggestedAliases)
    where seen.insert(importPersistenceKey(suggestion)).inserted {
      union.append(suggestion)
    }
    return CustomWord(
      canonical: candidate.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
      aliases: union,
      category: supplied(candidate.category, else: .general),
      priority: supplied(candidate.priority, else: 0),
      forceReplace: supplied(candidate.forceReplace, else: false),
      caseSensitive: supplied(candidate.caseSensitive, else: false),
      source: .user,
      minSimilarityOverride: supplied(candidate.minSimilarityOverride, else: nil)
    )
  }

  /// Whether a value may enter the library AT ALL, from any authoring path.
  ///
  /// The same question importing asks, asked here — because "what may be
  /// stored" is one rule and the library is what it protects. Applying only
  /// PART of it here (length, but not the character policy) let the editor
  /// author a word that export then refused, which is the round-trip
  /// asymmetry again with authoring as the door (cloud review, #1683).
  static func isStorable(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.unicodeScalars.count <= CustomWordsImportLimits.maximumStoredValueScalars
    else { return false }
    return CustomWordsImportTextPolicy.isAcceptableStoredValue(trimmed)
  }

  /// True when every alias the user actually authored can be stored.
  ///
  /// Blank aliases are not a refusal — the editor leaves empty rows behind and
  /// dropping those is ordinary trimming, not a lost edit. A NON-blank alias
  /// that the policy refuses is the lie this catches: `sanitizeAliases` would
  /// filter it out and the save would report success without it.
  private static func everyAliasIsStorable(_ aliases: [String]) -> Bool {
    aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .allSatisfy { isStorable($0) }
  }

  private static func sanitizeAliases(_ aliases: [String]) -> [String] {
    aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      // The whole rule, not a piece of it: an alias the app stores but cannot
      // export breaks the round trip just as thoroughly as a canonical does.
      .filter { isStorable($0) }
  }

  /// Guarantees no alias this import touched is left ambiguous, whatever
  /// Review believed. Precedence, in order: a word's own canonical beats its
  /// own redundant alias (dropped silently, it is not ambiguity); any other
  /// word's canonical beats an alias; an untouched incumbent's alias beats any
  /// imported one; among touched words, earlier in `touchedOrder` wins.
  ///
  /// `touchedOrder` is the APPLY order, so a shared alias resolves by the plan
  /// the user approved rather than by incidental storage order.
  static func enforceAliases(
    on words: [CustomWord], touchedOrder: [UUID]
  ) -> (words: [CustomWord], dropped: [CustomWordsImportAliasCollision]) {
    // Ownership comes from `WordCorrector`, not from a third copy of its rules
    // (#1667). This function used to mirror them itself, keyed on
    // `importPersistenceKey`, which has no no-space surface at all — so an
    // imported alias equal to an existing multi-word canonical's space-free
    // form was KEPT here even once the compare screen had learned to disclose
    // it. The screen said one thing and the commit did another; the alias was
    // saved and then never fired.
    var result = words
    // Last wins, and the list must not be assumed id-unique. Renaming a
    // built-in stores a user override carrying the built-in's OWN id while
    // `mergedWords` keeps showing the built-in (its canonical no longer
    // matches any user word), so within one process the two share an id and
    // `uniqueKeysWithValues` would trap on a state the manager itself creates.
    // `mergedWords` returns built-ins first, so last-wins resolves to the
    // user's own word — the one an import can legitimately touch.
    let indexByID = Dictionary(
      result.indices.map { (result[$0].id, $0) }, uniquingKeysWith: { _, last in last })

    // Canonical ownership is resolved by handing the WHOLE final array — the
    // exact array the runtime corrector will build its own lookups from — to
    // the one authority, in its own FINAL STORAGE order. A first version tried
    // to replay just the touched canonicals in APPLY order instead. That is
    // wrong: the compound namespace's last-write-wins rule is about storage
    // order, because that is the order `buildExactTriggerIndex` iterates when
    // it runs for real on the saved file. Apply order can name a winner the
    // corrector itself would never produce (grounded review r7, #1667).
    //
    // Touched words' proposed final aliases are stripped from this seed,
    // because their surviving aliases are decided by the loop below in the
    // plan's approved order — that precedence is a genuinely separate,
    // already-established rule this pass must not disturb. Canonicals stay,
    // so ownership is still resolved from the complete final vocabulary.
    let touchedIndices = Set(touchedOrder.compactMap { indexByID[$0] })
    let ownershipSeed = result.indices.map { wordIndex -> CustomWord in
      var word = result[wordIndex]
      if touchedIndices.contains(wordIndex) { word.aliases = [] }
      return word
    }
    var index = WordCorrector.buildExactTriggerIndex(words: ownershipSeed)

    /// The owner that would beat this word to a surface, if any. Holding a key
    /// is not always intercepting it — see `WordCorrector.ownerIntercepts`.
    func blocker(
      of claim: WordCorrector.ExactTriggerClaim, surface: String, for wordID: UUID
    ) -> WordCorrector.TriggerOwner? {
      guard let holder = index.owner(of: claim), holder.wordID != wordID else { return nil }
      return WordCorrector.ownerIntercepts(claim: claim, rawSurface: surface, owner: holder)
        ? holder : nil
    }

    var dropped: [CustomWordsImportAliasCollision] = []
    for id in touchedOrder {
      guard let wordIndex = indexByID[id] else { continue }
      let word = result[wordIndex]
      let canonicalKey = importPersistenceKey(word.canonical)
      var kept: [String] = []
      for alias in word.aliases {
        if importPersistenceKey(alias).isEmpty { continue }
        // Redundant with the word's own canonical: silently removed, never
        // reported — it is not an ambiguity anyone needs to hear about.
        if importPersistenceKey(alias) == canonicalKey { continue }

        let claims = WordCorrector.exactClaims(forAlias: alias)
        if claims.isEmpty { continue }

        // Evaluate every claim before registering any: the stored alias is the
        // unit kept or dropped, so a partially-registered alias that is then
        // dropped would leave an owner that does not exist and wrongly block a
        // later one. Same atomicity rule the compare engine follows.
        let blockers = claims.compactMap { claim in
          blocker(of: claim, surface: alias, for: word.id).map { (claim: claim, owner: $0) }
        }
        if let decisive = blockers.min(by: {
          $0.claim.namespace.passPriority < $1.claim.namespace.passPriority
        }) {
          dropped.append(
            CustomWordsImportAliasCollision(alias: alias, heldBy: decisive.owner.wordID))
          continue
        }

        // Gap-fill, never overwrite. An alias reaches here unblocked for one of
        // three reasons: nobody holds the key, this word already holds it, or a
        // compound holder declines to intercept. In that last case the holder
        // must STAY registered, because at runtime an alias only ever fills an
        // empty compound slot. Overwriting handed the key to the wrong word.
        index.gapFill(
          claims,
          owner: WordCorrector.TriggerOwner(
            wordID: word.id, canonical: word.canonical, isPack: false)
        )
        kept.append(alias)
      }
      result[wordIndex].aliases = kept
    }
    return (result, dropped)
  }

  /// Timestamped copy of the current file before a changing commit. Purely a
  /// convenience recovery path — failures are logged, never fatal. No retention
  /// policy in v1; an accumulating set of backups is an accepted, named scope cut.
  ///
  /// Never overwrites an existing backup. Two commits inside the same second
  /// would otherwise collide on the filename, and destroying the earlier
  /// pre-import state is the one thing this recovery path must not do.
  private func writePreImportBackup() {
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

  public func update(word: CustomWord, in words: inout [CustomWord]) throws {
    guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
    let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    // Same authoring door as `add`, same reason it throws: see there.
    guard Self.isStorable(trimmed) else { throw CustomWordsPersistenceError.unusableValue }
    guard Self.everyAliasIsStorable(word.aliases) else {
      throw CustomWordsPersistenceError.unusableValue
    }
    var edited = word
    edited.canonical = trimmed
    edited.aliases = Self.sanitizeAliases(edited.aliases)

    // An edit makes the word the user's, whatever it started as (#1680).
    // Editing a built-in produces a user override, but the value still carries
    // `source: .builtin` from `builtinDefaults` and `source` is a `let`, so it
    // is reconstructed here. Applied ONCE, before both the file write and the
    // in-memory publish: re-tagging only the file copy leaves the live list
    // still claiming `.builtin`, and an export taken right after the edit —
    // which filters on `source == .user` — would silently omit the user's own
    // change until the next launch decoded it. (No-op for words already `.user`.)
    let sanitized = edited.ownedByUser()

    var file = try loadFileForMutation()

    // An edit that MOVES a built-in's canonical away has to retire the
    // built-in too (mirrors the commitImport tombstone rule, #1668) —
    // otherwise the built-in still matches no user word, so `mergedWords`
    // keeps showing it beside the rename and the user gets two words where
    // they edited one (#1670). A same-canonical edit (alias-only change)
    // must NOT tombstone: the override already hides the built-in on its
    // own, and recording a tombstone would persist a deletion the user never
    // performed.
    let previousCanonical = words[index].canonical
    if let builtin = Self.builtinDefaults.first(where: {
      $0.word.canonical.lowercased() == previousCanonical.lowercased()
    }),
      builtin.word.canonical.lowercased() != sanitized.canonical.lowercased(),
      !file.deletedBuiltinIds.contains(builtin.id)
    {
      file.deletedBuiltinIds.append(builtin.id)
    }

    // Check if this is a built-in word being edited — store as user override
    if let existingIdx = file.words.firstIndex(where: { $0.id == word.id }) {
      file.words[existingIdx] = sanitized
    } else {
      // Editing a built-in: add as user word (overrides built-in by canonical match).
      file.words.append(sanitized)
    }
    try saveFile(file)

    // Update the in-memory array directly for the caller
    var updated = words
    updated[index] = sanitized
    words = updated
  }

  /// Bulk-update existing words by ID with a single file read + write. Mirrors
  /// `update(word:)` per word — canonical trim, reject-empty, alias sanitize —
  /// but collapses the per-word `loadFile`/`saveFile` into one of each so the
  /// contacts-import alias enrichment can flush a batch of generated aliases
  /// without an O(n) per-word rewrite (#636 follow-up).
  ///
  /// An ID not present in the file is skipped (no-op), NOT appended — unlike
  /// `update(word:)`, which appends a missing id as a built-in override.
  /// Enrichment must never resurrect a word the user deleted mid-job. Returns
  /// with `words` untouched if nothing matched.
  public func updateBatch(_ updates: [CustomWord], to words: inout [CustomWord]) throws {
    guard !updates.isEmpty else { return }
    var file = try loadFileForMutation()
    var changed = false
    for word in updates {
      let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isStorable(trimmed) else { continue }
      guard let idx = file.words.firstIndex(where: { $0.id == word.id }) else { continue }
      var sanitized = word
      sanitized.canonical = trimmed
      sanitized.aliases = Self.sanitizeAliases(sanitized.aliases)
      file.words[idx] = sanitized
      changed = true
    }
    guard changed else { return }
    try saveFile(file)
    words = mergedWords(file: file)
  }

  // MARK: - Private File I/O

  /// Single read path — normalizes legacy formats to CustomWordsFile.
  /// All callers (load, flush, CRUD mutations) go through this. The result
  /// distinguishes missing / loaded / unreadable / corrupted (#1646) so
  /// callers can fail closed instead of treating every failure as "empty".
  private func loadFile() -> CustomWordsLoadResult {
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
      try? saveFile(file)
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
      try? saveFile(file)
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
  private func saveFile(_ file: CustomWordsFile) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(file)
    let tmpURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent(".custom-words.json.\(UUID().uuidString).tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
      guard fd >= 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try fh.write(contentsOf: data)
      try fh.close()

      // Same-directory temp file means same filesystem, which is what makes
      // rename legal here.
      guard Foundation.rename(tmpURL.path, fileURL.path) == 0 else {
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(errno),
          userInfo: [
            NSLocalizedDescriptionKey: String(cString: strerror(errno)),
            NSFilePathErrorKey: fileURL.path,
          ])
      }
    } catch {
      try? fm.removeItem(at: tmpURL)
      throw error
    }
  }

  // MARK: - Runtime Merge

  /// Merge built-in defaults with user words. Built-ins not tombstoned and not
  /// overridden by a user word (same canonical, case-insensitive) are included.
  private func mergedWords(file: CustomWordsFile) -> [CustomWord] {
    let tombstones = Set(file.deletedBuiltinIds)
    let activeBuiltins = Self.builtinDefaults
      .filter { !tombstones.contains($0.id) }
      .map(\.word)

    let userCanonicals = Set(file.words.map { $0.canonical.lowercased() })
    let nonOverriddenBuiltins = activeBuiltins.filter {
      !userCanonicals.contains($0.canonical.lowercased())
    }

    return nonOverriddenBuiltins + file.words
  }
}
