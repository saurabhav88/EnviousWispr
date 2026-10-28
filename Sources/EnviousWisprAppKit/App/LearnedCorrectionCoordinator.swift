import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

// MARK: - Auto-learn with Undo (#996, 2026-09-21 plan §3.1 steps 8 and 10)
//
// A judged spelling fix is SAVED AT ONCE and a three-second pill offers Undo
// (founder 2026-09-21: "no accept, no reject. It just auto accepts with an
// undo button", Wispr Flow's shape). This coordinator owns the one vocabulary
// write, the exact Undo snapshot, and the three auto-learn telemetry rows. It
// holds no durable state: the Undo record lives only as long as its pill, so
// a crash between save and pill loses the Undo chance, never the word.
//
// Replaced the ask-first flow (a card with Accept/Reject, a Pending tab and a
// proposal ledger on disk) in the 2026-09-21 plan; nothing here persists
// anything but the word itself.

/// The vocabulary the coordinator reads and writes, as value closures so the
/// tests script every success, refusal, silent non-write and exact persisted
/// transformation. `userWords()` is a FRESH read each call: the coordinator
/// rereads after every write and compares exact values.
///
/// Every write runs inside `perform` (#4086): one learn or one Undo is ONE dictionary
/// command, so its memory check, target choice, write and proof see one library and no
/// other dictionary command runs in between.
struct LearnedCorrectionVocabularyAccess {
  /// What `restoreBuiltinAndLearn` answered, as the coordinator sees it.
  enum BuiltinRestore: Equatable {
    case restored(RestoredBuiltinLearnOutcome)
    /// No tombstoned built-in carries that canonical: create a new word.
    case notFound
    /// The manager refused or could not write.
    case failed

    static func == (lhs: Self, rhs: Self) -> Bool {
      switch (lhs, rhs) {
      case (.notFound, .notFound), (.failed, .failed): return true
      case (.restored(let a), .restored(let b)):
        return a.preState == b.preState && a.word == b.word && a.words == b.words
      default: return false
      }
    }
  }

  /// Current in-memory user words (values), reread on every call.
  let userWords: () -> [CustomWord]
  /// Terms of the ENABLED packs only.
  let packTerms: () -> [CustomWord]
  /// `CustomWordsCoordinator.saveLearned` in production. The second value is the word as
  /// the learn read it, or nil for a new word: an edit then lands only while the saved word
  /// still equals it. The answer is what the save's own transaction did.
  let save: @MainActor (CustomWord, CustomWord?) async -> CustomWordsCoordinator.LearnedSave
  /// `CustomWordsCoordinator.remove(id:expecting:)` in production; the answer says whether
  /// the write really happened (#4086).
  /// Undo's writes all carry the word as the learn left it (`postSave`); each applies only
  /// while the saved word still equals it, under the file lock, so a change saved
  /// meanwhile, in this window or another, is never overwritten.
  let remove: @MainActor (UUID, CustomWord) async -> CustomWordsCoordinator.UndoWrite
  /// `CustomWordsCoordinator.update(_:expecting:)` in production.
  let update: @MainActor (CustomWord, CustomWord) async -> CustomWordsCoordinator.UndoWrite
  /// Remove a user OVERRIDE of a built-in WITHOUT tombstoning the built-in,
  /// so the built-in shows again exactly as before the learn. `remove(id:)`
  /// cannot do this: it tombstones any built-in the removed word's canonical
  /// matches. Production binds this to `CustomWordsCoordinator.removeUserOverride(id:)`.
  let removeOverride: @MainActor (UUID, CustomWord) async -> CustomWordsCoordinator.UndoWrite
  /// `CustomWordsManager.restoreBuiltinAndLearn(canonical:alias:)` in
  /// production, through the words coordinator so the live list republishes.
  let restoreBuiltinAndLearn: @MainActor (String, String) async -> BuiltinRestore
  /// `CustomWordsManager.redeleteRestoredBuiltin(id:)` in production, through
  /// the words coordinator.
  let redeleteRestoredBuiltin:
    @MainActor (UUID, CustomWord) async -> CustomWordsCoordinator.UndoWrite
  /// `WordSuggestionService.classifyByHeuristic` in production.
  let classify: (String) -> WordCategory?
  /// `CustomWordsCoordinator.performAction` in production: runs one whole learn or Undo
  /// as one dictionary command. The writes above, called inside it, join that command.
  let perform: @MainActor (@escaping @MainActor () async -> Void) async -> Void
}

/// Carries an action's result out of `perform`, which returns nothing.
@MainActor private final class ActionResult<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// The three auto-learn rows, the shared refusal row and the user-refusal
/// row (#3975), typed like the `TelemetryService.learn*` emitters so a test
/// spy records the same shape.
@MainActor
protocol LearnedCorrectionTelemetrySink: AnyObject {
  typealias T = TelemetryService.LearnFromEditsTelemetry
  func learnAdded(state: T.AddedState, via: T.LearnVia)
  func learnUndoShown()
  /// `memory` nil = not an `undone` outcome, or the memory write did not land.
  func learnUndone(kind: T.UndoKind, outcome: T.UndoOutcome, via: T.LearnVia, memory: T.UndoMemory?)
  func learnSaveFailed(reason: T.SaveFailure)
  func learnRefusedByUser(source: T.RefusalSource, result: T.UndoMemory)
}

/// The production sink is `TelemetryService`; `LearnFromEditsWiring` wraps it
/// with the runtime's Debug logging sink.
extension TelemetryService: LearnedCorrectionTelemetrySink {}

/// What the pill shows (chunk 3b draws it). The mishearing is not on the
/// model: the pill names the correct word only (founder 2026-09-21), and the
/// Undo record is the one owner of what was added.
struct LearnedCorrectionPillModel: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    /// `Added “<canonical>” to Dictionary`.
    case added
    /// `“<canonical>” updated`: a sound-alike joined a word that existed.
    case updated
  }
  /// What the pill is showing. Only `.learned` draws the Undo button; the
  /// two results are same-identity morphs the reducer applies (chunk 3b).
  enum Phase: Sendable, Equatable {
    case learned
    /// `Undone`, 1.5 s, no button.
    case undone
    /// `Couldn’t undo`, 3 s, error tone, no button.
    case undoError
  }
  /// The pill's own identity; every presenter callback names it.
  let id: UUID
  let wordID: UUID
  let canonical: String
  let kind: Kind
  let phase: Phase

  init(id: UUID, wordID: UUID, canonical: String, kind: Kind, phase: Phase = .learned) {
    self.id = id
    self.wordID = wordID
    self.canonical = canonical
    self.kind = kind
    self.phase = phase
  }
}

/// A refused save, shown as `Couldn’t save “<canonical>”` for three seconds.
struct LearnedCorrectionSaveError: Sendable, Equatable {
  let canonical: String
  let reason: TelemetryService.LearnFromEditsTelemetry.SaveFailure
}

/// A refused or silent Undo, shown as `Couldn’t undo` on that pill.
struct LearnedCorrectionUndoError: Sendable, Equatable {
  let pillID: UUID
}

/// The overlay side (chunk 3b: a thin presenter over `OverlayDirector`).
/// Held weakly and attached late, like the card's presenter was.
@MainActor
protocol LearnedCorrectionPresenting: AnyObject {
  func show(pill: LearnedCorrectionPillModel)
  /// Morph the still-current pill into `Undone` (1.5 s, no button).
  func showUndone(pillID: UUID)
  func showError(_ error: LearnedCorrectionSaveError)
  func showUndoError(_ error: LearnedCorrectionUndoError)
  /// Close the pill without a result line (stale Undo, already changed).
  func close(pillID: UUID)
}

@MainActor @Observable
final class LearnedCorrectionCoordinator {
  typealias T = TelemetryService.LearnFromEditsTelemetry

  enum LearnOutcome: Equatable, Sendable {
    /// Saved and proven; the pill was offered.
    case learned(LearnedCorrectionPillModel)
    /// The target already carried the original: nothing written, no pill.
    case alreadyCovered
    /// Refused before or at the write; the error pill was shown.
    case refused(T.SaveFailure)
    /// The user refused this pair twice (#3975): nothing written, no pill,
    /// no `learn_save_failed`. The watcher counts it as `learn_blocked_seen`.
    case blocked
  }

  enum UndoOutcome: Equatable, Sendable {
    case undone
    /// The live word no longer equals the post-save snapshot: nothing written.
    case alreadyChanged
    /// The write was refused or did not land.
    case failed
    /// No record for that pill (expired, replaced, or already undone).
    case stale
  }

  /// What Undo has to reverse. `preSave` nil with `.updated` is the pack
  /// override case: the user word did not exist, so Undo removes it and the
  /// pack term shows again.
  enum UndoOperation: Equatable, Sendable {
    case added
    case updated
    case restoredBuiltin(LearnedWordPreState)
  }

  /// The one Undo authority (§3c): identity, exact pre-save and post-save
  /// values. `postSave` is what the live list held right after the write,
  /// never the value the coordinator proposed.
  struct UndoRecord: Equatable, Sendable {
    let pillID: UUID
    let wordID: UUID
    let operation: UndoOperation
    let preSave: CustomWord?
    let postSave: CustomWord
    let kind: T.UndoKind
    /// The learned pair (`CorrectionPairKey`), so an Undo records the user's
    /// "no" against exactly what was learned (#3975).
    let pairKey: String
    /// How the pair was learned; `learn_undone.via` copies it.
    let via: T.LearnVia
    /// `learn_undo_shown` fires once, at the first admission.
    var admitted = false
  }

  private let vocabulary: LearnedCorrectionVocabularyAccess
  /// Per-pair learning memory (#3975): the save-time block check and the
  /// user's "no" on Undo.
  private let memory: LearnMemory
  private let telemetry: any LearnedCorrectionTelemetrySink
  private let now: () -> Date
  private let makeID: () -> UUID
  private weak var presenter: (any LearnedCorrectionPresenting)?

  /// At most one: a new learn replaces it (the earlier add stays, its Undo
  /// window ends), and every presentation end deletes it.
  private(set) var undoRecord: UndoRecord?

  init(
    vocabulary: LearnedCorrectionVocabularyAccess,
    memory: LearnMemory,
    telemetry: any LearnedCorrectionTelemetrySink,
    now: @escaping () -> Date = Date.init,
    makeID: @escaping () -> UUID = UUID.init
  ) {
    self.vocabulary = vocabulary
    self.memory = memory
    self.telemetry = telemetry
    self.now = now
    self.makeID = makeID
  }

  func attach(presenter: any LearnedCorrectionPresenting) {
    self.presenter = presenter
  }

  // MARK: - Step 8: learn

  /// Save a judged or repeated correction now. `original` is the misheard
  /// form the user replaced, `corrected` what they typed, `expectedTarget`
  /// what the filter saw at judge time, `via` how it was learned (telemetry
  /// only; the save is identical). Returns after the write is proven (or
  /// refused) and the pill offered.
  @discardableResult
  func learn(
    original: String, corrected: String, expectedTarget: LearnTargetState,
    via: T.LearnVia = .judge
  ) async -> LearnOutcome {
    let result = ActionResult<LearnOutcome>(.blocked)
    await vocabulary.perform { [self] in
      result.value = await learnInsideAction(
        original: original, corrected: corrected, expectedTarget: expectedTarget, via: via)
    }
    return result.value
  }

  /// The learn itself, inside one dictionary command: the block check below sees every
  /// refusal an earlier command committed.
  private func learnInsideAction(
    original: String, corrected: String, expectedTarget: LearnTargetState,
    via: T.LearnVia
  ) async -> LearnOutcome {
    let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
    let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
    let pairKey = CorrectionPairKey.make(original: original, corrected: corrected)

    // 0. The single last door for a pair the user blocked (#3975): a judge
    //    answer that arrives late, or a held fix released later, can never
    //    save a pair blocked meanwhile.
    if memory.isBlocked(pairKey) { return .blocked }

    // 1. Resolve the target against fresh values, user words before pack terms.
    let userWords = vocabulary.userWords()
    let packTerms = vocabulary.packTerms()
    let target = CustomWordSaveHelper.proposalTarget(
      for: corrected, in: userWords, packTerms: packTerms)
    // The word the judge was asked about as an EXISTING target must still be
    // THAT word (plan §3.1 failure table, `target_gone`): gone entirely, or
    // replaced by another word with the same canonical while the judge ran,
    // and the correction is refused rather than recreated or attached to a
    // stranger that happens to spell the same.
    if case .existingWord(let expectedID) = expectedTarget {
      switch target {
      case .existing(let word), .packOverride(let word):
        if word.id != expectedID { return refuse(canonical: corrected, reason: .targetGone) }
      case .new:
        return refuse(canonical: corrected, reason: .targetGone)
      }
    }

    // 2. Both surfaces (the original as a trigger, the corrected phrase) must
    //    be free of another word's claim, the same check the candidate filter
    //    made; a claim that appeared since refuses.
    let targetID: UUID?
    switch target {
    case .existing(let word), .packOverride(let word): targetID = word.id
    case .new: targetID = nil
    }
    let index = WordCorrector.buildExactTriggerIndex(words: userWords + packTerms)
    for surface in [original, corrected] {
      if case .blocked = index.resolveAliasOwnership(for: surface, excludingOwnerID: targetID) {
        return refuse(canonical: corrected, reason: .aliasOwnedElsewhere)
      }
    }

    // 3. Already covered: the filter skips these; this is the race window.
    if case .existing(let word) = target, Self.covers(word, original: original) {
      return .alreadyCovered
    }
    if case .packOverride(let word) = target, Self.covers(word, original: original) {
      return .alreadyCovered
    }

    // 4. The one write.
    let wordID: UUID
    let operation: UndoOperation
    let preSave: CustomWord?
    // What this action's own write left, from its transaction (#4086): the Undo owns
    // exactly that change and nothing another writer did.
    let postSave: CustomWord
    let state: T.AddedState
    let kind: LearnedCorrectionPillModel.Kind
    switch target {
    case .existing(let live):
      var updated = live
      updated.aliases.append(original)
      updated.learnedAliases.append(original)
      let saved = await vocabulary.save(updated, live)
      guard case .saved(let before, let after) = saved else {
        // A target that is no longer in the live list after the write is a
        // different failure from a write that did not land on it: the word
        // vanished between the read that chose it and the save (plan §3.1
        // failure table, `target_gone`).
        guard let now = vocabulary.userWords().first(where: { $0.id == live.id }) else {
          return refuse(canonical: corrected, reason: .targetGone)
        }
        // Another writer gave the word this spelling meanwhile: nothing to learn, and no
        // Undo, because this action changed nothing.
        if saved == .notApplied, Self.covers(now, original: original) { return .alreadyCovered }
        return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
      }
      wordID = live.id
      operation = .updated
      preSave = before ?? live
      postSave = after
      state = .existingWord
      kind = .updated
    case .packOverride(let converted):
      // `proposalTarget` already applied `ownedByUser()`; the id is the pack's.
      var override = converted
      override.aliases.append(original)
      override.learnedAliases.append(original)
      guard case .saved(_, let after) = await vocabulary.save(override, nil) else {
        return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
      }
      wordID = converted.id
      operation = .updated
      preSave = nil
      postSave = after
      state = .packOverride
      kind = .updated
    case .new:
      switch await vocabulary.restoreBuiltinAndLearn(corrected, original) {
      case .restored(let outcome):
        wordID = outcome.word.id
        operation = .restoredBuiltin(outcome.preState)
        preSave = nil
        postSave = outcome.word
        state = .existingWord
        kind = .updated
      case .failed:
        return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
      case .notFound:
        let word = CustomWord(
          id: makeID(), canonical: corrected, aliases: [original],
          category: vocabulary.classify(corrected) ?? .general, source: .user,
          learnedAliases: [original], learnedAt: now())
        guard case .saved(_, let after) = await vocabulary.save(word, nil) else {
          return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
        }
        wordID = word.id
        operation = .added
        preSave = nil
        postSave = after
        state = .newWord
        kind = .added
      }
    }

    // 5. Prove it: the saved value, not the proposed one, is the snapshot.
    guard Self.covers(postSave, original: original) else {
      return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
    }

    // 6. Replacing the record ends the earlier Undo window before any
    //    presenter reentrancy. The overlay's learned-pill route owns visual
    //    replacement; the outgoing pill is not closed separately.
    let pill = LearnedCorrectionPillModel(
      id: makeID(), wordID: wordID, canonical: postSave.canonical, kind: kind)
    undoRecord = UndoRecord(
      pillID: pill.id, wordID: wordID, operation: operation, preSave: preSave,
      postSave: postSave, kind: kind == .added ? .added : .updated, pairKey: pairKey, via: via)
    telemetry.learnAdded(state: state, via: via)
    presenter?.show(pill: pill)
    return .learned(pill)
  }

  private func refuse(canonical: String, reason: T.SaveFailure) -> LearnOutcome {
    telemetry.learnSaveFailed(reason: reason)
    presenter?.showError(LearnedCorrectionSaveError(canonical: canonical, reason: reason))
    return .refused(reason)
  }

  // MARK: - Presentation callbacks (chunk 3b calls these)

  /// The pill was admitted to the overlay: `learn_undo_shown`, once.
  func pillAdmitted(pillID: UUID) {
    guard var record = undoRecord, record.pillID == pillID, !record.admitted else { return }
    record.admitted = true
    undoRecord = record
    telemetry.learnUndoShown()
  }

  /// The pill left the overlay without Undo (expired, declined, preempted,
  /// replaced): the Undo window is over. Stale ids are no-ops.
  func pillEnded(pillID: UUID) {
    guard let record = undoRecord, record.pillID == pillID else { return }
    undoRecord = nil
  }

  // MARK: - Step 10: undo

  /// Put back exactly what `learn` changed, only if the live word still equals
  /// the post-save snapshot; otherwise write nothing.
  @discardableResult
  func undo(pillID: UUID) async -> UndoOutcome {
    // Claimed at the click (#4086): the Undo may wait behind an earlier dictionary command,
    // and the pill expiring meanwhile must not take the accepted Undo with it.
    guard let record = undoRecord, record.pillID == pillID else {
      presenter?.close(pillID: pillID)
      return .stale
    }
    undoRecord = nil
    let result = ActionResult<UndoOutcome>(.stale)
    await vocabulary.perform { [self] in
      result.value = await undoInsideAction(record, pillID: pillID)
    }
    return result.value
  }

  /// The Undo itself, inside one dictionary command: the live-word check, the inverse
  /// write, its proof and the learning-memory "no" happen with no command in between.
  private func undoInsideAction(_ record: UndoRecord, pillID: UUID) async -> UndoOutcome {
    // This reads the live list THIS process holds. A change another window saved to the
    // shared file is caught by the writes below, which apply only while the saved word
    // still equals `postSave` under the file lock (#4086).
    let live = vocabulary.userWords().first { $0.id == record.wordID }
    guard live == record.postSave else {
      telemetry.learnUndone(
        kind: record.kind, outcome: .alreadyChanged, via: record.via, memory: nil)
      presenter?.close(pillID: pillID)
      return .alreadyChanged
    }
    let write: CustomWordsCoordinator.UndoWrite
    switch record.operation {
    case .added:
      write = await vocabulary.remove(record.wordID, record.postSave)
    case .updated:
      if let preSave = record.preSave, preSave.source == .builtin {
        // A live built-in gained a sound-alike, which persisted a user
        // override. The exact pre-state is "no override": remove it without
        // a tombstone and the built-in shows again as it was.
        write = await vocabulary.removeOverride(record.wordID, record.postSave)
      } else if let preSave = record.preSave {
        write = await vocabulary.update(preSave, record.postSave)
      } else {
        // Pack override: the user word did not exist; removing it reveals
        // the pack term again.
        write = await vocabulary.remove(record.wordID, record.postSave)
      }
    case .restoredBuiltin:
      write = await vocabulary.redeleteRestoredBuiltin(record.wordID, record.postSave)
    }
    // Prove the pre-state landed before saying so.
    let after = vocabulary.userWords().first { $0.id == record.wordID }
    let landed: Bool
    switch record.operation {
    case .added, .restoredBuiltin: landed = after == nil
    case .updated: landed = after == record.preSave
    }
    // The write found the word changed or already gone under the lock and wrote nothing:
    // nothing was undone, so no "no" is recorded (#4086).
    if write == .notApplied {
      telemetry.learnUndone(
        kind: record.kind, outcome: .alreadyChanged, via: record.via, memory: nil)
      presenter?.close(pillID: pillID)
      return .alreadyChanged
    }
    guard write == .applied, landed else {
      telemetry.learnUndone(kind: record.kind, outcome: .failed, via: record.via, memory: nil)
      presenter?.showUndoError(LearnedCorrectionUndoError(pillID: pillID))
      return .failed
    }
    // #3975: only a proven Undo is the user's "no". The memory key and the
    // refusal row ride only when the memory write committed.
    let memoryResult: T.UndoMemory?
    switch memory.recordUndo(record.pairKey) {
    case .committed(.watching): memoryResult = .watching
    case .committed(.blocked): memoryResult = .blocked
    case .notRemembered: memoryResult = nil
    }
    telemetry.learnUndone(
      kind: record.kind, outcome: .undone, via: record.via, memory: memoryResult)
    if let memoryResult { telemetry.learnRefusedByUser(source: .undo, result: memoryResult) }
    presenter?.showUndone(pillID: pillID)
    return .undone
  }

  // MARK: - Helpers

  #if DEBUG
    /// Local debug log only (plan §11 UAT tokens). Release logs no user text.
    static func debugLog(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "LearnFromEdits") }
    }
  #endif

  /// The target already carries the original as its canonical or a sound-alike.
  static func covers(_ word: CustomWord, original: String) -> Bool {
    let key = CorrectionPairKey.normalise(original)
    if CorrectionPairKey.normalise(word.canonical) == key { return true }
    return word.aliases.contains { CorrectionPairKey.normalise($0) == key }
  }
}
