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
    /// Persist a word and CONFIRM the spelling is on it afterwards. Returns nil only when both
    /// happened, or a user-facing message.
    ///
    /// The spelling is a separate parameter rather than read off `word.aliases.last`, because the
    /// postcondition would then depend on the caller having appended last — a fact no signature
    /// states and one edit could change without anything failing.
    var saveWord: (CustomWord, String) -> String?
    /// Move the panel to its compose stage, where the user authors the word by hand.
    ///
    /// **Takes no spelling, and that is the whole shape of the #2391 fix.** It used to present a
    /// SwiftUI `.sheet` seeded with the heard spelling — which presented NOTHING, because the panel
    /// refuses main status and AppKit refuses `beginSheet` on such a window, silently. The word is
    /// now assembled by the panel model, which already holds the heard spelling, so there is no
    /// second copy of it to hand anywhere and no second place that could disagree about trimming.
    var beginNewWord: () -> Void
    var emit: (QuickAddEvent) -> Void
    /// Injected so elapsed time is measurable without waiting.
    var now: () -> Date = Date.init
  }

  private var environment: Environment
  private let ranker = QuickAddRanker()

  init(environment: Environment) {
    self.environment = environment
  }

  /// Supply the create-new entry point after construction.
  ///
  /// Needed because the object that owns the live panel is the one that BUILDS this coordinator, so
  /// it cannot capture itself while doing so. Kept to this one seam rather than making the whole
  /// environment mutable: everything else is known at construction, and a settable environment is an
  /// invitation to change the rules at runtime.
  func setBeginNewWord(_ begin: @escaping () -> Void) {
    environment.beginNewWord = begin
  }

  /// One Quick Add invocation, from either door.
  ///
  /// Returns the panel model to present. **It no longer returns nil for a refusal, and the
  /// distinction is the whole point:** a `failed` event is a fact about a dashboard, and the review
  /// that caught the accept path reporting success without telling anyone caught this one branch
  /// over. A shortcut that emits telemetry and shows nothing is indistinguishable from a shortcut
  /// that is not registered.
  func begin(door: QuickAddDoor, selectionOverride: String? = nil) -> QuickAddPanelModel? {
    let startedAt = environment.now()
    let bundleID = environment.frontmostBundleID()

    // Read BEFORE anything activates our app — by the time a panel exists, the frontmost application
    // is us and the answer would be about our own window.
    //
    // Door B's text goes through `SelectionReader.classify` rather than straight into `.text`. The
    // Services system hands us whatever was on the pasteboard, and treating that as already-valid
    // is what let a whitespace-only selection open a panel on an empty string and an oversized one
    // reach the scorer — the ceiling and the empty check are properties of a SELECTION, not of the
    // door it arrived through.
    var selection: SelectionReader.Result =
      selectionOverride.map { SelectionReader.classify($0) } ?? environment.readSelection()

    // Refresh before ranking, every invocation. A sibling instance or the Settings window can have
    // changed the library since launch, and ranking a stale snapshot offers words that no longer
    // exist and hides ones that do.
    //
    // A failure REPLACES the selection rather than returning nil. Whatever was selected is now
    // unrankable, so the panel opens on the stated reason like any other refusal — which is what
    // §3 requires and what returning nil silently did not do.
    if !environment.refreshWords() {
      environment.emit(.failed(stage: "refresh", reason: "words_unreadable"))
      selection = .refused(.wordsUnavailable)
    }

    let heard: String
    let refusal: SelectionReader.Refusal?
    switch selection {
    case .text(let text):
      heard = text
      refusal = nil
    case .noSelection:
      heard = ""
      // No selection is not an error and not a success: the read SUCCEEDED and there was nothing to
      // read. It reaches the panel as the refusal meaning "you have not told me anything yet", the
      // panel states it, and the by-hand route is the only control that can do anything without a
      // heard word.
      //
      // **This used to be `.selectionUnavailable`, whose sentence names TERMINALS and accuses the
      // frontmost app of withholding a selection.** Pressing the shortcut having highlighted nothing
      // is the likeliest way to reach a refusal at all, so the commonest case got a confident
      // diagnosis of an app that had done nothing wrong instead of "select a word first".
      refusal = .nothingSelected
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

    // HELD, not emitted. `opened` names an event the user can see, so it fires when a panel is
    // actually on screen — see `didOpen()`. Emitting it here made presentation failure the one
    // remaining way to leave an open with nothing to resolve it, and it is the only such path that
    // cannot report a reason of its own.
    pendingOpen =
      .opened(
        door: door,
        refusal: refusal,
        sourceBundleID: bundleID,
        // The LENGTH, never the text. `CLAUDE.md` puts the privacy boundary at the network and the
        // test is whether user content crosses it; a character count is shape.
        heardScalarCount: heard.unicodeScalars.count,
        candidateCount: model.ranking.candidates.count,
        preselected: model.ranking.preselectedID != nil,
        topScore: model.ranking.topScore)

    self.startedAt = startedAt
    return model
  }

  /// The panel is on screen. Emits the held `opened` event.
  ///
  /// Split from `begin` so the funnel counts panels rather than attempts: one `opened`, one
  /// `resolved`, and no way to have the first without the second.
  func didOpen() {
    guard let event = pendingOpen else { return }
    pendingOpen = nil
    environment.emit(event)
  }

  /// The panel could NOT be shown. Discards the held `opened` and reports why.
  ///
  /// Never a `resolved`: nothing opened, so there is nothing to resolve, and inventing an outcome
  /// here would put a phantom row in the denominator of every rate computed from this funnel.
  func failedToOpen() {
    pendingOpen = nil
    startedAt = nil
    environment.emit(.failed(stage: "present", reason: "unmeasurable_panel"))
  }

  /// What an accept should write INTO, decided against the library as it is NOW.
  enum MergeTarget: Equatable {
    /// A pack term, converted to a user-owned override. Nothing in the user library to merge into.
    case override(CustomWord)
    /// A user word still in the library. Carries the CURRENT entry, never the snapshot.
    case live(CustomWord)
    /// It was in the library when the panel was ranked and is not there now.
    case gone
  }

  /// Resolve the merge target from the LIVE library rather than the ranking's snapshot.
  ///
  /// **`candidate.word` is a snapshot taken when the panel was ranked, and the panel is now
  /// persistent.** `windowDidResignKey` is deliberately a no-op — because treating focus loss as a
  /// dismissal cancelled the panel 339 ms after opening — so it can sit open across a visit to
  /// Settings. Appending an alias to that snapshot and handing it to `CustomWordsManager.update`
  /// replaces the WHOLE stored entry, so a canonical, alias, category, strictness or usage change
  /// made in between is silently reverted: a write that reports success while undoing the user's own
  /// edit.
  ///
  /// A third instance of two correct fixes composing into a defect neither had alone. Persistence
  /// was the fix for self-cancellation, and persistence is what gives the snapshot time to go stale.
  ///
  /// `.gone` is the same defect pointing the other way and is why this returns three cases rather
  /// than an optional: writing the snapshot back for a word deleted while the panel sat open would
  /// RESURRECT it, which is a silent undo of a deletion rather than of an edit.
  ///
  /// Scope, stated rather than implied: this reads the in-memory library, which is the one the
  /// editor writes through, so it covers every edit made inside this app. It is not a cross-process
  /// claim, and the app does not support a second instance.
  static func mergeTarget(
    for candidate: QuickAddRanker.Candidate, in userWords: [CustomWord]
  ) -> MergeTarget {
    // ASKED BEFORE THE PACK BRANCH, and the order is the whole point. `ownedByUser()` PRESERVES the
    // id, so a pack term the user overrode while this panel sat open is now a real user entry under
    // that same id — and converting the snapshot again would overwrite the override they just made.
    // A pack candidate that has not been overridden cannot be here: `packTermsNotOverridden` filters
    // the ranking by exactly this id set, so a pack row reaching this line has no live twin.
    if let current = userWords.first(where: { $0.id == candidate.word.id }) {
      return .live(current)
    }
    // **A pack row whose CANONICAL the user already owns under a different id.** `ownedByUser()`
    // keeps the pack's id, and `packTermsNotOverridden` filters the ranking by ID, so a user word
    // called "Codec" and an enabled pack term called "Codec" are two rows with two ids and one name.
    // Converting the pack snapshot then hands `CustomWordsManager.add` a colliding canonical, which
    // it refuses SILENTLY (`guard !words.contains(sameCanonical) else { return }`) — and the
    // post-write confirmation then finds the spelling on the USER word and reports success for an
    // override that was never created.
    //
    // Merging into the user's own entry is not a consolation prize, it is the only action that can
    // succeed: while that canonical is taken, no override under it is writable, and the end state
    // the user asked for — this spelling maps to that word — is exactly what this produces.
    //
    // Scoped to pack rows deliberately. A USER candidate missing by id is `.gone`, which is a
    // deletion the panel must not paper over by matching on a name that happens to be reused.
    if candidate.isPackTerm,
      let sameName = userWords.first(where: {
        $0.canonical.caseInsensitiveCompare(candidate.word.canonical) == .orderedSame
      })
    {
      return .live(sameName)
    }
    // A PACK term cannot be written through the words coordinator: `CustomWordsManager.update` looks
    // the id up in the user library, does not find it, and returns having written NOTHING. Convert
    // to a user-owned override first. The resulting override reaches the polish lane as well as the
    // corrector lane, which the underlying pack term never did.
    guard !candidate.isPackTerm else { return .override(candidate.word.ownedByUser()) }
    return .gone
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
    let usedSearch = model.isSearching
    let rank = model.ranking.candidates.firstIndex { $0.id == candidate.id }

    // **`kind` comes from the RESOLVED target, not from `candidate.isPackTerm`**, and this is the
    // third and last member of the class rounds four and six each found one of: a decision in this
    // function reading a value captured when the panel was RANKED rather than when Return was
    // pressed. Enumerated rather than waited for — `model.isSearching` is live, `rank` is a fact
    // about the ranking shown and is correctly a snapshot, and `spellingToWrite` is the user's
    // selection rather than library state and must NOT be re-read. That leaves this one.
    //
    // A pack term the user overrode while the panel sat open resolves to `.live`, so a USER word is
    // written while the snapshot still says pack. `pack_term` is a claim about what was written, so
    // reporting it there is a metric asserting the opposite of what happened.
    var word: CustomWord
    let kind: QuickAddTargetKind
    switch Self.mergeTarget(for: candidate, in: environment.userWords()) {
    case .override(let converted):
      word = converted
      kind = .packTerm
    case .live(let current):
      word = current
      kind = .userWord
    case .gone:
      environment.emit(.failed(stage: "save", reason: "target_gone"))
      return QuickAddPanelCopy.wordNoLongerExists
    }

    // **ONE already-has question, asked of the LIVE word, and it replaces a guard that ran BEFORE
    // the resolver on `candidate.alreadyHasHeardSpelling`.** That flag is a fact about the ranking
    // taken when the panel opened, and the panel is persistent, so it is wrong in BOTH directions by
    // the time Return is pressed: the library can have GAINED the spelling (appending again stores
    // it twice and reports success) or LOST it (the user removed that alias in Settings, and the
    // panel then reports "already saved" about a spelling that is no longer there, having written
    // nothing).
    //
    // The first version of this fix kept the snapshot guard and added a live check below it, which
    // closed only the gained direction — the snapshot guard runs FIRST, so `alreadyHasHeardSpelling
    // == true` returned before the resolver could ever load the current entry. `fix-the-path-that-
    // runs-first`, inside the fix for a defect of the same family, one round later.
    //
    // The flag stays on `Candidate` and the VIEW still reads it: dimming a row and choosing a header
    // are display, and display from the ranking is what the user is looking at. The DECISION is live.
    guard
      !word.aliases.contains(where: {
        $0.caseInsensitiveCompare(model.spellingToWrite) == .orderedSame
      })
    else {
      finish(.alreadySaved, usedSearch: usedSearch, rank: rank, kind: kind)
      return nil
    }
    word.aliases.append(model.spellingToWrite)

    if let message = environment.saveWord(word, model.spellingToWrite) {
      // `reason` stays a fixed token, never the message: the message is authored for a human and
      // can quote what they selected, which is the one thing telemetry may not carry.
      environment.emit(.failed(stage: "save", reason: "refused"))
      // **DELIBERATELY NOT A RESOLUTION, and the outcome member it used to emit is gone.** A refused
      // write leaves the panel OPEN — that is the whole point of the fix that introduced it — so the
      // invocation has not ended and the user can still succeed or give up. Resolving here emitted
      // `write_failed` and then a second `resolved` when they did either, which is two terminal
      // events for one open. `resolved` means ENDED; the refusal is reported by the `failed` event
      // above, which is what that channel is for.
      return message
    }
    finish(
      usedSearch ? .acceptedAfterSearch : .accepted,
      usedSearch: usedSearch, rank: rank, kind: kind)
    return nil
  }

  /// The user chose to create a new word. **Moves the panel to its compose stage and resolves
  /// NOTHING.**
  ///
  /// Emitting `createdNew` here counted an intention as an outcome: backing out of composing leaves
  /// the panel up, and cancelling the panel then emitted a SECOND resolved event for one open. The
  /// funnel is one `opened` and one `resolved`, and a rate computed over a denominator that
  /// double-counts is worse than no rate.
  ///
  /// Takes the model it does nothing with, deliberately: every other outcome on this type is
  /// reported against the panel the user was looking at, and a signature that quietly stopped
  /// naming one would be the only place a reader has to check which panel is meant.
  func createNew(from model: QuickAddPanelModel) {
    _ = model
    environment.beginNewWord()
  }

  /// The sheet saved, and the word is confirmed present. Called by the caller that checked.
  ///
  /// Takes `usedSearch` rather than a model because the panel may already be gone — the sheet
  /// outlives it in at least one ordering — and an `if let model` at the call site made a CONFIRMED
  /// save emit nothing at all, which is the funnel hole this whole split exists to close.
  func didCreateNew(usedSearch: Bool) {
    finish(.createdNew, usedSearch: usedSearch, rank: nil, kind: nil)
  }

  /// The sheet's canonical was already in the library and already carried every spelling the user
  /// kept, so `CustomWordsManager.add` wrote nothing and nothing needed writing.
  ///
  /// A separate entry point rather than a flag on `didCreateNew`, because the two differ in the one
  /// way the funnel cares about: whether a word was created. `alreadySaved` is not new vocabulary
  /// for this — it already means "the word carried this spelling, so there was nothing to write",
  /// and it is the same fact arriving through the other door.
  func didFindAlreadySaved(usedSearch: Bool) {
    finish(.alreadySaved, usedSearch: usedSearch, rank: nil, kind: nil)
  }

  /// Escape, clicking away, or the panel closing.
  func cancel(from model: QuickAddPanelModel) {
    finish(.cancelled, usedSearch: model.isSearching, rank: nil, kind: nil)
  }

  // MARK: - Internals

  private var startedAt: Date?

  /// The `opened` event for a panel that has been built and not yet shown.
  private var pendingOpen: QuickAddEvent?

  private func finish(
    _ outcome: QuickAddOutcome, usedSearch: Bool, rank: Int?, kind: QuickAddTargetKind?
  ) {
    // **A SECOND RESOLUTION IS REFUSED, LOUDLY, rather than substituted for.** The old
    // `startedAt ?? environment.now()` invented a start time for an invocation that had already
    // ended, which is what let one open produce two terminal events with plausible elapsed times on
    // both. Removing the reason (above) and removing the possibility are different jobs: this is the
    // second, and it reports rather than swallows, because a silent drop is how the funnel would
    // come to disagree with reality without anyone learning why.
    guard let started = startedAt else {
      environment.emit(.failed(stage: "resolve", reason: "double_resolution"))
      return
    }
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
