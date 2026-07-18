import SwiftUI

/// The Custom Words import sheet shell (#1657, epic #1619 PR-F1).
///
/// One observable model, one root `switch`, one container-level `.animation()`
/// — the `OnboardingV2View` root-switch pattern without its timers or
/// permissions logic. Every screen below the method picker is a fixture
/// placeholder until the real pieces land (F2c wires review/commit; P1/U1/4a
/// bring real inputs); the sheet is reachable only through the DEBUG-only
/// "Preview import" button in Your Words, so no release user can see these
/// placeholders. Deliberately zero `Task`, adapters, compare logic, manager
/// calls, telemetry, or persistence — dismissing at any point discards the
/// model and touches nothing.
struct CustomWordsImportSheet: View {
  private static let screenTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 20)),
    removal: .opacity
  )

  @State private var model = CustomWordsImportFlowModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      ZStack {
        switch model.step {
        case .methodPicker:
          ImportMethodPickerScreen(model: model)
            .transition(Self.screenTransition)
        case .paste:
          ImportPlaceholderScreen(
            notice: "Paste import arrives with a later update.",
            model: model
          )
          .transition(Self.screenTransition)
        case .upload:
          ImportPlaceholderScreen(
            notice: "File import arrives with a later update.",
            model: model
          )
          .transition(Self.screenTransition)
        case .smartImportAppPicker:
          ImportPlaceholderScreen(
            notice: "Importing from other apps arrives with a later update.",
            model: model
          )
          .transition(Self.screenTransition)
        case .review:
          ImportReviewPlaceholderScreen(model: model)
            .transition(Self.screenTransition)
        case .working(let work):
          ImportWorkingScreen(work: work, model: model)
            .transition(Self.screenTransition)
        case .result(let result):
          ImportResultScreen(result: result)
            .transition(Self.screenTransition)
        }
      }
      .animation(.easeInOut(duration: 0.25), value: model.step)

      footer
    }
    .padding(24)
    .frame(width: 480)
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
      if case .result = model.step {
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      } else {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
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
        subtitle: "Import a backup or a spreadsheet of words."
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

// MARK: - Fixture placeholders (replaced wholesale by later PRs)

/// Shared placeholder for the three input screens. The "Preview" button walks
/// the fixture flow the way the real source will: input → working → review.
private struct ImportPlaceholderScreen: View {
  let notice: String
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      InsetNotice(text: notice)
      Button("Preview finding words") {
        model.beginWork(.loadingCandidates)
      }
    }
  }
}

private struct ImportReviewPlaceholderScreen: View {
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      InsetNotice(text: "Review & Merge arrives with the compare engine.")
      Button("Preview saving") {
        model.beginWork(.committing)
      }
    }
  }
}

private struct ImportWorkingScreen: View {
  let work: CustomWordsImportFlowModel.Work
  let model: CustomWordsImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text(label)
          .settingsReadingCopy()
      }

      // Fixture-walk controls: real work drives these transitions from F2c on.
      VStack(alignment: .leading, spacing: 8) {
        Button("Preview review") { model.showReview() }
        Button("Preview success") { model.showResult(.completed(added: 3, replaced: 1)) }
        Button("Preview nothing found") { model.showResult(.nothingFound) }
        Button("Preview failure") {
          model.showResult(.failed(message: "We found their data, but couldn't read it this time."))
        }
      }
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

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(message)
        .settingsReadingCopy()
      Spacer(minLength: 0)
    }
  }

  private var icon: String {
    switch result {
    case .completed: return "checkmark.circle.fill"
    case .nothingFound: return "info.circle"
    case .failed: return "exclamationmark.triangle"
    }
  }

  private var tint: Color {
    switch result {
    case .completed: return .stSuccess
    case .nothingFound: return .stAccent
    case .failed: return .stWarning
    }
  }

  private var message: String {
    switch result {
    case .completed(let added, let replaced):
      return "Added \(added), replaced \(replaced). Your words are ready to use."
    case .nothingFound:
      return "No new words were found, and nothing was changed."
    case .failed(let message):
      return message
    }
  }
}
