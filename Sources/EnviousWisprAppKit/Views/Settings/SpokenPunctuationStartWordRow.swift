import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #2450: the "Start word" row, shown under the Spoken punctuation switch while it is on.
///
/// A picker chooses which language's start word is edited, and a field edits it. All the editing rules
/// live in `SpokenPunctuationStartWordEditor`; this view only draws its state. Keyboard, VoiceOver,
/// focus and the rendered layout are proven by hand in the dev app, not by this file's declarations.
struct SpokenPunctuationStartWordRow: View {
  @State private var editor: SpokenPunctuationStartWordEditor
  @FocusState private var fieldFocused: Bool

  init(settings: SettingsManager) {
    _editor = State(initialValue: SpokenPunctuationStartWordEditor(settings: settings))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsRow(
        icon: "text.cursor",
        resolvedTitle: SpokenPunctuationCopy.startWordTitle,
        resolvedShort: SpokenPunctuationCopy.startWordShort
      ) {
        SpokenPunctuationStartWordHelpPanel()
      } control: {
        languagePicker
      }
      editorBlock
        // Lines up under the row's title, past its icon (the Unload row's pattern).
        .padding(.leading, 37)
    }
    // The row leaves when the switch turns off or the page closes. A pending draft is settled for
    // the language it was typed for, never lost into another one.
    .onDisappear { editor.settleBeforeLeaving() }
  }

  private var languagePicker: some View {
    SpokenPunctuationLanguagePicker(editor: editor)
  }

  private var editorBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text(SpokenPunctuationCopy.languagePickerLabel)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
          .accessibilityHidden(true)
        field
        // Clicking elsewhere in the window does not always take focus off the field, so a typed word
        // needs a button that saves it; Return and focus loss still save it too.
        SettingsActionButton(
          verbatimTitle: SpokenPunctuationCopy.saveLabel, isEnabled: editor.hasUnsavedDraft,
          emphasis: .filled
        ) { editor.commitDraft() }
        .accessibilityLabel(Text(SpokenPunctuationCopy.saveAccessibilityLabel))
        SettingsActionButton(
          verbatimTitle: SpokenPunctuationCopy.resetLabel, isEnabled: editor.isCustomised
        ) { editor.reset() }
        .accessibilityLabel(Text(SpokenPunctuationCopy.resetAccessibilityLabel))
      }
      if let example = editor.exampleCommand {
        Text(SpokenPunctuationCopy.example(command: example))
          .settingsReadingCopy()
      }
      if let reason = editor.rejection {
        Label(SpokenPunctuationCopy.rejection(reason), systemImage: "exclamationmark.triangle.fill")
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
      if editor.showsNoStartWordWarning {
        Label(SpokenPunctuationCopy.noStartWordWarning, systemImage: "exclamationmark.triangle.fill")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var field: some View {
    let rejectionText = editor.rejection.map(SpokenPunctuationCopy.rejection)
    return TextField(
      "",
      text: Binding(
        get: { editor.draft },
        set: { editor.userEdited($0) }),
      prompt: Text(SpokenPunctuationCopy.noStartWordPlaceholder)
    )
    .focused($fieldFocused)
    .settingsFieldChrome(focused: $fieldFocused)
    .frame(width: 160)
    .onSubmit { editor.commitDraft() }
    .onChange(of: fieldFocused) { _, focused in
      if focused == false { editor.commitDraft() }
    }
    .onChange(of: rejectionText) { _, text in
      if let text { AccessibilityNotification.Announcement(text).post() }
    }
    .accessibilityLabel(
      Text(
        SpokenPunctuationCopy.fieldAccessibilityLabel(
          languageName: SpokenPunctuationStartWordEditor.displayName(for: editor.language))
      )
    )
    // The message is tied to the field, not only drawn beside it, so a screen reader reads it
    // with the field it is about.
    .accessibilityHint(Text(rejectionText ?? ""))
  }
}

/// #2450: what the Spoken punctuation "?" shows. Short guidance and a link to the Help Center article,
/// which owns the word list; there is no phrase table here.
struct SpokenPunctuationHelpPanel: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(SpokenPunctuationCopy.toggleDescription)
        .settingsReadingCopy()
      Text(SpokenPunctuationCopy.helpStartWord)
        .settingsReadingCopy()
      Text(SpokenPunctuationCopy.helpEnglish)
        .settingsReadingCopy()
      Text(SpokenPunctuationCopy.helpPolish)
        .settingsReadingCopy()
      Text(SpokenPunctuationCopy.helpFootnote)
        .settingsReadingCopy()
      SpokenPunctuationLearnMoreLink()
    }
    .frame(maxWidth: 300, alignment: .leading)
    .padding(16)
  }
}

/// #2450: what the Start word "?" shows. The row keeps one short line; how the word works, what the
/// language picker does and how English fits in live here, with the link to the article.
struct SpokenPunctuationStartWordHelpPanel: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(SpokenPunctuationCopy.startWordHelp)
        .settingsReadingCopy()
      Text(SpokenPunctuationCopy.pickerIsNotDictationLanguage)
        .settingsReadingCopy()
      Text(SpokenPunctuationCopy.helpEnglish)
        .settingsReadingCopy()
      SpokenPunctuationLearnMoreLink()
    }
    .frame(maxWidth: 300, alignment: .leading)
    .padding(16)
  }
}

/// The link to the Help Center article that owns the word list, shared by both "?" panels.
struct SpokenPunctuationLearnMoreLink: View {
  var body: some View {
    if let url = SpokenPunctuationCopy.learnMoreURL {
      Link(destination: url) {
        HStack(spacing: 4) {
          Text(SpokenPunctuationCopy.learnMoreLabel)
          Image(systemName: "arrow.up.right")
        }
        .font(.stHelper)
      }
      .foregroundStyle(.stAccent)
      .accessibilityLabel(Text(SpokenPunctuationCopy.learnMoreAccessibilityLabel))
    }
  }
}
