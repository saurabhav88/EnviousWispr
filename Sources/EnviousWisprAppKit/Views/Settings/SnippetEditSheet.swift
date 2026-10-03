import EnviousWisprCore
import SwiftUI

/// Add or edit one snippet (#628), to the approved design's sheet.
///
/// #2631: an unbounded preview of the expansion pushed the footer outside this 600pt sheet.
/// #3385 restores only the spoken keyword + trigger, in a bounded scroll area. The expansion
/// stays in the flexible editor; errors are bounded too, so fill-ins and actions keep their space.
struct SnippetEditSheet: View {
  @Environment(SnippetsCoordinator.self) private var coordinator
  @Environment(\.dismiss) private var dismiss

  let draft: SnippetDraft
  /// Passed in rather than read from the coordinator inside `body`: the pill beside the trigger
  /// input must show the keyword as it was when the sheet opened, so it cannot change under the
  /// user mid-edit.
  let keyword: String

  @State private var trigger = ""
  @State private var expansion = ""
  @State private var error: String?
  @State private var didLoad = false
  @FocusState private var triggerFocused: Bool

  private var isEditing: Bool { draft.snippet != nil }

  private var canSave: Bool {
    !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isEditing ? "Edit snippet" : "New snippet")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.stTextPrimary)

      triggerField
      expansionField
      SnippetSpeechPreview(keyword: keyword, trigger: trigger)

      footer
    }
    .padding(20)
    .frame(width: 480, height: 600)
    .background(Color.stPageBg)
    .onAppear(perform: load)
  }

  private func load() {
    guard !didLoad else { return }
    didLoad = true
    trigger = draft.snippet?.trigger ?? ""
    expansion = draft.snippet?.expansion ?? ""
  }

  // MARK: - Fields

  private var triggerField: some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsRow(
        icon: "text.word.spacing",
        title: "Trigger",
        short: SnippetsSettingsCopy.triggerShort,
        help: "Matched word for word, and only after you say \u{201C}\(keyword)\u{201D}."
      ) { EmptyView() }
      HStack(spacing: 8) {
        // The opening keyword is shared by every snippet and is not editable here.
        Text(keyword)
          .font(.stRowLabel)
          .foregroundStyle(.stAccent)
          .lineLimit(1)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .frame(maxWidth: 130)
          .background(Color.stAccentLight, in: Capsule())
          .overlay(
            Capsule().strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
              .allowsHitTesting(false))
        TextField("my email address", text: $trigger)
          .accessibilityLabel("Trigger")
          .focused($triggerFocused)
          .settingsFieldChrome(focused: $triggerFocused)
      }
    }
  }

  private var expansionField: some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsRow(
        icon: "doc.text",
        title: "Text to paste",
        short: SnippetsSettingsCopy.textShort,
        help: SnippetsSettingsCopy.fillInHelp
      ) { EmptyView() }
      // Takes every point the sheet has left rather than a fixed height. A snippet is routinely
      // a whole canned message, and the previous 110pt showed about four lines of one.
      TextEditor(text: $expansion)
        .font(.stBody)
        .accessibilityLabel("Text to paste")
        .frame(minHeight: 110, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1)
            .allowsHitTesting(false))
      fillInButtons
    }
  }

  /// One button per fill-in (#3018).
  ///
  /// Written over `SnippetPlaceholder.allCases` with an exhaustive switch for the label, so a
  /// fourth fill-in cannot ship without someone naming it, and appending `.token` rather than a
  /// spelling written here, so the editor and the matcher cannot disagree about what a fill-in
  /// looks like.
  ///
  /// **Appends rather than inserting at the caret**, because SwiftUI's `TextEditor` exposes no
  /// selection binding on macOS 14. The Text to paste help says so, because for someone editing an
  /// existing template that is a real cost rather than a detail.
  ///
  /// A fixed-height row under a `TextEditor` that takes `maxHeight: .infinity`, so the editor
  /// gives up the space and the footer stays on screen. That is the failure this sheet has had
  /// before; see the type's own header.
  private var fillInButtons: some View {
    HStack(spacing: 8) {
      ForEach(SnippetPlaceholder.allCases, id: \.self) { placeholder in
        SettingsActionButton(verbatimTitle: Self.fillInTitle(for: placeholder), isEnabled: true) {
          expansion += placeholder.token
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// The words on each button. An exhaustive switch, so the compiler asks for a label when a new
  /// fill-in is added rather than the button quietly going missing.
  private static func fillInTitle(for placeholder: SnippetPlaceholder) -> String {
    switch placeholder {
    case .date:
      return String(
        localized: "Today's date",
        comment: "Snippets, edit: button that inserts today's date into the snippet text.")
    case .time:
      return String(
        localized: "Time now",
        comment: "Snippets, edit: button that inserts the current time into the snippet text.")
    case .clipboard:
      return String(
        localized: "Last copied",
        comment:
          "Snippets, edit: button that inserts whatever was last copied into the snippet text."
      )
    }
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error {
        ScrollView(.vertical) {
          Text(error)
            .font(.stRowHelper)
            .foregroundStyle(.stError)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 54)
      }
      HStack(spacing: 8) {
        if let existing = draft.snippet {
          SettingsActionButton(title: "Delete", isEnabled: true, emphasis: .destructive) {
            if coordinator.delete(existing) { dismiss() } else { error = coordinator.errorMessage }
          }
        }
        Spacer(minLength: 0)
        SettingsActionButton(
          title: "Cancel", isEnabled: true, emphasis: .outlined, shortcut: .cancelAction
        ) { dismiss() }
        SettingsActionButton(title: "Save", isEnabled: canSave, emphasis: .filled) { save() }
      }
    }
  }

  private func save() {
    let snippet = Snippet(
      id: draft.snippet?.id ?? UUID(),
      trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
      // The expansion is NOT trimmed. Leading or trailing whitespace can be deliberate — a
      // snippet that starts with a newline, or ends with a space before the next word — and
      // "exactly as written" has to mean exactly.
      expansion: expansion,
      createdAt: draft.snippet?.createdAt ?? Date())

    if coordinator.save(snippet) {
      dismiss()
    } else {
      // Held locally as well as on the coordinator: the sheet stays open on a refusal, and the
      // message has to be visible where the user is looking rather than behind it.
      error = coordinator.errorMessage
    }
  }
}

/// Speech only, never the expansion (#2631). Long triggers scroll inside a fixed height.
private struct SnippetSpeechPreview: View {
  let keyword: String
  let trigger: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      SettingsRowIcon(systemName: "mic")
      ScrollView(.vertical) {
        Text("You'll say \u{201C}\(keyword) \(trigger)\u{201D}")
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(height: 40)
    }
    .padding(10)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1)
        .allowsHitTesting(false))
  }
}
