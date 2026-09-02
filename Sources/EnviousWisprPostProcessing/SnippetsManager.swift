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
  /// `SnippetExpander`'s longest-match tie-break UNREACHABLE rather than merely unlikely.
  case duplicateTrigger(existing: String)
  /// The keyword is more than one spoken word. The matcher compares the keyword against ONE
  /// transcript token, so a multi-word keyword can never match — it would report itself armed
  /// and silently switch every snippet off, which is worse than refusing it.
  case keywordNotOneWord
}

/// Why the store cannot be written right now. Distinct from a validation error: nothing the
/// user typed is wrong, the data on disk is the problem.
public enum SnippetStoreError: Error, Equatable, Sendable {
  /// An existing file could not be read, and its contents are still unknown. Every mutation is
  /// refused: writing now would rename a new file over data we never managed to load.
  case existingFileUnreadable
  /// Another process holds the store.
  case busy
  /// The lock could not be taken at all.
  case coordinationUnavailable
  case writeFailed(String)
}

/// On-disk store for the user's snippets (#628).
///
/// Durability discipline shared with `CustomWordsManager` through `DurableJSONFile`: 0700
/// directory with a Spotlight opt-out marker, 0600 file, unique-temp + fsync + atomic rename, a
/// cross-process companion-file lock, and a corrupt file archived rather than replaced.
///
/// **The load result is three-valued on purpose.** A missing file and an unreadable one are NOT
/// the same thing: the first is a new user, the second is a user whose snippets exist and could
/// not be read. Collapsing them means the next save renames an empty store over data that was
/// merely temporarily unavailable — the user's snippets deleted by opening Settings.
public final class SnippetsManager: @unchecked Sendable {

  /// The persisted shape. Versioned from the first release so a later migration has something
  /// to branch on; `CustomWordsManager` had to add its version field after the fact.
  struct StoredFile: Codable {
    var version: Int
    var keyword: String
    var snippets: [Snippet]
  }

  /// What is on disk right now. The `unreadable` case is the whole reason this is not an
  /// optional.
  enum LoadResult: Equatable {
    case missing
    case loaded(SnippetVocabulary)
    /// The file exists and its contents are unknown — a read error, or a corrupt file that
    /// could not be archived to safety. Either way the bytes must not be overwritten.
    case unreadable
  }

  /// The schema version stamped into both the store and an export. Public because the export
  /// document must carry the SAME number the store writes — two literals would let a schema
  /// bump land in one and not the other, and the file that lies about its version is the one
  /// a future import trusts.
  public static let currentVersion = 1
  private static let fileName = "snippets.json"
  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "Snippets")

  private let fileURL: URL
  /// Bumped on every successful save, and deliberately NOT persisted.
  ///
  /// A generation exists so a cross-actor reader can notice "I am holding an older snapshot
  /// than the other lane" WITHIN a process run (`VocabularyLanes.swift`). Nothing compares
  /// generations across launches, so writing it to disk would store a runtime concern.
  ///
  /// Its first version WAS inert — every load reset it to 0 — which the store's own test caught
  /// rather than a user.
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

  // MARK: - Load

  /// Read the store for DISPLAY. An unreadable file reads as empty here, because the screen has
  /// to render something — but `unreadableExisting` tells it to say so, and every mutation is
  /// refused until the file can be read.
  public func load() -> SnippetVocabulary {
    let empty = SnippetVocabulary(
      snippets: [], keyword: SnippetVocabulary.defaultKeyword, generation: generation)
    guard let result = try? withLock(blocking: true, { loadWhileLocked() }) else { return empty }
    if case .loaded(let vocabulary) = result { return vocabulary }
    return empty
  }

  /// True when a file exists that could not be read. The screen shows a banner, and saves are
  /// refused, rather than a silent empty list the next edit would make permanent.
  public var unreadableExisting: Bool {
    (try? withLock(blocking: true) { loadWhileLocked() }) == .unreadable
  }

  private func loadWhileLocked() -> LoadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      // The file is THERE and we could not read it. Saying "empty" here is what would let the
      // next save rename a new store over snippets that still exist.
      Self.logger.error(
        "snippets.json exists but could not be read; refusing to write over it. \(String(describing: error), privacy: .public)"
      )
      return .unreadable
    }

    do {
      let file = try JSONDecoder().decode(StoredFile.self, from: data)
      // A file from a NEWER app is data we do not fully understand. Synthesized decoding accepts
      // it happily and drops every field this version has never heard of, and the next save
      // would then write our narrower shape back over it — the user losing whatever the newer
      // release stored, by opening the older one.
      //
      // This is the same rule as the unreadable case one branch down, and the field it needs
      // already existed: `version` was added "so a later migration has something to branch on"
      // and then nothing branched on it. A version stamp nobody reads is a comment.
      guard file.version <= Self.currentVersion else {
        Self.logger.error(
          "snippets.json is version \(file.version, privacy: .public), newer than this app understands (\(Self.currentVersion, privacy: .public)); refusing to write over it."
        )
        return .unreadable
      }
      return .loaded(
        SnippetVocabulary(
          snippets: file.snippets,
          keyword: file.keyword.isEmpty ? SnippetVocabulary.defaultKeyword : file.keyword,
          generation: generation))
    } catch {
      // Archived, never deleted and never overwritten in place. These snippets were typed by
      // hand and exist nowhere else.
      let archive = fileURL.deletingLastPathComponent()
        .appendingPathComponent("\(Self.fileName).corrupted-\(UUID().uuidString)")
      do {
        try FileManager.default.moveItem(at: fileURL, to: archive)
      } catch {
        // The bytes are still the only copy. Reporting empty-and-writable here would let a
        // later save destroy the one recoverable version of the user's snippets.
        Self.logger.error(
          "snippets.json is corrupt AND could not be archived; refusing to write over it. \(String(describing: error), privacy: .public)"
        )
        return .unreadable
      }
      Self.logger.error(
        "snippets.json could not be parsed; archived and starting empty. \(String(describing: error), privacy: .public)"
      )
      return .missing
    }
  }

  /// Persist, bump, and hand back the SAVED vocabulary stamped with its new generation.
  ///
  /// The bump happens only after the write returns, so a failed save cannot advance a
  /// generation no reader's snapshot corresponds to. And the return value is re-stamped rather
  /// than echoing the caller's input, because a caller taking the pre-save value would publish
  /// a snapshot claiming a generation one behind the manager — a staleness signal reading stale.
  private func saveWhileLocked(_ vocabulary: SnippetVocabulary) throws -> SnippetVocabulary {
    do {
      try DurableJSONFile.write(
        StoredFile(
          version: Self.currentVersion, keyword: vocabulary.keyword,
          snippets: vocabulary.snippets),
        to: fileURL,
        tempPrefix: ".\(Self.fileName)")
    } catch {
      throw SnippetStoreError.writeFailed(error.localizedDescription)
    }
    generation &+= 1
    return SnippetVocabulary(
      snippets: vocabulary.snippets, keyword: vocabulary.keyword, generation: generation)
  }

  // MARK: - Mutations

  /// Every mutation is one load-transform-save inside ONE cross-process lock hold, and refuses
  /// outright when the existing file could not be read.
  ///
  /// The lock matters because two EnviousWispr processes can be open at once — a shipped copy
  /// and a dev build on this machine, routinely. Without it both load the same snapshot and
  /// atomically publish different valid files, and the second rename silently discards the
  /// first person's edit.
  private func mutate(
    _ transform: (SnippetVocabulary) throws -> SnippetVocabulary
  ) throws -> SnippetVocabulary {
    try withLock {
      let current: SnippetVocabulary
      switch loadWhileLocked() {
      case .missing:
        current = SnippetVocabulary(
          snippets: [], keyword: SnippetVocabulary.defaultKeyword, generation: generation)
      case .loaded(let vocabulary):
        current = vocabulary
      case .unreadable:
        throw SnippetStoreError.existingFileUnreadable
      }
      return try saveWhileLocked(try transform(current))
    }
  }

  private func withLock<T>(blocking: Bool = false, _ body: () throws -> T) throws -> T {
    do {
      return try DurableJSONFile.withExclusiveLock(on: fileURL, blocking: blocking, body)
    } catch DurableJSONFile.LockFailure.busy {
      throw SnippetStoreError.busy
    } catch DurableJSONFile.LockFailure.unavailable {
      throw SnippetStoreError.coordinationUnavailable
    }
  }

  @discardableResult
  public func upsert(_ snippet: Snippet) throws -> SnippetVocabulary {
    try mutate { current in
      try Self.validate(snippet, against: current.snippets)
      var snippets = current.snippets
      if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
        snippets[index] = snippet
      } else {
        snippets.insert(snippet, at: 0)
      }
      return SnippetVocabulary(
        snippets: snippets, keyword: current.keyword, generation: current.generation)
    }
  }

  @discardableResult
  public func remove(id: UUID) throws -> SnippetVocabulary {
    try mutate { current in
      SnippetVocabulary(
        snippets: current.snippets.filter { $0.id != id },
        keyword: current.keyword,
        generation: current.generation)
    }
  }

  /// Change the keyword. A blank keyword restores the default rather than being refused: the
  /// user is clearing a text field, not asking to disable the feature, and an empty field would
  /// silently switch every snippet off.
  @discardableResult
  public func setKeyword(_ keyword: String) throws -> SnippetVocabulary {
    try mutate { current in
      let cleaned = SnippetText.normalize(keyword)
      guard !cleaned.isEmpty else {
        return SnippetVocabulary(
          snippets: current.snippets,
          keyword: SnippetVocabulary.defaultKeyword,
          generation: current.generation)
      }
      try Self.validateKeyword(cleaned)
      return SnippetVocabulary(
        snippets: current.snippets, keyword: cleaned, generation: current.generation)
    }
  }

  // MARK: - Validation

  /// The rules from Gate 2, in one place so the sheet and any future caller cannot disagree
  /// about what a valid snippet is.
  public static func validate(_ snippet: Snippet, against existing: [Snippet]) throws {
    guard !snippet.triggerTokens.isEmpty else { throw SnippetValidationError.triggerEmpty }
    guard !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SnippetValidationError.expansionEmpty
    }
    if let clash = existing.first(where: { $0.id != snippet.id && $0.collidesWith(snippet) }) {
      throw SnippetValidationError.duplicateTrigger(existing: clash.trigger)
    }
  }

  /// A keyword must be exactly one spoken word.
  ///
  /// `SnippetExpander` compares the keyword against ONE transcript token, so "hey wispr" would
  /// pass `canFire` and never match — every snippet silently dead while the screen insists the
  /// feature is on. Refusing at the door is the honest failure; the alternative is a feature
  /// that reports itself working and is not.
  public static func validateKeyword(_ keyword: String) throws {
    let words = keyword.split(whereSeparator: { $0.isWhitespace })
    guard words.count <= 1 else { throw SnippetValidationError.keywordNotOneWord }
  }
}
