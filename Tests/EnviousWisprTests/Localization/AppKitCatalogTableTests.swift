import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3142 Phase 1: the AppKit String Catalog compiles into the AppKit resource
/// bundle and each key resolves from that table, not by key fallthrough.
///
/// Scope: this proves the TABLE. It does not prove that production call sites
/// name this bundle; the branch-only German receipts (plan S4) prove routing.
/// Oracle: literal English strings written here, independent of the catalog.
@Suite("AppKit catalog table", .tags(.driftGuard))
struct AppKitCatalogTableTests {
  private static let missing = "__MISSING_FROM_TABLE__"

  private static let expected: [(key: String, english: String)] = [
    ("settings.aiPolish.enable.title", "Enable AI Polish"),
    ("menu.setupRequired.continue", "Setup Required: Continue Setup…"),
    ("notification.update.ready.body", "Version %@ is ready. Click to install."),
  ]

  @Test("The English Localizable table ships in the AppKit resource bundle")
  func tableShipsInAppKitBundle() {
    let bundle = AppKitLocalization.bundle
    #expect(bundle != Bundle.main, "AppKit lookups must not use the main bundle")
    #expect(
      bundle.localizations.contains("en"),
      "AppKit bundle localizations: \(bundle.localizations)"
    )
    #expect(
      bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil,
      "Compiled en.lproj/Localizable.strings missing from \(bundle.bundleURL.path)"
    )
  }

  @Test("Each catalog key resolves to its literal English value from the table")
  func eachKeyResolvesFromTable() {
    let bundle = AppKitLocalization.bundle
    for entry in Self.expected {
      let value = bundle.localizedString(forKey: entry.key, value: Self.missing, table: "Localizable")
      #expect(value != Self.missing, "\(entry.key) fell through to the missing-value sentinel")
      #expect(value == entry.english, "\(entry.key) resolved to \(value)")
    }
  }
}
