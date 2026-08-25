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

  /// The panel currently up, if any. Held because the coordinator's outcome calls need the model the
  /// user was actually looking at, and a second invocation must reuse rather than stack.
  private var activeModel: QuickAddPanelModel?

  /// A new word the user asked to create, which drives the edit sheet's presentation.
  private var pendingNewWord: CustomWord?

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
        presentNewWordSheet: { _ in },
        emit: QuickAddTelemetryBridge.handler))

    // Assigned AFTER init rather than captured during it. `self` does not exist while the
    // coordinator is being built, and Swift says so; a placeholder that stayed would be a
    // Create-a-new-word button that renders, records its outcome, and opens nothing.
    //
    // Canonical EMPTY and focused: the user knows the misspelling, because they selected it. What
    // they have to supply is the correct form.
    coordinator.setPresentNewWordSheet { [weak self] spelling in
      self?.pendingNewWord = CustomWord(canonical: "", aliases: [spelling])
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
  }

  // MARK: - The two doors

  private func beginFromHotkey() {
    guard notAlreadyOpen() else { return }
    present(coordinator.begin(door: .hotkey))
  }

  /// Door B. Separate from the hotkey path only because the Service is HANDED its text.
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
  /// Doing nothing is the whole behaviour, and it is correct rather than lazy: the panel dismisses
  /// itself when it resigns key, so a visible panel is a FOCUSED panel and there is nothing to raise.
  /// The guard is on both doors because either can be fired while the other's panel is up — naming
  /// only the one review pointed at would leave the twin.
  private func notAlreadyOpen() -> Bool { !panelHost.isVisible }

  private func present(_ model: QuickAddPanelModel?) {
    guard let model else {
      // The coordinator already reported why. Nothing to show is not silence.
      return
    }
    activeModel = model
    let shown = panelHost.present(
      QuickAddRoot(
        model: model,
        onAccept: { [weak self] candidate in self?.accept(candidate, model: model) },
        onCreateNew: { [weak self] in self?.createNew(model: model) },
        onCancel: { [weak self] in self?.cancel(model: model) },
        newWord: Binding(
          get: { [weak self] in self?.pendingNewWord },
          set: { [weak self] in self?.pendingNewWord = $0 }),
        // `usedSearch` is captured HERE, from the model this panel was built with, rather than
        // read back off `activeModel` at save time. The sheet outlives the panel in at least one
        // ordering, and a nil lookup defaulting to false would report a search-assisted save as an
        // unassisted one — quietly, and in the direction that flatters the ranking.
        onSaveNewWord: { [weak self] word in
          self?.saveNewWord(word, usedSearch: !model.query.isEmpty)
        }))

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
  }

  // MARK: - Outcomes

  /// Dismiss only when the word was actually saved. The same rule `saveNewWord` below already
  /// followed — a refused write leaves the panel up, carrying the reason.
  private func accept(_ candidate: QuickAddRanker.Candidate, model: QuickAddPanelModel) {
    if let message = coordinator.accept(candidate, from: model) {
      model.noteWriteFailure(message)
      return
    }
    dismiss()
  }

  private func createNew(model: QuickAddPanelModel) {
    // NOT dismissed: the edit sheet presents OVER this panel, and tearing the panel down would take
    // its presenter with it.
    coordinator.createNew(from: model)
  }

  private func cancel(model: QuickAddPanelModel) {
    coordinator.cancel(from: model)
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
  /// Returns nil on success or a user-facing message, which is the sheet's own contract.
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
  private func saveNewWord(_ word: CustomWord, usedSearch: Bool) -> String? {
    if let message = customWords.add(word) { return message }
    // Compare against the TRIMMED canonical, because that is what `add` stores. Comparing the raw
    // one reports a correct save as a failure whenever the user typed a leading space.
    let canonical = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let stored = customWords.customWords.first(where: {
      $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame
    }) else {
      return QuickAddPanelCopy.newWordNotSaved
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
      return QuickAddPanelCopy.newWordAlreadyExists(canonical: stored.canonical)
    }
    coordinator.didCreateNew(usedSearch: usedSearch)
    dismiss()
    return nil
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
    pendingNewWord = nil
    panelHost.dismiss()
  }
}

/// The panel's content plus the edit sheet it can present over itself.
///
/// A real SwiftUI `.sheet`, not the edit view hosted directly: `CustomWordEditSheet` dismisses itself
/// through `@Environment(\.dismiss)`, which is supplied by a presenting context. Hosted bare in a
/// panel there is no such context, so its Cancel button would render, be clickable, and do nothing.
private struct QuickAddRoot: View {
  @Bindable var model: QuickAddPanelModel
  let onAccept: (QuickAddRanker.Candidate) -> Void
  let onCreateNew: () -> Void
  let onCancel: () -> Void
  @Binding var newWord: CustomWord?
  let onSaveNewWord: (CustomWord) -> String?

  var body: some View {
    QuickAddPanelView(
      model: model, onAccept: onAccept, onCreateNew: onCreateNew, onCancel: onCancel
    )
    .sheet(item: $newWord) { word in
      CustomWordEditSheet(word: word, onSave: onSaveNewWord)
    }
  }
}
