import EnviousWisprCore
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A, plan §3.6 item 1: the shared settings components can only be built with a Settings
/// Map identity or an approved exemption, and every place a search can land on is registered.
/// A drift guard over the SOURCE; SettingsMapRenderingTests checks what the pages actually render.
/// Counts were measured on the completed migration and are frozen: a change must be deliberate.
@Suite("Settings Map registration (#3482)", .tags(.driftGuard))
struct SettingsMapRegistrationTests {
  static let components = [
    "SettingsRow", "PolishRow", "SettingsSectionHeading", "KeybindSettingsRow",
    "SettingsSummaryCard", "EngineCard",
  ]

  static func sources() throws -> [(path: String, tree: SourceFileSyntax)] {
    let root = RepoRoot.url.appending(path: "Sources/EnviousWisprAppKit")
    let files = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects
        as? [URL])
    let swift = files.filter { $0.pathExtension == "swift" }
    #expect(swift.count > 100, "found only \(swift.count) AppKit sources; the scan root moved")
    return try swift.map { url in
      (url.path, Parser.parse(source: try String(contentsOf: url, encoding: .utf8)))
    }
  }

  @Test("no shared settings component offers an initializer that takes its own title")
  func sharedAPIsTakeNoTitle() throws {
    var checked = 0
    for (path, tree) in try Self.sources()
    where path.hasSuffix("SettingsComponents.swift")
      || path.hasSuffix("PolishSectionViews.swift") || path.hasSuffix("KeybindsSettingsView.swift")
    {
      for decl in tree.tokens(viewMode: .sourceAccurate).compactMap({
        $0.parent?.as(InitializerDeclSyntax.self)
      }) {
        guard let owner = Self.owningType(of: decl), Self.components.contains(owner) else {
          continue
        }
        checked += 1
        let labels = decl.signature.parameterClause.parameters.map(\.firstName.text)
        let titled = labels.contains("title") || labels.contains("resolvedTitle")
        let excused = labels.contains("notInSettingsMap") || labels.contains("registration")
        #expect(
          !titled || excused, "\(owner).init(\(labels.joined(separator: ":"))) takes its own title")
      }
    }
    #expect(checked >= 12, "checked only \(checked) initializers; the scan stopped matching")
  }

  @Test("every shared settings row in the app names a map identity or an approved exemption")
  func completeSourcePopulation() throws {
    var first: [String: Int] = [:]
    var exemptions: [String: Int] = [:]
    var total = 0
    for (path, tree) in try Self.sources() {
      for name in Self.components {
        for call in ClipboardSettingsWiringTests.calls(named: name, in: tree) {
          total += 1
          let labels = call.arguments.map { $0.label?.text ?? "_" }
          let identity = labels.first { $0 == "map" || $0 == "notInSettingsMap" }
          #expect(
            identity != nil,
            "\(path): \(name)(\(labels.joined(separator: ":"))) has no map identity")
          #expect(!labels.contains("fixtureTitle"), "\(path): a test fixture form in shipped code")
          first[identity ?? "none", default: 0] += 1
          if let reason = ClipboardSettingsWiringTests.argument("notInSettingsMap", of: call) {
            exemptions[reason, default: 0] += 1
          }
        }
      }
    }
    #expect(
      total == 93,
      "\(total) shared rows; frozen at 93 (map \(first["map"] ?? 0), exempt \(first["notInSettingsMap"] ?? 0))"
    )
    #expect(first["map"] == 74 && first["notInSettingsMap"] == 19, "\(first)")
    #expect(
      exemptions == [".statusLine": 15, ".sheetOrPopoverContent": 3, ".savedKeyRetry": 1],
      "\(exemptions)")
  }

  /// Registrations written directly on custom controls (not through a shared component).
  static let customRegistrations: Set<String> = [
    ".aiPolishProvider", ".aiPolishProviderSection", ".apiKeyClear", ".apiKeyGetKeyLink",
    ".apiKeyReveal", ".apiKeySave", ".appLanguageRelaunch", ".appleIntelligenceRecheck",
    ".autoDetectLanguageResetSuggestions", ".bluetoothGuideLearnMore", ".contactsSyncOnLaunch",
    ".enableAIPolish", ".enableDictionary", ".fastModelCancelDownload", ".importContacts",
    ".learnFrom", ".licenseGplView", ".licenseNoticesView", ".livePreviewBrowseDownloads",
    ".livePreviewLanguage", ".localModelCancel", ".localModelDownload", ".localModelResume",
    ".localModelTestLive", ".localModelTryAgain", ".lockedLanguageChange", ".ollamaBrowseModels",
    ".ollamaCancelPull", ".ollamaDownloadModel", ".ollamaDownloadOllama", ".ollamaPrepareModel",
    ".ollamaRecheck", ".ollamaStart", ".ollamaTryAgain", ".pauseDuration",
    ".permissionAccessibilityOpenSettings", ".permissionMicrophoneRequest",
    ".pillStyleConfigureLivePreview", ".polishModelRefresh", ".previewEngineCompare",
    ".quickAddMenuBar", ".quickAddShortcut", ".quickAddStep1", ".quickAddStep2", ".quickAddStep3",
    ".recordingChime", ".selfLearningDictionary", ".selfLearningDictionaryLearnMore",
    ".sendCrashReportsRestart", ".snippetKeyword", ".snippets", ".snippetsAdd", ".snippetsAddFirst",
    ".snippetsClearSearch", ".snippetsExport", ".snippetsImport", ".snippetsSearch",
    ".startWordField", ".startWordReset", ".startWordSave", ".transcribeFileSteps",
    ".transcriptionEngineRecheckFast", ".whatWeCollectSeeDetails", ".whisperModelCancelDownload",
    ".whisperModelRecheck", ".whisperModelRemove", ".whisperModelResume", ".whisperModelSetUp",
    ".whisperModelTryAgain", ".yourWordsAdd", ".yourWordsCategoryFilter", ".yourWordsClearSearch",
    ".yourWordsExport", ".yourWordsImport", ".yourWordsMassEdit", ".yourWordsSearch",
  ]

  static func registeredLiterals() throws -> [String] {
    var found: [String] = []
    for (_, tree) in try Self.sources() {
      for call in ClipboardSettingsWiringTests.calls(named: "settingsMapRegistration", in: tree) {
        // `calls(named:)` matches member calls through their DeclReference too.
        guard let argument = call.arguments.first?.expression.trimmedDescription else { continue }
        found.append(argument)
      }
      for token in tree.tokens(viewMode: .sourceAccurate)
      where token.text == "settingsMapRegistration" {
        guard let member = token.parent?.parent?.as(MemberAccessExprSyntax.self),
          let call = member.parent?.as(FunctionCallExprSyntax.self),
          let argument = call.arguments.first?.expression.trimmedDescription
        else { continue }
        found.append(argument)
      }
    }
    return found
  }

  @Test("custom controls register exactly the frozen set of identities, once each")
  func customAdapters() throws {
    let literals = try Self.registeredLiterals().filter {
      $0.hasPrefix(".") && !$0.contains("(") && !$0.contains("?")
    }
    let counts = Dictionary(literals.map { ($0, 1) }, uniquingKeysWith: +)
    #expect(
      Set(counts.keys) == Self.customRegistrations,
      "new: \(Set(counts.keys).subtracting(Self.customRegistrations).sorted()); gone: \(Self.customRegistrations.subtracting(counts.keys).sorted())"
    )
    #expect(
      counts.filter { $0.value > 1 }.isEmpty, "registered twice: \(counts.filter { $0.value > 1 })")
  }

  /// The map's own files declare every id; they are never evidence that a control registers one.
  static let mapFiles: Set<String> = [
    "SettingsMap.swift", "SettingsMapID.swift", "SettingsMapTypes.swift",
    "SettingsMapRegistration.swift", "SettingsMapChoiceIDs.swift", "SettingsItemCopy.swift",
  ]

  /// Controls whose identity is computed rather than written at the control: each producer, the
  /// file whose control consumes it, and the consuming expression that must appear there.
  static let indirectProducers: [(ids: [SettingsMapID], file: String, consumer: String)] = [
    (DictationTab.allCases.map(\.mapID), "DictationSettingsView.swift", "map: $0.mapID"),
    (AppSettingsTab.allCases.map(\.mapID), "AppSettingsView.swift", "map: $0.mapID"),
    (DictionaryTab.allCases.map(\.mapID), "YourWordsView.swift", ".settingsMapRegistration(tab.mapID)"),
    (EngineChoicePresentation.choices.map(\.mapID), "SpeechEngineSettingsView.swift", "map: .id(choice.mapID)"),
    (
      LivePreviewEngineChoice.allCases.map { LivePreviewSettingsView.mapID(for: $0) },
      "LivePreviewSettingsView.swift", "map: .id(Self.mapID(for: choice))"
    ),
    (
      RecordingSoundPairing.allCases.map { RecordingChimeCard.mapID(for: $0) },
      "RecordingChimesContent.swift", "card.settingsMapRegistration(Self.mapID(for: pairing))"
    ),
    ([.apiKeyOpenAI, .apiKeyGemini, .apiKeyClaude], "ProviderSetup.swift", "map: .id(mapID)"),
    ([.transcriptionEngineChange, .transcriptionEngineKeepCurrent], "SpeechEngineSettingsView.swift", "keepCurrent: .transcriptionEngineKeepCurrent"),
    ([.previewEngineChange, .previewEngineKeepCurrent], "LivePreviewSettingsView.swift", "keepCurrent: .previewEngineKeepCurrent"),
    ([.localModelResumeUpgrade, .localModelFinishUpgrade], "LocalEngineStatusCard.swift", ".settingsMapRegistration(action.id)"),
    ([.fastModelResume, .fastModelTryAgain], "SpeechEngineSettingsView.swift", ".settingsMapRegistration(action)"),
    (
      [
        .aiPolishWhyUseEgOne, .aiPolishWhyUseS1Mini, .aiPolishWhyUseAppleIntelligence,
        .aiPolishWhyUseOllama, .aiPolishWhyUseOpenAI, .aiPolishWhyUseGemini, .aiPolishWhyUseClaude,
        .aiPolishLinkAboutAppleIntelligence, .aiPolishLinkOllamaLibrary,
        .aiPolishLinkOpenAIRateLimits, .aiPolishLinkGeminiRateLimits, .aiPolishLinkClaudeRateLimits,
      ], "ProviderSetup.swift", "PolishWhyBlock("
    ),
  ]

  @Test("every place a search can land on is registered by some control")
  func everyTargetIsRegistered() throws {
    let files = try Self.sources().filter {
      !Self.mapFiles.contains(URL(fileURLWithPath: $0.path).lastPathComponent)
    }
    #expect(files.count > 100)
    let byName = Dictionary(
      files.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.tree.description) },
      uniquingKeysWith: { first, _ in first })
    let source = files.map { $0.tree.description }.joined(separator: "\n")
    var indirect: Set<SettingsMapID> = []
    for producer in Self.indirectProducers {
      let text = try #require(byName[producer.file], "\(producer.file) is gone")
      #expect(text.contains(producer.consumer), "\(producer.file) no longer consumes \(producer.consumer)")
      for id in producer.ids {
        indirect.insert(id)
        #expect(
          text.contains(".\(Self.caseName(id))") || producer.consumer.contains("mapID")
            || producer.consumer.contains("for:"),
          "\(id.rawValue) is not named where its consumer is")
      }
    }
    // Multi-line `.dynamic(` references read as one line.
    let compact = source.replacingOccurrences(
      of: #"\.dynamic\(\s+"#, with: ".dynamic(", options: .regularExpression)
    let targets = Set(SettingsMap.nodes.compactMap(\.target))
    var missing: [String] = []
    for target in targets {
      let name = Self.caseName(target)
      let literal =
        compact.contains("map: .id(.\(name))") || compact.contains(".settingsMapRegistration(.\(name))")
        || compact.contains(".dynamic(.\(name),")
      if !literal && !indirect.contains(target) { missing.append(target.rawValue) }
    }
    #expect(missing.isEmpty, "targets no control registers: \(missing.sorted())")
    #expect(targets.count >= 100, "only \(targets.count) distinct targets")
  }

  /// Every registration site in shipped code: the file, the component or modifier, and the
  /// identity it names (a map reference, an exemption reason, or a computed expression). Read
  /// with SwiftParser, so comments and strings cannot satisfy it.
  static func registrationSites() throws -> [String] {
    var sites: [String] = []
    for (path, tree) in try Self.sources() {
      let file = URL(fileURLWithPath: path).lastPathComponent
      guard !Self.mapFiles.contains(file) else { continue }
      for name in Self.components {
        for call in ClipboardSettingsWiringTests.calls(named: name, in: tree) {
          let identity =
            ClipboardSettingsWiringTests.argument("map", of: call).map { "map " + $0 }
            ?? ClipboardSettingsWiringTests.argument("notInSettingsMap", of: call).map {
              "exempt " + $0
            } ?? "none"
          sites.append("\(file) | \(name) | \(identity.split(whereSeparator: \.isWhitespace).joined(separator: " "))")
        }
      }
      for token in tree.tokens(viewMode: .sourceAccurate)
      where ["settingsMapRegistration", "settingsMapExemption", "settingsMapExemptScope"]
        .contains(token.text)
      {
        guard let member = token.parent?.parent?.as(MemberAccessExprSyntax.self),
          let call = member.parent?.as(FunctionCallExprSyntax.self)
        else { continue }
        let argument = call.arguments.map(\.expression.trimmedDescription).joined(separator: ", ")
        sites.append("\(file) | \(token.text) | \(argument.split(whereSeparator: \.isWhitespace).joined(separator: " "))")
      }
    }
    return sites.sorted()
  }

  @Test("every registration site matches the reviewed site list")
  func sitesMatchTheFixture() throws {
    let sites = try Self.registrationSites()
    let url = RepoRoot.sourceURL("Tests/Fixtures/settings-map/registration-sites.json")
    let expected = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    if sites != expected {
      let data = try JSONSerialization.data(withJSONObject: sites, options: [.prettyPrinted])
      print("MAP-SITES \(String(decoding: data, as: UTF8.self))")
    }
    let have = Dictionary(sites.map { ($0, 1) }, uniquingKeysWith: +)
    let want = Dictionary(expected.map { ($0, 1) }, uniquingKeysWith: +)
    #expect(
      have == want,
      "new: \(have.filter { want[$0.key] != $0.value }.keys.sorted()); gone: \(want.filter { have[$0.key] != $0.value }.keys.sorted())"
    )
    #expect(sites.count > 150, "only \(sites.count) sites; the scan stopped matching")
  }

  static func caseName(_ id: SettingsMapID) -> String {
    String(describing: id)
  }

  static func owningType(of decl: InitializerDeclSyntax) -> String? {
    var node: Syntax? = Syntax(decl)
    while let current = node {
      if let s = current.as(StructDeclSyntax.self) { return s.name.text }
      if let e = current.as(ExtensionDeclSyntax.self) { return e.extendedType.trimmedDescription }
      node = current.parent
    }
    return nil
  }
}
