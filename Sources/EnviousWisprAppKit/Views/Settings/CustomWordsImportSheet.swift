import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// The Custom Words import sheet (#1657 PR-F1 shell, #1669 PR-F2c review).
///
/// One observable model, one root `switch`, one container-level `.animation()`
/// — the `OnboardingV2View` root-switch pattern without its timers or
/// permissions logic. The three input screens are still placeholders until
/// their real sources land (P1 paste, U1 upload, 4a smart import); Review and
/// the commit path are real from F2c on.
///
/// The sheet is reachable only through the DEBUG-only "Preview import" button
/// in Your Words, so no release user can see the remaining placeholders.
/// Dismissing at any point cancels in-flight work and writes nothing.
struct CustomWordsImportSheet: View {
  private static let screenTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 20)),
    removal: .opacity
  )

  @State private var model: CustomWordsImportFlowModel
  @State private var showDiscardConfirm = false
  @Environment(\.dismiss) private var dismiss

  init(dependencies: CustomWordsImportFlowModel.Dependencies) {
    _model = State(initialValue: CustomWordsImportFlowModel(dependencies: dependencies))
  }

  var body: some View {
    // The macOS-15+ native window-close protection (#1700) is a second,
    // deliberately separate, best-effort layer for the OS-level window-close
    // trigger only — it is NOT proven reliable for this app's real nested
    // sheet-inside-window topology (see the plan's empirical findings), so it
    // is never relied on for Cancel/Escape/Done, which always use the local
    // dialog below on every macOS version.
    if #available(macOS 15.0, *) {
      sheetContent
        .dismissalConfirmationDialog(
          "You've entered words. This will discard them.",
          shouldPresent: model.hasDiscardableDraft
        ) {
          Button("Discard", role: .destructive) { model.cancel() }
          Button("Keep editing", role: .cancel) {
            model.keepEditingDiscardableDraft()
          }
        }
    } else {
      sheetContent
    }
  }

  private var sheetContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      ZStack {
        switch model.step {
        case .methodPicker:
          ImportMethodPickerScreen(model: model)
            .transition(Self.screenTransition)
        case .paste:
          ImportPasteScreen(model: model)
            .transition(Self.screenTransition)
        case .upload:
          ImportUploadScreen(model: model)
            .transition(Self.screenTransition)
        case .smartImportAppPicker:
          ImportSmartAppPickerScreen(model: model)
            .transition(Self.screenTransition)
        case .review:
          ImportReviewScreen(model: model)
            .transition(Self.screenTransition)
        case .working(let work):
          ImportWorkingScreen(work: work)
            .transition(Self.screenTransition)
        case .result(let result):
          ImportResultScreen(
            result: result,
            droppedAliasCollisionCount: model.droppedAliasCollisionCount
          )
          .transition(Self.screenTransition)
        }
      }
      .animation(.easeInOut(duration: 0.25), value: model.step)

      footer
    }
    .padding(24)
    .frame(width: 480)
    // The footer's Cancel is not the only way out: closing the settings window
    // or clearing the sheet route dismisses without it, and an in-flight load
    // or comparison would otherwise keep running against a sheet that is gone.
    .onDisappear { model.cancel() }
    // Single mechanism for Cancel, Escape, and Done, on every macOS version
    // (#1700) — see `requestCancel()`.
    .confirmationDialog(
      "You've entered words. This will discard them.",
      isPresented: $showDiscardConfirm,
      titleVisibility: .visible
    ) {
      Button("Discard", role: .destructive) {
        model.cancel()
        dismiss()
      }
      Button("Keep editing", role: .cancel) {
        model.keepEditingDiscardableDraft()
      }
    }
  }

  /// Single authority for every explicit discard action (Cancel, Escape via
  /// the same `.keyboardShortcut(.cancelAction)`, and Done) (#1700). Calls
  /// `model.cancel()` explicitly on the no-draft path rather than relying
  /// solely on `.onDisappear`, so cleanup is part of the action's own
  /// contract, not a lifecycle side effect.
  private func requestCancel() {
    if model.hasDiscardableDraft {
      showDiscardConfirm = true
    } else {
      model.cancel()
      dismiss()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if model.canGoBack {
        Button("Back") { model.goBack() }
      }
      Text(title)
        .font(.title3)
        .bold()
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack {
      Spacer()
      switch model.step {
      case .result:
        // Routed through requestCancel() (#1700): a `.nothingFound`/`.failed`
        // result still holds an uncommitted draft, so Done confirms first in
        // that case; `.completed`/`.nothingApproved` proceed silently, same
        // as before. The second, hidden button gives Escape the same route:
        // without it, this screen has no `.cancelAction` button at all, so
        // Escape would dismiss the system sheet directly and reach
        // `.onDisappear`'s unconfirmed cleanup — the exact bug this issue is
        // about, left open on the one screen this change touches (Codex
        // code-diff review).
        Button("Done") { requestCancel() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        Button("Done") { requestCancel() }
          .keyboardShortcut(.cancelAction)
          .hidden()
      case .review:
        Button("Cancel") { requestCancel() }
          .keyboardShortcut(.cancelAction)
        Button(confirmTitle) { model.confirm() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      case .methodPicker, .paste, .upload, .smartImportAppPicker, .working:
        Button("Cancel") { requestCancel() }
          .keyboardShortcut(.cancelAction)
      }
    }
  }

  /// Names the actual consequence, so Confirm is never a mystery button.
  private var confirmTitle: String {
    let count = model.approvedRows.count
    switch count {
    case 0: return "Add nothing"
    case 1: return "Add 1 word"
    default: return "Add \(count) words"
    }
  }

  private var title: String {
    switch model.step {
    case .methodPicker: return "Import words"
    case .paste: return "Paste words"
    case .upload: return "Open a file"
    case .smartImportAppPicker: return "From another app"
    case .review: return "Review & Merge"
    case .working(.loadingCandidates): return "Finding words"
    case .working(.comparing): return "Checking your list"
    case .working(.committing): return "Saving"
    case .result(.completed): return "Import complete"
    case .result(.nothingFound): return "Nothing to import"
    case .result(.nothingApproved): return "Nothing added"
    case .result(.failed): return "Import didn't finish"
    }
  }
}

// MARK: - Method picker

private struct ImportMethodPickerScreen: View {
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Bring your words in from anywhere. Nothing is added until you review it.")
        .settingsReadingCopy()

      ImportMethodCard(
        icon: "doc.on.clipboard",
        title: "Paste words",
        subtitle: "Paste a list of words from anywhere."
      ) {
        model.select(.paste)
      }
      // "Upload" implied a cloud destination for a purely local file read,
      // which fights the local-and-private positioning this whole feature is
      // built on. The copy also names the actual file and BOTH journeys, since
      // six later phases treat the export as their safety net and the person on
      // this screen is often recovering on the same Mac, not migrating (#1699).
      //
      // It deliberately does NOT say "restore". Import is additive: an existing
      // word is reported and skipped, and its aliases and settings are never
      // touched (D15; `confirmWithAllSkippedWritesNothing`). So importing a
      // backup over a library that still has those words restores nothing, and
      // promising otherwise would let someone believe their old settings came
      // back when they did not (Codex review r2, P2). "Bringing your words
      // back" is true of the additive behaviour; the second sentence states the
      // limit rather than leaving the user to discover it.
      ImportMethodCard(
        icon: "square.and.arrow.down",
        title: "Open a file",
        subtitle:
          "Moving Macs, or bringing your words back? Pick the "
          + "\(CustomWordsExportPanel.defaultFilename) you exported, or a plain "
          + "list. Words you already have are left as they are."
      ) {
        model.select(.upload)
      }
      ImportMethodCard(
        icon: "sparkles",
        title: "From another app",
        subtitle: "Bring your dictionary over from another dictation app."
      ) {
        model.select(.smartImport)
      }
    }
  }
}

private struct ImportMethodCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 11) {
        SettingsRowIcon(systemName: icon)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.stRowLabel)
            .foregroundStyle(.stTextPrimary)
          Text(subtitle)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.stTextTertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.stDivider, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title). \(subtitle)")
  }
}

// MARK: - Review & Merge (PR-F2c)

private struct ImportReviewScreen: View {
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let staleNotice = model.staleNotice {
        InsetNotice(text: staleNotice)
      }

      Text(summary)
        .settingsReadingCopy()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(model.rows) { row in
            ImportReviewRowView(row: row) { decision in
              model.setDecision(decision, forRow: row.id)
            }
          }
        }
      }
      .frame(maxHeight: 280)
    }
  }

  private var summary: String {
    let addable = model.rows.filter(\.isAddable).count
    let existing = model.rows.count - addable
    switch (addable, existing) {
    case (0, 0):
      return "Nothing to review."
    case (let new, 0):
      return "\(new) new \(new == 1 ? "word" : "words") found."
    case (0, let have):
      return "You already have all \(have) of these."
    case (let new, let have):
      return "\(new) new \(new == 1 ? "word" : "words") found. "
        + "\(have) you already have."
    }
  }
}

private struct ImportReviewRowView: View {
  let row: CustomWordsImportReviewRow
  let setDecision: (CustomWordsImportDecision) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.canonical)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
        if let matchSummary = row.matchSummary {
          Text(matchSummary)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
        if let collisionNote = row.collisionNote {
          Text(collisionNote)
            .font(.stHelper)
            .foregroundStyle(.stWarning)
        }
      }
      Spacer(minLength: 0)

      if row.isAddable {
        Toggle(
          "Add",
          isOn: Binding(
            get: { row.decision == .add },
            set: { setDecision($0 ? .add : .skip) }
          )
        )
        .toggleStyle(.checkbox)
        .accessibilityLabel("Add \(row.canonical)")
      } else {
        Text("Skipped")
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }
}

// MARK: - Paste words (PR-P1)

private struct ImportPasteScreen: View {
  @Bindable var model: CustomWordsImportFlowModel
  @FocusState private var isEditorFocused: Bool

  /// Recomputed when the draft changes, NOT on every render (code review r2).
  ///
  /// As a computed property this re-parsed the entire draft on every view
  /// update, on the main actor — so a large pasted list made the editor
  /// progressively less responsive the more it contained.
  @State private var wordCount = 0
  @State private var parseProblem: String?
  /// The in-flight count, so the next edit can cancel it.
  @State private var countingTask: Task<Void, Never>?
  /// True while the on-screen count belongs to an older draft than the one in
  /// the editor. Continue stays disabled until the current draft is counted.
  @State private var isCounting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Paste your words, one per line or separated by commas.")
        .settingsReadingCopy()

      // Bound to the model, not to local state: the sheet rebuilds this screen
      // on every step change, so Back from Review would otherwise hand the
      // user an empty editor and lose their list (code review r1).
      TextEditor(text: $model.pasteDraft)
        .focused($isEditorFocused)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(height: 200)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(Color.stDivider, lineWidth: 1)
        )
        .accessibilityLabel("Words to import")

      HStack {
        // Says what will actually happen, including the two cases people trip
        // on: nothing typed yet, and duplicates collapsing to fewer words.
        Text(summary)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Spacer(minLength: 0)
        Button("Continue") {
          model.begin(with: PasteWordsImportSource(text: model.pasteDraft))
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        // Over-limit is a refusal, not a warning: Confirm would throw and land
        // the user on the terminal failure screen, which has no Back, so the
        // draft they could have split is gone. Block it where they can still
        // edit it (cloud review, #1683).
        .disabled(
          isCounting || wordCount == 0
            || wordCount > CustomWordsImportLimits.maximumCandidates)
      }
    }
    .onAppear {
      isEditorFocused = true
      // Back from Review returns to an existing draft, so the count has to be
      // right on arrival, not only after the next keystroke.
      recount(model.pasteDraft)
    }
    .onChange(of: model.pasteDraft) { _, draft in
      recount(draft)
    }
  }

  /// Counts OFF the main actor, and keeps the parse failure rather than
  /// collapsing it to a zero count.
  ///
  /// Two separate lessons, one function. `try?` here turned a real, actionable
  /// error — an entry longer than the limit — into "No words found", which is
  /// false and left the user stuck with Continue disabled and nothing to act
  /// on (Codex review, #1683). And counting on the main actor made typing feel
  /// heavy: bounded work is still work, and at the ceiling it is 25,000 words
  /// per keystroke (code review r5, #1686).
  ///
  /// Off-main means results can land out of order, so each edit cancels the
  /// previous count and a result is applied only while its draft is still the
  /// current one — otherwise a slow count of a long list could finish after
  /// the user cleared the box and re-enable Continue for text that no longer
  /// exists (code review r6, #1686).
  private func recount(_ draft: String) {
    countingTask?.cancel()
    // The count belongs to the PREVIOUS draft until the new one is counted.
    // Leaving it on screen kept Continue enabled across the gap, so clearing
    // a valid paste — or replacing it with an over-limit one — could still be
    // submitted, landing on a terminal screen with no Back (Codex review,
    // #1686). Moving the count off the main actor is what opened that window;
    // an answer that is merely late must not be treated as current.
    isCounting = true
    countingTask = Task {
      do {
        let counted = try await PasteWordsParser.countWords(
          draft, limit: CustomWordsImportLimits.maximumCandidates)
        guard !Task.isCancelled, draft == model.pasteDraft else { return }
        wordCount = counted
        parseProblem = nil
        isCounting = false
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, draft == model.pasteDraft else { return }
        wordCount = 0
        parseProblem = error.localizedDescription
        isCounting = false
      }
    }
  }

  private var summary: String {
    // Says it is still working rather than reporting a stale number as
    // current, or flashing "no words found" at text nobody has counted yet.
    if isCounting { return "Counting…" }
    if let parseProblem { return parseProblem }
    let count = wordCount
    switch count {
    case 0 where model.pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return "Nothing pasted yet."
    case 0:
      return "No words found in that text."
    case 1:
      return "1 word ready to review."
    case let n where n > CustomWordsImportLimits.maximumCandidates:
      // The scan stops one past the limit, so this count is a sentinel rather
      // than a total — and none of these words are "ready to review", because
      // Confirm will refuse the batch. Saying so here beats letting the user
      // find out at the end (Codex review, #1683).
      return
        "That's more than \(CustomWordsImportLimits.maximumCandidates) words. "
        + "Paste a smaller batch."
    default:
      return "\(count) words ready to review."
    }
  }
}

// MARK: - Open a file (PR-U1)

/// Deliberately never says "restore" (founder, 2026-07-19).
///
/// v1 import ADDS words you don't have and SKIPS ones you do, leaving existing
/// words and their alternate spellings completely untouched. "Restore" would
/// promise that a word you had edited comes back as it was, which is exactly
/// the overwriting this scope rules out. The screen says what it does.
private struct ImportUploadScreen: View {
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose a file you exported from EnviousWispr, or a plain text list of words.")
        .settingsReadingCopy()

      Text("Words you already have are left exactly as they are.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)

      Button {
        // The panel is opened first and the file read only after a choice, so
        // cancelling reads nothing and starts no work.
        if let url = CustomWordsImportFilePanel.chooseFile() {
          model.begin(with: FileImportSource(url: url))
        }
      } label: {
        Label("Choose a file", systemImage: "folder")
      }
      .buttonStyle(.borderedProminent)

      Text("Spreadsheets aren't supported yet.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    }
  }
}

// MARK: - From another app (PR-4a/b/c)

private struct ImportSmartAppPickerScreen: View {
  let model: CustomWordsImportFlowModel
  /// Detection runs when this screen appears, not at launch or when the sheet
  /// opens: an installed competitor is never quietly inspected in the
  /// background, only when the user has asked to see this list.
  @State private var installed: [String] = []
  @State private var didLookForApps = false

  private var registry: SmartImportRegistry { .v1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Bring the words across from another dictation app you use.")
        .settingsReadingCopy()

      if !didLookForApps {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Looking for apps on this Mac.").settingsReadingCopy()
        }
      } else if installed.isEmpty {
        InsetNotice(
          text: "No supported dictation apps found on this Mac. "
            + "EnviousWispr can read Wispr Flow, FluidVoice, and Superwhisper.")
      } else {
        ForEach(registry.adapters.filter { installed.contains($0.identifier) }, id: \.identifier) {
          adapter in
          ImportMethodCard(
            icon: "app.badge",
            title: adapter.displayName,
            subtitle: "Read your words from \(adapter.displayName)."
          ) {
            model.begin(with: SmartImportSource(adapter: adapter))
          }
        }
      }

      // Says the honest shape of the migration before they commit to it: this
      // brings words across, not the corrections that map onto them.
      Text(
        "Words come across on their own. Alternate spellings you set up in the other app stay there."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    .task {
      // Off the main actor: this touches the filesystem.
      let found = await Task.detached { () -> [String] in
        // Detached rather than a plain Task: a plain Task inherits MainActor
        // from this view, and these are disk existence checks across several
        // locations. Nothing here needs actor context.
        SmartImportRegistry.v1.adapters.filter(\.isInstalled).map(\.identifier)
      }.value
      installed = found
      didLookForApps = true
    }
  }
}

// MARK: - Input placeholders (replaced wholesale by the real source PRs)

/// Shared placeholder for the three input screens. In DEBUG it walks the real
/// pipeline using a fixture source, so the whole flow is exercisable before
/// any real source exists; in a release build there is no way to reach it.
private struct ImportPlaceholderScreen: View {
  let notice: String
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      InsetNotice(text: notice)
      #if DEBUG
        Button("Preview with sample words") {
          model.begin(with: CustomWordsImportFixtureSource())
        }
      #endif
    }
  }
}

private struct ImportWorkingScreen: View {
  let work: CustomWordsImportFlowModel.Work

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(label)
        .settingsReadingCopy()
      Spacer(minLength: 0)
    }
  }

  private var label: String {
    switch work {
    case .loadingCandidates: return "Looking for words to import."
    case .comparing: return "Comparing against your existing words."
    case .committing: return "Saving your approved changes."
    }
  }
}

private struct ImportResultScreen: View {
  let result: CustomWordsImportFlowModel.Result
  let droppedAliasCollisionCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(tint)
          .accessibilityHidden(true)
        Text(message)
          .settingsReadingCopy()
        Spacer(minLength: 0)
      }

      if droppedAliasCollisionCount > 0, case .completed = result {
        Text(droppedCollisionMessage)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
    }
  }

  private var icon: String {
    switch result {
    case .completed: return "checkmark.circle.fill"
    case .nothingFound, .nothingApproved: return "info.circle"
    case .failed: return "exclamationmark.triangle"
    }
  }

  private var tint: Color {
    switch result {
    case .completed: return .stSuccess
    case .nothingFound, .nothingApproved: return .stAccent
    case .failed: return .stWarning
    }
  }

  private var message: String { CustomWordsImportResultCopy.message(for: result) }

  private var droppedCollisionMessage: String {
    CustomWordsImportResultCopy.droppedCollisionMessage(count: droppedAliasCollisionCount)
  }
}

// MARK: - DEBUG fixture source

#if DEBUG
  /// Sample words for the DEBUG preview walk, so the real load → compare →
  /// review → commit path is exercisable before any production source ships.
  ///
  /// Carries main words only, matching the v1 import contract: every authority
  /// field stays `.unspecified`, so this fixture cannot smuggle in behavior a
  /// real v1 source would not have.
  struct CustomWordsImportFixtureSource: CustomWordsImportSource {
    func loadRawCandidates() async throws -> CustomWordsImportBatch {
      CustomWordsImportBatch(
        sourceID: "debug-fixture",
        sourceDisplayName: "Sample words",
        candidates: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Anthropic"),
          CustomWordsImportCandidate(canonical: "EnviousWispr"),
          CustomWordsImportCandidate(canonical: "Saurabh"),
        ]
      )
    }
  }
#endif
