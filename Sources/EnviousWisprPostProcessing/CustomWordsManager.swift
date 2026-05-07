import EnviousWisprCore
import Foundation

/// A built-in default word shipped with the app. Identified by a stable string ID
/// for tombstone tracking across app updates.
public struct BuiltinWord: Sendable {
  public let id: String
  public let word: CustomWord
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

  // MARK: - Public API

  /// Load the effective word list: built-in defaults (minus tombstones) + user words.
  /// Returns nil only on unrecoverable I/O failure.
  public func load() -> [CustomWord]? {
    let file = loadFile() ?? CustomWordsFile()
    return mergedWords(file: file)
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

    var file = loadFile() ?? CustomWordsFile()
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

    var file = loadFile() ?? CustomWordsFile()

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

  public func remove(id: UUID, from words: inout [CustomWord]) throws {
    let word = words.first { $0.id == id }
    var file = loadFile() ?? CustomWordsFile()

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

  public func update(word: CustomWord, in words: inout [CustomWord]) throws {
    guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
    let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var sanitized = word
    sanitized.canonical = trimmed
    sanitized.aliases = sanitized.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var file = loadFile() ?? CustomWordsFile()

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

  // MARK: - Private File I/O

  /// Single read path — normalizes legacy formats to CustomWordsFile.
  /// All callers (load, add, remove, save) go through this.
  private func loadFile() -> CustomWordsFile? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    guard let data = try? Data(contentsOf: fileURL) else {
      Task {
        await AppLogger.shared.log(
          "Failed to read custom words file — returning nil to prevent data loss",
          level: .info, category: "CustomWords"
        )
      }
      return nil
    }

    // Try new versioned wrapper first
    if let file = try? JSONDecoder().decode(CustomWordsFile.self, from: data) {
      return file
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
      return file
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
      return file
    }

    // Corrupted — backup and start fresh
    let backup = fileURL.deletingLastPathComponent()
      .appendingPathComponent("custom-words.json.corrupted")
    try? FileManager.default.moveItem(at: fileURL, to: backup)
    Task {
      await AppLogger.shared.log(
        "Custom words file corrupted, backed up to \(backup.lastPathComponent)",
        level: .info, category: "CustomWords"
      )
    }
    return nil
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
