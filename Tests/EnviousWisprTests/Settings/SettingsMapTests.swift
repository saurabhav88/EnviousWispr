import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A: the Settings Map against its independent inventory
/// (`Tests/Fixtures/settings-map/inventory.json`, built from the Phase 0 seed and the plan's §5
/// exemptions, never from SettingsMap.swift), and its choices against the collections the UI
/// renders.
@Suite("Settings Map (#3482)", .tags(.driftGuard))
struct SettingsMapTests {
  struct Inventory: Decodable {
    struct Destination: Decodable {
      let page: String
      let tab: String?
      let dictionaryTab: String?
    }
    struct Item: Decodable {
      let id: String
      let kind: String
      let destination: Destination
      let disposition: String
      let reason: String?
      let parent: String?
      let target: String?
      let fallbacks: [String]?
      let dynamicTitle: Bool?
    }
    struct Structural: Decodable {
      let id: String
      let kind: String
      let parent: String?
      let destination: Destination?
    }
    let items: [Item]
    let structural: [Structural]
  }

  static func inventory() throws -> Inventory {
    let data = try Data(
      contentsOf: RepoRoot.sourceURL("Tests/Fixtures/settings-map/inventory.json"))
    return try JSONDecoder().decode(Inventory.self, from: data)
  }

  static func destination(_ d: Inventory.Destination) throws -> SettingsDestination {
    switch d.page {
    case "dictation": .dictation(try #require(DictationTab(rawValue: d.tab ?? "")))
    case "appSettings": .appSettings(try #require(AppSettingsTab(rawValue: d.tab ?? "")))
    case "keybinds": .keybinds
    case "transcribeFile": .transcribeFile
    case "aiPolish": .aiPolish
    case "dictionary": .dictionary
    case "snippets": .snippets
    default: throw InventoryError.unknownPage(d.page)
    }
  }

  enum InventoryError: Error { case unknownPage(String) }

  @Test("ids are unique, every parent exists, and the tree has one root and no cycle")
  func identityAndTree() throws {
    let nodes = SettingsMap.nodes
    #expect(nodes.count == Set(nodes.map(\.id)).count, "duplicate node ids")
    #expect(
      Set(nodes.map(\.id)) == Set(SettingsMapID.allCases),
      "ids without a node, or nodes without an id")
    #expect(nodes.filter { $0.parent == nil }.map(\.id) == [.windowSettings])
    for node in nodes {
      var seen: Set<SettingsMapID> = [node.id]
      var cursor = node.parent
      while let parent = cursor {
        let next = try #require(
          SettingsMap.byID[parent], "\(node.id.rawValue) has a missing parent")
        #expect(seen.insert(parent).inserted, "\(node.id.rawValue) sits in a cycle")
        cursor = next.parent
      }
    }
    #expect(nodes.count > 250, "only \(nodes.count) nodes; the map lost entries")
  }

  @Test("searchable entries match the inventory both ways; exempt places have no id")
  func itemCorrespondence() throws {
    let inventory = try Self.inventory()
    #expect(inventory.items.count == 310, "the seed had 310 places; got \(inventory.items.count)")
    let mapped = Set(inventory.items.filter { $0.disposition == "mapped" }.map(\.id))
    let exempt = Set(inventory.items.filter { $0.disposition == "exempt" }.map(\.id))
    #expect(
      mapped.count == 246 && exempt.count == 64, "mapped \(mapped.count), exempt \(exempt.count)")
    let searchable = Set(SettingsMap.nodes.filter { $0.item != nil }.map(\.id.rawValue))
    #expect(
      searchable == mapped,
      "in map only: \(searchable.subtracting(mapped).sorted()); in inventory only: \(mapped.subtracting(searchable).sorted())"
    )
    let ids = Set(SettingsMapID.allCases.map(\.rawValue))
    #expect(
      ids.isDisjoint(with: exempt), "exempt places with an id: \(ids.intersection(exempt).sorted())"
    )
    let structural = Set(inventory.structural.map(\.id))
    #expect(ids == mapped.union(structural), "ids that are neither inventory places nor structure")
    for item in inventory.items where item.disposition == "mapped" {
      let id = try #require(SettingsMapID(rawValue: item.id))
      let node = try #require(SettingsMap.byID[id])
      #expect(node.item?.rawValue == item.kind, "\(item.id) kind \(String(describing: node.item))")
    }
  }

  @Test("each entry's destination, Dictionary tab, target and fallbacks match the inventory")
  func destinationsAndTargets() throws {
    for item in try Self.inventory().items where item.disposition == "mapped" {
      let id = try #require(SettingsMapID(rawValue: item.id))
      let node = SettingsMap.node(id)
      let expected = try Self.destination(item.destination)
      #expect(node.destination == expected, "\(item.id) destination")
      #expect(
        node.dictionaryTab?.rawValue == item.destination.dictionaryTab, "\(item.id) dictionary tab")
      #expect(node.target?.rawValue == item.target, "\(item.id) target")
      #expect(node.fallbacks.map(\.rawValue) == (item.fallbacks ?? []), "\(item.id) fallbacks")
      if let target = node.target {
        #expect(SettingsMap.node(target).item != nil, "\(item.id) points at a structural node")
      }
      #expect(node.parent.map { SettingsMap.byID[$0] != nil } ?? false, "\(item.id) parent")
      if let parent = item.parent {
        #expect(
          node.parent?.rawValue == parent, "\(item.id) parent \(String(describing: node.parent))")
      }
    }
  }

  @Test("every title resolves through its owner; only the inventory's dynamic places are dynamic")
  func titleOwnership() throws {
    let inventory = try Self.inventory()
    let dynamic = Set(inventory.items.filter { $0.dynamicTitle == true }.map(\.id))
    for node in SettingsMap.nodes {
      switch node.title {
      case .resource(let resource):
        #expect(!String(localized: resource).isEmpty, "\(node.id.rawValue) resolves empty")
        #expect(!dynamic.contains(node.id.rawValue), "\(node.id.rawValue) should be dynamic")
      case .verbatim(let text):
        #expect(!text.isEmpty, "\(node.id.rawValue) is blank")
      case .dynamic:
        #expect(
          dynamic.contains(node.id.rawValue),
          "\(node.id.rawValue) is dynamic but the inventory says static")
      }
    }
    // Independent literal English for one name from each kind of owner.
    let expected: [(SettingsMapID, String)] = [
      (.theme, "Theme"), (.themeDark, "Dark"), (.transcriptionEngineFast, "Fast"),
      (.stopOnSilence, "Stop recording on silence"), (.pauseDuration, "Pause duration"),
      (.unloadModelOneHour, "After 1 hour"), (.micReadiness30s, "30 sec"),
      (.aiPolishProviderGemini, "Google Gemini"), (.enableAIPolish, "Enable AI Polish"),
      (.yourWordsAdd, "Add word"), (.dictionaryTabLearnFrom, "Learn from..."),
      (.sectionKeybindsRecording, "Recording"), (.licenseGpl, "EnviousWispr · GPLv3"),
    ]
    for (id, english) in expected {
      #expect(Array(SettingsMapRef.id(id).title.utf8) == Array(english.utf8), "\(id.rawValue)")
    }
  }

  /// The names of a parent's choice children, in map order.
  static func choiceTitles(of parent: SettingsMapID) -> [String] {
    SettingsMap.nodes.filter { $0.parent == parent && $0.item == .choice }.map { node in
      switch node.title {
      case .resource(let r): String(localized: r)
      case .verbatim(let t): t
      case .dynamic: "<dynamic>"
      }
    }
  }

  @Test("choices match the collections the pickers render, in order, with explicit exclusions")
  func presentationCoverage() {
    #expect(
      Self.choiceTitles(of: .theme)
        == ThemeChoicePresentation.choices.map { String(localized: $0.label) })
    #expect(
      ThemeChoicePresentation.choices.map(\.mapID) == [.themeSystem, .themeLight, .themeDark])
    #expect(
      Self.choiceTitles(of: .transcriptionEngine)
        == EngineChoicePresentation.choices.map { String(localized: $0.title) })
    #expect(
      Self.choiceTitles(of: .unloadModelAfter)
        == ModelUnloadPolicy.allCases.map { String(localized: $0.displayNameResource) })
    #expect(
      Self.choiceTitles(of: .micReadiness)
        == SettingsChoicePresentation.micReadiness.map { String(localized: $0.label) })
    #expect(
      Self.choiceTitles(of: .mediaDuringDictation)
        == SettingsChoicePresentation.mediaDuringDictation.map { String(localized: $0.label) })
    #expect(
      Self.choiceTitles(of: .pillPosition)
        == SettingsChoicePresentation.pillPosition.map { String(localized: $0.label) })
    #expect(
      Self.choiceTitles(of: .recordingMode)
        == SettingsChoicePresentation.recordingMode.map { String(localized: $0.label) })
    for list in [
      SettingsChoicePresentation.micReadiness.map(\.mapID),
      SettingsChoicePresentation.mediaDuringDictation.map(\.mapID),
      SettingsChoicePresentation.pillPosition.map(\.mapID),
      SettingsChoicePresentation.recordingMode.map(\.mapID),
    ] {
      #expect(list.allSatisfy { SettingsMap.node($0).item == .choice })
    }
    #expect(
      Set(Self.choiceTitles(of: .pillStyle))
        == Set(
          RecordingPillAppearancePanel.displayOrder.map {
            String(localized: $0.displayNameResource)
          }))
    #expect(
      Self.choiceTitles(of: .recordingChime)
        == RecordingSoundPairing.allCases.map { String(localized: displayNameResource(for: $0)) })
    #expect(
      RecordingSoundPairing.allCases.map { RecordingChimeCard.mapID(for: $0) }
        == SettingsMap.nodes.filter { $0.parent == .recordingChime && $0.item == .choice }.map(\.id)
    )
    #expect(
      Self.choiceTitles(of: .s1Tone) == S1Styling.allCases.map { S1ControlCopy.label(for: $0) })
    #expect(
      Self.choiceTitles(of: .s1Structure)
        == S1Structure.allCases.map { S1ControlCopy.label(for: $0) })
    #expect(
      Self.choiceTitles(of: .s1Context) == S1Context.allCases.map { S1ControlCopy.label(for: $0) })
    #expect(
      Self.choiceTitles(of: .yourWordsCategoryFilter)
        == [String(localized: SettingsItemCopy.Dictionary.allCategories)]
        + WordCategory.allCases.map(\.displayName) + [CustomTermProvenanceCopy.filterPill])
    // Every exposed provider; `LLMProvider.none` is the switched-off state, not a choice.
    #expect(Self.choiceTitles(of: .aiPolishProvider) == PolishRailCatalog.all.map(\.name))
    #expect(!PolishRailCatalog.all.contains { $0.provider == .none })
    #expect(
      LivePreviewEngineChoice.allCases.map { LivePreviewSettingsView.mapID(for: $0) }
        == [.previewEngineApple, .previewEngineUniversal])
    #expect(
      SpokenPunctuationRules.startWordLanguages.map { "startWordLanguage.\($0)" }
        == SettingsMap.nodes.filter { $0.parent == .startWordLanguage && $0.item == .choice }
        .map(\.id.rawValue))
    #expect(DictationTab.allCases.map(\.mapID).allSatisfy { SettingsMap.node($0).item == .feature })
    #expect(
      AppSettingsTab.allCases.map(\.mapID).allSatisfy { SettingsMap.node($0).item == .feature })
    #expect(
      DictionaryTab.allCases.map(\.mapID).allSatisfy { SettingsMap.node($0).item == .feature })
  }

  @Test("exemptions use only the plan's reasons, and every exempt inventory place names one")
  func exemptions() throws {
    let approved: Set<String> = [
      "transcribeFileWizard", "vocabularyPackContent", "learningSetupAction", "userContent",
      "sheetOrPopoverContent", "statusLine", "bundledModelRemove", "savedKeyRetry",
    ]
    let reasons: [SettingsMapExemption] = [
      .transcribeFileWizard, .vocabularyPackContent, .learningSetupAction, .userContent,
      .sheetOrPopoverContent, .statusLine, .bundledModelRemove, .savedKeyRetry,
    ]
    #expect(Set(reasons.map(\.rawValue)) == approved)
    for item in try Self.inventory().items where item.disposition == "exempt" {
      let reason = try #require(item.reason, "\(item.id) is exempt without a reason")
      #expect(
        approved.contains(reason),
        "\(item.id): \(reason) is not approved")
    }
  }
}
