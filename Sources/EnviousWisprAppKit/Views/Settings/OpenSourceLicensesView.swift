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
  @State private var isMounted = false
  @State private var restoreKeyboard = false
  @State private var restoreAccessibility = false
  @AccessibilityFocusState private var accessibilityDocument: LicenseDocument?

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
              .accessibilityFocused($accessibilityDocument, equals: .license)
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
              .accessibilityFocused($accessibilityDocument, equals: .notices)
            }
          }
        }
      }
    }
    .sheet(item: $selected, onDismiss: restoreFocus) { document in
      LicenseDocumentReader(document: document)
    }
    .onAppear { isMounted = true }
    .onDisappear {
      isMounted = false
      restoreKeyboard = false
      restoreAccessibility = false
    }
  }

  private func open(_ document: LicenseDocument) {
    restoreKeyboard = focusedDocument == document
    restoreAccessibility = accessibilityDocument == document
    opener = document
    selected = document
  }

  private func restoreFocus() {
    defer {
      restoreKeyboard = false
      restoreAccessibility = false
    }
    guard isMounted else { return }
    if restoreKeyboard { focusedDocument = opener }
    if restoreAccessibility { accessibilityDocument = opener }
  }
}
