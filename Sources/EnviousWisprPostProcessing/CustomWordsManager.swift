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
      minSimilarityOverride: word.minSimilarityOverride,
      learnedAliases: word.learnedAliases
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
  /// Another process currently holds the cross-process lock (#1690). Thrown
  /// only by the non-blocking explicit mutation paths; nothing was written.
  case libraryBusy
  /// The lock file itself could not be opened, or `flock` failed for a
  /// reason other than contention (#1690), e.g. permissions or disk full.
  case coordinationUnavailable
  /// `restoreBuiltinAndLearn` found no tombstoned built-in for that canonical
  /// on fresh disk state, or a user word already claims it (#996). Nothing
  /// was written; the learn path reports it as "target gone".
  case noRestorableBuiltin

  /// The same sentences in fixed English, for app.log: a log line must read the same whatever
  /// language the app runs in (#3142 G6). `errorDescription` is the on-screen copy.
  package var diagnosticDescription: String {
    switch self {
    case .unreadableExistingFile:
      return "Your saved words could not be read. Nothing was changed. Try again."
    case .corruptedExistingFile:
      return
        "Your saved words file was damaged and moved aside for recovery. No edit or import was applied."
    case .unusableValue:
      return
        "That word or spelling can't be saved. It may be too long, or contain characters that aren't part of a word."
    case .libraryBusy:
      return
        "Your word list is being updated by another EnviousWispr window. Nothing was changed. Try again."
    case .coordinationUnavailable:
      return "Your saved words could not be updated safely. Nothing was changed. Try again."
    case .noRestorableBuiltin:
      return "That word is no longer where it was. Nothing was changed."
    }
  }

  package var errorDescription: String? {
    switch self {
    case .unreadableExistingFile:
      return String(
        localized:
          "Your saved words could not be read. Nothing was changed. Try again.",
        comment:
          "Your Words: error. The saved list could not be read.")
    case .corruptedExistingFile:
      return String(
        localized:
          "Your saved words file was damaged and moved aside for recovery. No edit or import was applied.",
        comment:
          "Your Words: error. The saved list was damaged.")
    case .unusableValue:
      return String(
        localized:
          "That word or spelling can't be saved. It may be too long, or contain characters that aren't part of a word.",
        comment:
          "Your Words: error. A word or misheard form could not be saved.")
    case .libraryBusy:
      return String(
        localized:
          "Your word list is being updated by another EnviousWispr window. Nothing was changed. Try again.",
        comment:
          "Your Words: error. Another window holds the list.")
    case .coordinationUnavailable:
      return String(
        localized:
          "Your saved words could not be updated safely. Nothing was changed. Try again.",
        comment:
          "Your Words: error. Saving is briefly unavailable.")
    case .noRestorableBuiltin:
      return String(
        localized:
          "That word is no longer where it was. Nothing was changed.",
        comment:
          "Your Words: error. A built-in word could not be restored.")
    }
  }
}

/// What a learned word replaced, so Undo can put it back exactly (#996).
/// Today's only case: the word's canonical was a built-in the user had
/// deleted; the learn path restored it as a user-owned override. Undo
/// re-deletes the built-in (`redeleteRestoredBuiltin`) rather than "updating"
/// a word that did not exist before.
package enum LearnedWordPreState: Sendable, Equatable {
  case deletedBuiltin(id: UUID)
}

/// The receipt of `restoreBuiltinAndLearn`: the typed pre-state, the word
/// exactly as it was persisted (the coordinator's post-save snapshot), and
/// the merged library after the write.
package struct RestoredBuiltinLearnOutcome: Sendable {
  package let preState: LearnedWordPreState
  package let word: CustomWord
  package let words: [CustomWord]

  package init(preState: LearnedWordPreState, word: CustomWord, words: [CustomWord]) {
    self.preState = preState
    self.word = word
    self.words = words
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
  private let store: CustomWordsFileStore
  /// The on-disk schema every word-policy transform edits; owned by the store (#4086).
  private typealias CustomWordsFile = CustomWordsFileStore.CustomWordsFile

  /// Where the live word list is kept.
  ///
  /// Exposed so the export path can refuse to write ONTO it (#1686). Choosing
  /// it as an export destination would atomically replace the app's own
  /// storage with the transfer-document schema; the next load would find a
  /// file it cannot parse, archive it as corrupt, and the user would have
  /// destroyed their dictionary by exporting it.
  /// `nonisolated`: this is a path computation with no state, and the export
  /// writer runs off the main actor.
  /// The learning memory lives beside this dictionary (#3975), so a
  /// temp-file manager in a test gets a temp-file memory too.
  package var learnMemoryURL: URL {
    store.fileURL.deletingLastPathComponent().appendingPathComponent(LearnMemory.fileName)
  }

  nonisolated package static var liveFileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("EnviousWispr", isDirectory: true)
      .appendingPathComponent("custom-words.json")
  }

  public init() {
    store = CustomWordsFileStore()
  }

  /// Test seam (#648): inject an explicit file URL so unit tests can hit a
  /// per-test temp file instead of the production Application Support path.
  /// Production code always uses the zero-arg `init()`. Bible §9.3 disk
  /// round-trip coverage was missing from Phase 3b; this seam closes it.
  // periphery:ignore - test seam
  package init(fileURL: URL) {
    store = CustomWordsFileStore(fileURL: fileURL)
  }

  // MARK: - Built-in Defaults

  public static let builtinDefaults: [BuiltinWord] = [
    BuiltinWord(
      id: "enviouswispr",
      word: CustomWord(
        canonical: "EnviousWispr",
        aliases: [
          "envious whisper", "envious wisper", "envious whispr",
          "envious visper", "envious cisper", "mbs cisper",
          "in vious wispr", "envy us wispr", "NVS Visper", "NBS Vesper",
          // Added 2026-09-01 from the founder's own library, where each of these
          // is a mishearing his recognizer actually produced. They are kept
          // verbatim rather than tidied: the alias has to match what the engine
          // emits, not what the phrase looks like written down.
          "envious wispr", "Enviousvisper", "NVSBesper", "NVSBSPur",
          "NVIS VICPRSO", "EnvyS Visper", "senvy wpr", "Dambius Bispe",
          // Added 2026-09-30 (#3339) from the founder's app logs (`[RAW ASR]`,
          // 2026-09-14..30): forms the shipped list did not already fix, run
          // through the real corrector. Verbatim for the same reason as above.
          "MBS Visper", "MVS Visper", "MBS Vesper", "MBS Whisper", "NVIS VISPR",
          "NVIS Whisper", "Envy S Whisper", "envy as whisper", "envy as whisker",
          "Envice whisper", "NvSvisker", "VS Visper",
        ],
        category: .brand
      )),
    BuiltinWord(
      id: "eg1",
      word: CustomWord(
        canonical: "EG-1",
        // Our own on-device polish model. Every alias here carries the DIGIT,
        // and that is the whole design rather than a stylistic preference.
        //
        // **The spelled-out "one" forms were proposed and REMOVED, measured
        // rather than reasoned about.** The fuzzy multi-word pass matches a
        // two-token alias against any two-token phrase close enough to it, and
        // English is full of near neighbours: "egg one" ate "she cracked an egg
        // on the pan", and "E G one" ate "the item is e g on the list". Both came
        // out with "EG-1" swallowing the following preposition. Matching is
        // case-insensitive, so dropping only the lowercase spelling would have
        // changed nothing.
        //
        // "EG1" is a single token and therefore reaches the single-word fuzzy
        // pass; its neighbours are checked as standing controls rather than
        // assumed safe.
        //
        // The cost is stated rather than hidden: a user who says "EG one" and
        // whose recognizer writes it out in words gets no correction. That is a
        // missed fix, and the alternative was corrupting ordinary sentences.
        // `BuiltinDictionaryCorrectionTests` keeps every one of those sentences,
        // so re-adding a spelled-out form fails a test rather than shipping.
        aliases: ["EG 1", "E G 1", "EG-one", "EG1"],
        category: .brand
      )),
    BuiltinWord(
      id: "enviouslabs",
      word: CustomWord(
        canonical: "Envious Labs",
        // #3339: "MVS Labs" .. "NVS laps" are the founder's logged mishearings; the
        // NVS/MBS/NBS Labs forms follow the same letter confusions logged for
        // EnviousWispr.
        aliases: [
          "envious laps", "MVS Labs", "NVIS Labs", "NVIS LAPS", "NVS laps", "NVS Labs",
          "MBS Labs", "NBS Labs",
        ],
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
        // Both are everyday English words ("the cat clawed the sofa"), so they are
        // check-only: `WordCorrector` never swaps them, and the Learned Word Check
        // asks the model whether this sentence means Claude (founder 2026-09-30,
        // #3339). Claude is the only built-in routed this way. Because of this entry
        // the step also runs for a user with no learned words, on a take whose text
        // holds "clod" or "clawed"; the fix needs an available checker.
        aliases: ["clod", "clawed"],
        category: .brand,
        learnedAliases: ["clod", "clawed"]
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

  // MARK: - Public API

  /// Why the most recent `load()` returned nil; nil after a successful load
  /// or a legitimate first run (#1646). Owned by `CustomWordsFileStore`.
  package var lastLoadFailure: CustomWordsInitialLoadFailure? { store.lastLoadFailure }

  /// Test seam forwarded to `CustomWordsFileStore.afterFileExistsCheckForTesting`.
  package var afterFileExistsCheckForTesting: (() -> Void)? {
    get { store.afterFileExistsCheckForTesting }
    set { store.afterFileExistsCheckForTesting = newValue }
  }

  /// Load the effective word list: built-in defaults (minus tombstones) + user words.
  /// Returns nil only on unrecoverable I/O failure or a corrupted (archived)
  /// file — `lastLoadFailure` says which (#1646).
  public func load() -> [CustomWord]? {
    guard let file = store.resolveCurrentFile() else { return nil }
    return CustomWordsMutationPolicy.mergedWords(file: file, builtins: Self.builtinDefaults)
  }

  /// One read of the persisted library AND its durable bulk-import-enrichment
  /// total together (#1701 Chunk 2), so a caller — `CustomWordsCoordinator`,
  /// the sole AppKit adapter — can never see one without the other. Existing
  /// `load()` stays a words-only convenience for every untouched consumer;
  /// this is additive, sharing the identical resolution cascade.
  package func loadSnapshot() -> CustomWordsLibrarySnapshot? {
    guard let file = store.resolveCurrentFile() else { return nil }
    return CustomWordsLibrarySnapshot(
      words: CustomWordsMutationPolicy.mergedWords(file: file, builtins: Self.builtinDefaults),
      pendingEnrichmentBatchTotal: file.pendingEnrichmentBatchTotal)
  }

  /// Word list filtered to `enrichmentPending == true` (#1701 Chunk 2) — the
  /// durable bulk-import-enrichment queue IS this scan over live state, never
  /// a separately-tracked in-memory job list. Returns nil only on the same
  /// unrecoverable read failure `load()`/`loadSnapshot()` report.
  package func loadPendingEnrichmentWords() -> [CustomWord]? {
    guard let file = store.resolveCurrentFile() else { return nil }
    return CustomWordsMutationPolicy.mergedWords(file: file, builtins: Self.builtinDefaults).filter(\.enrichmentPending)
  }

  /// Two-way self-heal (#1701 Chunk 2, Codex Chunk 2 review finding 2b) — a
  /// state normal operation should never produce, but tolerated defensively
  /// rather than treated as fatal:
  /// - Pending words exist but no durable total: repairs the total to the
  ///   current live pending count.
  /// - No pending words exist but a total is stuck non-nil (e.g. the last
  ///   pending word was deleted, whose checkpoint result then found nothing
  ///   to apply and so never reached the total-clearing check): clears it.
  /// No-op write when nothing needs repairing. Returns the resulting
  /// (possibly just-repaired) total either way, so the caller always learns
  /// the true current denominator. Called by the background coordinator
  /// before it begins draining.
  package func repairPendingEnrichmentTotalIfNeeded() throws -> Int? {
    try store.performLockedTransaction { file in
      CustomWordsEnrichmentPolicy.repairPendingTotal(in: &file)
    }
  }

  /// Test seam forwarded to `CustomWordsFileStore.lockSyscall`.
  package var lockSyscall: (Int32, Int32) -> Int32 {
    get { store.lockSyscall }
    set { store.lockSyscall = newValue }
  }

  /// Phase 3b (#631): debounced writer that bumps `frequencyUsed` and
  /// `lastUsed` on each source `CustomWord`. Bible §9.3.
  ///
  /// Debounce policy:
  /// - Aggregate increments in `pendingIncrements` (per UUID).
  /// - Flush sync when total pending count >= 50.
  /// - Otherwise schedule a 30s timer flush (cancel + reschedule on each call).
  /// - On flush: one locked load-transform-save via `performLockedTransaction`
  ///   bumps `frequencyUsed` and sets `lastUsed` for each pending UUID found
  ///   in the persisted file (#1690).
  ///
  /// IDs not found in the persisted file (rare: file edited concurrently,
  /// built-in term not yet in file) are skipped silently, and a snapshot
  /// that matches nothing writes nothing. An unreadable, corrupted, busy, or
  /// contended file (#1690) requeues the WHOLE captured snapshot and
  /// reschedules the debounce timer instead of dropping it — see
  /// `requeuePendingIncrementSnapshot`. Any OTHER save failure is logged and
  /// genuinely dropped, not retried: this remains a best-effort writer for
  /// that narrower class of failure, and the next correction starts a fresh
  /// accumulator.
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

    do {
      try store.performLockedTransaction { file -> (value: Void, shouldSave: Bool) in
        var changed = false
        for (id, increment) in snapshot {
          guard let idx = file.words.firstIndex(where: { $0.id == id }) else { continue }
          file.words[idx].frequencyUsed += increment.count
          // Merge, don't assign (#1690 cloud review): the freshly loaded
          // `lastUsed` may already be newer than this snapshot's timestamp if
          // a sibling process's own, later-captured flush acquired the lock
          // first — the same max() merge `requeuePendingIncrementSnapshot`
          // already uses below, applied here against the persisted value too.
          file.words[idx].lastUsed = max(
            file.words[idx].lastUsed ?? .distantPast, increment.lastTimestamp)
          changed = true
        }
        guard changed else { return ((), false) }
        return ((), true)
      }
    } catch let persistenceError as CustomWordsPersistenceError {
      switch persistenceError {
      case .unreadableExistingFile, .corruptedExistingFile, .libraryBusy, .coordinationUnavailable:
        // Best-effort writer (#1646, extended #1690): requeue instead of
        // dropping so the increments survive to the next flush attempt.
        requeuePendingIncrementSnapshot(snapshot)
      case .unusableValue, .noRestorableBuiltin:
        // Never actually thrown on this path today — this method never calls
        // the isStorable-gated authoring doors `add`/`update` use, nor the
        // learn path's `restoreBuiltinAndLearn` — but these cases keep it
        // from silently falling into the requeue policy meant for lock/read
        // failures if that ever changed.
        Task {
          await AppLogger.shared.log(
            "CustomWordsManager: recordReplacements flush failed: \(persistenceError.diagnosticDescription)",
            level: .info, category: "CustomWords"
          )
        }
      }
    } catch {
      // An arbitrary save failure (e.g. disk full mid-write) is logged and
      // genuinely dropped, not requeued — preserving the pre-#1690 policy
      // that this narrower class of failure is not retried.
      Task {
        await AppLogger.shared.log(
          "CustomWordsManager: recordReplacements flush failed: \(error.localizedDescription)",
          level: .info, category: "CustomWords"
        )
      }
    }
  }

  /// Merges a flush snapshot back into any already-pending increments — adds
  /// counts, keeps the later timestamp, never overwrites what's already
  /// queued — and reschedules the debounce timer, since `flushPendingIncrements`
  /// already cancelled it on entry; without that, a quiet session would
  /// strand the requeued increments in memory until app exit (cloud review,
  /// PR #1647). Shared by every persistence failure that must not drop a
  /// captured usage-count increment (#1690).
  private func requeuePendingIncrementSnapshot(_ snapshot: [UUID: PendingIncrement]) {
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
        "CustomWordsManager: flush skipped — words file unreadable, corrupted, or contended; increments requeued",
        level: .info, category: "CustomWords"
      )
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
    guard CustomWordsMutationPolicy.isStorable(trimmed) else { throw CustomWordsPersistenceError.unusableValue }
    guard CustomWordsMutationPolicy.everyAliasIsStorable(word.aliases) else {
      throw CustomWordsPersistenceError.unusableValue
    }
    guard
      !words.contains(where: {
        $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
      })
    else { return }

    let merged = try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.add(
        word: word, trimmed: trimmed, to: &file, builtins: Self.builtinDefaults)
    }
    words = merged
  }

  /// Bulk-insert custom words with a single file read + write. Mirrors
  /// `add(word:to:)` per word — canonical trim, reject-empty, case-insensitive
  /// de-dupe (against existing terms AND earlier entries in this same batch),
  /// alias sanitize, and the tombstoned-built-in restore branch — but collapses
  /// the O(n) per-word locked load/save cycle into one of each so a large
  /// import (thousands of names) never rewrites the file per word.
  ///
  /// Returns the UUIDs of the user words this call actually appended, in input
  /// order. De-duplicated inputs and tombstoned-built-in restores are NOT in the
  /// returned set: the caller (contacts import) treats the result as the
  /// import's owned set for bulk-removal, and a restored built-in is not
  /// import-owned.
  public func addBatch(_ incoming: [CustomWord], to words: inout [CustomWord]) throws
    -> [UUID]
  {
    let (createdIDs, merged) = try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.addBatch(
        incoming, existing: words, to: &file, builtins: Self.builtinDefaults)
    }
    words = merged
    return createdIDs
  }

  public func remove(id: UUID, from words: inout [CustomWord]) throws {
    let word = words.first { $0.id == id }
    let merged = try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.remove(
        id: id, word: word, from: &file, builtins: Self.builtinDefaults)
    }
    words = merged
  }

  /// Bulk-remove by ID with a single file read + write. Mirrors `remove(id:)`
  /// per ID — including tombstoning a built-in whose canonical matches a removed
  /// word — but collapses to one locked load/save cycle. IDs not present are
  /// skipped. Used by the contacts-import bulk-remove pill (#636) to avoid an
  /// O(n) per-word rewrite when clearing a large import.
  public func removeBatch(ids: [UUID], from words: inout [CustomWord]) throws {
    guard !ids.isEmpty else { return }
    let idSet = Set(ids)
    let merged = try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.removeBatch(
        ids: ids, idSet: idSet, existing: words, from: &file, builtins: Self.builtinDefaults)
    }
    words = merged
  }

  // MARK: - Learned words over a deleted built-in (#996)

  /// The learn path's answer to a corrected word that is a built-in the user
  /// deleted: ordinary `add` would only clear the tombstone and DISCARD the
  /// sound-alike (its restore branch above), and a revealed built-in is
  /// immutable, so there is nowhere to put the alias. This does the whole
  /// thing in ONE locked transaction from fresh disk state: clear the
  /// tombstone and persist a user-owned override with the built-in's UUID,
  /// its aliases plus `alias`, and `alias` marked as learned. `learnedAt`
  /// stays nil: the user did not create this word, they brought it back.
  ///
  /// Refuses (nothing written) when no tombstoned built-in matches on disk,
  /// or a user word already claims that canonical: both mean the world moved
  /// between judge and save, and the caller reports "target gone". An
  /// unstorable alias refuses like every other authoring door.
  package func restoreBuiltinAndLearn(canonical: String, alias: String) throws
    -> RestoredBuiltinLearnOutcome
  {
    let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CustomWordsMutationPolicy.isStorable(trimmedAlias) else { throw CustomWordsPersistenceError.unusableValue }
    return try store.performLockedTransaction { file in
      try CustomWordsMutationPolicy.restoreBuiltinAndLearn(
        trimmedCanonical: trimmedCanonical, trimmedAlias: trimmedAlias, in: &file,
        builtins: Self.builtinDefaults)
    }
  }

  /// Remove a user OVERRIDE of a built-in without tombstoning the built-in,
  /// so the shipped built-in shows again exactly as it did before the
  /// override existed (#996 auto-learn Undo of a live built-in that gained a
  /// sound-alike). `remove(id:)` cannot do this: it tombstones any built-in
  /// the removed word's canonical matches. One locked transaction from fresh
  /// disk state; idempotent (an absent override writes nothing); unrelated
  /// words and tombstones survive. Returns the merged library.
  package func removeUserOverride(id: UUID) throws -> [CustomWord] {
    try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.removeUserOverride(
        id: id, from: &file, builtins: Self.builtinDefaults)
    }
  }

  /// Undo for `restoreBuiltinAndLearn`: remove the override with that UUID and
  /// put the built-in's tombstone back, in ONE locked transaction, returning
  /// the merged library. Idempotent: an override already gone and a tombstone
  /// already present are left as they are, and nothing is written when both
  /// hold. Unrelated words and tombstones written meanwhile survive, because
  /// the transaction starts from fresh disk state.
  package func redeleteRestoredBuiltin(id: UUID) throws -> [CustomWord] {
    try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.redeleteRestoredBuiltin(
        id: id, in: &file, builtins: Self.builtinDefaults)
    }
  }

  // MARK: - Import commit (#1665, epic #1619 PR-F2b)

  /// Apply a reviewed import — additions AND replacements — in ONE atomic
  /// write, or write nothing at all. Built on PR-P0's strict loader: an
  /// existing-but-unreadable file fails closed, touching neither disk nor the
  /// caller's list.
  ///
  /// Every key comparison here is a PERSISTENCE question, so it uses
  /// `importPersistenceKey` (the dictionary's own `trimmed.lowercased()` dedup
  /// rule, owned by `CustomWordsMutationPolicy` since #4086), never the compare
  /// engine's stronger matching key (PR-F2a).
  package func commitImport(
    _ plan: CustomWordsImportCommitPlan, to words: inout [CustomWord]
  ) throws -> CustomWordsImportCommitReceipt {
    let outcome: (CustomWordsImportCommitReceipt, [CustomWord]?)
    do {
      outcome = try store.performLockedTransaction { file in
        try CustomWordsImportPolicy.commit(
          plan, to: &file, builtins: Self.builtinDefaults,
          backup: { store.writePreImportBackup() })
      }
    } catch let persistenceError as CustomWordsPersistenceError {
      switch persistenceError {
      case .unreadableExistingFile, .corruptedExistingFile:
        throw CustomWordsImportCommitError.unreadableLibrary
      case .libraryBusy, .coordinationUnavailable:
        // Propagate unchanged — a lock problem is not "the library is
        // unreadable," and the coordinator's honest retry message for these
        // cases is the correct one to show (#1690).
        throw persistenceError
      case .unusableValue, .noRestorableBuiltin:
        // Never actually thrown on this path — commitImport never calls the
        // isStorable-gated authoring doors `add`/`update` use, nor the learn
        // path's `restoreBuiltinAndLearn` — but these cases keep it from
        // silently collapsing into .unreadableLibrary if that ever changed.
        throw persistenceError
      }
    }

    // (8) Publish only after the wrapper's write succeeded — this line only
    // runs once `performLockedTransaction` has returned normally, which only
    // happens after `saveFileWhileLocked` itself succeeded whenever
    // `shouldSave` was true. All-Skip and every thrown validation/staleness
    // error skip this entirely, matching the pre-#1690 contract exactly.
    if let merged = outcome.1 {
      words = merged
    }
    return outcome.0
  }

  // MARK: - Bulk-import enrichment checkpoint (#1701 Chunk 2)

  /// Merge-safe, pending-gated checkpoint. For each result: reload the live
  /// word by ID under the SAME lock this saves with, apply only if it still
  /// has `enrichmentPending == true` — first durable terminal action wins, so
  /// a late result for a word another writer already checkpointed or
  /// Cancel already cleared is silently skipped, never resurrecting the flag
  /// and never applying a second time — append sanitized, nonduplicate
  /// generated aliases to whatever aliases are there RIGHT NOW (never a
  /// caller-supplied snapshot that could have gone stale across the await
  /// before this call), clear the flag, leave every other field untouched. A
  /// missing/deleted ID is skipped, never resurrected. Reapplying the
  /// identical result is idempotent: a second pass finds
  /// `enrichmentPending == false` already and no-ops.
  ///
  /// A generated alias clears the SAME `WordCorrector` ownership index the
  /// import commit path's `enforceAliases` is built on, but ONLY the newly
  /// generated alias is validated against it — never a touched word's
  /// pre-existing aliases, which `enforceAliases`'s own touched-order replay
  /// would otherwise re-evaluate and could silently drop even though this
  /// checkpoint never intended to touch them (Codex Chunk 2 review round 2
  /// finding 1: reusing `enforceAliases` wholesale let one touched word's
  /// PRE-EXISTING alias lose to another touched word's PRE-EXISTING alias in
  /// the same batch — neither was generated content). So a generated guess
  /// can never collide with another word's canonical or ANY existing alias,
  /// human-authored or otherwise (D17), while every already-persisted alias
  /// on every word — touched or not — is left completely untouched. `applied`
  /// reports exactly which generated aliases actually landed per touched
  /// word (finding 6).
  ///
  /// The durable total is cleared whenever the freshly-computed live pending
  /// count is zero, unconditionally — never gated behind whether THIS batch
  /// itself changed anything (Codex Chunk 2 review finding 2b: a checkpoint
  /// whose only result referenced an already-deleted word changes nothing
  /// itself, but the delete may have been what brought the live count to
  /// zero, and that must still clear the total).
  package func applyEnrichmentResults(
    _ results: [CustomWordEnrichmentResult]
  ) throws -> CustomWordsEnrichmentCheckpointOutcome {
    try store.performLockedTransaction { file in
      CustomWordsEnrichmentPolicy.applyResults(results, to: &file, builtins: Self.builtinDefaults)
    }
  }

  /// Durable Cancel: one locked reload-and-sweep that clears
  /// `enrichmentPending` on every word CURRENTLY found `true` in the freshly
  /// reloaded file — never a caller's potentially-stale in-memory target
  /// list — and clears the durable total to nil in the same transaction.
  /// Returns the resulting snapshot so the caller can atomically adopt both.
  package func cancelEnrichment() throws -> CustomWordsLibrarySnapshot {
    try store.performLockedTransaction { file in
      CustomWordsEnrichmentPolicy.cancel(in: &file, builtins: Self.builtinDefaults)
    }
  }
  public func update(word: CustomWord, in words: inout [CustomWord]) throws {
    guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
    let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    // Same authoring door as `add`, same reason it throws: see there.
    guard CustomWordsMutationPolicy.isStorable(trimmed) else { throw CustomWordsPersistenceError.unusableValue }
    guard CustomWordsMutationPolicy.everyAliasIsStorable(word.aliases) else {
      throw CustomWordsPersistenceError.unusableValue
    }
    var edited = CustomWordsMutationPolicy.sanitizeForPersistence(word)
    edited.canonical = trimmed

    // An edit makes the word the user's, whatever it started as (#1680).
    // Editing a built-in produces a user override, but the value still carries
    // `source: .builtin` from `builtinDefaults` and `source` is a `let`, so it
    // is reconstructed here. Applied ONCE, before both the file write and the
    // in-memory publish: re-tagging only the file copy leaves the live list
    // still claiming `.builtin`, and an export taken right after the edit —
    // which filters on `source == .user` — would silently omit the user's own
    // change until the next launch decoded it. (No-op for words already `.user`.)
    let sanitized = edited.ownedByUser()

    // An edit that MOVES a built-in's canonical away has to retire the
    // built-in too (mirrors the commitImport tombstone rule, #1668) —
    // otherwise the built-in still matches no user word, so `mergedWords`
    // keeps showing it beside the rename and the user gets two words where
    // they edited one (#1670). A same-canonical edit (alias-only change)
    // must NOT tombstone: the override already hides the built-in on its
    // own, and recording a tombstone would persist a deletion the user never
    // performed.
    let previousCanonical = words[index].canonical

    // Publish the freshly merged file, not a manual patch of the caller's
    // stale array (#1690 cloud review): the other five ordinary mutations
    // already do this, so any OTHER change a sibling process saved while
    // this lock was held stays visible instead of being silently dropped
    // until the next reload or mutation.
    let merged = try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.update(
        word: word, sanitized: sanitized, previousCanonical: previousCanonical, in: &file,
        builtins: Self.builtinDefaults)
    }
    words = merged
  }

  /// Bulk-update existing words by ID with a single file read + write. Mirrors
  /// `update(word:)` per word — canonical trim, reject-empty, alias sanitize —
  /// but collapses the per-word locked load/save cycle into one of each so the
  /// contacts-import alias enrichment can flush a batch of generated aliases
  /// without an O(n) per-word rewrite (#636 follow-up).
  ///
  /// An ID not present in the file is skipped (no-op), NOT appended — unlike
  /// `update(word:)`, which appends a missing id as a built-in override.
  /// Enrichment must never resurrect a word the user deleted mid-job. Returns
  /// with `words` untouched if nothing matched.
  public func updateBatch(_ updates: [CustomWord], to words: inout [CustomWord]) throws {
    guard !updates.isEmpty else { return }
    let merged = try store.performLockedTransaction { file in
      CustomWordsMutationPolicy.updateBatch(updates, in: &file, builtins: Self.builtinDefaults)
    }
    guard let merged else { return }
    words = merged
  }
}
