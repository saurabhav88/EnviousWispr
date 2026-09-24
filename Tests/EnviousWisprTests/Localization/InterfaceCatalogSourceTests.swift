import Foundation
import Testing

/// #3142: the interface String Catalog as committed. A unit-test process's
/// `Bundle.main` is the test host, not the app, so the shipped lookup is proven
/// on built products; this suite freezes the SOURCE the build compiles.
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

  /// The unit-test process cannot see the shipped app bundle, so a catalog dropped from the app
  /// target would still pass every lookup test through the English `defaultValue`. The build
  /// declaration is the checkable proxy; built products are inspected in the PR evidence.
  @Test("The catalog is declared as an app-target resource")
  func catalogIsAppTargetResource() throws {
    let project = try String(contentsOf: Self.repoRoot.appendingPathComponent("Project.swift"), encoding: .utf8)
    // An ACTIVE array element: the whole trimmed line is the quoted path, so a commented-out
    // entry (`// "…",`) or a mention inside prose does not count.
    let entry = "\"\(Self.catalogPath)\","
    let active = project.split(separator: "\n").filter {
      $0.trimmingCharacters(in: .whitespaces) == entry
    }
    #expect(active.count == 1, "Project.swift must list the catalog exactly once as a live resource entry")
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
