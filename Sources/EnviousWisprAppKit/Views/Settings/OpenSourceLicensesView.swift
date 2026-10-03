import SwiftUI

/// The GNU GPL license text and third-party notices, bundled directly into
/// this module (`resources: [.process("Resources")]` in Package.swift, copied
/// from the same root `LICENSE` / `THIRD-PARTY-NOTICES.txt` the release DMG
/// bundles at `Contents/Resources/Licenses/`) so the text is present in every
/// build variant — dev, release, and the test target — not only a signed
/// release DMG. #1487.
struct OpenSourceLicensesView: View {
  @State private var selected: LicenseDocument = .license

  var body: some View {
    SettingsContentView {
      Picker("Document", selection: $selected) {
        ForEach(LicenseDocument.allCases) { doc in
          Text(doc.rawValue).tag(doc)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      BrandedSection {
        BrandedRow(showDivider: false) {
          LicenseDocumentReader(document: selected)
        }
      }
    }
  }
}
