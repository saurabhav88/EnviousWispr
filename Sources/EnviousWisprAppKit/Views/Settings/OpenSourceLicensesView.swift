import SwiftUI

/// The GNU GPL license text and third-party notices, bundled directly into
/// this module (`resources: [.process("Resources")]` in Package.swift, copied
/// from the same root `LICENSE` / `THIRD-PARTY-NOTICES.txt` the release DMG
/// bundles at `Contents/Resources/Licenses/`) so the text is present in every
/// build variant — dev, release, and the test target — not only a signed
/// release DMG. #1487.
struct OpenSourceLicensesView: View {
  private enum Document: String, CaseIterable, Identifiable {
    case license = "GPL-3.0 License"
    case notices = "Third-Party Notices"
    var id: String { rawValue }
  }

  @State private var selected: Document = .license

  var body: some View {
    SettingsContentView {
      Picker("Document", selection: $selected) {
        ForEach(Document.allCases) { doc in
          Text(doc.rawValue).tag(doc)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      BrandedSection {
        BrandedRow(showDivider: false) {
          Group {
            switch selected {
            case .license: licenseText
            case .notices: noticesText
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var licenseText: some View {
    if let text = Self.contents(of: "GPL-3.0", extension: "txt") {
      documentText(text)
    } else {
      unavailableText
    }
  }

  @ViewBuilder
  private var noticesText: some View {
    if let text = Self.contents(of: "THIRD-PARTY-NOTICES", extension: "txt") {
      documentText(text)
    } else {
      unavailableText
    }
  }

  private func documentText(_ text: String) -> some View {
    ScrollView {
      Text(text)
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.stTextSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
    .frame(maxHeight: 420)
  }

  private var unavailableText: some View {
    Text("License information isn't available in this build.")
      .settingsReadingCopy()
  }

  /// Reads a bundled text resource. Live-only file I/O against a resource this
  /// module ships with every build; failure here means a genuinely broken
  /// bundle, not a normal runtime condition, so it degrades to a plain message
  /// rather than crashing (limb, not heart).
  private static func contents(of name: String, extension ext: String) -> String? {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}
