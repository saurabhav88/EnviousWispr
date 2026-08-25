import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// What happened during one Quick Add, as facts rather than as telemetry (#2381).
///
/// **Deliberately knows no vendor.** The coordinator emits these; a bridge maps them onto PostHog and
/// Sentry. Deleting that bridge leaves this feature working, silently, which is the test of whether
/// observability was bolted on or wired in.
enum QuickAddEvent: Equatable, Sendable {
  /// The panel opened. `refusal` nil means a selection was read.
  case opened(
    door: QuickAddDoor,
    refusal: SelectionReader.Refusal?,
    sourceBundleID: String?,
    heardScalarCount: Int,
    candidateCount: Int,
    preselected: Bool,
    topScore: Double?)

  /// The panel closed, one way or another.
  case resolved(
    outcome: QuickAddOutcome,
    usedSearch: Bool,
    candidateRank: Int?,
    targetKind: QuickAddTargetKind?,
    elapsedMilliseconds: Int)

  /// Something failed in a way support would need to see. Never user content.
  case failed(stage: String, reason: String)
}

/// Which door the user came through.
enum QuickAddDoor: String, Equatable, Sendable, CaseIterable {
  case hotkey
  case service
}

/// How the panel ended. A closed set, so a new ending cannot inherit another's name.
enum QuickAddOutcome: String, Equatable, Sendable, CaseIterable {
  /// The user accepted a ranked row.
  case accepted
  /// The user accepted a row they had searched for.
  case acceptedAfterSearch = "accepted_after_search"
  /// The user chose to create a new word.
  case createdNew = "created_new"
  /// Escape, clicking away, or closing the panel.
  case cancelled
  /// The user accepted, and the write was refused.
  case writeFailed = "write_failed"
  /// The word already carried this spelling, so there was nothing to write.
  case alreadySaved = "already_saved"
}

/// What kind of library entry the user accepted onto.
enum QuickAddTargetKind: String, Equatable, Sendable, CaseIterable {
  case userWord = "user_word"
  /// A shipped pack term, which is CONVERTED to a user-owned override before writing.
  case packTerm = "pack_term"
}

/// Drives one Quick Add from a keypress to a written word (#2381).
///
/// **Orchestration only.** It does not own the window, does not rank, does not read Accessibility, and
/// does not know what PostHog is. Every one of those is a collaborator, which is what makes this the
/// piece you can read to find out what the feature DOES.
@MainActor
final class QuickAddCoordinator {

  /// Everything this needs from the rest of the app, as functions rather than objects.
  ///
  /// Not ceremony: the alternative is a coordinator holding the words coordinator, the pack manager,
  /// the ranker and the panel host, which is four objects' worth of API surface reachable from a limb
  /// and the shape `keep-central-types-thin` refuses. It also makes every branch below testable
  /// without a window, a words file, or a real selection.
  struct Environment {
    var readSelection: () -> SelectionReader.Result
    var frontmostBundleID: () -> String?
    /// Returns false when the words file could not be re-read. The panel then says so rather than
    /// ranking a stale snapshot.
    var refreshWords: () -> Bool
    var userWords: () -> [CustomWord]
    var packTerms: () -> [CustomWord]
    /// Persist a word. Returns nil on success, or a user-facing message.
    var saveWord: (CustomWord) -> String?
    /// Open the existing edit sheet on a new word carrying the heard spelling as its first alias.
    var presentNewWordSheet: (String) -> Void
    var emit: (QuickAddEvent) -> Void
    /// Injected so elapsed time is measurable without waiting.
    var now: () -> Date = Date.init
  }

  private var environment: Environment
  private let ranker = QuickAddRanker()

  init(environment: Environment) {
    self.environment = environment
  }

  /// Supply the create-new presenter after construction.
  ///
  /// Needed because the object that presents the sheet is the one that BUILDS this coordinator, so
  /// it cannot capture itself while doing so. Kept to this one seam rather than making the whole
  /// environment mutable: everything else is known at construction, and a settable environment is an
  /// invitation to change the rules at runtime.
  func setPresentNewWordSheet(_ present: @escaping (String) -> Void) {
    environment.presentNewWordSheet = present
  }

  /// One Quick Add invocation, from either door.
  ///
  /// Returns the panel model to present, or nil when there is nothing to present at all. **nil is
  /// never silence:** the only path that returns it has already emitted a `failed` event, and the
  /// caller shows nothing because there is genuinely nothing to show.
  func begin(door: QuickAddDoor, selectionOverride: String? = nil) -> QuickAddPanelModel? {
    let startedAt = environment.now()
    let bundleID = environment.frontmostBundleID()

    // Read BEFORE anything activates our app — by the time a panel exists, the frontmost application
    // is us and the answer would be about our own window.
    let selection: SelectionReader.Result =
      selectionOverride.map { .text($0) } ?? environment.readSelection()

    // Refresh before ranking, every invocation. A sibling instance or the Settings window can have
    // changed the library since launch, and ranking a stale snapshot offers words that no longer
    // exist and hides ones that do.
    guard environment.refreshWords() else {
      environment.emit(
        .failed(stage: "refresh", reason: "words_unreadable"))
      environment.emit(
        .resolved(
          outcome: .writeFailed, usedSearch: false, candidateRank: nil, targetKind: nil,
          elapsedMilliseconds: elapsed(since: startedAt)))
      return nil
    }

    let heard: String
    let refusal: SelectionReader.Refusal?
    switch selection {
    case .text(let text):
      heard = text
      refusal = nil
    case .noSelection:
      heard = ""
      // No selection is not an error and not a success. It reaches the panel as the one refusal that
      // means "you have not told me anything yet", and the search field is the way forward.
      refusal = .selectionUnavailable
    case .refused(let reason):
      heard = ""
      refusal = reason
    }

    let model = QuickAddPanelModel(
      heard: heard,
      refusal: refusal,
      rankHeard: { [ranker, environment] heardString in
        ranker.rank(
          heard: heardString, userWords: environment.userWords(),
          packTerms: environment.packTerms())
      },
      searchLibrary: { [ranker, environment] query, heardString in
        ranker.search(
          query: query, heard: heardString, userWords: environment.userWords(),
          packTerms: environment.packTerms())
      })

    environment.emit(
      .opened(
        door: door,
        refusal: refusal,
        sourceBundleID: bundleID,
        // The LENGTH, never the text. `CLAUDE.md` puts the privacy boundary at the network and the
        // test is whether user content crosses it; a character count is shape.
        heardScalarCount: heard.unicodeScalars.count,
        candidateCount: model.ranking.candidates.count,
        preselected: model.ranking.preselectedID != nil,
        topScore: model.ranking.topScore))

    self.startedAt = startedAt
    return model
  }

  /// The user accepted a row.
  ///
  /// **Returns the refusal message when the library would not take the word, and nil otherwise.**
  /// The return value is what tells the caller whether it may dismiss: `saveWord` can refuse for
  /// reasons that have nothing to do with this feature — the stored-value character policy, the
  /// 512-scalar ceiling, a words file that will not write — and dismissing regardless is a panel
  /// reporting success for a word that was never saved. The sibling path through the edit sheet
  /// already had this shape; this one did not.
  @discardableResult
  func accept(_ candidate: QuickAddRanker.Candidate, from model: QuickAddPanelModel) -> String? {
    let usedSearch = !model.query.isEmpty
    let rank = model.ranking.candidates.firstIndex { $0.id == candidate.id }
    let kind: QuickAddTargetKind = candidate.isPackTerm ? .packTerm : .userWord

    guard !candidate.alreadyHasHeardSpelling else {
      // Writing again would add a duplicate and report success. Saying so is the honest outcome, and
      // it is a distinct one from a refusal because nothing went wrong.
      finish(.alreadySaved, usedSearch: usedSearch, rank: rank, kind: kind)
      return nil
    }

    // A PACK term cannot be written through the words coordinator: `CustomWordsManager.update` looks
    // the id up in the user library, does not find it, and returns having written NOTHING. Convert
    // to a user-owned override first. The resulting override reaches the polish lane as well as the
    // corrector lane, which the underlying pack term never did.
    var word = candidate.word.ownedByUser()
    word.aliases.append(model.spellingToWrite)

    if let message = environment.saveWord(word) {
      // `reason` stays a fixed token, never the message: the message is authored for a human and
      // can quote what they selected, which is the one thing telemetry may not carry.
      environment.emit(.failed(stage: "save", reason: "refused"))
      finish(.writeFailed, usedSearch: usedSearch, rank: rank, kind: kind)
      return message
    }
    finish(
      usedSearch ? .acceptedAfterSearch : .accepted,
      usedSearch: usedSearch, rank: rank, kind: kind)
    return nil
  }

  /// The user chose to create a new word.
  func createNew(from model: QuickAddPanelModel) {
    environment.presentNewWordSheet(model.spellingToWrite)
    finish(.createdNew, usedSearch: !model.query.isEmpty, rank: nil, kind: nil)
  }

  /// Escape, clicking away, or the panel closing.
  func cancel(from model: QuickAddPanelModel) {
    finish(.cancelled, usedSearch: !model.query.isEmpty, rank: nil, kind: nil)
  }

  // MARK: - Internals

  private var startedAt: Date?

  private func finish(
    _ outcome: QuickAddOutcome, usedSearch: Bool, rank: Int?, kind: QuickAddTargetKind?
  ) {
    let started = startedAt ?? environment.now()
    startedAt = nil
    environment.emit(
      .resolved(
        outcome: outcome, usedSearch: usedSearch, candidateRank: rank, targetKind: kind,
        elapsedMilliseconds: elapsed(since: started)))
  }

  private func elapsed(since start: Date) -> Int {
    Int((environment.now().timeIntervalSince(start) * 1000).rounded())
  }
}
