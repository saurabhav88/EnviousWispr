import EnviousWisprCore
import SwiftUI

/// #2450: the language dropdown of the Start word row, drawn like the microphone dropdown
/// (`MicrophoneDevicePicker`): a card that names the choice with the line under it, which opens the
/// shared `settingsDropdown` menu with a check column, a leading mark, a title and a line under each
/// choice (founder, 2026-10-05: "the drop down menu needs to be as nice as the microphone selection
/// drop down"). The line under each language is the start word that language uses right now, so the
/// menu doubles as an overview.
///
/// Presentation only. The editor owns which language is picked, `selectLanguage(_:)` settles the old
/// language's draft first, and the picker never touches `languageMode`.
struct SpokenPunctuationLanguagePicker: View {
  let editor: SpokenPunctuationStartWordEditor
  @State private var isOpen = false
  static let width: CGFloat = 240

  var body: some View {
    Button {
      isOpen.toggle()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "globe")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.stAccent)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(SpokenPunctuationStartWordEditor.displayName(for: editor.language))
            .font(.stRowLabel)
            .foregroundStyle(Color.stTextPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(Self.startWordLine(editor.startWord(for: editor.language)))
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .lineLimit(1)
        }
        Spacer(minLength: 6)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.stTextSecondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(width: Self.width, alignment: .leading)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 9))
      .overlay(
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(isOpen ? Color.stAccent : Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .settingsHoverRow(cornerRadius: 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityLabel(Text(SpokenPunctuationCopy.languagePickerLabel))
    .accessibilityValue(
      Text(
        SpokenPunctuationStartWordEditor.displayName(for: editor.language) + ", "
          + Self.startWordLine(editor.startWord(for: editor.language)))
    )
    .settingsDropdown(isPresented: $isOpen, width: Self.width) {
      menu
    }
  }

  @ViewBuilder private var menu: some View {
    ForEach(SpokenPunctuationStartWordEditor.languages, id: \.self) { code in
      choice(code)
    }
  }

  private func choice(_ code: String) -> some View {
    let isChosen = editor.language == code
    let name = SpokenPunctuationStartWordEditor.displayName(for: code)
    let line = Self.startWordLine(editor.startWord(for: code))
    return SettingsDropdownRow(
      isChosen: isChosen, spokenTitle: name + ", " + line,
      action: {
        editor.selectLanguage(code)
        isOpen = false
      },
      leading: {
        Image(systemName: "globe")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(isChosen ? Color.stAccent : Color.stTextSecondary)
          .frame(width: 18)
      },
      title: name,
      subtitle: {
        Text(line).font(.stHelper).foregroundStyle(Color.stTextSecondary).lineLimit(1)
      })
  }

  /// The word a language uses, or the words for "no start word" when its field is blank.
  static func startWordLine(_ word: String) -> String {
    word.isEmpty ? SpokenPunctuationCopy.noStartWordPlaceholder : word
  }
}
