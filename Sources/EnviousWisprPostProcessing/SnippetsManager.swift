import EnviousWisprCore
import Foundation
import os

/// Why a snippet could not be saved. A closed set, so the edit sheet renders one message per
/// case rather than guessing from a bare `false`.
public enum SnippetValidationError: Error, Equatable, Sendable {
  /// The trigger is empty, or is punctuation only, so nothing could ever match it.
  case triggerEmpty
  /// The expansion is empty or whitespace only. Founder call, 2026-09-01: a snippet that pastes
  /// nothing is not a snippet, and Save must refuse rather than store a trigger that silently
  /// deletes the words the user spoke.
  case expansionEmpty
  /// Another snippet already fires on the same spoken words. Refusing here is what makes
  /// `SnippetExpander`'s longest-match tie-break UNREACHABLE rather than merely unlikely —
  /// without it two snippets could share a trigger and the winner would be list order, which is
  /// a rule nobody chose.
  case duplicateTrigger(existing: String)
}

/// On-disk store for the user's snippets (#628).
///
/// Mirrors `CustomWordsManager`'s durability discipline through the shared `DurableJSONFile`:
/// 0700 directory with a Spotlight opt-out marker, 0600 file, unique-temp + fsync + atomic
/// rename, and a corrupt file archived rather than silently replaced.
///
/// Deliberately much smaller than `CustomWordsManager`, and the difference is not an oversight:
/// that type carries built-in defaults, tombstones, a pack tier, debounced usage counters and a
/// cross-process file lock because custom words are written from several places. Snippets have
/// exactly one writer — the Settings screen — so a second copy of that machinery would be
/// weight with no reader.
public final class SnippetsManager: @unchecked Sendable {

  /// The persisted shape. Versioned from the first release so a later migration has something
  /// to branch on; `CustomWordsManager` had to add its version field after the fact.
  struct StoredFile: Codable {
    var version: Int
    var keyword: String
    var snippets: [Snippet]
  }

  /// The schema version stamped into both the store and an export. Public because the export
  /// document must carry the SAME number the store writes — two literals would let a schema
  /// bump land in one and not the other, and the file that lies about its version is the one
  /// a future import trusts.
  public static let currentVersion = 1
  private static let fileName = "snippets.json"
  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "Snippets")

  private let fileURL: URL
  private let lock = NSLock()
  /// Bumped on every successful save, and deliberately NOT persisted.
  ///
  /// A generation exists so a cross-actor reader can notice "I am holding an older snapshot
  /// than the other lane" WITHIN a process run (`VocabularyLanes.swift`). Nothing compares
  /// generations across launches, so writing it to disk would store a runtime concern and
  /// invite someone to read meaning into a number that only counts saves since app start.
  ///
  /// Its first version WAS inert — every load reset it to 0, so `current.generation &+ 1` was
  /// always 1 — which the store's own test caught rather than a user.
  private var generation: UInt64 = 0

  public init() {
    let base =
      FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("EnviousWispr", isDirectory: true)
    DurableJSONFile.prepareDirectory(at: directory)
    fileURL = directory.appendingPathComponent(Self.fileName)
    DurableJSONFile.tightenFileIfPresent(at: fileURL)
  }

  /// Test seam: a per-test temp file instead of the production Application Support path.
  // periphery:ignore - test seam
  package init(fileURL: URL) {
    self.fileURL = fileURL
    DurableJSONFile.prepareDirectory(at: fileURL.deletingLastPathComponent())
    DurableJSONFile.tightenFileIfPresent(at: fileURL)
  }

  package var storageURL: URL { fileURL }

  /// The production store's path, for the export guard. Static and `nonisolated` for the same
  /// reason `CustomWordsManager.liveFileURL` is: the export writer runs off the main actor and
  /// must be able to refuse the app's own file as a destination without holding a manager.
  nonisolated public static var liveFileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("EnviousWispr", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  // MARK: - Load and save

  /// Read the store. A missing file is the EMPTY store, not an error — that is what a user who
  /// has never opened Snippets has, and it must not be reported as a failure.
  public func load() -> SnippetVocabulary {
    lock.lock()
    defer { lock.unlock() }
    return loadWhileLocked()
  }

  private func loadWhileLocked() -> SnippetVocabulary {
    guard let data = try? Data(contentsOf: fileURL) else {
      return SnippetVocabulary(
        snippets: [], keyword: SnippetVocabulary.defaultKeyword, generation: generation)
    }
    do {
      let file = try JSONDecoder().decode(StoredFile.self, from: data)
      return SnippetVocabulary(
        snippets: file.snippets,
        keyword: file.keyword.isEmpty ? SnippetVocabulary.defaultKeyword : file.keyword,
        generation: generation)
    } catch {
      // Archived, never deleted and never overwritten in place. The user's snippets are typed
      // by hand and exist nowhere else, so a parse failure must leave the bytes recoverable —
      // same reasoning as `custom-words.json.corrupted-*`.
      let archive = fileURL.deletingLastPathComponent()
        .appendingPathComponent("\(Self.fileName).corrupted-\(UUID().uuidString)")
      try? FileManager.default.moveItem(at: fileURL, to: archive)
      Self.logger.error(
        "snippets.json could not be parsed; archived and starting empty. \(String(describing: error), privacy: .public)"
      )
      return SnippetVocabulary(
        snippets: [], keyword: SnippetVocabulary.defaultKeyword, generation: generation)
    }
  }

  /// Persist, bump, and hand back the SAVED vocabulary stamped with its new generation.
  ///
  /// Both halves of that matter. The bump happens only after the write returns, so a failed
  /// save cannot advance a generation no reader's snapshot corresponds to. And the return value
  /// is re-stamped rather than the caller's input being returned, because a caller who took the
  /// pre-save value would publish a snapshot claiming a generation one behind the manager — a
  /// staleness signal that itself reads stale.
  private func saveWhileLocked(_ vocabulary: SnippetVocabulary) throws -> SnippetVocabulary {
    try DurableJSONFile.write(
      StoredFile(
        version: Self.currentVersion, keyword: vocabulary.keyword,
        snippets: vocabulary.snippets),
      to: fileURL,
      tempPrefix: ".\(Self.fileName)")
    generation &+= 1
    return SnippetVocabulary(
      snippets: vocabulary.snippets, keyword: vocabulary.keyword, generation: generation)
  }

  // MARK: - Mutations

  /// Add or update one snippet, validating first. Returns the new vocabulary so the caller has
  /// exactly one source for what is now on disk.
  @discardableResult
  public func upsert(_ snippet: Snippet) throws -> SnippetVocabulary {
    lock.lock()
    defer { lock.unlock() }
    let current = loadWhileLocked()
    try Self.validate(snippet, against: current.snippets)

    var snippets = current.snippets
    if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
      snippets[index] = snippet
    } else {
      snippets.insert(snippet, at: 0)
    }
    return try saveWhileLocked(
      SnippetVocabulary(
        snippets: snippets, keyword: current.keyword, generation: current.generation))
  }

  @discardableResult
  public func remove(id: UUID) throws -> SnippetVocabulary {
    lock.lock()
    defer { lock.unlock() }
    let current = loadWhileLocked()
    return try saveWhileLocked(
      SnippetVocabulary(
        snippets: current.snippets.filter { $0.id != id },
        keyword: current.keyword,
        generation: current.generation))
  }

  /// Change the keyword. A blank keyword is stored as the default rather than refused: the user
  /// is clearing a text field, not asking to disable the feature, and leaving the field empty
  /// would silently switch every snippet off.
  @discardableResult
  public func setKeyword(_ keyword: String) throws -> SnippetVocabulary {
    lock.lock()
    defer { lock.unlock() }
    let current = loadWhileLocked()
    let cleaned = SnippetText.normalize(keyword)
    return try saveWhileLocked(
      SnippetVocabulary(
        snippets: current.snippets,
        keyword: cleaned.isEmpty ? SnippetVocabulary.defaultKeyword : cleaned,
        generation: current.generation))
  }

  // MARK: - Validation

  /// The two founder calls from Gate 2, in one place so the sheet and any future caller cannot
  /// disagree about what a valid snippet is.
  public static func validate(_ snippet: Snippet, against existing: [Snippet]) throws {
    guard !snippet.triggerTokens.isEmpty else { throw SnippetValidationError.triggerEmpty }
    guard !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SnippetValidationError.expansionEmpty
    }
    if let clash = existing.first(where: { $0.id != snippet.id && $0.collidesWith(snippet) }) {
      throw SnippetValidationError.duplicateTrigger(existing: clash.trigger)
    }
  }
}
