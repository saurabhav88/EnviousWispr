import SwiftUI

/// The top of the Dictionary page (#3385): the DICTIONARY heading carrying the Enable
/// Dictionary switch, with its short line under it, in place of the page's large banner
/// (tracker A5: no page headers; the Enable switch keeps a home in the heading row). Fixed
/// above the rail and the scrolling detail pane.
///
/// Stateless: `YourWordsView` hands it the one binding, `settings.wordCorrectionEnabled`.
struct DictionarySettingsHeading: View {
  @Binding var isEnabled: Bool

  private typealias Copy = SettingsShellCopy.Dictionary

  private var title: String { String(localized: Copy.heading).localizedUppercase }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // The heading and its control on one line where they fit; at a narrow
      // window the control drops under the heading rather than squeezing it.
      ViewThatFits(in: .horizontal) {
        SettingsSectionHeading(resolvedTitle: title) { enableControl }
        VStack(alignment: .leading, spacing: 8) {
          SettingsSectionHeading(resolvedTitle: title)
          enableControl
        }
      }
      Text(Copy.enableShort)
        .font(.stRowHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The visible name, its "?" and the switch, as one group. The "?" is a sibling of the
  /// switch, never inside it, and reuses the shared popover's focus return.
  private var enableControl: some View {
    HStack(spacing: 8) {
      Text(Copy.enableTitle)
        .font(.stRowLabel)
        .foregroundStyle(Color.stTextPrimary)
      SettingsInfoButton(
        rowTitle: String(localized: Copy.enableTitle),
        tooltip: String(localized: Copy.enableHelp)
      ) {
        SettingsHelpText(text: String(localized: Copy.enableHelp))
      }
      // .fixedSize(): BrandedToggleStyle's internal Spacer otherwise
      // claims whatever width this HStack hands it, which here would be
      // the banner's entire remaining row rather than the toggle's own
      // label-gap-track shape (#2492 review r1).
      // #3385: still the reason; the switch has no caption of its own (the
      // visible name beside it names it), so it is the track alone.
      Toggle("", isOn: $isEnabled)
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(Copy.enableTitle))
    }
  }
}
