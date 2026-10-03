import SwiftUI

/// The GNU GPL license text and third-party notices, bundled directly into
/// this module (`resources: [.process("Resources")]` in Package.swift, copied
/// from the same root `LICENSE` / `THIRD-PARTY-NOTICES.txt` the release DMG
/// bundles at `Contents/Resources/Licenses/`) so the text is present in every
/// build variant — dev, release, and the test target — not only a signed
/// release DMG. #1487.
struct OpenSourceLicensesView: View {
  @State private var selected: LicenseDocument?
  @State private var opener: LicenseDocument?
  @FocusState private var focusedDocument: LicenseDocument?

  var body: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 10) {
        SettingsSectionHeading(title: "ABOUT")
        BrandedSection {
          BrandedRow {
            SettingsRow(
              icon: "doc.text", title: "EnviousWispr · GPLv3",
              short: "Open source under the GNU GPL version 3.",
              help: "Read the GNU General Public License for EnviousWispr."
            ) {
              SettingsActionButton(title: "View license", isEnabled: true) {
                open(.license)
              }
              .focused($focusedDocument, equals: .license)
            }
          }
          BrandedRow(showDivider: false) {
            SettingsRow(
              icon: "doc.on.doc", title: "Third-party notices",
              short: "Licenses for the tools EnviousWispr uses.",
              help: "Read the notices for WhisperKit, FluidAudio, Silero VAD, Sparkle and other components."
            ) {
              SettingsActionButton(title: "View notices", isEnabled: true) {
                open(.notices)
              }
              .focused($focusedDocument, equals: .notices)
            }
          }
        }
      }
    }
    .sheet(item: $selected, onDismiss: { focusedDocument = opener }) { document in
      LicenseDocumentReader(document: document)
    }
  }

  private func open(_ document: LicenseDocument) {
    opener = document
    selected = document
  }
}
