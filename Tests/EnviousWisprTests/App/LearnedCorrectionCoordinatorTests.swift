import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

// MARK: - Doubles

@MainActor
final class LearnedTelemetrySpy: LearnedCorrectionTelemetrySink {
  enum Event: Equatable {
    case added(T.AddedState)
    case undoShown
    case undone(T.UndoKind, T.UndoOutcome)
    case saveFailed(T.SaveFailure)
  }
  private(set) var events: [Event] = []
  func learnAdded(state: T.AddedState) { events.append(.added(state)) }
  func learnUndoShown() { events.append(.undoShown) }
  func learnUndone(kind: T.UndoKind, outcome: T.UndoOutcome) {
    events.append(.undone(kind, outcome))
  }
  func learnSaveFailed(reason: T.SaveFailure) { events.append(.saveFailed(reason)) }
}

@MainActor
final class LearnedPresenterSpy: LearnedCorrectionPresenting {
  enum Call: Equatable {
    case show(LearnedCorrectionPillModel)
    case undone(UUID)
    case error(LearnedCorrectionSaveError)
    case undoError(UUID)
    case close(UUID)
  }
  private(set) var calls: [Call] = []
  /// Every pill shown, in order (the watcher tests read this).
  var offers: [LearnedCorrectionPillModel] {
    calls.compactMap {
      if case .show(let pill) = $0 { return pill }
      return nil
    }
  }
  var onOffer: ((LearnedCorrectionPillModel) -> Void)?
  func show(pill: LearnedCorrectionPillModel) {
    calls.append(.show(pill))
    onOffer?(pill)
  }
  func showUndone(pillID: UUID) { calls.append(.undone(pillID)) }
  func showError(_ error: LearnedCorrectionSaveError) { calls.append(.error(error)) }
  func showUndoError(_ error: LearnedCorrectionUndoError) { calls.append(.undoError(error.pillID)) }
  func close(pillID: UUID) { calls.append(.close(pillID)) }
}

/// A scripted library. Every write lands on `userWords` the way the manager
/// would persist it (aliases trimmed, marks a subset), unless scripted to
/// refuse (`saveRefusal` ...) or to lie (`silent` ...: report success, write
/// nothing).
@MainActor
final class LearnedLibraryFake {
  var userWords: [CustomWord] = []
  var packTerms: [CustomWord] = []
  /// Built-ins the user deleted, by canonical, with the built-in's value.
  var deletedBuiltins: [CustomWord] = []
  var saveRefusal: String?
  var removeRefusal: String?
  var updateRefusal: String?
  var removeOverrideRefusal: String?
  var redeleteRefusal: String?
  var restoreFails = false
  var silentSave = false
  var silentRemove = false
  var silentUpdate = false
  /// Runs once, at the start of the first `save`, after the coordinator
  /// resolved its target: the race window.
  var beforeWrite: (() -> Void)?
  private var reads = 0
  private(set) var saves: [(CustomWord, String)] = []
  private(set) var removes: [UUID] = []
  private(set) var overrideRemoves: [UUID] = []
  private(set) var updates: [CustomWord] = []
  private(set) var redeletes: [UUID] = []

  private func persist(_ word: CustomWord) -> CustomWord {
    var out = word
    out.aliases = word.aliases.map { $0.trimmingCharacters(in: .whitespaces) }
    out.learnedAliases = out.aliases.filter { word.learnedAliases.contains($0) }
    return out
  }

  var access: LearnedCorrectionVocabularyAccess {
    LearnedCorrectionVocabularyAccess(
      userWords: { [unowned self] in
        self.reads += 1
        return self.userWords
      },
      packTerms: { [unowned self] in self.packTerms },
      save: { [unowned self] word, spelling in
        let race = self.beforeWrite
        self.beforeWrite = nil
        race?()
        self.saves.append((word, spelling))
        if let refusal = self.saveRefusal { return refusal }
        if self.silentSave { return nil }
        let persisted = self.persist(word.ownedByUser())
        if let i = self.userWords.firstIndex(where: { $0.id == word.id }) {
          self.userWords[i] = persisted
        } else {
          self.userWords.append(persisted)
        }
        return nil
      },
      remove: { [unowned self] id in
        self.removes.append(id)
        if let refusal = self.removeRefusal { return refusal }
        if self.silentRemove { return nil }
        self.userWords.removeAll { $0.id == id }
        return nil
      },
      update: { [unowned self] word in
        self.updates.append(word)
        if let refusal = self.updateRefusal { return refusal }
        if self.silentUpdate { return nil }
        if let i = self.userWords.firstIndex(where: { $0.id == word.id }) {
          self.userWords[i] = self.persist(word.ownedByUser())
        }
        return nil
      },
      removeOverride: { [unowned self] id in
        self.overrideRemoves.append(id)
        if let refusal = self.removeOverrideRefusal { return refusal }
        // The override goes; the built-in shows again as it shipped.
        guard let i = self.userWords.firstIndex(where: { $0.id == id }) else { return nil }
        let canonical = self.userWords[i].canonical
        if let builtin = CustomWordsManager.builtinDefaults.first(where: {
          $0.word.canonical == canonical
        }) {
          self.userWords[i] = builtin.word
        } else {
          self.userWords.remove(at: i)
        }
        return nil
      },
      restoreBuiltinAndLearn: { [unowned self] canonical, alias in
        if self.restoreFails { return .failed }
        guard
          let i = self.deletedBuiltins.firstIndex(where: {
            $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame
          })
        else { return .notFound }
        let builtin = self.deletedBuiltins.remove(at: i)
        var override = builtin.ownedByUser()
        override.aliases.append(alias)
        override.learnedAliases.append(alias)
        let persisted = self.persist(override)
        self.userWords.append(persisted)
        return .restored(
          RestoredBuiltinLearnOutcome(
            preState: .deletedBuiltin(id: builtin.id), word: persisted, words: self.userWords))
      },
      redeleteRestoredBuiltin: { [unowned self] id in
        self.redeletes.append(id)
        if let refusal = self.redeleteRefusal { return refusal }
        guard let i = self.userWords.firstIndex(where: { $0.id == id }) else { return nil }
        self.userWords.remove(at: i)
        // The tombstone is back: the built-in is deleted again, as it shipped.
        if let builtin = CustomWordsManager.builtinDefaults.first(where: { $0.word.id == id }) {
          self.deletedBuiltins.append(builtin.word)
        }
        return nil
      },
      classify: { _ in .person })
  }
}

// MARK: - Suite

/// A judged fix is saved at once, proven on disk, offered with Undo for one
/// pill, and put back exactly or not at all (#996, 2026-09-21 plan §3.1
/// steps 8 and 10).
@MainActor
@Suite("Learned correction coordinator: save now, exact Undo (#996)", .tags(.productOutcome))
struct LearnedCorrectionCoordinatorTests {
  typealias T = TelemetryService.LearnFromEditsTelemetry

  struct Fixture {
    let library: LearnedLibraryFake
    let telemetry: LearnedTelemetrySpy
    let presenter: LearnedPresenterSpy
    let coordinator: LearnedCorrectionCoordinator
    let ids: [UUID]
  }

  private static let learnedAt = Date(timeIntervalSince1970: 1_800_000_000)

  private func fixture(ids: [UUID] = (0..<8).map { _ in UUID() }) -> Fixture {
    let library = LearnedLibraryFake()
    let telemetry = LearnedTelemetrySpy()
    let presenter = LearnedPresenterSpy()
    var remaining = ids
    let coordinator = LearnedCorrectionCoordinator(
      vocabulary: library.access, telemetry: telemetry, now: { Self.learnedAt },
      makeID: { remaining.isEmpty ? UUID() : remaining.removeFirst() })
    coordinator.attach(presenter: presenter)
    return Fixture(
      library: library, telemetry: telemetry, presenter: presenter, coordinator: coordinator,
      ids: ids)
  }

  private func shown(_ f: Fixture) -> LearnedCorrectionPillModel? {
    for call in f.presenter.calls.reversed() {
      if case .show(let pill) = call { return pill }
    }
    return nil
  }

  // MARK: Save

  @Test(
    "an existing user word gains the sound-alike, marked as learned; the pill says updated and Undo restores the exact pre-save word"
  )
  func existingWordSaveAndUndo() throws {
    let f = fixture()
    let saira = CustomWord(canonical: "Saira", aliases: ["sarah"], category: .person, priority: 2)
    f.library.userWords = [saira]

    let outcome = f.coordinator.learn(
      original: "sara", corrected: "Saira", expectedTarget: .existingWord(saira.id))
    let pill = try #require(shown(f))
    #expect(outcome == .learned(pill))
    #expect(pill.kind == .updated && pill.canonical == "Saira" && pill.wordID == saira.id)
    let live = try #require(f.library.userWords.first { $0.id == saira.id })
    #expect(live.aliases == ["sarah", "sara"] && live.learnedAliases == ["sara"])
    #expect(live.learnedAt == nil && live.priority == 2, "the rest of the word is untouched")
    #expect(f.telemetry.events == [.added(.existingWord)])
    let record = try #require(f.coordinator.undoRecord)
    #expect(record.preSave == saira && record.postSave == live && record.operation == .updated)

    #expect(f.coordinator.undo(pillID: pill.id) == .undone)
    #expect(f.library.userWords == [saira], "exact pre-save word")
    #expect(f.telemetry.events.last == .undone(.updated, .undone))
    #expect(f.presenter.calls.last == .undone(pill.id))
    #expect(f.coordinator.undoRecord == nil)
  }

  @Test(
    "a live built-in gains the sound-alike as a user override; Undo removes the override without deleting the built-in"
  )
  func liveBuiltinSaveAndUndo() throws {
    let f = fixture()
    let github = try #require(CustomWordsManager.builtinDefaults.first { $0.id == "github" }?.word)
    f.library.userWords = [github]
    let outcome = f.coordinator.learn(
      original: "git-hub", corrected: "GitHub", expectedTarget: .existingWord(github.id))
    let pill = try #require(shown(f))
    #expect(outcome == .learned(pill) && pill.kind == .updated)
    let live = try #require(f.library.userWords.first { $0.id == github.id })
    #expect(live.source == .user && live.aliases == ["git hub", "get hub", "git-hub"])
    #expect(live.learnedAliases == ["git-hub"])
    #expect(f.coordinator.undo(pillID: pill.id) == .undone)
    #expect(f.library.overrideRemoves == [github.id] && f.library.removes.isEmpty, "no tombstone")
    #expect(f.library.userWords == [github], "the built-in shows again as it shipped")
  }

  @Test(
    "a pack term becomes a user override carrying the pack's id; Undo removes the override so the pack term shows again"
  )
  func packOverrideSaveAndUndo() throws {
    let f = fixture()
    let pack = CustomWord(canonical: "Tuist", aliases: ["twist"], category: .brand, source: .pack)
    f.library.packTerms = [pack]

    let outcome = f.coordinator.learn(
      original: "to-ist", corrected: "Tuist", expectedTarget: .existingWord(pack.id))
    let pill = try #require(shown(f))
    #expect(outcome == .learned(pill) && pill.kind == .updated)
    let live = try #require(f.library.userWords.first { $0.id == pack.id })
    #expect(live.source == .user && live.aliases == ["twist", "to-ist"])
    #expect(live.learnedAliases == ["to-ist"])
    #expect(f.telemetry.events == [.added(.packOverride)])
    #expect(f.coordinator.undoRecord?.preSave == nil)

    #expect(f.coordinator.undo(pillID: pill.id) == .undone)
    #expect(f.library.userWords.isEmpty && f.library.removes == [pack.id])
    #expect(f.telemetry.events.last == .undone(.updated, .undone))
  }

  @Test(
    "a new word is created with one learned sound-alike, learnedAt, the classified category and the allocated id; the pill says added; Undo removes it"
  )
  func newWordSaveAndUndo() throws {
    let f = fixture()
    let outcome = f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    #expect(outcome == .learned(pill) && pill.kind == .added && pill.canonical == "Kwmala")
    let live = try #require(f.library.userWords.first)
    #expect(live.id == f.ids[0] && pill.id == f.ids[1], "word id then pill id, both allocated")
    #expect(live.aliases == ["kumala"] && live.learnedAliases == ["kumala"])
    #expect(live.learnedAt == Self.learnedAt && live.category == .person && live.source == .user)
    #expect(f.telemetry.events == [.added(.newWord)])
    #expect(f.coordinator.undoRecord?.operation == .added)

    #expect(f.coordinator.undo(pillID: pill.id) == .undone)
    #expect(f.library.userWords.isEmpty)
    #expect(f.telemetry.events.last == .undone(.added, .undone))
  }

  @Test("a deleted built-in is restored and learned in one step; Undo deletes it again exactly")
  func deletedBuiltinRestoreAndRedelete() throws {
    let f = fixture()
    let github = try #require(CustomWordsManager.builtinDefaults.first { $0.id == "github" }?.word)
    f.library.deletedBuiltins = [github]

    let outcome = f.coordinator.learn(original: "git-hub", corrected: "GitHub", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    #expect(outcome == .learned(pill) && pill.kind == .updated && pill.wordID == github.id)
    let live = try #require(f.library.userWords.first { $0.id == github.id })
    #expect(
      live.source == .user && live.aliases.last == "git-hub" && live.learnedAliases == ["git-hub"])
    #expect(live.learnedAt == nil, "the user brought it back, they did not create it")
    #expect(f.telemetry.events == [.added(.existingWord)])
    #expect(
      f.coordinator.undoRecord?.operation == .restoredBuiltin(.deletedBuiltin(id: github.id)))

    #expect(f.coordinator.undo(pillID: pill.id) == .undone)
    #expect(f.library.redeletes == [github.id] && f.library.userWords.isEmpty)
    #expect(f.library.deletedBuiltins == [github], "tombstone back, alias gone")
  }

  @Test("already covered (the race between judge and save): nothing written, no pill, no telemetry")
  func alreadyCoveredRace() {
    let f = fixture()
    f.library.userWords = [CustomWord(canonical: "Saira", aliases: ["sara"])]
    #expect(f.coordinator.learn(original: "Sara", corrected: "saira", expectedTarget: .newWord) == .alreadyCovered)
    #expect(f.library.saves.isEmpty && f.presenter.calls.isEmpty && f.telemetry.events.isEmpty)
    #expect(f.coordinator.undoRecord == nil)
  }

  @Test(
    "the target that vanished between the read and the write is a refused save with the error pill, and nothing lands"
  )
  func targetGoneBetweenReads() {
    let f = fixture()
    let saira = CustomWord(canonical: "Saira")
    f.library.userWords = [saira]
    // The word is deleted after the first read; the fake's `save` then
    // reports success but the reread finds no word with that id.
    f.library.beforeWrite = { f.library.userWords = [] }
    f.library.silentSave = true
    #expect(
      f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .existingWord(saira.id))
        == .refused(.targetGone))
    #expect(f.telemetry.events == [.saveFailed(.targetGone)])
    #expect(
      f.presenter.calls == [
        .error(LearnedCorrectionSaveError(canonical: "Saira", reason: .targetGone))
      ])
    #expect(f.coordinator.undoRecord == nil)
  }

  @Test(
    "a word the judge saw as an existing target that is gone by the time the save resolves is refused as target_gone, never recreated"
  )
  func targetGoneBeforeResolution() {
    let f = fixture()
    let saira = CustomWord(canonical: "Saira")
    // The filter saw Saira; the user deleted it while the judge was running.
    f.library.userWords = []
    #expect(
      f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .existingWord(saira.id))
        == .refused(.targetGone))
    #expect(f.library.saves.isEmpty && f.library.userWords.isEmpty, "nothing was written")
    #expect(f.telemetry.events == [.saveFailed(.targetGone)])
    #expect(f.coordinator.undoRecord == nil)
    // Control: the same spelling expected NEW is created.
    let g = fixture()
    g.library.userWords = []
    if case .learned = g.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord) {
    } else {
      Issue.record("expected the new word to be learned")
    }
    #expect(g.library.userWords.map(\.canonical) == ["Saira"])
  }

  @Test(
    "a word deleted and re-created under the same spelling while the judge ran is a different word: refused as target_gone, the stranger untouched"
  )
  func replacedTargetIsNotWrittenTo() {
    let f = fixture()
    let a = CustomWord(canonical: "Saira", category: .person)
    let b = CustomWord(canonical: "Saira", category: .brand)
    // The filter saw A; by the time the verdict lands, A is gone and B stands
    // in its place with the same canonical.
    f.library.userWords = [b]
    #expect(
      f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .existingWord(a.id))
        == .refused(.targetGone))
    #expect(f.library.saves.isEmpty && f.library.userWords == [b], "B was not written to")
    #expect(f.telemetry.events == [.saveFailed(.targetGone)])
    // Control: expected B itself is learned onto B.
    let g = fixture()
    g.library.userWords = [b]
    if case .learned = g.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .existingWord(b.id)) {
    } else {
      Issue.record("expected the existing word B to be updated")
    }
    #expect(g.library.userWords.first?.aliases == ["sara"])
  }

  @Test(
    "the original already belongs to another word as a trigger: refused as alias_owned_elsewhere, nothing written"
  )
  func originalOwnedElsewhere() {
    let f = fixture()
    f.library.userWords = [
      CustomWord(canonical: "Sara", aliases: ["sarah"]),
      CustomWord(canonical: "Saira"),
    ]
    #expect(
      f.coordinator.learn(original: "sarah", corrected: "Saira", expectedTarget: .newWord) == .refused(.aliasOwnedElsewhere))
    #expect(f.library.saves.isEmpty && f.telemetry.events == [.saveFailed(.aliasOwnedElsewhere)])
  }

  @Test(
    "the corrected phrase is another word's trigger: refused as alias_owned_elsewhere, nothing written"
  )
  func correctedOwnedElsewhere() {
    let f = fixture()
    f.library.userWords = [CustomWord(canonical: "Tuist", aliases: ["twist"])]
    #expect(
      f.coordinator.learn(original: "twizt", corrected: "twist", expectedTarget: .newWord) == .refused(.aliasOwnedElsewhere))
    #expect(f.library.saves.isEmpty)
  }

  @Test("a refused vocabulary write shows the error pill and offers no Undo")
  func saveRefusal() {
    let f = fixture()
    f.library.saveRefusal = "disk full"
    #expect(
      f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
        == .refused(.vocabularyWriteFailed))
    #expect(f.telemetry.events == [.saveFailed(.vocabularyWriteFailed)])
    #expect(f.coordinator.undoRecord == nil && f.library.userWords.isEmpty)
  }

  @Test("a save that reports success but writes nothing is a failure: no pill, no learn_added")
  func silentNonWrite() {
    let f = fixture()
    f.library.silentSave = true
    #expect(
      f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
        == .refused(.vocabularyWriteFailed))
    #expect(
      f.library.saves.count == 1 && f.telemetry.events == [.saveFailed(.vocabularyWriteFailed)])
    #expect(shown(f) == nil)
  }

  @Test("postSave is what the library holds after the write, not what was proposed")
  func postSaveComesFromTheReread() throws {
    let f = fixture()
    f.library.userWords = [CustomWord(canonical: "Saira")]
    // The fake trims on persist; the coordinator proposes " sara " untrimmed.
    f.coordinator.learn(original: " sara ", corrected: "Saira", expectedTarget: .newWord)
    let proposed = try #require(f.library.saves.first?.0)
    let record = try #require(f.coordinator.undoRecord)
    #expect(proposed.aliases == ["sara"], "the coordinator trims before proposing")
    #expect(record.postSave == f.library.userWords[0])
    #expect(record.postSave.learnedAliases == ["sara"])
  }

  @Test(
    "a second learn ends the first pill's Undo window: the first add stays, its record is gone, the overlay replaces the pill"
  )
  func newLearnInvalidatesThePreviousRecord() throws {
    let f = fixture()
    f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
    let first = try #require(shown(f))
    f.coordinator.learn(original: "twist", corrected: "Tuist", expectedTarget: .newWord)
    let second = try #require(shown(f))
    #expect(f.coordinator.undoRecord?.pillID == second.id)
    #expect(f.presenter.calls == [.show(first), .show(second)], "two shows, no separate close")
    #expect(f.coordinator.undo(pillID: first.id) == .stale)
    #expect(f.library.userWords.map(\.canonical) == ["Kwmala", "Tuist"], "the first add stays")
  }

  // MARK: Presentation callbacks

  @Test("admission counts learn_undo_shown once; a repeat or a stale admission counts nothing")
  func admissionCountsOnce() throws {
    let f = fixture()
    f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    f.coordinator.pillAdmitted(pillID: pill.id)
    f.coordinator.pillAdmitted(pillID: pill.id)
    f.coordinator.pillAdmitted(pillID: UUID())
    #expect(f.telemetry.events == [.added(.newWord), .undoShown])
  }

  @Test(
    "expiry, decline or preemption removes the record; Undo afterwards is stale and writes nothing")
  func presentationEndRemovesTheRecord() throws {
    let f = fixture()
    f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    f.coordinator.pillEnded(pillID: UUID())
    #expect(f.coordinator.undoRecord != nil, "a stale end is a no-op")
    f.coordinator.pillEnded(pillID: pill.id)
    #expect(f.coordinator.undoRecord == nil)
    #expect(f.coordinator.undo(pillID: pill.id) == .stale)
    #expect(f.library.removes.isEmpty && f.library.userWords.count == 1)
    #expect(f.telemetry.events == [.added(.newWord)], "no undone row for a stale id")
  }

  // MARK: Undo exactness

  @Test(
    "Undo after the user changed the word (category, strictness or an alias) writes nothing and reports already_changed"
  )
  func changedLiveWordIsNotUndone() throws {
    let f = fixture()
    f.library.userWords = [CustomWord(canonical: "Saira")]
    f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    f.library.userWords[0].category = .brand
    #expect(f.coordinator.undo(pillID: pill.id) == .alreadyChanged)
    #expect(f.library.updates.isEmpty && f.library.removes.isEmpty)
    #expect(f.library.userWords[0].aliases == ["sara"] && f.library.userWords[0].category == .brand)
    #expect(f.telemetry.events.last == .undone(.updated, .alreadyChanged))
    #expect(f.presenter.calls.last == .close(pill.id))
    #expect(f.coordinator.undoRecord == nil)
  }

  @Test("Undo after the word was deleted by hand is already_changed")
  func deletedLiveWordIsNotUndone() throws {
    let f = fixture()
    f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    f.library.userWords = []
    #expect(f.coordinator.undo(pillID: pill.id) == .alreadyChanged)
    #expect(f.library.removes.isEmpty)
  }

  @Test(
    "an Undo write that is refused, or that reports success without landing, never shows Undone")
  func undoRefusalAndSilentNonWrite() throws {
    let f = fixture()
    f.coordinator.learn(original: "kumala", corrected: "Kwmala", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    f.library.removeRefusal = "locked"
    #expect(f.coordinator.undo(pillID: pill.id) == .failed)
    #expect(f.telemetry.events.last == .undone(.added, .failed))
    #expect(f.presenter.calls.last == .undoError(pill.id))
    #expect(f.library.userWords.count == 1, "the word stays")

    let g = fixture()
    g.library.userWords = [CustomWord(canonical: "Saira")]
    g.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord)
    let pill2 = try #require(shown(g))
    g.library.silentUpdate = true
    #expect(g.coordinator.undo(pillID: pill2.id) == .failed)
    #expect(!g.presenter.calls.contains(.undone(pill2.id)))
    #expect(g.telemetry.events.last == .undone(.updated, .failed))
  }

  @Test("a stale Undo (unknown pill) closes that pill and touches nothing")
  func staleUndo() {
    let f = fixture()
    let id = UUID()
    #expect(f.coordinator.undo(pillID: id) == .stale)
    #expect(f.presenter.calls == [.close(id)] && f.telemetry.events.isEmpty)
  }

  // MARK: Privacy

  @Test("telemetry carries enums only: no canonical, no alias, no id")
  func telemetryIsEnumsOnly() throws {
    let f = fixture()
    f.library.userWords = [CustomWord(canonical: "Saira")]
    f.coordinator.learn(original: "sara", corrected: "Saira", expectedTarget: .newWord)
    let pill = try #require(shown(f))
    f.coordinator.pillAdmitted(pillID: pill.id)
    f.coordinator.undo(pillID: pill.id)
    #expect(
      f.telemetry.events == [
        .added(.existingWord), .undoShown, .undone(.updated, .undone),
      ])
    // The spy's event type has no String or UUID payload, which is the point:
    // there is no place a word could ride.
    for event in f.telemetry.events {
      #expect(
        !String(describing: event).contains("Saira") && !String(describing: event).contains("sara"))
    }
  }
}
