import EnviousWisprServices
import SwiftUI

/// Clipboard behavior settings.
///
/// #3385 (Clipboard tab): every switch is a shared row (title, short line, "?"),
/// in two headed sections. The first three settings are snapshotted per
/// recording, so the Clipboard heading carries the next-recording note; Quick
/// Add is read on its next press and sits under its own heading, outside that note.
struct ClipboardSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  private typealias Copy = DictationSettingsCopy.Clipboard

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(
        map: .id(.sectionClipboard), casing: .localizedUppercase) {
        Text(DictationSettingsCopy.Engine.nextRecordingNote)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      BrandedSection {
        BrandedRow {
          SettingsRow(
            map: .id(.autoCopyToClipboard),
            icon: "doc.on.clipboard",
            help: Copy.autoCopyHelp
          ) {
            Toggle("", isOn: $settings.autoCopyToClipboard)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(Copy.autoCopyTitle))
          }
        }
        BrandedRow {
          SettingsRow(
            map: .id(.restoreClipboard),
            icon: "arrow.uturn.backward",
            help: Copy.restoreHelp
          ) {
            Toggle("", isOn: $settings.restoreClipboardAfterPaste)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(Copy.restoreTitle))
          }
        }
        BrandedRow(showDivider: false) {
          SettingsRow(
            map: .id(.smartInsertion),
            icon: "text.cursor",
            help: Copy.smartInsertionHelp
          ) {
            Toggle("", isOn: $settings.smartInsertion)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(Copy.smartInsertionTitle))
          }
        }
      }

      }

      // **Its own section, not a fourth row above.** The Clipboard section carries the
      // frozen-per-recording footnote, and this setting has nothing to do with a recording: it
      // governs a shortcut, and a change to it applies to the very next press. Filing it under a
      // footnote saying otherwise would be a false claim about the one row a user is most likely to
      // read carefully, since it is the row that says we touch their clipboard.
      // #3385: the frozen-per-recording footnote is now the Clipboard heading's
      // "Changes apply to the next recording" note (tracker B4). This section keeps
      // its own heading and no note, so the note still covers only the three rows
      // above, and Quick Add still applies on the next press.
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(
        map: .id(.sectionQuickAddClipboard), casing: .localizedUppercase)

      BrandedSection {
        BrandedRow(showDivider: false) {
          SettingsRow(
            map: .id(.quickAddClipboardFallback),
            icon: "text.viewfinder",
            help: Copy.quickAddHelp
          ) {
            Toggle("", isOn: $settings.quickAddClipboardFallback)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(Copy.quickAddTitle))
          }
        }
      }
      }
    }
    .environment(\.settingsPR1Density, true)
  }
}
