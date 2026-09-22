import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

// MARK: - Auto-learn with Undo (#996, 2026-09-21 plan §3.1 steps 8 and 10)
//
// A judged spelling fix is SAVED AT ONCE and a two-second pill offers Undo
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
  /// `CustomWordSaveHelper.saveAndConfirm` in production: nil means the
  /// spelling is on the word now.
  let save: (CustomWord, String) -> String?
  /// `CustomWordsCoordinator.remove(id:)` in production: nil means no error.
  let remove: (UUID) -> String?
  /// `CustomWordsCoordinator.update(_:)` in production: nil means no error.
  let update: (CustomWord) -> String?
  /// Remove a user OVERRIDE of a built-in WITHOUT tombstoning the built-in,
  /// so the built-in shows again exactly as before the learn. `remove(id:)`
  /// cannot do this: it tombstones any built-in the removed word's canonical
  /// matches. Production binds this to `CustomWordsCoordinator.removeUserOverride(id:)`.
  let removeOverride: (UUID) -> String?
  /// `CustomWordsManager.restoreBuiltinAndLearn(canonical:alias:)` in
  /// production, through the words coordinator so the live list republishes.
  let restoreBuiltinAndLearn: (String, String) -> BuiltinRestore
  /// `CustomWordsManager.redeleteRestoredBuiltin(id:)` in production, through
  /// the words coordinator: nil means no error.
  let redeleteRestoredBuiltin: (UUID) -> String?
  /// `WordSuggestionService.classifyByHeuristic` in production.
  let classify: (String) -> WordCategory?
}

/// The three auto-learn rows plus the shared refusal row, typed like the
/// `TelemetryService.learn*` emitters so a test spy records the same shape.
@MainActor
protocol LearnedCorrectionTelemetrySink: AnyObject {
  typealias T = TelemetryService.LearnFromEditsTelemetry
  func learnAdded(state: T.AddedState)
  func learnUndoShown()
  func learnUndone(kind: T.UndoKind, outcome: T.UndoOutcome)
  func learnSaveFailed(reason: T.SaveFailure)
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
    /// `learn_undo_shown` fires once, at the first admission.
    var admitted = false
  }

  private let vocabulary: LearnedCorrectionVocabularyAccess
  private let telemetry: any LearnedCorrectionTelemetrySink
  private let now: () -> Date
  private let makeID: () -> UUID
  private weak var presenter: (any LearnedCorrectionPresenting)?

  /// At most one: a new learn replaces it (the earlier add stays, its Undo
  /// window ends), and every presentation end deletes it.
  private(set) var undoRecord: UndoRecord?

  init(
    vocabulary: LearnedCorrectionVocabularyAccess,
    telemetry: any LearnedCorrectionTelemetrySink,
    now: @escaping () -> Date = Date.init,
    makeID: @escaping () -> UUID = UUID.init
  ) {
    self.vocabulary = vocabulary
    self.telemetry = telemetry
    self.now = now
    self.makeID = makeID
  }

  func attach(presenter: any LearnedCorrectionPresenting) {
    self.presenter = presenter
  }

  // MARK: - Step 8: learn

  /// Save a judged correction now. `original` is the misheard form the user
  /// replaced, `corrected` what they typed, `expectedTarget` what the filter
  /// saw at judge time. Returns after the write is proven (or refused) and the
  /// pill offered.
  @discardableResult
  func learn(original: String, corrected: String, expectedTarget: LearnTargetState) -> LearnOutcome {
    let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
    let original = original.trimmingCharacters(in: .whitespacesAndNewlines)

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
    let state: T.AddedState
    let kind: LearnedCorrectionPillModel.Kind
    switch target {
    case .existing(let live):
      var updated = live
      updated.aliases.append(original)
      updated.learnedAliases.append(original)
      let saveError = vocabulary.save(updated, original)
      // A target that is no longer in the live list after the write is a
      // different failure from a write that did not land on it: the word
      // vanished between the read that chose it and the save (plan §3.1
      // failure table, `target_gone`).
      guard vocabulary.userWords().contains(where: { $0.id == live.id }) else {
        return refuse(canonical: corrected, reason: .targetGone)
      }
      if saveError != nil {
        return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
      }
      wordID = live.id
      operation = .updated
      preSave = live
      state = .existingWord
      kind = .updated
    case .packOverride(let converted):
      // `proposalTarget` already applied `ownedByUser()`; the id is the pack's.
      var override = converted
      override.aliases.append(original)
      override.learnedAliases.append(original)
      if vocabulary.save(override, original) != nil {
        return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
      }
      wordID = converted.id
      operation = .updated
      preSave = nil
      state = .packOverride
      kind = .updated
    case .new:
      switch vocabulary.restoreBuiltinAndLearn(corrected, original) {
      case .restored(let outcome):
        wordID = outcome.word.id
        operation = .restoredBuiltin(outcome.preState)
        preSave = nil
        state = .existingWord
        kind = .updated
      case .failed:
        return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
      case .notFound:
        let word = CustomWord(
          id: makeID(), canonical: corrected, aliases: [original],
          category: vocabulary.classify(corrected) ?? .general, source: .user,
          learnedAliases: [original], learnedAt: now())
        if vocabulary.save(word, original) != nil {
          return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
        }
        wordID = word.id
        operation = .added
        preSave = nil
        state = .newWord
        kind = .added
      }
    }

    // 5. Prove it: the live list, not the proposed value, is the snapshot.
    guard let postSave = vocabulary.userWords().first(where: { $0.id == wordID }),
      Self.covers(postSave, original: original)
    else {
      return refuse(canonical: corrected, reason: .vocabularyWriteFailed)
    }

    // 6. Replacing the record ends the earlier Undo window before any
    //    presenter reentrancy. The overlay's learned-pill route owns visual
    //    replacement; the outgoing pill is not closed separately.
    let pill = LearnedCorrectionPillModel(
      id: makeID(), wordID: wordID, canonical: postSave.canonical, kind: kind)
    undoRecord = UndoRecord(
      pillID: pill.id, wordID: wordID, operation: operation, preSave: preSave,
      postSave: postSave, kind: kind == .added ? .added : .updated)
    telemetry.learnAdded(state: state)
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
  func undo(pillID: UUID) -> UndoOutcome {
    guard let record = undoRecord, record.pillID == pillID else {
      presenter?.close(pillID: pillID)
      return .stale
    }
    undoRecord = nil
    // Known limit (final review 2026-09-22): this reads the live list THIS
    // process holds. A second instance of the app writing the same word to
    // the shared file inside the two-second window is not seen here; the
    // manager's own reload-before-write applies the inverse by id. Two
    // instances never run together outside a dev-and-release UAT, and a
    // locked compare-and-write transaction would be a new manager contract.
    let live = vocabulary.userWords().first { $0.id == record.wordID }
    guard live == record.postSave else {
      telemetry.learnUndone(kind: record.kind, outcome: .alreadyChanged)
      presenter?.close(pillID: pillID)
      return .alreadyChanged
    }
    let refusal: String?
    switch record.operation {
    case .added:
      refusal = vocabulary.remove(record.wordID)
    case .updated:
      if let preSave = record.preSave, preSave.source == .builtin {
        // A live built-in gained a sound-alike, which persisted a user
        // override. The exact pre-state is "no override": remove it without
        // a tombstone and the built-in shows again as it was.
        refusal = vocabulary.removeOverride(record.wordID)
      } else if let preSave = record.preSave {
        refusal = vocabulary.update(preSave)
      } else {
        // Pack override: the user word did not exist; removing it reveals
        // the pack term again.
        refusal = vocabulary.remove(record.wordID)
      }
    case .restoredBuiltin:
      refusal = vocabulary.redeleteRestoredBuiltin(record.wordID)
    }
    // Prove the pre-state landed before saying so.
    let after = vocabulary.userWords().first { $0.id == record.wordID }
    let landed: Bool
    switch record.operation {
    case .added, .restoredBuiltin: landed = after == nil
    case .updated: landed = after == record.preSave
    }
    guard refusal == nil, landed else {
      telemetry.learnUndone(kind: record.kind, outcome: .failed)
      presenter?.showUndoError(LearnedCorrectionUndoError(pillID: pillID))
      return .failed
    }
    telemetry.learnUndone(kind: record.kind, outcome: .undone)
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
