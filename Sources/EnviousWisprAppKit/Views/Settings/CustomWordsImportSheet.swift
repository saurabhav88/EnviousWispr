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
  @Environment(\.dismiss) private var dismiss

  init(dependencies: CustomWordsImportFlowModel.Dependencies) {
    _model = State(initialValue: CustomWordsImportFlowModel(dependencies: dependencies))
  }

  var body: some View {
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
          ImportPlaceholderScreen(
            notice: "Importing from other apps arrives with a later update.",
            model: model
          )
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
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      case .review:
        Button("Cancel") {
          model.cancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(confirmTitle) { model.confirm() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      case .methodPicker, .paste, .upload, .smartImportAppPicker, .working:
        Button("Cancel") {
          model.cancel()
          dismiss()
        }
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
    case .upload: return "Upload a file"
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
      ImportMethodCard(
        icon: "square.and.arrow.down",
        title: "Upload a file",
        subtitle: "Import words from a file you exported, or a list."
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
        .disabled(wordCount == 0)
      }
    }
    .onAppear {
      isEditorFocused = true
      // Back from Review returns to an existing draft, so the count has to be
      // right on arrival, not only after the next keystroke.
      wordCount = (try? PasteWordsParser.parse(
        model.pasteDraft, limit: CustomWordsImportLimits.maximumCandidates))?.count ?? 0
    }
    .onChange(of: model.pasteDraft) { _, draft in
      wordCount = (try? PasteWordsParser.parse(
        draft, limit: CustomWordsImportLimits.maximumCandidates))?.count ?? 0
    }
  }

  private var summary: String {
    let count = wordCount
    switch count {
    case 0 where model.pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return "Nothing pasted yet."
    case 0:
      return "No words found in that text."
    case 1:
      return "1 word ready to review."
    default:
      return "\(count) words ready to review."
    }
  }
}

// MARK: - Upload a file (PR-U1)

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
    func loadCandidates() async throws -> CustomWordsImportBatch {
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
