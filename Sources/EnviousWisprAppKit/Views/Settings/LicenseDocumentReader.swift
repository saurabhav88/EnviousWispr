import SwiftUI

enum LicenseDocument: String, CaseIterable, Identifiable {
  case license = "GPL-3.0 License"
  case notices = "Third-Party Notices"
  var id: String { rawValue }
  var title: LocalizedStringResource {
    switch self {
    case .license: "GPL-3.0 License"
    case .notices: "Third-Party Notices"
    }
  }
}

/// Selectable bundled text, presented by the Licenses tab in an item-driven sheet.
struct LicenseDocumentReader: View {
  let document: LicenseDocument
  @Environment(\.dismiss) private var dismiss

  static let unavailableMessage: LocalizedStringResource =
    "License information isn't available in this build."

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(document.title).settingsRowTitle()
      if let text = Self.contents(of: document) {
        documentText(text)
      } else {
        unavailableText
      }
      HStack {
        Spacer()
        SettingsActionButton(title: "Done", isEnabled: true, shortcut: .cancelAction) {
          dismiss()
        }
      }
    }
    .padding(24)
    .frame(minWidth: 400, idealWidth: 560, minHeight: 300, idealHeight: 520)
    .background(Color.stPageBg)
  }

  static func contents(of document: LicenseDocument) -> String? {
    switch document {
    case .license: contents(of: "GPL-3.0", extension: "txt")
    case .notices: contents(of: "THIRD-PARTY-NOTICES", extension: "txt")
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
    Text(Self.unavailableMessage)
      .settingsReadingCopy()
  }

  /// Reads a bundled text resource. Live-only file I/O against a resource this
  /// module ships with every build; failure here means a genuinely broken
  /// bundle, not a normal runtime condition, so it degrades to a plain message
  /// rather than crashing (limb, not heart).
  static func contents(of name: String, extension ext: String) -> String? {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}
