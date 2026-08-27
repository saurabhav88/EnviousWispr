import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2381 — what one Quick Add actually does, from keypress to written word.
///
/// When this fails the user presses their shortcut and the wrong thing lands in their library: a word
/// gains a spelling twice, a pack term is "saved" and silently written nowhere, or a stale snapshot is
/// ranked so the panel offers words that no longer exist. Every one of those reports success.
///
/// Every collaborator is a function, so each branch is reachable without a window, a words file, or a
/// real selection — and so the assertions are about the DECISION rather than about a stub's shape.
@MainActor
@Suite("Quick Add orchestration — #2381", .tags(.productOutcome))
struct QuickAddCoordinatorTests {

  private final class Recorder {
    /// How many times `begin` went to the live reader. The menu door must never.
    var events: [QuickAddEvent] = []
    var saved: [CustomWord] = []
    var savedSpellings: [String] = []
    /// How many times the panel was asked to move to its compose stage. A COUNT, not the heard
    /// spelling: the coordinator stopped handing one over when the sheet was replaced by a stage of
    /// the panel, and the model that already holds it is the only thing that assembles the word.
    var beganNewWord = 0
    var refreshCalls = 0

    /// The user library, LIVE. Held here rather than captured by value so a test can change it
    /// between opening the panel and accepting a row — which is the whole shape of the staleness
    /// this suite has to reach, and is not reproducible against a frozen array.
    var userWords: [CustomWord] = []

    var outcomes: [QuickAddOutcome] {
      events.compactMap {
        if case .resolved(let outcome, _, _, _, _) = $0 { return outcome }
        return nil
      }
    }
    /// The `targetKind` of every resolution, which is a claim about WHAT WAS WRITTEN rather than
    /// about what the ranking showed — so it has to be asserted separately from the outcome.
    var targetKinds: [QuickAddTargetKind] {
      events.compactMap {
        if case .resolved(_, _, _, let kind, _) = $0 { return kind }
        return nil
      }
    }
    var opened: QuickAddEvent? { events.first { if case .opened = $0 { true } else { false } } }
  }

  private func word(_ canonical: String, aliases: [String] = [], source: WordSource = .user)
    -> CustomWord
  {
    CustomWord(canonical: canonical, aliases: aliases, source: source)
  }

  /// `begin` plus the presentation callback, which is what the wiring does and what a test asserting
  /// an `opened` event must reproduce.
  ///
  /// **The menu door carries its own outcome and must not read again.**
  ///
  /// The menu reads under a 0.25s-per-operation cap so a stalled Accessibility provider cannot hold
  /// the menu shut. Passing `nil` for a refusal made `begin` read AGAIN through the uncapped live
  /// reader, so clicking the deliberately-enabled blocked row repeated the same stalled operations
  /// under the system default — the stall moved from the menu to the panel and the bound bought
  /// nothing. Cloud review, PR #2427.
  ///
  /// The read COUNT is the assertion, not the refusal that comes out: a re-read of the same fixture
  /// produces the same refusal, so asserting the reason alone passes either way.
  /// **These two rows REPLACE a pair that counted reads, and the reason is worth stating (#2465).**
  /// The old pair asserted that the menu door does not re-read and that the hotkey door does, using
  /// a counted `readSelection` closure on the environment. That closure is gone: every door now
  /// hands `begin` an outcome somebody else obtained, so "the coordinator does not read" is true by
  /// construction rather than by assertion — there is nothing left to count.
  ///
  /// A count against a subject that no longer exists is a test that cannot fail, so what survives
  /// is the property the count was a proxy for: whatever a door was handed is what the panel is
  /// told, unchanged.
  @Test(
    "An acquired outcome reaches the panel untouched",
    arguments: [
      SelectionReader.Result.text("codecs"),
      .refused(.accessibilityNotTrusted),
      .refused(.copyRefused),
      .refused(.targetApplicationGone),
    ])
  func anAcquiredOutcomeIsCarried(result: SelectionReader.Result) throws {
    let (coordinator, _) = makeCoordinator()

    let model = try #require(
      coordinator.begin(door: .menuBar, selection: .acquired(outcome(result))))

    switch result {
    case .text(let text): #expect(model.heard == text)
    case .refused(let why): #expect(model.refusal == why)
    case .noSelection: #expect(model.refusal == .nothingSelected)
    }
  }

  /// The paired negative: door B is the one door that DOES transform what it is handed, because
  /// macOS gives it whatever was on the pasteboard and the ceiling and the empty check are
  /// properties of a selection rather than of the door it arrived through.
  @Test("The Services door still classifies the raw text it is handed")
  func theServiceDoorClassifies() throws {
    let (coordinator, _) = makeCoordinator()

    let padded = try #require(coordinator.begin(door: .service, selection: .text("   codecs \n")))
    #expect(padded.heard == "codecs")

    let empty = try #require(coordinator.begin(door: .service, selection: .text("   ")))
    #expect(empty.refusal == .nothingSelected)
  }

  /// **Telemetry must name the application the READ sampled, not whoever is frontmost now (#2465).**
  ///
  /// For the menu door this is reliably wrong the other way: the menu's read happens while the
  /// user's own app is frontmost, and by click time EnviousWispr is. So every menu-route
  /// acquisition used to be attributed to us, which makes the one field that says WHICH APPS need
  /// the clipboard fallback answer "ours". After the shortcut door's asynchronous wait it can be
  /// wrong too.
  ///
  /// The fixture's live lookup returns a DIFFERENT identifier from the outcome's on purpose: with
  /// both the same, this row would pass against the defect.
  @Test("An acquired outcome is attributed to the application it was sampled from")
  func acquiredOutcomesCarryTheirOwnBundleID() throws {
    let (coordinator, recorder) = makeCoordinator()

    let outcome = SelectionAcquisition.Outcome(
      result: .text("codecs"),
      context: .init(pid: 501, bundleIdentifier: "net.whatsapp.WhatsApp", focusedSubrole: nil),
      acquired: .clipboardCopy,
      acquisitionMs: 41,
      clipboardRestore: .restored)

    _ = coordinator.begin(door: .menuBar, selection: .acquired(outcome))
    coordinator.didOpen()

    guard case .opened(_, _, let bundle, _, _, _, _, let acquired, let ms, let restore) =
      try #require(recorder.opened)
    else {
      Issue.record("not an opened event")
      return
    }
    #expect(bundle == "net.whatsapp.WhatsApp", "the live lookup would have said com.apple.TextEdit")
    #expect(acquired == .clipboardCopy)
    #expect(ms == 41)
    #expect(restore == .restored)
  }

  /// The pair: the Services door has no sample of its own, so the live lookup is the only answer
  /// available and is still the right one. Without this row, "always use the outcome" would pass.
  @Test("The Services door still uses the live lookup, because it has no sample")
  func theServiceDoorUsesTheLiveLookup() throws {
    let (coordinator, recorder) = makeCoordinator()

    _ = coordinator.begin(door: .service, selection: .text("codecs"))
    coordinator.didOpen()

    guard case .opened(_, _, let bundle, _, _, _, _, let acquired, let ms, let restore) =
      try #require(recorder.opened)
    else {
      Issue.record("not an opened event")
      return
    }
    #expect(bundle == "com.apple.TextEdit")
    #expect(acquired == .handed, "macOS handed this text over; nothing was acquired")
    #expect(ms == nil, "a zero would be a real measurement of something that did not happen")
    #expect(restore == .notTouched)
  }

  /// Build an acquisition outcome for a test, with the fields no row here is about left neutral.
  private func outcome(_ result: SelectionReader.Result) -> SelectionAcquisition.Outcome {
    SelectionAcquisition.Outcome(
      result: result,
      context: .init(pid: 501, bundleIdentifier: "com.apple.TextEdit", focusedSubrole: nil),
      acquired: { if case .text = result { return .accessibility } else { return .nothing } }(),
      acquisitionMs: nil,
      clipboardRestore: .notTouched)
  }

  /// The two are separate in production on purpose: `opened` names an event the user can SEE, so it
  /// fires when a panel is on screen. Emitting it from `begin` made a panel that could not be
  /// measured leave an open with nothing to resolve it.
  ///
  /// `acquired` is what the SHORTCUT and MENU doors hand over since #2465: an outcome obtained
  /// before `begin` was called at all. `selectionOverride` is still the Services door's raw text.
  private func beginAndShow(
    _ coordinator: QuickAddCoordinator, door: QuickAddDoor = .hotkey,
    selectionOverride: String? = nil,
    acquired: SelectionReader.Result = .text("codecs")
  ) -> QuickAddPanelModel? {
    // The helper still takes text, because that is what almost every row is about. It maps to
    // `.text`, which is the Services door's shape — classification still happens inside `begin`.
    let model = coordinator.begin(
      door: door,
      selection: selectionOverride.map { .text($0) } ?? .acquired(outcome(acquired)))
    if model != nil { coordinator.didOpen() }
    return model
  }

  /// **No `selection` parameter since #2465.** The coordinator has no reader to seed: what it gets
  /// is decided per call at the door, so the fixture moved to `beginAndShow(acquired:)` where the
  /// row that cares can see it.
  private func makeCoordinator(
    refreshSucceeds: Bool = true,
    userWords: [CustomWord] = [],
    packTerms: [CustomWord] = [],
    saveFailure: String? = nil
  ) -> (QuickAddCoordinator, Recorder) {
    let recorder = Recorder()
    recorder.userWords = userWords
    var clock = Date(timeIntervalSince1970: 0)
    let environment = QuickAddCoordinator.Environment(
      frontmostBundleID: { "com.apple.TextEdit" },
      refreshWords: {
        recorder.refreshCalls += 1
        return refreshSucceeds
      },
      userWords: { recorder.userWords },
      packTerms: { packTerms },
      saveWord: { candidate, spelling in
        if let saveFailure { return saveFailure }
        recorder.saved.append(candidate)
        // Recorded so a test can assert the coordinator hands over the SELECTION, never the query.
        // The postcondition the real one checks lives in the wiring; what is checkable here is that
        // the spelling it would check is the right string.
        recorder.savedSpellings.append(spelling)
        return nil
      },
      beginNewWord: { recorder.beganNewWord += 1 },
      emit: { recorder.events.append($0) },
      now: {
        clock.addTimeInterval(0.01)
        return clock
      })
    return (QuickAddCoordinator(environment: environment), recorder)
  }

  // MARK: - Opening

  @Test("The library is re-read before anything is ranked")
  func refreshHappensBeforeRanking() throws {
    // A sibling instance or the Settings window can change the library after launch. Ranking a stale
    // snapshot offers words that no longer exist and hides ones that do.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])

    _ = beginAndShow(coordinator)

    #expect(recorder.refreshCalls == 1)
  }

  @Test("An unreadable library states a reason rather than ranking a stale snapshot")
  func anUnreadableLibraryStatesAReason() throws {
    // REWRITTEN in review round 1, and the previous version is why: it asserted `model == nil` plus
    // a resolved event, which is the defect written down as a contract. Reporting the failure to
    // telemetry is a fact about a dashboard; the user got a shortcut that did nothing visible,
    // which is indistinguishable from one that was never registered.
    let (coordinator, recorder) = makeCoordinator(
      refreshSucceeds: false, userWords: [word("Codex")])

    let model = try #require(beginAndShow(coordinator))

    #expect(model.refusal == .wordsUnavailable)
    // The stale snapshot half of the name is the part that was always right.
    #expect(model.ranking.candidates.isEmpty)
    #expect(recorder.events.contains { if case .failed = $0 { true } else { false } })
    // Opening is not resolving. A resolved event here closes a funnel the user is still inside.
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("Opening reports SHAPE, never the word itself")
  func openingReportsShapeOnly() throws {
    // The privacy boundary is the network and the test is whether user content crosses it. A scalar
    // count is shape; the string is not.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])

    _ = beginAndShow(coordinator)
    let opened = try #require(recorder.opened)

    guard case .opened(let door, let refusal, let bundle, let count, _, _, _, _, _, _) = opened else {
      Issue.record("not an opened event")
      return
    }
    #expect(door == .hotkey)
    #expect(refusal == nil)
    #expect(bundle == "com.apple.TextEdit")
    #expect(count == "codecs".unicodeScalars.count)
  }

  @Test("A refusal still opens the panel, carrying its reason")
  func aRefusalStillOpens() throws {
    let (coordinator, recorder) = makeCoordinator()

    let model = try #require(
      beginAndShow(coordinator, acquired: .refused(.accessibilityNotTrusted)))

    #expect(model.refusal == .accessibilityNotTrusted)
    #expect(recorder.opened != nil, "the panel opens on a stated reason, never a silent no-op")
  }

  @Test("No selection gets its OWN reason, never the one that blames the app")
  func noSelectionGetsItsOwnReason() throws {
    // This used to map onto `selectionUnavailable`, whose sentence names terminals and accuses the
    // frontmost app of withholding a selection. Pressing the shortcut having highlighted nothing is
    // the likeliest way to reach a refusal at all, so the commonest case got a confident diagnosis
    // of an app that had done nothing wrong. The old test asserted `refusal != nil`, which is true
    // of every member and so could not see it.
    let (coordinator, _) = makeCoordinator()

    let model = try #require(beginAndShow(coordinator, acquired: .noSelection))

    #expect(model.refusal == .nothingSelected)
    #expect(model.heard.isEmpty)
  }

  // MARK: - Accepting

  @Test("Accepting writes the heard spelling onto the chosen word")
  func acceptingWritesTheHeardSpelling() throws {
    let codex = word("Codex", aliases: ["codeks"])
    let (coordinator, recorder) = makeCoordinator(userWords: [codex])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    coordinator.accept(target, from: model)

    #expect(recorder.saved.count == 1)
    #expect(recorder.saved.first?.canonical == "Codex")
    #expect(recorder.saved.first?.aliases.contains("codecs") == true)
    #expect(recorder.saved.first?.aliases.contains("codeks") == true, "existing spellings survive")
    #expect(recorder.outcomes == [.accepted])
  }

  @Test("A pack term is converted to a user-owned word before it is written")
  func aPackTermIsConvertedBeforeWriting() throws {
    // `CustomWordsManager.update` looks an id up in the USER library. A pack term is not there, so
    // the call returns having written nothing and reporting success — a save that silently does not.
    let pack = word("codec", source: .pack)
    let (coordinator, recorder) = makeCoordinator(userWords: [], packTerms: [pack])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)
    #expect(target.isPackTerm)

    coordinator.accept(target, from: model)

    let saved = try #require(recorder.saved.first)
    #expect(saved.source == .user, "written as a pack term, it would have gone nowhere")
    #expect(saved.id == pack.id, "the override keeps the pack term's identity")
    #expect(saved.aliases.contains("codecs"))
  }

  @Test("A word that already carries the spelling is not written again")
  func anAlreadySavedWordIsNotWrittenAgain() throws {
    let codex = word("Codex", aliases: ["codecs"])
    let (coordinator, recorder) = makeCoordinator(userWords: [codex])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    coordinator.accept(target, from: model)

    #expect(recorder.saved.isEmpty, "writing again adds a duplicate and reports success")
    #expect(recorder.outcomes == [.alreadySaved], "a distinct outcome: nothing went wrong")
  }

  @Test("A spelling removed while the panel sat open is written again, not reported as saved")
  func aSpellingRemovedInBetweenIsWrittenAgain() throws {
    // The MIRROR of the de-dup below, and the direction the first version of this fix missed. The
    // snapshot's `alreadyHasHeardSpelling` was consulted BEFORE the live lookup, so a spelling the
    // user removed in Settings while the panel sat open still short-circuited to "already saved" —
    // the panel reporting a spelling was there, having written nothing, about a word that no longer
    // had it. Same family as the P1, arriving through the guard that runs first.
    let codex = word("Codex", aliases: ["codecs"])
    let (coordinator, recorder) = makeCoordinator(userWords: [codex])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)
    #expect(target.alreadyHasHeardSpelling, "the snapshot says it is already there")

    var edited = codex
    edited.aliases = []
    recorder.userWords = [edited]

    coordinator.accept(target, from: model)

    let saved = try #require(recorder.saved.first)
    #expect(saved.aliases.contains("codecs"), "it is not there any more, so it gets written")
    #expect(recorder.outcomes == [.accepted], "never alreadySaved for a spelling that is absent")
  }

  @Test("Accepting merges into the word as it is NOW, not the snapshot the panel was ranked from")
  func acceptingMergesIntoTheLiveWord() throws {
    // The panel is deliberately persistent — it survives losing focus — so the user can open it,
    // go and edit the word in Settings, and come back to it. Appending an alias to the SNAPSHOT and
    // handing that to `update` replaces the whole stored entry, so their edit is reverted by a write
    // that reports success. Silent data loss, and the panel says it worked.
    let opened = word("Codex", aliases: ["codeks"])
    let (coordinator, recorder) = makeCoordinator(userWords: [opened])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    // What the user did in Settings while the panel sat open.
    var edited = opened
    edited.canonical = "Codex CLI"
    edited.aliases = ["codeks", "kodex"]
    edited.category = .domain
    recorder.userWords = [edited]

    coordinator.accept(target, from: model)

    let saved = try #require(recorder.saved.first)
    #expect(saved.id == opened.id, "still the same entry")
    #expect(saved.canonical == "Codex CLI", "the rename survived")
    #expect(saved.category == .domain, "and so did every other field on it")
    #expect(saved.aliases.contains("kodex"), "the spelling they added in Settings survived")
    #expect(saved.aliases.contains("codecs"), "and the one Quick Add was for landed")
  }

  @Test("A pack term overridden while the panel sat open merges into the override, not over it")
  func aPackTermOverriddenInBetweenIsNotOverwritten() throws {
    // `ownedByUser()` PRESERVES the id, so once the user takes ownership of a pack term the same id
    // names a real entry. Converting the pack snapshot a second time would write over the override
    // they just made — which is why the live lookup runs BEFORE the pack branch rather than after.
    let pack = word("codec", source: .pack)
    let (coordinator, recorder) = makeCoordinator(userWords: [], packTerms: [pack])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)
    #expect(target.isPackTerm)

    var override = pack.ownedByUser()
    override.canonical = "Codec"
    override.aliases = ["kodek"]
    recorder.userWords = [override]

    coordinator.accept(target, from: model)

    let saved = try #require(recorder.saved.first)
    #expect(saved.canonical == "Codec", "their edit to the override survived")
    #expect(saved.aliases.contains("kodek"), "and so did the spelling they put on it")
    #expect(saved.aliases.contains("codecs"))
    // And the funnel says what was WRITTEN. The snapshot still calls this a pack term; a user word
    // is what landed, so reporting `pack_term` would be a metric asserting the opposite.
    #expect(recorder.targetKinds == [.userWord])
  }

  @Test("A pack row whose NAME the user already owns merges into their word, not a doomed override")
  func aPackRowCollidingByNameMergesIntoTheUserWord() throws {
    // `ownedByUser()` keeps the pack term's id and `packTermsNotOverridden` filters the ranking by
    // ID, so a user word and an enabled pack term can share a canonical and differ by id — two rows,
    // one name. Converting the pack snapshot hands `add` a colliding canonical, which it refuses
    // SILENTLY, and the post-write confirmation then finds the spelling on the USER word and reports
    // success for an override that was never created.
    let pack = word("Codec", source: .pack)
    let mine = word("Codec", aliases: ["kodek"])
    #expect(pack.id != mine.id, "the whole case is one name under two identities")

    let (coordinator, recorder) = makeCoordinator(userWords: [mine], packTerms: [pack])
    let model = try #require(beginAndShow(coordinator))
    // Reached through SEARCH, not the heard ranking, and the difference is load-bearing. Pack terms
    // enter the heard list only when the user's best score misses the confidence bar, so a strong
    // user match hides them; the search population is `userWords + packTermsNotOverridden`
    // unconditionally, so both rows are on screen the moment the user types the shared name.
    model.updateQuery("Codec")
    let packRow = try #require(model.ranking.candidates.first { $0.isPackTerm })

    coordinator.accept(packRow, from: model)

    let saved = try #require(recorder.saved.first)
    #expect(saved.id == mine.id, "written to the entry that can actually take it")
    #expect(saved.aliases.contains("kodek"), "and their own spelling survived the merge")
    #expect(saved.aliases.contains("codecs"))
    #expect(recorder.targetKinds == [.userWord], "a user word is what was written, so say so")
  }

  @Test("A word deleted while the panel sat open is not resurrected by accepting its row")
  func aDeletedWordIsNotResurrected() throws {
    // The same staleness pointing the other way, and it is why the resolver returns three cases
    // rather than an optional: writing the snapshot back would silently undo a DELETION.
    let codex = word("Codex", aliases: ["codeks"])
    let (coordinator, recorder) = makeCoordinator(userWords: [codex])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    recorder.userWords = []

    let result = coordinator.accept(target, from: model)

    #expect(result == .refused(QuickAddPanelCopy.wordNoLongerExists))
    #expect(recorder.saved.isEmpty, "nothing may be written for a word that is gone")
    #expect(
      recorder.outcomes.isEmpty,
      "a refusal leaves the panel open, so the invocation has not ended and nothing resolves")
    #expect(
      recorder.events.contains {
        if case .failed(_, let reason) = $0 { reason == "target_gone" } else { false }
      })
  }

  @Test("A spelling that arrived from elsewhere is not appended a second time")
  func aSpellingAddedElsewhereIsNotAppendedAgain() throws {
    // The snapshot guard answers this from the ranking taken when the panel opened. The library can
    // gain the spelling AFTER that, and appending it again stores it twice and reports success.
    let codex = word("Codex", aliases: ["codeks"])
    let (coordinator, recorder) = makeCoordinator(userWords: [codex])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)
    #expect(!target.alreadyHasHeardSpelling, "the snapshot says there is work to do")

    var edited = codex
    // Case differs, which is still the same spelling — matching exactly would store both.
    edited.aliases = ["codeks", "Codecs"]
    recorder.userWords = [edited]

    coordinator.accept(target, from: model)

    #expect(recorder.saved.isEmpty, "storing it twice would report success for a duplicate")
    #expect(recorder.outcomes == [.alreadySaved], "one outcome, two sources, same answer")
  }

  @Test("A refused write is reported as a failure, not as a save")
  func aRefusedWriteIsReported() throws {
    // The reader reuses only the LENGTH half of the store's policy, so a selection carrying a bidi
    // override passes the reader and is refused here. The user must be told.
    let (coordinator, recorder) = makeCoordinator(
      userWords: [word("Codex")], saveFailure: "That word cannot be saved.")
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    let result = coordinator.accept(target, from: model)

    // The RETURNED message is the assertion that matters, and the first version of this test did
    // not make it. It asserted the TELEMETRY outcome, which is a fact about a dashboard; what the
    // comment above promises — "the user must be told" — is only true if the caller is handed
    // something to show, and the caller dismissed the panel regardless until this was added.
    #expect(result == .refused("That word cannot be saved."))
    #expect(recorder.events.contains { if case .failed = $0 { true } else { false } })
    // NOT resolved. The panel is still open, so the invocation has not ended — `resolved` means
    // ENDED, and the second version of this test asserted `[.writeFailed]` here, which was the
    // defect written down as a contract one layer up from the first version's.
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("A refused write then a cancel is ONE resolution, not two")
  func aRefusedWriteThenCancelResolvesOnce() throws {
    // The axis-A member the enumeration missed, and the reason it missed it: I enumerated which
    // ENDINGS exist and checked each in isolation, when the generating dimension is which ordered
    // PAIRS are reachable in one open. Only a refused write leaves the panel up, so only it can be
    // followed by a second ending.
    let (coordinator, recorder) = makeCoordinator(
      userWords: [word("Codex")], saveFailure: "That word cannot be saved.")
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    _ = coordinator.accept(target, from: model)
    coordinator.cancel(from: model)

    #expect(recorder.outcomes == [.cancelled])
    #expect(
      !recorder.events.contains {
        if case .failed(let stage, _) = $0 { stage == "resolve" } else { false }
      })
  }

  @Test("A second resolution is refused loudly rather than invented")
  func aSecondResolutionIsRefused() throws {
    // Removing the REASON and removing the POSSIBILITY are different jobs. `finish` used to
    // substitute `environment.now()` for a cleared start time, which gave a second terminal event a
    // plausible elapsed time and no way to tell it apart from a real one.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.cancel(from: model)
    coordinator.cancel(from: model)

    #expect(recorder.outcomes == [.cancelled])
    #expect(
      recorder.events.contains {
        if case .failed(let stage, let reason) = $0 {
          stage == "resolve" && reason == "double_resolution"
        } else {
          false
        }
      })
  }

  @Test("A save that succeeds names the word it wrote to")
  func aSuccessfulWriteNamesItsTarget() throws {
    // The paired accepted case for the refusal above. Without it the caller could dismiss on any
    // non-refusal rule and still pass, and a check that never classifies anything looks clean.
    //
    // The NAME is what the panel's confirmation quotes, so a result that merely said "fine" would
    // send the caller back to the row the user clicked — a snapshot taken when the panel opened.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    #expect(coordinator.accept(target, from: model) == .saved(word: "Codex"))
    #expect(recorder.outcomes == [.accepted])
  }

  @Test("A word that already carries the spelling reports that, not a save")
  func alreadySavedIsDistinctFromSaved() throws {
    // Nothing went wrong, so there is nothing to keep the panel open for — and nothing was written,
    // so a confirmation reading `"codecs" added to Codex` would be a false sentence. The two
    // successes are distinguished HERE because the caller cannot tell them apart: the row's
    // `alreadyHasHeardSpelling` is the ranking's snapshot, and the decision is made live.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex", aliases: ["codecs"])])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    #expect(coordinator.accept(target, from: model) == .alreadyHad(word: "Codex"))
    #expect(recorder.outcomes == [.alreadySaved])
  }

  /// **A word IS its canonical, so selecting that text adds nothing.** The live guard read the
  /// aliases only, so this appended the canonical as an alias of itself and reported a save — a
  /// junk write into the user's words file under a sentence reading `"Codex" added to Codex`.
  ///
  /// The fixture has NO aliases deliberately: with one, the row could pass on the alias check and
  /// the canonical comparison would never be reached, which is the shape that lets a guard look
  /// covered while asserting nothing.
  @Test("Selecting a word's own canonical reports that it is already there, and writes nothing")
  func theCanonicalCountsAsAlreadyCovered() throws {
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator, acquired: .text("Codex")))
    let target = try #require(model.ranking.candidates.first)

    #expect(coordinator.accept(target, from: model) == .alreadyHad(word: "Codex"))
    #expect(recorder.outcomes == [.alreadySaved])
    #expect(
      recorder.saved.isEmpty,
      "nothing may be written: a canonical is already the spelling it is being asked to carry")
  }

  /// **Case-insensitively, matching the ranker and the alias check either side of it.**
  @Test("A differently-cased canonical is still already covered")
  func theCanonicalComparisonIgnoresCase() throws {
    let (coordinator, _) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator, acquired: .text("codex")))
    let target = try #require(model.ranking.candidates.first)

    #expect(coordinator.accept(target, from: model) == .alreadyHad(word: "Codex"))
  }

  /// **The staleness the confirmation could reintroduce, in the direction that matters.** The row
  /// said `already has this` when the panel opened; the user then removed that alias in Settings and
  /// pressed Return. The write happens, and a confirmation composed from the snapshot would tell
  /// them nothing was added.
  @Test("The result follows the live library, never the row the user clicked")
  func theResultIsLiveNotSnapshotted() throws {
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex", aliases: ["codecs"])])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)
    #expect(target.alreadyHasHeardSpelling, "the snapshot says there is nothing to add")

    // The user deletes that spelling in Settings while the panel sits open.
    recorder.userWords = [
      CustomWord(id: target.word.id, canonical: "Codex", aliases: [])
    ]

    #expect(coordinator.accept(target, from: model) == .saved(word: "Codex"))
    #expect(recorder.outcomes == [.accepted])
  }

  @Test("Accepting after searching is a distinct outcome from accepting the top row")
  func acceptingAfterSearchIsDistinct() throws {
    // The two say different things about the ranking: one is the guess landing, the other is the
    // user rescuing it. A single `accepted` would hide how often the ranking is wrong.
    let (coordinator, recorder) = makeCoordinator(
      userWords: [word("Codex"), word("Claude Code")])
    let model = try #require(beginAndShow(coordinator))
    model.updateQuery("claude")
    let target = try #require(model.ranking.candidates.first)

    coordinator.accept(target, from: model)

    #expect(recorder.outcomes == [.acceptedAfterSearch])
  }

  @Test("Searching never changes what gets written")
  func searchingNeverChangesWhatIsWritten() throws {
    let (coordinator, recorder) = makeCoordinator(
      userWords: [word("Codex"), word("Claude Code")])
    let model = try #require(beginAndShow(coordinator))
    model.updateQuery("claude")
    let target = try #require(model.ranking.candidates.first)

    coordinator.accept(target, from: model)

    #expect(recorder.saved.first?.aliases.contains("codecs") == true)
    #expect(
      recorder.saved.first?.aliases.contains("claude") == false,
      "the query must never become the spelling")
  }

  // MARK: - The other two endings

  @Test("Create-new moves the panel to its compose stage and writes nothing")
  func createNewBeginsComposing() throws {
    let (coordinator, recorder) = makeCoordinator()
    let model = try #require(beginAndShow(coordinator))

    coordinator.createNew(from: model)

    #expect(recorder.beganNewWord == 1)
    // `createdNew` deliberately does NOT fire here — reaching the compose field is an intention, and
    // emitting on the click double-counted every open where the user then backed out. The outcome is
    // asserted in `didCreateNewResolvesOnce`, after the save is confirmed.
    #expect(recorder.outcomes.isEmpty)
    #expect(recorder.saved.isEmpty, "composing writes nothing")
  }

  @Test("Cancelling writes nothing and says so")
  func cancellingWritesNothing() throws {
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.cancel(from: model)

    #expect(recorder.saved.isEmpty)
    #expect(recorder.outcomes == [.cancelled])
  }

  @Test("Every door is reported, and the set is closed")
  func bothDoorsAreReported() throws {
    let (coordinator, recorder) = makeCoordinator()

    _ = beginAndShow(coordinator, door: .service, selectionOverride: "codecs")
    guard case .opened(let door, _, _, _, _, _, _, _, _, _) = try #require(recorder.opened) else { return }

    #expect(door == .service)
    // Three since #2412 added the status-item menu. The count is here so a new door cannot be added
    // without someone reading the funnel — which is what happened.
    #expect(QuickAddDoor.allCases.count == 3)
    #expect(QuickAddDoor.allCases.contains(.menuBar))
  }

  @Test("The Service door uses the pasteboard text and does not read Accessibility")
  func theServiceDoorUsesItsOwnText() throws {
    // A Service is HANDED the selection. Reading Accessibility as well would ask a second question
    // whose answer is about whatever is frontmost now, which by then may be us.
    let (coordinator, _) = makeCoordinator()

    let model = try #require(
      beginAndShow(
        coordinator, door: .service, selectionOverride: "sarag",
        acquired: .refused(.accessibilityNotTrusted)))

    #expect(model.heard == "sarag")
    #expect(model.refusal == nil, "the AX refusal is irrelevant when the text was handed to us")
  }

  @Test("Every outcome name is distinct")
  func outcomeNamesAreDistinct() {
    // The raw values are the telemetry values. Two outcomes sharing one makes a dashboard unable to
    // tell a cancel from a failed write.
    let names = QuickAddOutcome.allCases.map(\.rawValue)
    #expect(Set(names).count == names.count)
    #expect(names.allSatisfy { !$0.isEmpty })
  }
  // MARK: - Round 1 of the whole-diff review (#2381)

  @Test("A Service handing over whitespace opens on a stated reason, not on an empty word")
  func serviceWhitespaceIsARefusal() throws {
    // The Services system hands us whatever was on the pasteboard. Treating that as already-valid
    // opened a panel reading `Heard: ` with the search field up, from which Return could write an
    // alias the store then stripped while reporting success.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator, door: .service, selectionOverride: "   "))

    #expect(model.heard.isEmpty)
    // The TWIN of the hotkey case, and it moved with it: whitespace classifies as no selection, so
    // both doors now land on the reason that blames nobody rather than on the one naming terminals.
    // Its sentence deliberately names no route, because a message telling a Services user to "press
    // the shortcut again" is wrong about how they got here.
    #expect(model.refusal == .nothingSelected)
    #expect(model.ranking.candidates.isEmpty)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("A Service handing over an oversized selection is refused at the store's own ceiling")
  func serviceOversizedIsRefused() throws {
    // Door A bounded this and door B did not, so the same selection was refused through one door
    // and sent to the scorer through the other — where edit distance builds a matrix per candidate.
    let huge = String(repeating: "a", count: SelectionReader.maximumSelectionScalars + 1)
    let (coordinator, _) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator, door: .service, selectionOverride: huge))

    #expect(model.refusal == .selectionTooLong)
    #expect(model.ranking.candidates.isEmpty)
  }

  @Test("A Service handing over a real word still ranks it, so the guard is not blanket refusal")
  func serviceOrdinaryWordStillRanks() throws {
    // The paired accepted case. Without it every assertion above passes against a door that refuses
    // everything, which is a check that never classifies anything.
    let (coordinator, _) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(
      beginAndShow(coordinator, door: .service, selectionOverride: "  codecs  "))

    #expect(model.heard == "codecs")
    #expect(model.refusal == nil)
    #expect(!model.ranking.candidates.isEmpty)
  }

  @Test("Reaching the compose field resolves nothing, because an intention is not an outcome")
  func createNewDoesNotResolve() throws {
    // Emitting createdNew on the click counted the INTENTION as a save: backing out left the
    // panel up, and cancelling the panel then emitted a SECOND resolved event for one open.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.createNew(from: model)

    #expect(recorder.beganNewWord == 1)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("Cancelling after reaching the compose field resolves exactly once, as cancelled")
  func cancellingAfterComposingResolvesOnce() throws {
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.createNew(from: model)
    coordinator.cancel(from: model)

    #expect(recorder.outcomes == [.cancelled])
  }

  @Test("A confirmed save resolves as createdNew, once")
  func didCreateNewResolvesOnce() throws {
    // The paired positive: the outcome still exists and is still reachable. Moving the emission
    // without this would be indistinguishable from deleting it.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.createNew(from: model)
    coordinator.didCreateNew(usedSearch: false)

    #expect(recorder.outcomes == [.createdNew])
  }

  @Test("A panel that could not be shown leaves no open event behind")
  func aPanelThatCannotBeShownEmitsNoOpen() throws {
    // Found by ENUMERATING the ways a Quick Add can end, not by a review round. The host refuses to
    // present a panel it could not measure — an unmeasurable panel is an invisible window reporting
    // success — and `opened` used to fire before that, so the one path that cannot report a reason
    // of its own left an open with nothing to resolve it.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])

    _ = try #require(
      coordinator.begin(door: .hotkey, selection: .acquired(outcome(.text("codecs")))))
    coordinator.failedToOpen()

    #expect(recorder.opened == nil)
    // And NOT a resolved either: nothing opened, so there is nothing to resolve, and inventing an
    // outcome would put a phantom row in the denominator of every rate built on this funnel.
    #expect(recorder.outcomes.isEmpty)
    #expect(recorder.events.contains { if case .failed = $0 { true } else { false } })
  }

  @Test("A panel that IS shown emits exactly one open")
  func aPanelThatIsShownEmitsOneOpen() throws {
    // The paired positive. Deferring the emission is indistinguishable from deleting it without
    // something that still requires it to arrive, exactly once.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])

    _ = try #require(beginAndShow(coordinator))

    #expect(recorder.events.filter { if case .opened = $0 { true } else { false } }.count == 1)
  }

  @Test("A confirmed new word resolves even when the panel has already gone")
  func createdNewResolvesWithoutAModel() throws {
    // The call site used to read `if let model = activeModel`, so a CONFIRMED save emitted
    // nothing at all. **The ordering that made this reachable is gone** — composing is a stage
    // of the panel now, and a stage cannot outlive it, which is why `usedSearch` is read live.
    // Kept because the coordinator is still callable this way and the funnel hole it closed is
    // the expensive kind: a save that happened and was never counted.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))
    coordinator.createNew(from: model)

    coordinator.didCreateNew(usedSearch: false)

    #expect(recorder.outcomes == [.createdNew])
  }

  @Test("The spelling handed to the write path is the SELECTION, never the search query")
  func theWritePathIsGivenTheSelection() throws {
    // The write path now takes the spelling as its own parameter so it can prove that spelling
    // landed. That check is only worth anything if the string it is given is the right one — and the
    // search field exists precisely to let the user type something else.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex"), word("Kubernetes")])
    let model = try #require(beginAndShow(coordinator))
    model.updateQuery("kub")
    let target = try #require(model.ranking.candidates.first)

    coordinator.accept(target, from: model)

    #expect(recorder.savedSpellings == ["codecs"])
    #expect(recorder.saved.first?.aliases.contains("codecs") == true)
  }
  // MARK: - Did the create actually produce a word (#2381, cloud review)

  @Test("A no-spelling save onto an existing canonical is its own outcome, not a refusal")
  func noSpellingOntoExistingCanonicalIsAlreadyPresent() {
    // **This cell was `.refused` and its REASON has been removed rather than overruled.** The
    // postcondition asks "did the kept spellings land", which is vacuously true of none — so a
    // canonical that already existed took the success path while `add` silently no-oped, and the
    // panel closed saying nothing. Refusing was how that silence was made audible.
    //
    // #2391 §1 gave the panel something to say on EVERY ending, so the silence is gone and the
    // refusal became a dead end: only the panel opened WITHOUT a readable selection can produce this
    // cell, its ranking is empty and its search field disabled by construction, and the refusal's
    // copy told the user to choose the word from a list that cannot exist there.
    //
    // Nothing is wrong in this state. They asked for the word to be in their words, and it is.
    //
    // **It did NOT become `.alreadyComplete`, and the case below is why.** Renaming the cell is a
    // claim about the panel; merging it is a claim about the postcondition, and only the first is
    // true.
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: [], missingSpellings: [], canonicalExistedBefore: true) == .alreadyPresent)
  }

  /// **The distinction round three drew, restated as the thing that must not collapse.** The
  /// no-spelling cell has nothing for `alreadyComplete`'s postcondition to confirm, which is why it
  /// was split out; folding the two together makes that postcondition vacuous exactly where it
  /// already was once. A guard on #2403 mutates one into the other, and this is the test it fires.
  @Test("The two already-there cells stay distinct, because only one has a spelling to confirm")
  func theTwoAlreadyThereCellsAreDistinct() {
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: [], missingSpellings: [], canonicalExistedBefore: true) == .alreadyPresent)
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: ["codecs"], missingSpellings: [],
        canonicalExistedBefore: true) == .alreadyComplete)
  }

  /// **The argument that CLOSES the class, so it is a test rather than a paragraph.**
  ///
  /// Root B of this branch's review rounds is "an outcome that keeps the panel open must name an
  /// action the panel can perform". The panel opened WITHOUT a readable selection cannot perform
  /// any: its ranking is empty and its search field disabled by construction. So the enumeration is
  /// only closed if no panel-keeping outcome is REACHABLE from that state.
  ///
  /// `.refused` is the only panel-keeping outcome, and it needs a missing spelling. With no heard
  /// word `QuickAddPanelModel.draftWord` attaches no alias, so `keptSpellings` is empty, so
  /// `missingSpellings` is empty, so `.refused` cannot arise. That chain is three files long and
  /// entirely invisible from either end — which is exactly the kind of claim that decays into a
  /// comment nobody rechecks.
  @Test("A no-selection panel cannot reach an outcome that keeps it open")
  func aRefusalPanelCannotReachAPanelKeepingOutcome() {
    // What `draftWord` produces with no heard spelling: a word carrying no aliases.
    let authored = CustomWord(canonical: "Qwen", aliases: [])
    let kept = authored.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    #expect(kept.isEmpty, "no heard spelling means nothing to keep")

    // Every canonical-existed value, since that is the only other axis.
    for existedBefore in [true, false] {
      let outcome = QuickAddWiring.newWordOutcome(
        keptSpellings: kept, missingSpellings: [], canonicalExistedBefore: existedBefore)
      #expect(outcome != .refused, "a state with no way forward must not keep the panel open")
    }
  }

  /// The paired NEGATIVE, and it is what stops the change above collapsing the enum: `.refused` is
  /// still reachable, and it is reachable for the one reason that outranks everything — a spelling
  /// the user typed that is not on the word afterwards is a lost edit, whatever else is true.
  @Test("A missing spelling is still refused, whatever else holds")
  func aMissingSpellingIsStillRefused() {
    for existedBefore in [true, false] {
      #expect(
        QuickAddWiring.newWordOutcome(
          keptSpellings: ["codecs"], missingSpellings: ["codecs"],
          canonicalExistedBefore: existedBefore) == .refused)
    }
  }

  @Test("A blank-alias save of a genuinely new canonical IS a creation")
  func blankAliasOntoNewCanonicalIsACreation() {
    // The paired positive, and without it the fix reads as "refuse every blank-alias save", which
    // would break creating a word by hand from a panel that could not read a selection — the one
    // route that state has.
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: [], missingSpellings: [], canonicalExistedBefore: false) == .created)
  }

  @Test("A spelling landing on a NEW canonical is a creation")
  func aLandedSpellingOnANewCanonicalIsACreation() {
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: ["codecs"], missingSpellings: [], canonicalExistedBefore: false) == .created)
  }

  @Test("A spelling already on an EXISTING canonical is already-saved, never a creation")
  func aSpellingAlreadyOnAnExistingCanonicalIsAlreadySaved() {
    // REWRITTEN in round five, and the previous version is why. It asserted this as a success, on a
    // comment reading "adding a spelling to a word you already have is the feature's main path, not
    // a duplicate". That is true of the ACCEPT route and false here: through Create New, `add`
    // no-ops on a duplicate canonical, so an existing canonical means NOTHING was written. The panel
    // reported a creation and the funnel counted a `created_new` for a write that never happened.
    //
    // Not `.refused` either, which is the half that makes this three states rather than a flipped
    // Bool: the end state the user asked for already holds, so refusing would hand them a message
    // telling them to go and add a spelling the word already has.
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: ["codecs"], missingSpellings: [], canonicalExistedBefore: true)
        == .alreadyComplete)
  }

  @Test("A spelling that vanished is refused however new the canonical is")
  func aMissingSpellingIsAlwaysRefused() {
    // Outranks both other questions: if the user typed a spelling and it is not on the word, no
    // amount of the canonical being new makes that a save. Asserted BOTH ways, because a guard that
    // only ever sees one value of the thing it is said to outrank has not been shown to outrank it.
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: ["codecs"], missingSpellings: ["codecs"], canonicalExistedBefore: false)
        == .refused)
    #expect(
      QuickAddWiring.newWordOutcome(
        keptSpellings: ["codecs"], missingSpellings: ["codecs"], canonicalExistedBefore: true)
        == .refused)
  }

  // MARK: - Whether a second press starts a fresh capture (#2391 §1)

  /// **The regression the confirmation could have introduced, and it lands on the commonest way to
  /// use this feature: adding two words in a row.**
  ///
  /// A confirmation stays on screen for two seconds after Return, with the invocation already
  /// resolved. A visibility test alone would raise that confirmation and refuse the new capture —
  /// indistinguishable, from the user's side, from the shortcut not firing.
  ///
  /// Paired with the case it must NOT break: a genuinely live panel still raises rather than
  /// throwing away the selection the user already made, which is the #2381 fix this sits beside.
  @Test("A fading confirmation yields to a new capture; a live panel does not")
  func aFadingConfirmationDoesNotBlockTheNextCapture() {
    #expect(
      QuickAddWiring.mayBeginCapture(panelVisible: true, hasLiveInvocation: false),
      "a resolved panel is a confirmation fading out, not a capture in progress")
    #expect(
      !QuickAddWiring.mayBeginCapture(panelVisible: true, hasLiveInvocation: true),
      "a live panel is raised, never re-captured against our own window")
    #expect(QuickAddWiring.mayBeginCapture(panelVisible: false, hasLiveInvocation: false))
    // Nothing on screen wins outright. A stale live flag with no panel must not wedge the shortcut.
    #expect(QuickAddWiring.mayBeginCapture(panelVisible: false, hasLiveInvocation: true))
  }

  // MARK: - What a VoiceOver user hears (#2391, confirming round)

  /// **A spoken confirmation that differs from the visible one is two answers to "what happened",
  /// and the blind user has no way to notice.** So the announcement is not a paraphrase — it is the
  /// string the view renders, and this asserts that rather than trusting one derivation.
  @Test("Every message the panel shows is spoken with the words it shows")
  func theAnnouncementIsTheRenderedSentence() {
    for kind in QuickAddPanelModel.Notice.Kind.allCases {
      let notice = QuickAddPanelModel.Notice(
        kind: kind,
        spelling: [.created, .alreadyInWords].contains(kind) ? "" : "codecs",
        word: "Codex", searchable: false)
      #expect(
        QuickAddWiring.announcement(notice: notice, writeFailure: nil)
          == QuickAddPanelCopy.notice(notice))
    }
    #expect(
      QuickAddWiring.announcement(notice: nil, writeFailure: "That word cannot be saved.")
        == QuickAddPanelCopy.writeFailure("That word cannot be saved."))
  }

  /// The member the confirming round did NOT name, found by enumerating the channel axis rather than
  /// fixing the two sites it did name. A refusal is the only message the user has to ACT on, and it
  /// appears after a keypress while focus sits in the search field — so it is a dynamic status
  /// change with nothing focused on it, exactly like the two notices.
  @Test("A refusal is spoken too, and outranks a notice")
  func aRefusalIsSpokenAndOutranksANotice() {
    let notice = QuickAddPanelModel.Notice(
      kind: .saved, spelling: "codecs", word: "Codex", searchable: false)

    #expect(
      QuickAddWiring.announcement(notice: notice, writeFailure: "nope")
        == QuickAddPanelCopy.writeFailure("nope"))
  }

  /// The panel ASKING is not the panel TELLING. A ranked list with nothing refused and no notice has
  /// no status change to announce, and speaking there would talk over the user exploring the rows.
  @Test("A panel that is asking rather than telling says nothing")
  func aPanelThatIsAskingAnnouncesNothing() {
    #expect(QuickAddWiring.announcement(notice: nil, writeFailure: nil) == nil)
  }

  // MARK: - Focus hand-back: REMOVED (#2391, founder 2026-08-25)

  // **The focus-return tests are GONE with the mechanism they guarded (founder, 2026-08-25).**
  // `theKeyboardGoesWhereItBelongs`, `aVisibleWindowIsNotProvenance`,
  // `ourOwnActivationDoesNotRewriteTheOrigin`, `aRaiseOntoAnUnfocusedPanelRecapturesTheOrigin`,
  // `dismissalReleasesOnlyWhatItHolds` and `anUnknownOriginDeactivates` all asserted decisions about
  // where to hand the keyboard back, and there is no longer anywhere to hand it back to.
  //
  // Per `deleting-a-test-carries-the-burden-of-adding-one`: what they protected was the correctness
  // of a mechanism that has been REMOVED, not a user-facing outcome that still exists. The three
  // refutations they carried — a visible window is not provenance, our own activation must not
  // rewrite the origin, a second press onto an unfocused panel is a new origin — were all facts
  // about that mechanism. Nothing else asserts them because nothing else needs them.

  // MARK: - The created confirmation names what was written (#2391, r5)

  /// **Selecting a word that is already spelled correctly and authoring it is ordinary**, and
  /// `draftWord` correctly declines to store a word as an alias of itself. Choosing the sentence by
  /// "was the selection non-empty" then claims an add that did not happen.
  @Test("A word created with no alias attached is not confirmed as a spelling that was added")
  func aSelfNamedCreationDoesNotClaimAnAdd() {
    let model = QuickAddPanelModel(
      heard: "Claude", refusal: nil, rankHeard: { _ in .empty }, searchLibrary: { _, _ in .empty })
    model.beginComposing()
    model.updateDraft("Claude")
    let authored = model.draftWord

    #expect(authored?.aliases.isEmpty == true, "a word is not an alias of itself")
    // The selection is NON-empty, which is exactly what the old rule read.
    #expect(!model.spellingToWrite.isEmpty)
  }
}
