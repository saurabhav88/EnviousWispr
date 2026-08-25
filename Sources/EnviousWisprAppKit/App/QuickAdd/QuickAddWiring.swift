import AppKit
import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import SwiftUI

/// Everything Quick Add needs to actually run, in ONE object (#2381).
///
/// **One stored property in the composition root, not four.** `EnviousWisprAppCeilingsTests` caps
/// what `WisprBootstrapper` may hold, and the documented way to spend one slot on a group of
/// collaborators is a nested type — the same pattern `RecordingLockedAccess` and
/// `SparkleUpdaterFactory` use. It is also what keeps the deletability property honest: removing this
/// feature is three directories, one property, and one call.
///
/// This is composition, not behaviour. Every decision lives in the coordinator; this decides only who
/// holds whom and who is told about what.
@MainActor
final class QuickAddWiring {

  private let coordinator: QuickAddCoordinator
  private let panelHost = QuickAddPanelHost()
  /// Built in `install()`, not here: its whole job is to call back into this object, and `self` does
  /// not exist yet during init. Constructing it early with a placeholder closure is how a door ships
  /// registered, enabled, and wired to nothing.
  private var serviceProvider: QuickAddServiceProvider?
  private let hotkeyService: HotkeyService
  private let customWords: CustomWordsCoordinator

  /// How long a confirmation stays up after Return. The founder's number: *"fade away by itself
  /// after two seconds"*.
  private static let noticeSeconds: Double = 2

  /// How long the opened-onto-a-covered-word notice stays up.
  ///
  /// Longer than the confirmation, and for a reason rather than for feel: that notice ASKS
  /// something. The user has to read it, decide whether the ranking was right about them, and reach
  /// for the search field if it was not. A confirmation asks nothing — it reports a decision the
  /// user already made — so it can be as brief as it is legible.
  private static let searchableNoticeSeconds: Double = 3

  /// The pending fade. Cancelled by anything that takes the panel down first, so a stale timer can
  /// never resolve or dismiss the NEXT invocation.
  private var noticeDismissal: Task<Void, Never>?

  /// The panel currently up, if any. Held because the coordinator's outcome calls need the model the
  /// user was actually looking at, and a second invocation must reuse rather than stack.
  private var activeModel: QuickAddPanelModel?

  init(
    hotkeyService: HotkeyService,
    customWords: CustomWordsCoordinator,
    packManager: VocabularyPackManager
  ) {
    self.hotkeyService = hotkeyService
    self.customWords = customWords
    self.coordinator = QuickAddCoordinator(
      environment: QuickAddCoordinator.Environment(
        readSelection: { SelectionReader.read() },
        frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        refreshWords: { customWords.refreshFromDiskIfPossible() },
        userWords: { customWords.customWords },
        packTerms: { packManager.enabledPackTerms() },
        saveWord: { word, spelling in
          Self.saveAndConfirm(word, carrying: spelling, through: customWords)
        },
        beginNewWord: {},
        emit: QuickAddTelemetryBridge.handler))

    // Assigned AFTER init rather than captured during it. `self` does not exist while the
    // coordinator is being built, and Swift says so; a placeholder that stayed would be a
    // Create-a-new-word button that renders, records its outcome, and opens nothing.
    //
    // **Which is what shipped, for a different reason, and is what #2391 fixes.** The placeholder
    // was replaced correctly and the mechanism it was replaced with could not work: a SwiftUI
    // `.sheet` over a panel that refuses main status presents nothing, silently. The button ran its
    // action, set its binding, and changed no pixel.
    coordinator.setBeginNewWord { [weak self] in
      self?.activeModel?.beginComposing()
    }
  }

  /// Install both doors. Call after launch: `NSApp.servicesProvider` set before the app has finished
  /// launching is registered against an app that cannot yet answer.
  func install() {
    hotkeyService.onQuickAdd = { [weak self] in self?.beginFromHotkey() }
    let provider = QuickAddServiceProvider(
      begin: { [weak self] text in self?.beginFromService(text: text) })
    provider.install()
    serviceProvider = provider
    panelHost.onDismiss = { [weak self] in self?.panelDismissed() }
    // Escape means "back to the list" while composing and "close" otherwise, and only the model
    // knows which. A missing wire here dismisses, which is the shipped behaviour rather than a trap.
    panelHost.shouldConsumeCancel = { [weak self] in self?.activeModel?.consumeCancel() ?? false }
  }

  // MARK: - The two doors

  private func beginFromHotkey() {
    guard notAlreadyOpen() else { return }
    present(coordinator.begin(door: .hotkey))
  }

  /// Door B. Separate from the hotkey path only because the Service is HANDED its text.
  /// The status-item menu handed us text it read while the menu was open.
  ///
  /// **Takes the text rather than reading it here, and that is the whole point of the door.** The
  /// menu is rendered while the user's own application is still frontmost — measured, twice — so the
  /// read happens there, at the one moment the answer is about their document. Reading it from this
  /// side would run after the click, by which time the menu has closed and the answer is ours.
  func beginFromMenuBar(text: String) {
    guard notAlreadyOpen() else { return }
    present(coordinator.begin(door: .menuBar, selectionOverride: text))
  }

  func beginFromService(text: String) {
    guard notAlreadyOpen() else { return }
    present(coordinator.begin(door: .service, selectionOverride: text))
  }

  /// Whether a new capture may start at all.
  ///
  /// **Pressing the shortcut again while the panel is up is an ordinary thing to do** — the user is
  /// not sure it fired — and without this it started a SECOND capture whose frontmost application is
  /// our own panel. The new read finds no selection, so the word the user actually selected is
  /// replaced by a refusal, the first `opened` event never resolves, and the funnel gains an open it
  /// can never close.
  ///
  /// **The "doing nothing is correct" half of this rested on a premise that a later fix removed.**
  /// It read: the panel dismisses itself when it resigns key, so a visible panel is a FOCUSED panel
  /// and there is nothing to raise. `windowDidResignKey` is now deliberately a no-op — because
  /// treating focus loss as a dismissal cancelled the panel 339 ms after opening — so a panel can now
  /// be visible and NOT key. In that state every later hotkey and Services invocation returned false
  /// here and did nothing at all: no raise, no new capture, no reason given.
  ///
  /// Two correct fixes composing into a defect neither had alone, which is why the reason is written
  /// down beside the code rather than in the commit that changed the other one.
  ///
  /// Raising rather than re-capturing is deliberate. The panel already holds a selection the user
  /// made; a second press is "I am not sure that fired", and answering it by throwing away their
  /// word to read whatever is frontmost NOW — which is our own panel — is the defect this guard was
  /// added to prevent in the first place.
  private func notAlreadyOpen() -> Bool {
    guard
      Self.mayBeginCapture(
        panelVisible: panelHost.isVisible, hasLiveInvocation: activeModel != nil)
    else {
      panelHost.raise()
      return false
    }
    // Replacing a fading confirmation rather than raising it means its timer must not survive to
    // dismiss the panel the new capture is about to fill.
    noticeDismissal?.cancel()
    noticeDismissal = nil
    return true
  }

  /// What a VoiceOver user must HEAR when the panel changes what it is telling them, or nil when
  /// the panel is asking rather than telling.
  ///
  /// **One derivation, so the two channels cannot disagree.** It returns the string the view
  /// renders — not a paraphrase — because a spoken confirmation that differs from the visible one is
  /// two answers to "what happened", and the blind user has no way to notice.
  ///
  /// A write failure outranks a notice. They are mutually exclusive today (`showNotice` clears the
  /// failure), and stating the order closes the case rather than leaving it to that invariant.
  package static func announcement(
    notice: QuickAddPanelModel.Notice?, writeFailure: String?
  ) -> String? {
    if let writeFailure { return QuickAddPanelCopy.writeFailure(writeFailure) }
    if let notice { return QuickAddPanelCopy.notice(notice) }
    return nil
  }

  /// Speak the panel's current message, if it has one.
  ///
  /// **`.accessibilityLabel` is not this.** A label names an element when it is VISITED; every
  /// message this panel shows is a dynamic status change, and two of the three vanish on a timer
  /// while focus is somewhere else entirely — the terminal confirmation deliberately releases focus,
  /// and the searchable notice gives it to the search field rather than to the sentence.
  private func speak(_ model: QuickAddPanelModel) {
    guard let text = Self.announcement(notice: model.notice, writeFailure: model.writeFailure)
    else { return }
    OverlayDirector.postAnnouncement(.medium(text))
  }

  /// Whether a fresh capture may start.
  ///
  /// **A confirmation fading out is NOT a live panel, and treating it as one costs the user their
  /// next word.** `conclude` clears `activeModel` because the invocation has already resolved; the
  /// window then stays up for two seconds carrying `"clawwed" added to Claude`. Inside that window
  /// the visibility test alone raises the confirmation and refuses the capture — which from the
  /// user's side is the shortcut not firing, on the second word they try to add in a row. Adding two
  /// words in a row is the ordinary way to use this feature, so the window is not rare.
  ///
  /// Split out for the same reason `newWordOutcome` was: the version inline could not be tested, and
  /// the state it gets wrong is one no test could reach. Two Bools, because those are the only two
  /// facts the decision turns on and naming them is what makes the case above statable at all.
  package static func mayBeginCapture(panelVisible: Bool, hasLiveInvocation: Bool) -> Bool {
    guard panelVisible else { return true }
    return !hasLiveInvocation
  }

  private func present(_ model: QuickAddPanelModel?) {
    guard let model else {
      // The coordinator already reported why. Nothing to show is not silence.
      return
    }
    activeModel = model
    // A previous invocation's fade must not reach this panel.
    noticeDismissal?.cancel()
    noticeDismissal = nil
    let shown = panelHost.present(
      QuickAddPanelView(
        model: model,
        onAccept: { [weak self] candidate in self?.accept(candidate, model: model) },
        onCreateNew: { [weak self] in self?.createNew(model: model) },
        onCreate: { [weak self] word in self?.createWord(word, model: model) },
        onCancel: { [weak self] in self?.cancel(model: model) }))

    // The host refuses to present a panel it could not measure, because an unmeasurable panel is an
    // invisible window that reports success. Clearing `activeModel` matters as much as the event:
    // a stale model here is what a later dismiss would resolve, attributing a cancel to an open that
    // never happened.
    guard shown else {
      activeModel = nil
      coordinator.failedToOpen()
      return
    }
    coordinator.didOpen()
    // Opened onto a word that already knows this spelling: the panel says so and fades, unless the
    // user types (#2391 §3).
    if model.isShowingSearchableNotice {
      speak(model)
      scheduleSearchableNoticeFade(for: model)
    }
  }

  // MARK: - Outcomes

  /// Confirm what happened, then leave. A refused write leaves the panel up carrying the reason —
  /// the same rule `saveNewWord` below already followed.
  ///
  /// **The confirmation exists because failure was handled better than success (#2391 §1).** A
  /// refusal kept the panel open and stated why; a save called `dismiss()` and that was the entire
  /// behaviour. So the user learned more from failing than from succeeding, on a feature whose whole
  /// promise is that succeeding is invisible — what they were told would happen only shows up in a
  /// future dictation.
  ///
  /// The sentence is composed from what the coordinator REPORTS, never from the row the user
  /// clicked: the row is a snapshot taken when the panel opened, and the panel is persistent.
  private func accept(_ candidate: QuickAddRanker.Candidate, model: QuickAddPanelModel) {
    switch coordinator.accept(candidate, from: model) {
    case .refused(let message):
      model.noteWriteFailure(message)
      speak(model)
    case .saved(let word):
      conclude(model, .saved, spelling: model.spellingToWrite, word: word)
    case .alreadyHad(let word):
      conclude(model, .nothingToAdd, spelling: model.spellingToWrite, word: word)
    }
  }

  /// The invocation is over. Say what happened, hand the keyboard back, and fade.
  ///
  /// **`activeModel` is cleared FIRST, and that is what makes the beat safe.** The coordinator has
  /// already resolved; leaving the model live would let the fade — or an Escape during it — report a
  /// SECOND outcome for one open, which the double-resolution guard would then record as a defect
  /// rather than as the ordinary thing the user just did.
  ///
  /// Focus goes back before the panel does. The user has already returned to their sentence, and a
  /// key-capable panel that lingers for two seconds eats the first letters of their next word — a
  /// confirmation that costs a keystroke is worse than no confirmation, which is what nearly sent
  /// this to the dictation overlay instead of the panel.
  private func conclude(
    _ model: QuickAddPanelModel, _ kind: QuickAddPanelModel.Notice.Kind, spelling: String,
    word: String
  ) {
    activeModel = nil
    model.showNotice(kind, spelling: spelling, word: word)
    speak(model)
    noticeDismissal?.cancel()
    noticeDismissal = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.noticeSeconds))
      guard !Task.isCancelled else { return }
      self?.dismiss()
    }
  }

  /// Fade the opened-onto-a-covered-word notice, resolving it as the non-event it is.
  ///
  /// **This one HAS to resolve, and the shipped `cancelled` would have been wrong.** Nothing was
  /// written, but the user did not abandon anything either — there was nothing to abandon. The
  /// funnel already has the word for it.
  ///
  /// Re-checked at fire time rather than cancelled on every keystroke: the user can type, which
  /// returns the panel to its full list and makes this invocation live again. One guard beats a
  /// cancellation the model would have to remember to request.
  private func scheduleSearchableNoticeFade(for model: QuickAddPanelModel) {
    noticeDismissal?.cancel()
    noticeDismissal = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.searchableNoticeSeconds))
      guard !Task.isCancelled, let self else { return }
      guard self.activeModel === model, model.isShowingSearchableNotice else { return }
      self.coordinator.didFindAlreadySaved(usedSearch: false)
      self.dismiss()
    }
  }

  private func createNew(model: QuickAddPanelModel) {
    // NOT dismissed: composing is a STAGE of this panel now, so tearing it down would take the
    // field the user is about to type into with it.
    coordinator.createNew(from: model)
  }

  /// The user pressed Return on the compose field.
  ///
  /// **A refusal keeps the panel up carrying the reason**, exactly as the accept route does — which
  /// is the rule the sheet route already followed and the one thing worth preserving from it.
  private func createWord(_ word: CustomWord, model: QuickAddPanelModel) {
    // Read LIVE rather than captured at present time. The old capture existed because the sheet
    // outlived the panel in at least one ordering; a stage of the panel cannot, and the honest
    // answer to "did the ranking need rescuing" is the state the user was in when they committed.
    switch saveNewWord(word, usedSearch: model.isSearching) {
    case .refused(let message):
      model.noteWriteFailure(message)
      speak(model)
    case .created(let canonical):
      // **Composed from the WORD THAT WAS WRITTEN, never from the selection.** Selecting a word that
      // is already spelled correctly and authoring it is an ordinary thing to do: `draftWord`
      // correctly declines to store a word as an alias of itself, so nothing is attached — and
      // choosing the sentence by "was the selection non-empty" then said `"Claude" added to Claude`
      // about an add that did not happen. Third instance on this branch of a sentence composed from
      // a neighbouring value instead of from what the write path reports.
      let attached = word.aliases.first ?? ""
      conclude(
        model, attached.isEmpty ? .created : .saved, spelling: attached, word: canonical)
    case .alreadyComplete(let canonical):
      conclude(model, .nothingToAdd, spelling: model.spellingToWrite, word: canonical)
    case .alreadyPresent(let canonical):
      // Split by OUTCOME rather than by re-testing the spelling here, which is the same rule the
      // confirmation follows: the sentence is composed from what the write path REPORTS. There is no
      // mishearing to name in this cell by construction, so `X already knows ""` cannot arise.
      conclude(model, .alreadyInWords, spelling: "", word: canonical)
    }
  }

  /// Only a LIVE invocation can be cancelled.
  ///
  /// **The close control stays on screen underneath a confirmation, deliberately** — dismissing the
  /// beat early is a reasonable thing to want — and `conclude` has already resolved by then. Without
  /// this the button emits a SECOND terminal event for one open, which the coordinator reports as
  /// `double_resolution`: a defect that never reaches the screen and quietly disagrees with the
  /// funnel.
  ///
  /// Identity, not a Bool: the captured `model` belongs to the panel this button was built for, and
  /// a later invocation reusing the panel must not have its outcome cancelled by a stale closure.
  private func cancel(model: QuickAddPanelModel) {
    if activeModel === model { coordinator.cancel(from: model) }
    dismiss()
  }

  /// The panel went away on its own — Escape, or the user clicking elsewhere.
  private func panelDismissed() {
    guard let model = activeModel else { return }
    activeModel = nil
    coordinator.cancel(from: model)
  }

  /// The edit sheet's Save. Routed through the SAME authority every other write uses, so its
  /// validation, its error message and its change notification are the ones the rest of the app
  /// already relies on — a second write path here would be a second set of rules.
  ///
  /// **Returns what happened rather than dismissing**, because the caller now has a sentence to
  /// say and cannot say it from a nil. Taking the panel down here would also mean the confirmation
  /// had nowhere to appear.
  ///
  /// **A nil return from `add` is not proof the word was saved, and this is the second time that
  /// assumption cost this feature a false success.** `CustomWordsManager.add` RETURNS silently,
  /// without throwing, when the canonical already exists case-insensitively — three lines below its
  /// own comment explaining that it throws precisely so a silent return cannot dismiss a sheet on a
  /// nil error. It also has a branch that restores a deleted built-in, which discards the aliases
  /// the user typed. Both end as: sheet closes, panel closes, nothing saved.
  ///
  /// So this asserts the OUTCOME rather than the call's return value — the word is there and it
  /// carries the spellings the user kept — which is the one check that covers both branches and any
  /// third one nobody has found yet.
  private enum NewWordSaveResult: Equatable {
    /// The word is in the library and it was not there before.
    case created(canonical: String)
    /// The canonical was already there and already carried every spelling the user kept.
    case alreadyComplete(canonical: String)
    /// The canonical was already there and there was no spelling to attach.
    case alreadyPresent(canonical: String)
    /// Nothing was written and the user did not get what they asked for.
    case refused(String)
  }

  private func saveNewWord(_ word: CustomWord, usedSearch: Bool) -> NewWordSaveResult {
    // Snapshotted BEFORE the write, because it is the only way to tell "created" from "was already
    // there". See the vacuity note on the guard below.
    let canonicalExistedBefore = customWords.customWords.contains {
      $0.canonical.caseInsensitiveCompare(
        word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
    if let message = customWords.add(word) { return .refused(message) }
    // Compare against the TRIMMED canonical, because that is what `add` stores. Comparing the raw
    // one reports a correct save as a failure whenever the user typed a leading space.
    let canonical = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let stored = customWords.customWords.first(where: {
        $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame
      })
    else {
      return .refused(QuickAddPanelCopy.newWordNotSaved)
    }
    // Blank rows are ordinary trimming, not a lost edit — the editor leaves them behind. A NON-blank
    // spelling that vanished is the lie worth catching.
    let kept = word.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let missing = kept.filter { alias in
      !stored.aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame }
    }
    guard missing.isEmpty else {
      return .refused(QuickAddPanelCopy.newWordAlreadyExists(canonical: stored.canonical))
    }
    // **AND THE GUARD ABOVE IS VACUOUS WHEN THERE IS NOTHING TO CONFIRM.** Quick Add opened without
    // a readable selection has no heard spelling, so the sheet starts with one BLANK alias, `kept`
    // is empty, and `missing.isEmpty` is trivially true. A canonical that already existed then took
    // the success path: `add` silently no-ops on a duplicate, the word the user typed was never
    // created, and the panel closed saying nothing.
    //
    // Seventh instance of this feature's one class, and it arrived INSIDE the fix for the fifth —
    // the postcondition was written for the case where a spelling exists to look for, and the state
    // with no spelling is exactly the state it cannot see. So the existence question is asked
    // separately: with nothing to confirm, "was this canonical already here before I wrote" is the
    // only evidence available.
    switch Self.newWordOutcome(
      keptSpellings: kept, missingSpellings: missing,
      canonicalExistedBefore: canonicalExistedBefore)
    {
    case .created:
      coordinator.didCreateNew(usedSearch: usedSearch)
      return .created(canonical: stored.canonical)
    case .alreadyComplete:
      // NOT `didCreateNew`. Nothing was created, so counting one puts a write that did not happen in
      // the numerator of every rate computed off this funnel — and `alreadySaved` already means
      // exactly this, on the accept route, for exactly this reason.
      coordinator.didFindAlreadySaved(usedSearch: usedSearch)
      return .alreadyComplete(canonical: stored.canonical)
    case .alreadyPresent:
      coordinator.didFindAlreadySaved(usedSearch: usedSearch)
      return .alreadyPresent(canonical: stored.canonical)
    case .refused:
      return .refused(QuickAddPanelCopy.newWordAlreadyExists(canonical: stored.canonical))
    }
  }

  /// Whether the sheet's save actually produced the word the user asked for.
  ///
  /// **Split out because the version inline could not be tested, and it was wrong in exactly the
  /// state no test could reach.** The postcondition asks "did the spellings the user kept land on
  /// the word", which is the right question whenever there ARE spellings. Quick Add opened without a
  /// readable selection has none — the sheet starts with one blank alias — so the check passed
  /// trivially, and a canonical that already existed took the success path while `add` silently
  /// no-oped. Nothing was created and the panel closed saying nothing.
  ///
  /// So there are two questions, not one, and which applies depends on whether there is anything to
  /// confirm. With spellings: did they land. Without: was this canonical already here before the
  /// write, because that is then the only evidence available.
  ///
  /// **AND A BOOL WAS THE WRONG RETURN TYPE, which round five found.** The first version answered
  /// true for "the canonical already existed and already carried the spelling", on the stated
  /// reasoning that adding a spelling to a word you already have is the feature's main path. That
  /// reasoning is about the ACCEPT route and is false here: through Create New, an existing
  /// canonical means `CustomWordsManager.add` silently wrote NOTHING, always. So the panel reported
  /// a creation, and the funnel counted a `created_new`, for a write that did not happen.
  ///
  /// The desired end state was nonetheless already true, which is why the answer is not `false`
  /// either — refusing would hand the user a message telling them to go and add a spelling the word
  /// already has. Three states, and the third is the one a Bool cannot hold: this is the same
  /// three-valued shape as `QuickAddCoordinator.mergeTarget`, which is what `validation-discipline`
  /// means by an unhandled input still landing somewhere, usually in the permissive branch.
  package enum NewWordOutcome: Equatable {
    /// The write produced the word the user asked for.
    case created
    /// The canonical was already there and already carried every spelling the user kept. Nothing was
    /// written and nothing needed to be: report it as already saved rather than as a creation.
    case alreadyComplete
    /// Nothing was written and the user did not get what they asked for. Say so, keep the panel up.
    case refused
    /// The canonical was already there and there was no spelling to attach, so nothing was written
    /// and nothing needed to be — and unlike `refused`, there is nothing the user can DO about it.
    ///
    /// **Its own case rather than either neighbour, and both alternatives were tried.** It was
    /// `refused`, which is honest about the write and wrong about the panel: only the invocation
    /// that opened WITHOUT a readable selection can reach this cell, and that panel's ranking is
    /// empty and its search field disabled, so the refusal's copy sent the user to a list that
    /// cannot exist. Folding it into `alreadyComplete` fixes that and retires a distinction a review
    /// round established — that cell has no spelling to confirm, so `alreadyComplete`'s
    /// postcondition is vacuous there, which is the whole reason it was split out.
    ///
    /// Reports as `alreadySaved` like `alreadyComplete` does: nothing was created either way, so the
    /// funnel does not care, and inventing a fifth outcome for it would put a distinction in the
    /// telemetry that nobody asked a question about.
    case alreadyPresent
  }

  package static func newWordOutcome(
    keptSpellings: [String], missingSpellings: [String], canonicalExistedBefore: Bool
  ) -> NewWordOutcome {
    // Outranks everything below: a spelling the user typed that is not on the word is a lost edit,
    // whatever else is true.
    guard missingSpellings.isEmpty else { return .refused }
    // Through this route `add` no-ops on a duplicate canonical, so a canonical that was NOT there
    // before is the only evidence a creation happened.
    guard canonicalExistedBefore else { return .created }
    // It was already there, and nothing the user kept is missing, so the end state they asked for
    // holds either way. The two differ in whether there was a spelling to confirm, and that is the
    // distinction round three drew — kept, because `alreadyComplete`'s postcondition is vacuous
    // without one. What changed is only its NAME for the no-spelling half: `refused` was honest
    // about the write and wrong about the panel. See the case docs above.
    return keptSpellings.isEmpty ? .alreadyPresent : .alreadyComplete
  }

  /// Write a word and PROVE the spelling is on it afterwards.
  ///
  /// **A nil return from the words coordinator is not evidence the write happened**, and this is the
  /// third distinct way that has been true in this feature. `add` returns silently for a duplicate
  /// canonical and for a deleted-built-in restore; `update` opens
  /// `guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }`, so a word
  /// another instance removed while this panel was open is written NOWHERE and reported as saved.
  /// The panel then closes on a spelling that was never stored.
  ///
  /// Every one of those is invisible to the caller and all of them have one observable: is the
  /// spelling on the word now. So that is what this asks, instead of asking three questions about
  /// how the write was routed.
  ///
  /// `add` when the word is new to the user library, `update` when it is already there. A converted
  /// pack term is NEW here even though its id is the pack's, which is why the decision is by
  /// membership rather than by `source`.
  private static func saveAndConfirm(
    _ word: CustomWord, carrying spelling: String, through customWords: CustomWordsCoordinator
  ) -> String? {
    let existing = customWords.customWords.contains { $0.id == word.id }
    if let message = existing ? customWords.update(word) : customWords.add(word) { return message }

    let wanted = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
    let landed = customWords.customWords.contains { stored in
      stored.canonical.caseInsensitiveCompare(word.canonical) == .orderedSame
        && stored.aliases.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }
    return landed ? nil : QuickAddPanelCopy.newWordNotSaved
  }

  private func dismiss() {
    activeModel = nil
    noticeDismissal?.cancel()
    noticeDismissal = nil
    panelHost.dismiss()
  }
}
