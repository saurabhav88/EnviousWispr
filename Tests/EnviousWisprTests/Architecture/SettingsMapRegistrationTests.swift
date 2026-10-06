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

  @Test("every place a search can land on is registered by some control")
  func everyTargetIsRegistered() throws {
    let source = try Self.sources().map { $0.tree.description }.joined(separator: "\n")
    // Identities reached through typed helpers rather than a literal at the control.
    var indirect: Set<SettingsMapID> = [
      .localModelResumeUpgrade, .localModelFinishUpgrade, .fastModelResume, .fastModelTryAgain,
    ]
    indirect.formUnion(DictationTab.allCases.map(\.mapID))
    indirect.formUnion(AppSettingsTab.allCases.map(\.mapID))
    indirect.formUnion(DictionaryTab.allCases.map(\.mapID))
    indirect.formUnion(EngineChoicePresentation.choices.map(\.mapID))
    indirect.formUnion(
      LivePreviewEngineChoice.allCases.map { LivePreviewSettingsView.mapID(for: $0) })
    indirect.formUnion(RecordingSoundPairing.allCases.map { RecordingChimeCard.mapID(for: $0) })
    indirect.formUnion([.apiKeyOpenAI, .apiKeyGemini, .apiKeyClaude])
    indirect.formUnion([
      .aiPolishWhyUseEgOne, .aiPolishWhyUseS1Mini, .aiPolishWhyUseAppleIntelligence,
      .aiPolishWhyUseOllama, .aiPolishWhyUseOpenAI, .aiPolishWhyUseGemini, .aiPolishWhyUseClaude,
      .aiPolishLinkAboutAppleIntelligence, .aiPolishLinkOllamaLibrary,
      .aiPolishLinkOpenAIRateLimits, .aiPolishLinkGeminiRateLimits, .aiPolishLinkClaudeRateLimits,
      .transcriptionEngineChange, .transcriptionEngineKeepCurrent, .previewEngineChange,
      .previewEngineKeepCurrent,
    ])
    for id in indirect {
      #expect(source.contains(".\(Self.caseName(id))"), "\(id.rawValue) is never named in the app")
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
