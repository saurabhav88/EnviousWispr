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
  /// Nil for normal presentation. Layout tests attach non-sizing background probes to the
  /// real controls and invoke the real Save action after load to render a refusal.
  var layoutProbe: ((String) -> AnyView)? = nil
  var onLoadedForTesting: ((() -> Void) -> Void)? = nil

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
      // Mockup 15 (founder, 2026-10-03): the braces tile, the title, a rule under them.
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          Image(systemName: "curlybraces")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.stAccent)
            .frame(width: 34, height: 34)
            .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
          Text(isEditing ? "Edit snippet" : "New snippet")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.stTextPrimary)
        }
        Divider().overlay(Color.stDivider)
      }

      triggerField
      expansionField
      SnippetSpeechPreview(keyword: keyword, trigger: trigger, layoutProbe: layoutProbe)

      footer
        .background { layoutProbe?("footer") }
    }
    .padding(20)
    .frame(width: 480, height: 600)
    .background(Color.stPageBg)
    .background { layoutProbe?("sheet") }
    .onAppear {
      load()
      onLoadedForTesting?(save)
    }
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
        notInSettingsMap: .sheetOrPopoverContent,
        icon: "text.word.spacing",
        title: "Trigger",
        short: SnippetsSettingsCopy.triggerShort,
        help: "Matched word for word, and only after you say \u{201C}\(keyword)\u{201D}."
      ) { EmptyView() }
      // One field with the keyword inline as its prefix (mockup 15). The keyword is shared
      // by every snippet and is not editable here.
      HStack(spacing: 8) {
        Text(keyword)
          .font(.stBody.weight(.semibold))
          .foregroundStyle(.stAccent)
          .lineLimit(1)
          .frame(maxWidth: 130, alignment: .leading)
          .fixedSize()
          .accessibilityHidden(true)
        TextField(Self.triggerPlaceholder, text: $trigger)
          .accessibilityLabel("Trigger")
          .focused($triggerFocused)
      }
      .settingsFieldChrome(focused: $triggerFocused)
      .contentShape(Rectangle())
      .onTapGesture { triggerFocused = true }
    }
  }

  private var expansionField: some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsRow(
        notInSettingsMap: .sheetOrPopoverContent,
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
        // TextEditor has no placeholder; the mockup's sample shows until the user types.
        .overlay(alignment: .topLeading) {
          if expansion.isEmpty {
            Text(verbatim: "john.doe@example.com")
              .font(.stBody)
              .foregroundStyle(.stTextTertiary)
              .padding(.horizontal, 11)
              .padding(.vertical, 6)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1)
            .allowsHitTesting(false))
        .background { layoutProbe?("editor") }
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
        .background { layoutProbe?("fillIn-\(placeholder.token)") }
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

  /// The trigger field's placeholder, also shown in the speech preview until a trigger is typed.
  static var triggerPlaceholder: String { String(localized: "my email address") }

  // MARK: - Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider().overlay(Color.stDivider)
      if let error {
        ScrollView(.vertical) {
          Text(error)
            .font(.stRowHelper)
            .foregroundStyle(.stError)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 54)
        .background { layoutProbe?("error") }
      }
      HStack(spacing: 8) {
        if let existing = draft.snippet {
          SettingsActionButton(title: "Delete", isEnabled: true, emphasis: .destructive) {
            if coordinator.delete(existing) { dismiss() } else { error = coordinator.errorMessage }
          }
          .background { layoutProbe?("Delete") }
        }
        Spacer(minLength: 0)
        SettingsActionButton(
          title: "Cancel", isEnabled: true, emphasis: .outlined, shape: .roundedRect,
          size: .medium, shortcut: .cancelAction
        ) { dismiss() }
        .background { layoutProbe?("Cancel") }
        // A new snippet's confirm says what it does (mockup 15); an edit keeps Save.
        SettingsActionButton(
          title: isEditing ? "Save" : "Add snippet", isEnabled: canSave, emphasis: .filled,
          shape: .roundedRect, size: .medium
        ) { save() }
          .background { layoutProbe?("Save") }
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
  var layoutProbe: ((String) -> AnyView)? = nil
  @State private var viewportHeight: CGFloat = 0

  private var shownTrigger: String {
    let typed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? SnippetEditSheet.triggerPlaceholder : typed
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      SettingsRowIcon(systemName: "mic")
      ScrollView(.vertical) {
        // Until a trigger is typed, the field's placeholder stands in, so the line never ends
        // in a stray space ("You'll say "insert "", #3385 audit).
        Text("You'll say \u{201C}\(keyword) \(shownTrigger)\u{201D}")
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .background { layoutProbe?("previewText") }
      }
      .frame(height: viewportHeight)
      .background { layoutProbe?("previewViewport") }
      // Measure two complete lines with the SAME font as the speech. A point constant can
      // reveal a fraction of a third line (#3385); the hidden sample never claims layout space.
      .background(alignment: .topLeading) {
        Text(verbatim: "Ag\nAg")
          .font(.stRowHelper)
          .fixedSize()
          .background {
            GeometryReader { geometry in
              Color.clear.preference(key: SnippetPreviewHeightKey.self, value: geometry.size.height)
            }
          }
          .hidden()
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
      .onPreferenceChange(SnippetPreviewHeightKey.self) { height in
        viewportHeight = height
      }
    }
    .padding(10)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1)
        .allowsHitTesting(false))
  }
}

private struct SnippetPreviewHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
