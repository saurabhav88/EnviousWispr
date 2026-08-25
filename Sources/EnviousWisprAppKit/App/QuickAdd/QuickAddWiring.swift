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
        saveWord: { word in
          // `add` when the word is new to the user library, `update` when it is already there. A
          // converted pack term is NEW here even though its id is the pack's, which is why the
          // decision is by membership rather than by `source`.
          customWords.customWords.contains { $0.id == word.id }
            ? customWords.update(word)
            : customWords.add(word)
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
    present(coordinator.begin(door: .hotkey))
  }

  /// Door B. Separate from the hotkey path only because the Service is HANDED its text.
  func beginFromService(text: String) {
    present(coordinator.begin(door: .service, selectionOverride: text))
  }

  private func present(_ model: QuickAddPanelModel?) {
    guard let model else {
      // The coordinator already reported why. Nothing to show is not silence.
      return
    }
    activeModel = model
    panelHost.present(
      QuickAddRoot(
        model: model,
        onAccept: { [weak self] candidate in self?.accept(candidate, model: model) },
        onCreateNew: { [weak self] in self?.createNew(model: model) },
        onCancel: { [weak self] in self?.cancel(model: model) },
        newWord: Binding(
          get: { [weak self] in self?.pendingNewWord },
          set: { [weak self] in self?.pendingNewWord = $0 }),
        onSaveNewWord: { [weak self] word in self?.saveNewWord(word) }))
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
  private func saveNewWord(_ word: CustomWord) -> String? {
    let message = customWords.add(word)
    if message == nil { dismiss() }
    return message
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
