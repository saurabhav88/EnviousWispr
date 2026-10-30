import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #4216: the Spoken punctuation window, opened by the Configure button beside the switch.
///
/// It holds the Start word row (moved here from the Settings list, unchanged: same editor, same
/// validation, same Save and Reset) and the English "period" switch. The switch is always shown,
/// whichever language the Start word picker is on, because the picker opens on the dictation language
/// and a user arriving to turn "period" off must find it. Everything here is sheet content, so none of
/// it is a Settings Map arrival target; search lands on the Spoken punctuation row instead.
///
/// The chrome follows `LanguageLockSheet`: one inset shared by the title bar and the body, a close
/// button in the title bar, the action in a footer.
struct SpokenPunctuationConfigureSheet: View {
  @Bindable var settings: SettingsManager
  @Environment(\.dismiss) private var dismiss

  /// One inset shared by the title, the body and the footer.
  private static let inset: CGFloat = 16

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      Divider().overlay(Color.stDivider)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(SpokenPunctuationCopy.configureSubtitle)
            .settingsReadingCopy()
          BrandedRow {
            SpokenPunctuationStartWordRow(settings: settings)
          }
          BrandedRow {
            // The row's "?" repeats its own line: there is nothing more to say, and no new claim.
            SettingsRow(
              notInSettingsMap: .sheetOrPopoverContent,
              icon: "textformat.abc",
              title: SpokenPunctuationCopy.periodWordTitle,
              short: SpokenPunctuationCopy.periodWordShort,
              help: SpokenPunctuationCopy.periodWordShort
            ) {
              Toggle("", isOn: $settings.spokenPunctuation.englishPeriodWord)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(Text(SpokenPunctuationCopy.periodWordTitle))
            }
          }
        }
        .padding(Self.inset)
      }

      Divider().overlay(Color.stDivider)
      footer
    }
    .background(Color.stPageBg)
    .frame(minWidth: 560, minHeight: 420)
    .onExitCommand { dismiss() }
  }

  private var titleBar: some View {
    HStack(spacing: 8) {
      Text(SpokenPunctuationCopy.configureTitle)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.stTextPrimary)
      Spacer(minLength: 12)
      SettingsSheetCloseButton(accessibilityTitle: SpokenPunctuationCopy.configureClose) {
        dismiss()
      }
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, 12)
  }

  /// `Done`, filled: every change here is saved as it is made, so closing confirms rather than abandons.
  /// Escape closes the window too (the cancel shortcut), and the Start word row settles a pending draft
  /// when it leaves, whichever way the window closes.
  private var footer: some View {
    HStack {
      Spacer(minLength: 0)
      SettingsActionButton(
        verbatimTitle: SpokenPunctuationCopy.configureDone, isEnabled: true, emphasis: .filled,
        shortcut: .defaultAction
      ) { dismiss() }
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, 12)
  }
}
