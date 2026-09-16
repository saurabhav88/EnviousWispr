import SwiftUI

/// Screens shared by the Custom Words and Snippets import sheets (#2997).
///
/// Moved out of `CustomWordsImportSheet.swift` unchanged when the Snippets sheet needed the
/// same method cards and the same "working" row. Each sheet keeps its own flow model and
/// its own copy; only the views that carry no words-or-snippets meaning live here.

struct ImportMethodCard: View {
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
      // The first screen of the import flow is three of these and nothing else,
      // so if they do not read as choices the flow has no visible entry point.
      .settingsHoverCard(cornerRadius: 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title). \(subtitle)")
  }
}

/// The one-line "something is happening" row. Each sheet maps its own `Work` enum to a
/// label, so this view never learns what the work is.
struct ImportWorkingRow: View {
  let label: String

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(label)
        .settingsReadingCopy()
      Spacer(minLength: 0)
    }
  }
}
