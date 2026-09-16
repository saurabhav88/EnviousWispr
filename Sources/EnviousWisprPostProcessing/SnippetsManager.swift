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
  /// An import's review was built against a list that no longer matches disk (#2997). Nothing
  /// was written; the caller recompares against the current list. Never a failure to the user.
  case listChangedDuringReview
}

/// What an import wrote (#2997): the saved vocabulary and the ids it added, in review order.
public struct SnippetImportReceipt: Sendable, Equatable {
  public let vocabulary: SnippetVocabulary
  public let addedIDs: [UUID]

  public init(vocabulary: SnippetVocabulary, addedIDs: [UUID]) {
    self.vocabulary = vocabulary
    self.addedIDs = addedIDs
  }
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
  /// optional, and `archivedCorrupt` is the second reason: THREE different situations produce
  /// no readable snippets, and they do not all license the same next action.
  enum LoadResult: Equatable {
    /// No file has ever been written here. The only state a fresh install is in.
    case missing
    case loaded(SnippetVocabulary)
    /// A file was there, could not be parsed, and was moved aside to a `.corrupted-<uuid>`
    /// archive. Reading and writing may proceed from empty — but this is NOT a new user, and
    /// anything that treats it as one acts on somebody's data-loss moment. Split out after
    /// review found starter snippets being written into exactly this state, where they would
    /// have read as recovered content.
    case archivedCorrupt
    /// The file exists and its contents are unknown — a read error, a file from a NEWER app, or
    /// a corrupt file that could not be archived. Either way the bytes must not be overwritten.
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
  ///
  /// Behind its own in-process lock (#2997): an import's write runs off the main actor while
  /// the screen can still `load()`, and `@unchecked Sendable` protects nothing by itself. The
  /// file lock does not cover the reads that build a fallback BEFORE it is taken. This lock
  /// is held for one read or one increment and never while the file lock is acquired.
  private let generationState = OSAllocatedUnfairLock(initialState: UInt64(0))

  private var generation: UInt64 { generationState.withLock { $0 } }

  private func advanceGeneration() -> UInt64 {
    generationState.withLock {
      $0 &+= 1
      return $0
    }
  }

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
    // `archivedCorrupt` renders as empty exactly like `missing`: the screen has to draw, and the
    // bytes are safe in the archive. Only `loadOrSeedStarters` needs the two kept apart.
    if case .loaded(let vocabulary) = result { return vocabulary }
    return empty
  }

  /// Read the store for PUBLICATION after a write (#2997): the vocabulary only when the file is
  /// there and readable, nil otherwise.
  ///
  /// `load()` answers "what should the screen draw" and reads an unreadable file as empty.
  /// A caller about to PUBLISH cannot use that answer: publishing empty would silently switch
  /// every snippet off for the session. Three-valued in, two-valued out, with the empty case
  /// kept out of reach.
  public func loadedVocabulary() -> SnippetVocabulary? {
    // Non-blocking: this runs on the main actor, and another process holding the lock must
    // not freeze the window. Contention reads as nil, and the caller's fallback holds.
    guard let result = try? withLock(blocking: false, { loadWhileLocked() }) else { return nil }
    if case .loaded(let vocabulary) = result { return vocabulary }
    return nil
  }

  /// Read the store for a REFRESH of the published list (#2997): the vocabulary when the
  /// file is readable, EMPTY when there is none (missing, or archived as corrupt), and nil
  /// when the file exists and cannot be read.
  ///
  /// The difference from `load()` is the nil: a publisher that adopted `load()`'s empty
  /// answer for an unreadable file would switch every snippet off for the session while the
  /// user's snippets still sit on disk. Missing and archived ARE empty, and are adopted.
  public func refreshedVocabulary() -> SnippetVocabulary? {
    // BLOCKING, unlike `loadedVocabulary`: an explicit refresh (the export's re-read after
    // the save panel, the import's review) waits for an in-progress writer rather than
    // silently answering with an older published snapshot, which the export would then
    // write as a backup (cloud review, PR #3006).
    guard let result = try? withLock(blocking: true, { loadWhileLocked() }) else { return nil }
    switch result {
    case .loaded(let vocabulary): return vocabulary
    case .missing, .archivedCorrupt:
      return SnippetVocabulary(
        snippets: [], keyword: SnippetVocabulary.defaultKeyword, generation: generation)
    case .unreadable: return nil
    }
  }

  /// Read the store, and on a brand-new install write the starter examples first (#628).
  ///
  /// The seed is attempted for `missing` ONLY, which is what makes it a one-time event: after
  /// it runs the file exists, so a user who deletes every starter is left with a file holding
  /// none, and the next launch loads that empty list instead of putting them back. An
  /// `unreadable` file is never seeded over, for the same reason no mutation touches one — the
  /// snippets on disk are still the only copy.
  ///
  /// The load and the write happen inside ONE lock hold. Two of these racing on first launch
  /// (a shipped copy and a dev build both starting) would otherwise both read `missing` and
  /// both write the starters, and the second rename would discard whichever edit the first
  /// user had already made.
  ///
  /// A failed seed returns the EMPTY vocabulary rather than the starters it could not persist.
  /// Showing a list the store does not hold is how the next delete writes a file with the other
  /// five missing; the honest outcome is an empty screen now and the examples on the next
  /// launch that can write.
  public func loadOrSeedStarters() -> SnippetVocabulary {
    let empty = SnippetVocabulary(
      snippets: [], keyword: SnippetVocabulary.defaultKeyword, generation: generation)
    let result = try? withLock(blocking: true) { () -> SnippetVocabulary in
      switch loadWhileLocked() {
      case .loaded(let vocabulary):
        return vocabulary
      case .unreadable, .archivedCorrupt:
        // Neither is a new install. `archivedCorrupt` is the one that looks like one and is not:
        // the user HAD snippets, they were just moved aside, and writing six John Doe examples
        // into that moment presents sample data as recovered content.
        return empty
      case .missing:
        // `missing` means no file HERE, NOW. It does not mean this install never had one: the
        // corrupt-file archive moves the store aside, so the same read reports `missing` for a
        // user who just lost their snippets. Ask the disk the question actually being asked.
        guard !hasStoreHistoryOnDisk() else { return empty }
        let seeded = SnippetVocabulary(
          snippets: SnippetStarters.all,
          keyword: SnippetVocabulary.defaultKeyword,
          generation: generation)
        guard let saved = try? saveWhileLocked(seeded) else {
          Self.logger.error("Starter snippets could not be written; starting empty.")
          return empty
        }
        return saved
      }
    }
    return result ?? empty
  }

  /// Whether anything on disk says this install has EVER held a snippets store.
  ///
  /// The single reader of the only question the seed needs answered, and it is deliberately
  /// broader than "does `snippets.json` exist". Three rounds of review found three ways the
  /// primary file can be absent from an install that had one, and every one of them ran through
  /// the corrupt-file archive: the archive removes the file, so a read reports `missing`, so the
  /// seed would write six John Doe examples into somebody's data-loss moment where they read as
  /// recovered content.
  ///
  /// A `.corrupted-<uuid>` sibling is that history, and it needs no write to create — which is
  /// what makes it strictly stronger than writing an empty file back, the previous fix. That
  /// write could fail, and the failure landed on exactly the launch after a data loss.
  ///
  /// Deleting the archives is not covered and should not be: a user who cleared them out has
  /// asked for a clean slate, and a clean slate is what they get.
  private func hasStoreHistoryOnDisk() -> Bool {
    if FileManager.default.fileExists(atPath: fileURL.path) { return true }
    let directory = fileURL.deletingLastPathComponent()
    let siblings =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return siblings.contains { $0.hasPrefix("\(Self.fileName).corrupted-") }
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
      // NOT repaired by writing an empty file back. That was the round-2 fix and it is
      // dominated by `hasStoreHistoryOnDisk` below, which answers the same question and also
      // survives the case where the replacement write itself fails. One reader for one
      // question, and no write on a read path.
      Self.logger.error(
        "snippets.json could not be parsed; archived and starting empty. \(String(describing: error), privacy: .public)"
      )
      return .archivedCorrupt
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
    let saved = advanceGeneration()
    return SnippetVocabulary(
      snippets: vocabulary.snippets, keyword: vocabulary.keyword, generation: saved)
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
      case .missing, .archivedCorrupt:
        // A save is allowed after an archive: the old bytes are safe under their own name, and
        // refusing here would leave the user unable to type anything new.
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

  // MARK: - Import

  /// What "the same list" means for an import's stale check: id, trigger and expansion.
  /// `createdAt` is left out on purpose; it never changes after creation and carries nothing
  /// the review showed.
  private struct Fingerprint: Hashable {
    let id: UUID
    let trigger: String
    let expansion: String

    init(_ snippet: Snippet) {
      id = snippet.id
      trigger = snippet.trigger
      expansion = snippet.expansion
    }
  }

  /// Counted, not a set: a hand-edited file can carry the same entry twice, and a set would
  /// read `[a, a]` on disk as equal to the `[a]` the review was built against.
  private static func fingerprints(_ snippets: [Snippet]) -> [Fingerprint: Int] {
    var counts: [Fingerprint: Int] = [:]
    for snippet in snippets { counts[Fingerprint(snippet), default: 0] += 1 }
    return counts
  }

  /// One atomic write of every approved snippet, or nothing (#2997).
  ///
  /// `baseline` is the list the review screen was built against. Inside the lock the current
  /// list is compared to it first; a mismatch throws `listChangedDuringReview` and writes
  /// nothing, so a snippet another EnviousWispr process added during the review can neither be
  /// duplicated nor silently overwritten. Then every addition is validated against the current
  /// list AND the additions before it, in O(n + m): one key per current snippet, one lookup
  /// per addition. Never `validate(_:against:)` per addition, whose linear scan would be
  /// 5,000 × the whole list inside the lock. The first invalid addition refuses the whole
  /// batch. Accepted snippets go in at the front in review order, like `upsert`, in one save.
  ///
  /// Add-only, with fresh ids: unlike `validate`, an addition is never excused from colliding
  /// with a snippet that carries its own id, because an import never edits in place.
  public func importSnippets(
    _ additions: [Snippet], reviewedAgainst baseline: [Snippet]
  ) throws -> SnippetImportReceipt {
    // Empty additions are a store-level no-op: no lock, no save, no generation bump. The flow
    // model already returns "nothing approved" before reaching here; this is the second
    // boundary so the store cannot be made to rewrite its file for nothing. No disk read
    // either: `load()` takes the blocking lock and can archive a corrupt file. The vocabulary
    // returned is a placeholder no caller adopts (`commitImport` publishes nothing for an
    // empty receipt).
    guard !additions.isEmpty else {
      return SnippetImportReceipt(
        vocabulary: SnippetVocabulary(
          snippets: baseline, keyword: SnippetVocabulary.defaultKeyword, generation: 0),
        addedIDs: [])
    }
    var added: [UUID] = []
    let vocabulary = try mutate { current in
      guard Self.fingerprints(current.snippets) == Self.fingerprints(baseline) else {
        throw SnippetStoreError.listChangedDuringReview
      }
      // collisionKey -> the trigger that owns it. The FIRST owner is kept, as `validate`'s
      // linear scan names the first; a hand-edited file is the only way to hold two.
      var keys: [String: String] = [:]
      for snippet in current.snippets {
        if let key = snippet.collisionKey, keys[key] == nil { keys[key] = snippet.trigger }
      }
      var accepted: [Snippet] = []
      accepted.reserveCapacity(additions.count)
      for snippet in additions {
        // The same three rules as `validate`, expressed through the key set.
        guard let key = snippet.collisionKey else { throw SnippetValidationError.triggerEmpty }
        guard !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw SnippetValidationError.expansionEmpty
        }
        if let existing = keys[key] {
          throw SnippetValidationError.duplicateTrigger(existing: existing)
        }
        keys[key] = snippet.trigger
        accepted.append(snippet)
        added.append(snippet.id)
      }
      var snippets = current.snippets
      snippets.insert(contentsOf: accepted, at: 0)
      return SnippetVocabulary(
        snippets: snippets, keyword: current.keyword, generation: current.generation)
    }
    return SnippetImportReceipt(vocabulary: vocabulary, addedIDs: added)
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
