import EnviousWisprCore
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
    var events: [QuickAddEvent] = []
    var saved: [CustomWord] = []
    var savedSpellings: [String] = []
    var sheetsFor: [String] = []
    var refreshCalls = 0

    var outcomes: [QuickAddOutcome] {
      events.compactMap {
        if case .resolved(let outcome, _, _, _, _) = $0 { return outcome }
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
  /// The two are separate in production on purpose: `opened` names an event the user can SEE, so it
  /// fires when a panel is on screen. Emitting it from `begin` made a panel that could not be
  /// measured leave an open with nothing to resolve it.
  private func beginAndShow(
    _ coordinator: QuickAddCoordinator, door: QuickAddDoor = .hotkey, selectionOverride: String? = nil
  ) -> QuickAddPanelModel? {
    let model = coordinator.begin(door: door, selectionOverride: selectionOverride)
    if model != nil { coordinator.didOpen() }
    return model
  }

  private func makeCoordinator(
    selection: SelectionReader.Result = .text("codecs"),
    refreshSucceeds: Bool = true,
    userWords: [CustomWord] = [],
    packTerms: [CustomWord] = [],
    saveFailure: String? = nil
  ) -> (QuickAddCoordinator, Recorder) {
    let recorder = Recorder()
    var clock = Date(timeIntervalSince1970: 0)
    let environment = QuickAddCoordinator.Environment(
      readSelection: { selection },
      frontmostBundleID: { "com.apple.TextEdit" },
      refreshWords: {
        recorder.refreshCalls += 1
        return refreshSucceeds
      },
      userWords: { userWords },
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
      presentNewWordSheet: { recorder.sheetsFor.append($0) },
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

    guard case .opened(let door, let refusal, let bundle, let count, _, _, _) = opened else {
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
    let (coordinator, recorder) = makeCoordinator(selection: .refused(.accessibilityNotTrusted))

    let model = try #require(beginAndShow(coordinator))

    #expect(model.refusal == .accessibilityNotTrusted)
    #expect(recorder.opened != nil, "the panel opens on a stated reason, never a silent no-op")
  }

  @Test("No selection is a reason, not an error")
  func noSelectionIsAReason() throws {
    let (coordinator, _) = makeCoordinator(selection: .noSelection)

    let model = try #require(beginAndShow(coordinator))

    #expect(model.refusal != nil, "the search field is the way forward, and the panel says so")
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

  @Test("A refused write is reported as a failure, not as a save")
  func aRefusedWriteIsReported() throws {
    // The reader reuses only the LENGTH half of the store's policy, so a selection carrying a bidi
    // override passes the reader and is refused here. The user must be told.
    let (coordinator, recorder) = makeCoordinator(
      userWords: [word("Codex")], saveFailure: "That word cannot be saved.")
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    let message = coordinator.accept(target, from: model)

    // The RETURNED message is the assertion that matters, and the first version of this test did
    // not make it. It asserted the TELEMETRY outcome, which is a fact about a dashboard; what the
    // comment above promises — "the user must be told" — is only true if the caller is handed
    // something to show, and the caller dismissed the panel regardless until this was added.
    #expect(message == "That word cannot be saved.")
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
    #expect(!recorder.events.contains { if case .failed(let stage, _) = $0 { stage == "resolve" } else { false } })
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
        if case .failed(let stage, let reason) = $0 { stage == "resolve" && reason == "double_resolution" }
        else { false }
      })
  }

  @Test("A save that succeeds returns nothing to show, which is what licenses the dismiss")
  func aSuccessfulWriteReturnsNil() throws {
    // The paired accepted case for the refusal above. Without it the caller could dismiss on any
    // non-nil-ness rule and still pass, and a check that never classifies anything looks clean.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    #expect(coordinator.accept(target, from: model) == nil)
    #expect(recorder.outcomes == [.accepted])
  }

  @Test("A word that already carries the spelling returns nothing to show")
  func alreadySavedReturnsNil() throws {
    // Nothing went wrong, so there is nothing to keep the panel open for. Distinguished from the
    // refusal above only by the return value, which is why both are asserted.
    let (coordinator, recorder) = makeCoordinator(
      selection: .text("codecs"), userWords: [word("Codex", aliases: ["codecs"])])
    let model = try #require(beginAndShow(coordinator))
    let target = try #require(model.ranking.candidates.first)

    #expect(coordinator.accept(target, from: model) == nil)
    #expect(recorder.outcomes == [.alreadySaved])
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

  @Test("Create-new opens the edit sheet on the heard spelling")
  func createNewOpensTheSheet() throws {
    let (coordinator, recorder) = makeCoordinator()
    let model = try #require(beginAndShow(coordinator))

    coordinator.createNew(from: model)

    #expect(recorder.sheetsFor == ["codecs"])
    // `createdNew` deliberately does NOT fire here any more — opening a sheet is an intention, and
    // emitting on the click double-counted every open where the user then cancelled. The outcome is
    // asserted in `didCreateNewResolvesOnce`, after the save is confirmed.
    #expect(recorder.outcomes.isEmpty)
    #expect(recorder.saved.isEmpty, "the sheet writes, not this")
  }

  @Test("Cancelling writes nothing and says so")
  func cancellingWritesNothing() throws {
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.cancel(from: model)

    #expect(recorder.saved.isEmpty)
    #expect(recorder.outcomes == [.cancelled])
  }

  @Test("Both doors are reported, and they are the only two")
  func bothDoorsAreReported() throws {
    let (coordinator, recorder) = makeCoordinator()

    _ = beginAndShow(coordinator, door: .service, selectionOverride: "codecs")
    guard case .opened(let door, _, _, _, _, _, _) = try #require(recorder.opened) else { return }

    #expect(door == .service)
    #expect(QuickAddDoor.allCases.count == 2)
  }

  @Test("The Service door uses the pasteboard text and does not read Accessibility")
  func theServiceDoorUsesItsOwnText() throws {
    // A Service is HANDED the selection. Reading Accessibility as well would ask a second question
    // whose answer is about whatever is frontmost now, which by then may be us.
    let (coordinator, _) = makeCoordinator(selection: .refused(.accessibilityNotTrusted))

    let model = try #require(beginAndShow(coordinator, door: .service, selectionOverride: "sarag"))

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
    #expect(model.refusal == .selectionUnavailable)
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
    let model = try #require(beginAndShow(coordinator, door: .service, selectionOverride: "  codecs  "))

    #expect(model.heard == "codecs")
    #expect(model.refusal == nil)
    #expect(!model.ranking.candidates.isEmpty)
  }

  @Test("Opening the new-word sheet resolves nothing, because an intention is not an outcome")
  func createNewDoesNotResolve() throws {
    // Emitting createdNew on the click counted opening a sheet as a save: cancelling the sheet left
    // the panel up, and cancelling the panel then emitted a SECOND resolved event for one open.
    let (coordinator, recorder) = makeCoordinator(userWords: [word("Codex")])
    let model = try #require(beginAndShow(coordinator))

    coordinator.createNew(from: model)

    #expect(recorder.sheetsFor == ["codecs"])
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("Cancelling after opening the sheet resolves exactly once, as cancelled")
  func cancellingAfterTheSheetResolvesOnce() throws {
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

    _ = try #require(coordinator.begin(door: .hotkey))
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
    // The sheet outlives the panel in at least one ordering, and the call site used to read
    // `if let model = activeModel`, so a CONFIRMED save emitted nothing at all.
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
    let (coordinator, recorder) = makeCoordinator(
      selection: .text("codecs"), userWords: [word("Codex"), word("Kubernetes")])
    let model = try #require(beginAndShow(coordinator))
    model.updateQuery("kub")
    let target = try #require(model.ranking.candidates.first)

    coordinator.accept(target, from: model)

    #expect(recorder.savedSpellings == ["codecs"])
    #expect(recorder.saved.first?.aliases.contains("codecs") == true)
  }
}
