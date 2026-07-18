import EnviousWisprCore
import Foundation

/// A built-in default word shipped with the app. Identified by a stable string ID
/// for tombstone tracking across app updates.
public struct BuiltinWord: Sendable {
  public let id: String
  public let word: CustomWord
}

/// Thrown by the CRUD mutation methods when an EXISTING custom-words file
/// cannot be read (#1646). Failing closed here is what prevents a mutation
/// from silently substituting an empty library and writing it over the
/// user's real one.
package enum CustomWordsPersistenceError: LocalizedError, Sendable, Equatable {
  case unreadableExistingFile
  case corruptedExistingFile

  package var errorDescription: String? {
    switch self {
    case .unreadableExistingFile:
      return "Your saved words could not be read. Nothing was changed. Try again."
    case .corruptedExistingFile:
      return
        "Your saved words file was damaged and moved aside for recovery. No edit or import was applied."
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
      // increments survive to the next flush attempt.
      for (id, increment) in snapshot {
        var entry =
          pendingIncrements[id]
          ?? PendingIncrement(count: 0, lastTimestamp: increment.lastTimestamp)
        entry.count += increment.count
        entry.lastTimestamp = max(entry.lastTimestamp, increment.lastTimestamp)
        pendingIncrements[id] = entry
      }
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
    sanitized.aliases = sanitized.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
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
      guard !trimmed.isEmpty else { continue }
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
      sanitized.aliases = sanitized.aliases
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
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

  public func update(word: CustomWord, in words: inout [CustomWord]) throws {
    guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
    let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var sanitized = word
    sanitized.canonical = trimmed
    sanitized.aliases = sanitized.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var file = try loadFileForMutation()

    // Check if this is a built-in word being edited — store as user override
    if let existingIdx = file.words.firstIndex(where: { $0.id == word.id }) {
      file.words[existingIdx] = sanitized
    } else {
      // Editing a built-in: add as user word (overrides built-in by canonical match)
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
      guard !trimmed.isEmpty else { continue }
      guard let idx = file.words.firstIndex(where: { $0.id == word.id }) else { continue }
      var sanitized = word
      sanitized.canonical = trimmed
      sanitized.aliases = sanitized.aliases
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
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
  private func saveFile(_ file: CustomWordsFile) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(file)
    let tmpURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".custom-words.json.tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try fh.write(contentsOf: data)
      try fh.close()
      if fm.fileExists(atPath: fileURL.path) {
        _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
      } else {
        try fm.moveItem(at: tmpURL, to: fileURL)
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
