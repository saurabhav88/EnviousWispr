import Foundation
import Testing

/// #3142: the interface String Catalog, as committed and as compiled into the app
/// the same build produces beside this test bundle.
///
/// #3142 Phase 5: English and German ship. A `de` value in a catalog makes the main bundle
/// declare German, so German must stay on every key (completeness itself, per unit, is
/// `l10n-catalog-sync.sh --check`); these tests keep that check from going vacuous.
@Suite("Interface catalog source", .tags(.driftGuard))
struct InterfaceCatalogSourceTests {
  private static let catalogPath = "Sources/EnviousWispr/Resources/Localizable.xcstrings"
  /// #3142 Phase 3: permission prompts, written from Info.plist.
  private static let infoPlistCatalogs = [
    "Sources/EnviousWispr/Resources/InfoPlist.xcstrings"
  ]

  // Literal oracle, independent of the catalog.
  private static let expectedEnglish: [String: String] = [
    "settings.aiPolish.enable.title": "Enable AI Polish",
    "menu.setupRequired.continue": "Setup Required: Continue Setup…",
    "notification.update.ready.body": "Version %@ is ready. Click to install.",
    // #3153: Send Feedback.
    "feedback.message.placeholder": "What happened, or what would you like to see?",
    "feedback.message.label": "Feedback message",
    "feedback.email.placeholder": "Email (optional, if you'd like a reply)",
    "feedback.send": "Send",
    "feedback.unavailable": "Couldn't send. Email hello@enviouslabs.co",
    "feedback.email.invalid": "Enter a valid email address",
    "feedback.message.tooLong": "Maximum 4,000 characters",
    "feedback.title": "Send feedback",
    "feedback.subtitle": "Found a bug or have an idea? We read every message.",
    "feedback.sent.title": "Thanks, it's on its way",
    "feedback.sent.detail": "If you left your email, we'll reply there.",
  ]

  // Literal oracle for the German, independent of the catalog (reviewed 2026-09-25).
  private static let expectedGerman: [String: String] = [
    "settings.aiPolish.enable.title": "KI-Nachbearbeitung aktivieren",
    "menu.setupRequired.continue": "Einrichtung erforderlich: Einrichtung fortsetzen…",
    "notification.update.ready.body": "Version %@ ist bereit. Klicke zum Installieren.",
    "feedback.title": "Feedback senden",
    "feedback.send": "Senden",
    // #3482: the Theme picker's choices, now owned by ThemeChoicePresentation.
    "System": "System",
    "Light": "Hell",
    "Dark": "Dunkel",
    // #3482: the engine cards' copy, now owned by EngineChoicePresentation (German as shipped
    // at cdd03bf9, including its range dash).
    "Fast": "Schnell",
    "All Languages": "Alle Sprachen",
    "Pick this for everyday English and European dictation.":
      "Wähle dies für alltägliche Diktate auf Englisch und in europäischen Sprachen.",
    "Pick this for other languages or the toughest audio.":
      "Wähle dies für andere Sprachen oder besonders schwierige Aufnahmen.",
    "Model": "Modell",
    "Languages": "Sprachen",
    "Runs on": "Läuft auf",
    "Transcribe time": "Transkriptionsdauer",
    "25 European languages": "25 europäische Sprachen",
    "99+ languages": "Über 99 Sprachen",
    "Apple Neural Engine": "Apple Neural Engine",
    "Apple GPU": "Apple GPU",
    "Usually ~0.1s after you speak": "Meist ~0,1 Sek. nach dem Sprechen",
    "Usually 1-2s after you speak": "Meist 1\u{2013}2 Sek. nach dem Sprechen",
    // #3271: the model download host moved; the sentence gives IT allowlist guidance.
    "Could not download the model. Check your connection. On a managed network, ask IT whether models.enviouswispr.com is allowed.":
      "Das Modell konnte nicht heruntergeladen werden. Prüfe deine Verbindung. Frage in einem verwalteten Netzwerk die IT, ob models.enviouswispr.com freigegeben ist.",
  ]

  @Test("Semantic keys carry today's exact English")
  func semanticKeysCarryExactEnglish() throws {
    let strings = try Self.strings()
    for (key, english) in Self.expectedEnglish {
      let entry = try #require(strings[key] as? [String: Any], "\(key) missing from the catalog")
      #expect(Self.value(of: entry, language: "en") == english, "\(key)")
    }
  }

  @Test(
    "English and German only, and German on every key",
    arguments: [catalogPath] + infoPlistCatalogs)
  func englishAndGermanShip(catalog: String) throws {
    let strings = try Self.strings(catalog)
    #expect(!strings.isEmpty, "catalog parsed to zero entries")
    var languages = Set<String>()
    var withoutGerman: [String] = []
    for (key, value) in strings {
      let localizations = (value as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
      languages.formUnion(localizations.keys)
      // `Text("")` extracts an empty key with nothing to translate.
      if !key.isEmpty, localizations["de"] == nil { withoutGerman.append(key) }
    }
    #expect(languages.isSubset(of: ["en", "de"]), "languages present: \(languages.sorted())")
    #expect(languages.contains("de"), "German is gone from \(catalog)")
    #expect(withoutGerman.isEmpty, "keys without German: \(withoutGerman.sorted().prefix(10))")
  }

  /// #3482: the Settings item names moved from inline literals into `SettingsItemCopy`. Each
  /// constant keeps its key, default English and comment, so it reads the catalog entry the
  /// literal read, and the app ships its German. Read from the source text (the constants are
  /// not enumerable at run time); a line the reader cannot parse fails the count.
  @Test("Settings item copy keeps its catalog entries, English, comments and shipped German")
  func settingsItemCopyKeepsItsEntries() throws {
    let source = try String(
      contentsOf: Self.repoRoot.appendingPathComponent(
        "Sources/EnviousWisprAppKit/Views/Settings/SettingsItemCopy.swift"), encoding: .utf8)
    let pattern = try Regex(
      #"LocalizedStringResource\(\s*"((?:[^"\\]|\\\([^)]*\))*)"(?:, defaultValue: "([^"\\]*)")?(?:, comment: "([^"\\]*)")?\)"#)
    let constants = source.matches(of: pattern)
    let calls = source.components(separatedBy: "LocalizedStringResource(").count - 1
    #expect(constants.count == calls, "parsed \(constants.count) of \(calls) constants")
    #expect(calls >= 100, "only \(calls) constants; the file moved or the reader broke")
    let strings = try Self.strings()
    let compiled = try Self.compiledTable(
      in: try Self.builtApp(), language: "de", table: "Localizable")
    for match in constants {
      // An interpolated key is catalogued with `%@` in place of each interpolation.
      let key = String(try #require(match.output[1].substring)).replacing(
        try Regex(#"\\\([^)]*\)"#), with: "%@")
      let english = match.output[2].substring.map(String.init) ?? key
      let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
      #expect((Self.value(of: entry, language: "en") ?? key) == english, "\(key): English changed")
      if let comment = match.output[3].substring {
        // A key shared by several controls carries each of their comments, one per line.
        let lines = (entry["comment"] as? String ?? "").components(separatedBy: "\n")
        #expect(lines.contains(String(comment)), "\(key): comment changed")
      }
      let german = Self.value(of: entry, language: "de")
      #expect(german != nil && Self.state(of: entry, language: "de") == "translated", "\(key)")
      #expect(compiled[key] == german, "\(key): the shipped German differs from the catalog")
    }
  }

  /// The unit-test process's `Bundle.main` is not the app, but the same build places the app
  /// beside the test bundle. Reading the COMPILED table there proves the catalog ships; a
  /// catalog dropped from the app target (deleted, commented out, excluded) leaves no table.
  @Test("The built app ships the compiled German table")
  func builtAppShipsCompiledGermanTable() throws {
    let compiled = try Self.compiledTable(
      in: try Self.builtApp(), language: "de", table: "Localizable")
    for (key, german) in Self.expectedGerman {
      #expect(compiled[key] == german, "\(key) in the shipped German table")
    }
  }

  @Test("The built app ships the compiled English table with every translated entry")
  func builtAppShipsCompiledTable() throws {
    let compiled = try Self.compiledTable(
      in: try Self.builtApp(), language: "en", table: "Localizable")
    // Only entries in state `translated` are compiled into the English table. A key the
    // compiler extracted (state `new`, #3157's sync) is absent from it and resolves to the
    // `defaultValue` written beside it in the code, which is the same English (#3153, measured:
    // the Debug table held exactly the three `translated` entries).
    let strings = try Self.strings()
    let shipped = Self.expectedEnglish.filter { key, _ in
      Self.state(of: strings[key] as? [String: Any], language: "en") == "translated"
    }
    #expect(!shipped.isEmpty, "no translated entries to check; the filter read nothing")
    for (key, english) in shipped {
      #expect(compiled[key] == english, "\(key) in the shipped table")
    }
  }

  /// The permission prompts and the About box line compile from Info.plist's InfoPlist catalog to
  /// exactly the English in Info.plist, read here from the plist itself. The German table carries
  /// exactly the same keys.
  @Test("The built app's permission table equals Info.plist's English")
  func builtAppShipsInfoPlistTables() throws {
    let plistData = try Data(
      contentsOf: Self.repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources/Info.plist"))
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
    let prompts = plist.filter { key, _ in
      (key.hasPrefix("NS") && key.hasSuffix("UsageDescription"))
        || key == "NSHumanReadableCopyright"
    }
    .compactMapValues { $0 as? String }
    #expect(prompts.count >= 5, "Info.plist prompts read: \(prompts.keys.sorted())")

    let app = try Self.builtApp()
    #expect(try Self.compiledTable(in: app, language: "en", table: "InfoPlist") == prompts)
    let germanPrompts = try Self.compiledTable(in: app, language: "de", table: "InfoPlist")
    #expect(Set(germanPrompts.keys) == Set(prompts.keys))
    #expect(
      germanPrompts["NSMicrophoneUsageDescription"]
        == "EnviousWispr benötigt Zugriff auf dein Mikrofon, um deine Sprache in Text umzuwandeln.")
  }

  private static func builtApp() throws -> URL {
    let products = Bundle(for: BuildProductsMarker.self).bundleURL.deletingLastPathComponent()
    // The product name is per configuration: Debug and Release build `EnviousWispr.app`, Dev
    // builds `EnviousWispr Local.app` (Project.swift Dev settings). Exactly one lives beside the
    // test bundle; zero or both means the products directory is not what this test assumes.
    let apps = ["EnviousWispr.app", "EnviousWispr Local.app"]
      .map { products.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    return try #require(
      apps.count == 1 ? apps.first : nil,
      "app products beside the tests: \(apps.map(\.lastPathComponent))")
  }

  private static func compiledTable(in app: URL, language: String, table: String) throws
    -> [String: String]
  {
    let path = app.appendingPathComponent("Contents/Resources/\(language).lproj/\(table).strings")
    let data = try #require(
      FileManager.default.contents(atPath: path.path), "no compiled table at \(path.path)")
    return try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
  }

  private static func strings(_ catalog: String = catalogPath) throws -> [String: Any] {
    let url = repoRoot.appendingPathComponent(catalog)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let root = try #require(object as? [String: Any])
    #expect(root["sourceLanguage"] as? String == "en")
    return try #require(root["strings"] as? [String: Any])
  }

  private static func state(of entry: [String: Any]?, language: String) -> String? {
    let localizations = entry?["localizations"] as? [String: Any]
    let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    return unit?["state"] as? String
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
