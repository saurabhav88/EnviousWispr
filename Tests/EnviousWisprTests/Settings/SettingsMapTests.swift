import EnviousWisprAudio
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
      let description: Description?
    }
    struct Description: Decodable {
      let kind: String
      let english: String?
      let why: String?
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
        try #require(seen.insert(parent).inserted, "\(node.id.rawValue) sits in a cycle")
        cursor = next.parent
      }
    }
    #expect(nodes.count > 250, "only \(nodes.count) nodes; the map lost entries")
  }

  /// The plan's tree (§3.6): window, page, tab, section, item. A node's parent sits higher in
  /// that order, except that a choice or action belongs to the item it acts on.
  @Test("the tree runs window, page, tab, section, item, and sections match the inventory")
  func hierarchy() throws {
    func level(_ structure: SettingsMapStructure) -> Int {
      switch structure {
      case .window: 0
      case .page: 1
      case .tab: 2
      case .section: 3
      case .item: 4
      }
    }
    var checked = 0
    for node in SettingsMap.nodes {
      guard let parentID = node.parent else { continue }
      let parent = SettingsMap.node(parentID)
      checked += 1
      if node.structure == .item, parent.structure == .item {
        // Headings drawn as items (the current engine's heading, a provider's section) hold rows.
        continue
      }
      #expect(
        level(parent.structure) < level(node.structure),
        "\(node.id.rawValue) (\(node.structure)) sits under \(parentID.rawValue) (\(parent.structure))")
      if node.structure == .tab || node.structure == .section {
        #expect(parent.destination?.page == node.destination?.page, "\(node.id.rawValue) page")
      }
    }
    #expect(checked == SettingsMap.nodes.count - 1)
    let sections = try Self.inventory().structural.filter { $0.kind == "section" }
    // The map's sections are exactly the inventory's (no frozen total, #3482 review).
    #expect(
      Set(sections.map(\.id))
        == Set(SettingsMap.nodes.filter { $0.structure == .section }.map(\.id.rawValue)))
    for section in sections {
      let node = SettingsMap.node(try #require(SettingsMapID(rawValue: section.id)))
      #expect(node.structure == .section, "\(section.id)")
      #expect(node.parent?.rawValue == section.parent, "\(section.id) parent")
    }
  }

  /// An arrival lands on its target, or walks its fallbacks when the target is not on screen.
  /// Whatever the state, the place it ends on must exist whenever its page is shown.
  @Test("every entry ends on a place that is always shown")
  func everyArrivalHasALanding() {
    var checked = 0
    for node in SettingsMap.nodes {
      guard let target = node.target else { continue }
      checked += 1
      let landing = node.fallbacks.last ?? target
      #expect(
        SettingsMap.node(landing).visibility == .always,
        "\(node.id.rawValue) ends on \(landing.rawValue), which is not always shown")
      for step in node.fallbacks {
        #expect(SettingsMap.node(step).item != nil, "\(node.id.rawValue) falls back to structure")
        #expect(
          SettingsMap.node(step).destination?.page == node.destination?.page,
          "\(node.id.rawValue) falls back to another page")
      }
    }
    #expect(checked == SettingsMap.nodes.filter { $0.item != nil }.count)
  }

  @Test("searchable entries match the inventory both ways; exempt places have no id")
  func itemCorrespondence() throws {
    let inventory = try Self.inventory()
    let mapped = Set(inventory.items.filter { $0.disposition == "mapped" }.map(\.id))
    let exempt = Set(inventory.items.filter { $0.disposition == "exempt" }.map(\.id))
    // Every place is mapped or exempt, and the reader found some: no frozen totals, so adding
    // a place edits the inventory, not this test.
    #expect(!mapped.isEmpty, "the inventory reader found no mapped places")
    #expect(
      mapped.count + exempt.count == inventory.items.count,
      "\(inventory.items.count - mapped.count - exempt.count) places are neither mapped nor exempt")
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

  /// The expected English is the Phase 0 survey's text for the item's line, matched exactly to
  /// the String Catalog; it is not read from the map or from the copy owners.
  @Test("each item's description is its line's own owner, a declared runtime line, or none")
  func descriptions() throws {
    var counts: [String: Int] = [:]
    for item in try Self.inventory().items where item.disposition == "mapped" {
      let node = SettingsMap.node(try #require(SettingsMapID(rawValue: item.id)))
      let kind = item.description?.kind ?? "none"
      counts[kind, default: 0] += 1
      switch (kind, node.description) {
      case ("static", .resource(let resource)?):
        #expect(
          String(localized: resource) == item.description?.english,
          "\(item.id): \(String(localized: resource))")
      case ("runtime", .runtime?), ("none", nil):
        break
      default:
        Issue.record("\(item.id): inventory says \(kind), map has \(String(describing: node.description))")
      }
    }
    #expect(!counts.isEmpty, "the inventory reader found no mapped places")
    for node in SettingsMap.nodes where node.item == nil {
      #expect(node.description == nil, "\(node.id.rawValue): structure has no line")
    }
  }

  /// Each runtime-named place resolves through its node's resolver. Expected English is written
  /// here from the shipped interface (test host locale: English), not read from the resolvers.
  @Test("every runtime-named place resolves through its own resolver")
  func dynamicResolvers() {
    func title(_ id: SettingsMapID, _ context: SettingsMapTitleContext) -> String {
      SettingsMapRef.dynamic(id, context).title
    }
    #expect(
      title(.currentEngineSection, .currentEngine(EngineChoicePresentation.fast))
        == "FAST · PARAKEET V3")
    #expect(
      title(.appleIntelligenceStatus, .appleIntelligenceStatus(unavailable: true))
        == "Not available on this Mac")
    #expect(
      title(.appleIntelligenceStatus, .appleIntelligenceStatus(unavailable: false)) == "Status")
    // The name follows the Mac's own language ("German" here, "Deutsch" on a German Mac), so the
    // check is that the map hands back the picker's name and that a name was found, not a code.
    let german = title(.startWordLanguageDe, .startWordLanguage(code: "de"))
    #expect(german == SpokenPunctuationStartWordEditor.displayName(for: "de"))
    #expect(german != "de" && !german.isEmpty)
    let device = AudioInputDevice(id: 7, name: "Scarlett 2i2", uid: "usb", inputChannelCount: 2)
    #expect(title(.inputDeviceDevice, .inputDevice(device)) == "Scarlett 2i2")
    #expect(title(.inputSocketInput, .inputSocket(index: 1)) == "Input 2")
    #expect(
      title(.livePreviewLanguage, .previewLanguage(.init(name: "Deutsch", provenance: "x")))
        == "Deutsch")
    #expect(title(.recordingChimePreview, .chime(name: "Dust Mote")) == "Preview Dust Mote")
    #expect(title(.transcribeFileSteps, .transcribeFileStep(.upload)) == "Upload")
    #expect(title(.transcribeFileSteps, .transcribeFileStep(.polish)) == "Polish")
    #expect(title(.aiPolishProvider, .provider(.gemini)) == "Google Gemini")
    #expect(title(.aiPolishProviderSection, .provider(.egOne)) == "EG-1")
    #expect(
      title(.apiKeyGetKeyLink, .provider(.openAI))
        == "Get your free API key at platform.openai.com")
    #expect(title(.apiKeyGetKeyLink, .provider(.claude)) == "Get your Claude API key")
    #expect(title(.localModelTestLive, .localEngine(name: "EG-1")) == "Test that EG-1 is live")
    #expect(title(.ollamaDownloadModel, .ollamaModel(name: "llama3.2")) == "Download llama3.2")
    #expect(title(.apiKeyReveal, .apiKeyReveal(revealed: false)) == "Show key")
    #expect(title(.apiKeyReveal, .apiKeyReveal(revealed: true)) == "Hide key")
    #expect(title(.appLanguageShipped, .appLanguage(code: "de")) == "Deutsch")
    #expect(title(.lockedLanguage, .lockedLanguage(code: "de", spelling: .american)) == "Deutsch (German)")
    let packs = title(.previewLanguagesInstall, .livePreviewPacks(loading: false, failed: false))
    #expect(packs == String(localized: LivePreviewSettingsCopy.packsInstallRowTitleResource))
    #expect(
      title(.previewLanguagesInstall, .livePreviewPacks(loading: true, failed: false))
        == LivePreviewSettingsCopy.packsLoading)
    // Every declared resolver kind is exercised above or by a page render.
    let dynamicKinds = Set(
      SettingsMap.nodes.compactMap { node -> String? in
        if case .dynamic(let kind) = node.title { return String(describing: kind) }
        return nil
      })
    // Every declared resolver kind is used by some node (no frozen total, #3482 review).
    #expect(
      dynamicKinds == Set(SettingsMapDynamicTitle.allCases.map { String(describing: $0) }),
      "\(dynamicKinds.sorted())")
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
      Self.choiceTitles(of: .pillStyle)
        == RecordingPillAppearancePanel.displayOrder.map {
          String(localized: $0.displayNameResource)
        })
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
    // The dropdown lists providers group by group.
    #expect(
      Self.choiceTitles(of: .aiPolishProvider)
        == PolishRailGroup.allCases.flatMap { PolishRailCatalog.providers(in: $0) }.map(\.name))
    #expect(Set(Self.choiceTitles(of: .aiPolishProvider)) == Set(PolishRailCatalog.all.map(\.name)))
    #expect(!PolishRailCatalog.all.contains { $0.provider == .none })
    #expect(
      LivePreviewSettingsView.engineChoices.map { LivePreviewSettingsView.mapID(for: $0) }
        == SettingsMap.nodes.filter { $0.parent == .previewEngine && $0.item == .choice }.map(\.id))
    #expect(Set(LivePreviewSettingsView.engineChoices) == Set(LivePreviewEngineChoice.allCases))
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
