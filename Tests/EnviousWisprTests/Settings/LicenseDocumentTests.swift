import Foundation
import Testing

@testable import EnviousWisprAppKit

/// A reader must show the selected bundled document, with the existing message if unavailable.
@MainActor
@Suite("License documents (#3385)", .tags(.productOutcome))
struct LicenseDocumentTests {
  @Test("Each selection resolves the complete correct bundled text", arguments: [
    (LicenseDocument.license, "GPL-3.0.txt", "GPL-3.0 License"),
    (LicenseDocument.notices, "THIRD-PARTY-NOTICES.txt", "Third-Party Notices"),
  ])
  func bundledText(document: LicenseDocument, resource: String, title: String) throws {
    let expected = try String(
      contentsOf: RepoRoot.url.appending(path: "Sources/EnviousWisprAppKit/Resources/" + resource),
      encoding: .utf8)
    try #require(expected.isEmpty == false)
    let actual = try #require(LicenseDocumentReader.contents(of: document))
    #expect(actual.utf8.elementsEqual(expected.utf8))
    #expect(document.rawValue == title)
    #expect(document.id == title)
  }

  @Test("An unavailable bundled resource retains the existing plain message")
  func unavailableResource() {
    #expect(LicenseDocumentReader.contents(of: "missing-license-3385", extension: "txt") == nil)
    #expect(String(localized: LicenseDocumentReader.unavailableMessage)
      == "License information isn't available in this build.")
  }
}
