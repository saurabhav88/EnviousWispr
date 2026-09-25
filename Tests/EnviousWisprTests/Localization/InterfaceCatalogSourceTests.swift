import Foundation
import Testing

/// #3142: the interface String Catalog, as committed and as compiled into the app
/// the same build produces beside this test bundle.
///
/// No language beyond English ships until it is complete: a `de` value in this
/// file makes the main bundle declare German, and macOS would then show a
/// half-translated app to German Macs.
@Suite("Interface catalog source", .tags(.driftGuard))
struct InterfaceCatalogSourceTests {
  private static let catalogPath = "Sources/EnviousWispr/Resources/Localizable.xcstrings"

  // Literal oracle, independent of the catalog.
  private static let expectedEnglish: [String: String] = [
    "settings.aiPolish.enable.title": "Enable AI Polish",
    "menu.setupRequired.continue": "Setup Required: Continue Setup…",
    "notification.update.ready.body": "Version %@ is ready. Click to install.",
  ]

  @Test("Semantic keys carry today's exact English")
  func semanticKeysCarryExactEnglish() throws {
    let strings = try Self.strings()
    for (key, english) in Self.expectedEnglish {
      let entry = try #require(strings[key] as? [String: Any], "\(key) missing from the catalog")
      #expect(Self.value(of: entry, language: "en") == english, "\(key)")
    }
  }

  @Test("No language other than English is in the catalog")
  func onlyEnglishShips() throws {
    let strings = try Self.strings()
    #expect(!strings.isEmpty, "catalog parsed to zero entries")
    var languages = Set<String>()
    for case let entry as [String: Any] in strings.values {
      let localizations = entry["localizations"] as? [String: Any] ?? [:]
      languages.formUnion(localizations.keys)
    }
    #expect(
      languages.isSubset(of: ["en"]), "non-English localizations present: \(languages.sorted())")
    // Control: the check above can see a language, because English is present.
    #expect(languages.contains("en"))
  }

  /// The unit-test process's `Bundle.main` is not the app, but the same build places the app
  /// beside the test bundle. Reading the COMPILED table there proves the catalog ships; a
  /// catalog dropped from the app target (deleted, commented out, excluded) leaves no table.
  @Test("The built app ships the compiled English table with the three entries")
  func builtAppShipsCompiledTable() throws {
    let products = Bundle(for: BuildProductsMarker.self).bundleURL.deletingLastPathComponent()
    // The product name is per configuration: Debug and Release build `EnviousWispr.app`, Dev
    // builds `EnviousWispr Local.app` (Project.swift Dev settings). Exactly one lives beside the
    // test bundle; zero or both means the products directory is not what this test assumes.
    let apps = ["EnviousWispr.app", "EnviousWispr Local.app"]
      .map { products.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    let app = try #require(apps.count == 1 ? apps.first : nil, "app products beside the tests: \(apps.map(\.lastPathComponent))")
    let table = app.appendingPathComponent("Contents/Resources/en.lproj/Localizable.strings")
    let data = try #require(
      FileManager.default.contents(atPath: table.path),
      "no compiled catalog at \(table.path)")
    let compiled = try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    for (key, english) in Self.expectedEnglish {
      #expect(compiled[key] == english, "\(key) in the shipped table")
    }
  }

  private static func strings() throws -> [String: Any] {
    let url = repoRoot.appendingPathComponent(catalogPath)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let root = try #require(object as? [String: Any])
    #expect(root["sourceLanguage"] as? String == "en")
    return try #require(root["strings"] as? [String: Any])
  }

  private static func value(of entry: [String: Any], language: String) -> String? {
    let localizations = entry["localizations"] as? [String: Any]
    let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    return unit?["value"] as? String
  }

  private static var repoRoot: URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
      if FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Package.swift").path)
      {
        return directory
      }
      directory = directory.deletingLastPathComponent()
    }
    return directory
  }
}

private final class BuildProductsMarker {}
