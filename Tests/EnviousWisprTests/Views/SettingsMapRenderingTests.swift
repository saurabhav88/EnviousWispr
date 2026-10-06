import AppKit
import EnviousWisprContacts
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import SwiftUI
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprLivePreview
@testable import EnviousWisprPostProcessing
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #3482 PR A, plan §3a(c) and §3.6 item 4: render the real Settings pages, in the states that
/// expose their conditional controls, and collect what each page registers with the Settings
/// Map. Semantic identities come from the rendered view tree, independently of arrival targets
/// and of the source scan in SettingsMapRegistrationTests.
@MainActor
@Suite("Settings Map rendering (#3482)", .serialized, .tags(.productOutcome))
struct SettingsMapRenderingTests {
  init() { _ = NSApplication.shared }

  @MainActor final class Box { var value: [SettingsMapRegistration] = [] }

  /// Everything a rendered view registers, in render order. `settle` lets a page's own
  /// appear-time tasks (a saved-key read, a status probe) finish before the final read.
  static func registrations(
    _ view: AnyView, width: CGFloat = 900, height: CGFloat = 2600, settle: Duration = .zero
  ) async -> [SettingsMapRegistration] {
    let box = Box()
    let root =
      view
      .frame(width: width, height: height)
      .onPreferenceChange(SettingsMapRegistrationKey.self) { value in
        MainActor.assumeIsolated { box.value = value }
      }
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    host.layoutSubtreeIfNeeded()
    if settle > .zero {
      try? await Task.sleep(for: settle)
      host.layoutSubtreeIfNeeded()
    }
    window.contentView = nil
    return box.value
  }

  static func mapped(_ list: [SettingsMapRegistration]) -> [SettingsMapID] {
    list.compactMap { if case .mapped(let id) = $0 { id } else { nil } }
  }

  static func exempt(_ list: [SettingsMapRegistration]) -> [SettingsMapExemption: Int] {
    var counts: [SettingsMapExemption: Int] = [:]
    for case .exempt(let reason) in list { counts[reason, default: 0] += 1 }
    return counts
  }

  /// Checks every rendered state shares: no test-only fixture rows, no identity registered twice,
  /// and nothing from another destination.
  static func checkCommon(
    _ list: [SettingsMapRegistration], on destination: SettingsDestination, label: String,
    allowEmpty: Bool = false
  ) {
    #expect(allowEmpty || !list.isEmpty, "\(label): the page registered nothing, which is not a pass")
    #expect(
      !list.contains(.exempt(.renderFixture)), "\(label): a test fixture row on a real page")
    let ids = mapped(list)
    let repeated = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +).filter { $0.value > 1 }
    #expect(
      repeated.isEmpty, "\(label): registered twice: \(repeated.keys.map(\.rawValue).sorted())")
    // A page's tab strip registers every tab of that page.
    let strip: Set<SettingsMapID> =
      switch destination {
      case .dictation: Set(DictationTab.allCases.map(\.mapID))
      case .appSettings: Set(AppSettingsTab.allCases.map(\.mapID))
      case .dictionary: Set(DictionaryTab.allCases.map(\.mapID))
      default: []
      }
    for id in ids where !strip.contains(id) {
      let node = SettingsMap.node(id)
      #expect(
        node.destination == destination || node.destination == nil,
        "\(label): \(id.rawValue) belongs to \(String(describing: node.destination))")
    }
  }

  static func dictationPage(
    _ tab: DictationTab, scenario: DictationSettingsRenderHarness.Scenario = .init()
  ) async throws -> AnyView {
    try await DictationSettingsRenderHarness.page(tab: tab, german: false, scenario: scenario)
  }

  /// The six Dictation tabs in their ordinary state.
  @Test(
    "each Dictation tab registers its controls",
    arguments: DictationTab.allCases)
  func dictationTabs(tab: DictationTab) async throws {
    let list = await Self.registrations(try await Self.dictationPage(tab))
    Self.checkCommon(list, on: .dictation(tab), label: "dictation.\(tab.rawValue)")
    let ids = Set(Self.mapped(list))
    #expect(ids.contains(tab.mapID), "the \(tab.rawValue) tab itself is not registered")
    Self.expectShown(
      Self.alwaysShown(on: .dictation(tab)), in: list, label: "dictation.\(tab.rawValue)")
    for required in Self.dictationAlways[tab] ?? [] {
      #expect(ids.contains(required), "\(tab.rawValue): \(required.rawValue) is missing")
    }
    print(
      "MAP-RENDER dictation.\(tab.rawValue) mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))"
    )
  }

  /// Controls each Dictation tab shows in its ordinary state (written from the pages, not
  /// read from the map).
  static let dictationAlways: [DictationTab: [SettingsMapID]] = [
    .engine: [
      .sectionTranscriptionEngine, .transcriptionEngine, .transcriptionEngineChange,
      .currentEngineSection, .fasterTranscription, .sectionEngineShared, .stopOnSilence,
      .fillerRemoval, .spokenEmoji, .spokenPunctuation, .unloadModelAfter, .lockedLanguage,
      .lockedLanguageChange,
    ],
    .microphone: [
      .sectionMicrophone, .inputDevice, .micReadiness, .mediaDuringDictation, .bluetoothGuide,
      .bluetoothGuideLearnMore,
    ],
    .livePreview: [
      .sectionLivePreview, .livePreview, .sectionPreviewEngine, .previewEngine,
      .previewEngineCompare,
    ],
    .pill: [.sectionPill, .pillPosition, .pillStyle],
    .chimes: [.sectionChimes, .recordingChimes, .recordingChime],
    .clipboard: [
      .sectionClipboard, .autoCopyToClipboard, .restoreClipboard, .smartInsertion,
      .sectionQuickAddClipboard, .quickAddClipboardFallback,
    ],
  ]

  @Test("expanded engine choices register both engines and Keep current")
  func engineChoices() async throws {
    var scenario = DictationSettingsRenderHarness.Scenario()
    scenario.label = "expanded"
    scenario.expanded = true
    let ids = Set(
      Self.mapped(await Self.registrations(try await Self.dictationPage(.engine, scenario: scenario))))
    for id: SettingsMapID in [
      .transcriptionEngineFast, .transcriptionEngineAllLanguages, .transcriptionEngineKeepCurrent,
    ] {
      #expect(ids.contains(id), "\(id.rawValue) is missing with the choices open")
    }
    #expect(!ids.contains(.transcriptionEngineChange), "Change shows while the choices are open")
  }

  @Test("expanded preview engine choices register both engines and Keep current")
  func previewChoices() async throws {
    var scenario = DictationSettingsRenderHarness.Scenario()
    scenario.label = "expanded"
    scenario.expanded = true
    let ids = Set(
      Self.mapped(
        await Self.registrations(try await Self.dictationPage(.livePreview, scenario: scenario))))
    for id: SettingsMapID in [
      .previewEngineApple, .previewEngineUniversal, .previewEngineKeepCurrent,
    ] {
      #expect(ids.contains(id), "\(id.rawValue) is missing with the choices open")
    }
  }

  @Test("All Languages without a model registers its setup action and the auto-detect row")
  func whisperSetup() async throws {
    var scenario = DictationSettingsRenderHarness.Scenario()
    scenario.label = "whisper"
    scenario.backend = .whisperKit
    scenario.mode = .auto
    let list = await Self.registrations(try await Self.dictationPage(.engine, scenario: scenario))
    let ids = Set(Self.mapped(list))
    #expect(ids.contains(.whisperModelSetUp), "Set up model is missing")
    #expect(Self.exempt(list)[.statusLine, default: 0] >= 1, "the setup status row is not marked")
    #expect(!ids.contains(.lockedLanguage), "a locked language shows in auto mode")
  }

  /// Where an arrival lands (the target, or the node itself for a heading or tab) for every node
  /// the map says is always on screen when `destination` is shown. A choice inside a menu lands
  /// on its menu, so the menu is what must render.
  static func alwaysShown(
    on destination: SettingsDestination, dictionaryTab: DictionaryTab? = nil,
    includeTabs: Bool = true
  ) -> Set<SettingsMapID> {
    Set(
      SettingsMap.nodes.filter { node in
        node.destination == destination && node.visibility == .always
          && node.structure != .page && node.structure != .window
          && (includeTabs || node.structure != .tab)
          && (dictionaryTab == nil || node.dictionaryTab == dictionaryTab)
      }.map { $0.target ?? $0.id })
  }

  /// Fails with the names of map entries a render did not show.
  static func expectShown(
    _ wanted: Set<SettingsMapID>, in list: [SettingsMapRegistration], label: String
  ) {
    let missing = wanted.subtracting(mapped(list)).map(\.rawValue).sorted()
    #expect(missing.isEmpty, "\(label): the map says these show, the page did not: \(missing)")
  }

  // MARK: - Isolated environment for the other pages

  static let scratch = FileManager.default.temporaryDirectory
    .appending(path: "ew-settings-map-render-\(UUID().uuidString)")

  /// One isolated home: preferences, key files, words, snippets and runtimes. Nothing reaches
  /// the real Keychain, Application Support, a model server or the network (Ollama is never
  /// selected: its setup service cannot be replaced).
  struct Home {
    let defaults: UserDefaults
    let settings: SettingsManager
    let keys: KeychainManager
    let setup: SetupCoordinator
    let egOne: EGOneRuntime
    let s1: EGOneRuntime
    let directory: URL

    @MainActor init(provider: LLMProvider = .none, seed: (UserDefaults) -> Void = { _ in }) throws {
      directory = SettingsMapRenderingTests.scratch.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defaults = try #require(TestDefaults.suite("ew.settingsMapRender.\(UUID().uuidString)"))
      // Seeded before the manager exists, so no change handler (or its telemetry) runs.
      defaults.set(provider.rawValue, forKey: "llmProvider")
      seed(defaults)
      settings = SettingsManager(defaults: defaults)
      keys = KeychainManager(
        backend: .legacyFiles,
        legacyStore: FileLegacyKeyStore(storageDirectory: directory.appending(path: "keys")))
      setup = SetupCoordinator(
        asrManager: RouterTestASRManager(),
        whisperKitSetup: WhisperKitSetupService(
          engineMutationScope: .alwaysAllowedForTesting, readAvailability: { .notDownloaded }),
        setupStateReader: { .notDownloaded }, preloadAction: {}, ollamaStatusProbe: { _ in })
      egOne = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: defaults)
      s1 = EGOneRuntime(
        manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: defaults, provider: .s1Mini)
    }

    /// Everything the AI Polish and Transcribe a File pages read.
    @MainActor func polish(_ view: some View) -> AnyView {
      AnyView(
        view.environment(settings).environment(setup)
          .environment(AIAvailabilityCoordinator())
          .environment(
            LLMModelDiscoveryCoordinator(
              keychainManager: keys, cacheDefaults: defaults, savedKeyPresence: SavedKeyPresence(),
              discoverModels: { _, _ in [] }))
          .environment(SavedKeyPresence())
          .environment(egOne).environment(LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1))
          .environment(\.keychainManager, keys))
    }
  }

  // MARK: - AI Polish

  @Test("AI Polish, switched off, registers its switch and nothing of a provider")
  func aiPolishOff() async throws {
    let home = try Home(provider: .none)
    let list = await Self.registrations(home.polish(AIPolishSettingsView()))
    Self.checkCommon(list, on: .aiPolish, label: "aiPolish.off")
    Self.expectShown(Self.alwaysShown(on: .aiPolish), in: list, label: "aiPolish.off")
    #expect(!Set(Self.mapped(list)).contains(.aiPolishProvider), "the provider list shows while off")
    print("MAP-RENDER aiPolish.off mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  /// Ollama is left out: its setup service is not replaceable and would reach the local daemon
  /// and ollama.com. Its rows are listed in `notStaged`.
  nonisolated static let polishProviders: [LLMProvider] = [
    .appleIntelligence, .egOne, .s1Mini, .openAI, .gemini, .claude,
  ]

  static func aiPolishRender(_ provider: LLMProvider, savedKey: Bool = false) async throws
    -> [SettingsMapRegistration]
  {
    let home = try Home(provider: provider)
    if savedKey {
      let id =
        switch provider {
        case .openAI: KeychainManager.openAIKeyID
        case .gemini: KeychainManager.geminiKeyID
        default: KeychainManager.claudeKeyID
        }
      try home.keys.store(key: id, value: "fixture-not-a-key")
    }
    return await Self.registrations(
      home.polish(AIPolishSettingsView()), settle: .milliseconds(400))
  }

  @Test("AI Polish, on, registers the provider list and the chosen provider's section", arguments: polishProviders)
  func aiPolishProvider(provider: LLMProvider) async throws {
    let list = try await Self.aiPolishRender(provider)
    let label = "aiPolish.\(provider.rawValue)"
    Self.checkCommon(list, on: .aiPolish, label: label)
    Self.expectShown(Self.alwaysShown(on: .aiPolish), in: list, label: label)
    let ids = Set(Self.mapped(list))
    for id: SettingsMapID in [.sectionAiPolishModel, .aiPolishProvider, .aiPolishProviderSection] {
      #expect(ids.contains(id), "\(label): \(id.rawValue) is missing")
    }
    for id in Self.providerRows[provider] ?? [] {
      #expect(ids.contains(id), "\(label): \(id.rawValue) is missing")
    }
    // Another provider's own rows never show.
    let others = Self.providerRows.filter { $0.key != provider }.values.flatMap { $0 }
      .filter { !(Self.providerRows[provider] ?? []).contains($0) }
    let leaked = ids.intersection(others).map(\.rawValue).sorted()
    #expect(leaked.isEmpty, "\(label): another provider's rows show: \(leaked)")
    print("MAP-RENDER \(label) mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  /// Each provider's own rows (written from ProviderSetup and the why-use blocks).
  static let providerRows: [LLMProvider: [SettingsMapID]] = [
    .appleIntelligence: [
      .aiPolishWhyUseAppleIntelligence, .aiPolishLinkAboutAppleIntelligence,
      .appleIntelligenceStatus,
    ],
    .egOne: [.aiPolishWhyUseEgOne, .localModelDownload],
    .s1Mini: [
      .aiPolishWhyUseS1Mini, .localModelDownload, .s1Tone, .s1Structure, .s1Context,
    ],
    .openAI: [
      .aiPolishWhyUseOpenAI, .aiPolishLinkOpenAIRateLimits, .apiKeyOpenAI, .apiKeySave,
      .apiKeyGetKeyLink, .polishModel, .polishModelRefresh,
    ],
    .gemini: [
      .aiPolishWhyUseGemini, .aiPolishLinkGeminiRateLimits, .apiKeyGemini, .apiKeySave,
      .apiKeyGetKeyLink, .polishModel, .polishModelRefresh,
    ],
    .claude: [
      .aiPolishWhyUseClaude, .aiPolishLinkClaudeRateLimits, .apiKeyClaude, .apiKeySave,
      .apiKeyGetKeyLink, .polishModel, .polishModelRefresh,
    ],
  ]

  @Test("a saved cloud key registers Clear and Reveal")
  func savedKey() async throws {
    let list = try await Self.aiPolishRender(.openAI, savedKey: true)
    Self.checkCommon(list, on: .aiPolish, label: "aiPolish.openAI.saved")
    let ids = Set(Self.mapped(list))
    #expect(ids.contains(.apiKeyClear), "Clear is missing with a saved key")
    #expect(ids.contains(.apiKeyReveal), "Reveal is missing with a saved key")
  }

  // MARK: - Dictionary

  static func dictionaryHome() throws -> (Home, CustomWordsCoordinator) {
    let home = try Home()
    let words = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: home.directory.appending(path: "custom-words.json")))
    return (home, words)
  }

  @Test("the Dictionary page, on Your Words, registers its heading, tabs and list controls")
  func dictionaryPage() async throws {
    let (home, words) = try Self.dictionaryHome()
    let empty = await Self.registrations(
      AnyView(YourWordsView().environment(home.settings).environment(words)))
    #expect(!Self.mapped(empty).contains(.yourWordsMassEdit), "Mass edit shows with no words")
    try #require(words.add(CustomWord(canonical: "Envious")) == nil)
    let list = await Self.registrations(
      AnyView(YourWordsView().environment(home.settings).environment(words)))
    Self.checkCommon(list, on: .dictionary, label: "dictionary.yourWords")
    let ids = Set(Self.mapped(list))
    for tab in DictionaryTab.allCases {
      #expect(ids.contains(tab.mapID), "the \(tab) tab is not registered")
    }
    Self.expectShown(
      Self.alwaysShown(on: .dictionary).filter {
        let node = SettingsMap.node($0)
        return node.dictionaryTab == nil || node.dictionaryTab == .yourWords
      }, in: list, label: "dictionary.yourWords")
    print("MAP-RENDER dictionary.yourWords mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  /// The other three tabs, hosted as YourWordsView hosts them (its tab is private state).
  static func dictionaryTab(_ tab: DictionaryTab) async throws -> [SettingsMapRegistration] {
    let (home, words) = try Self.dictionaryHome()
    let dir = home.directory
    let packs = VocabularyPackManager(
      overridesStore: VocabularyPackOverridesStore(fileURL: dir.appending(path: "overrides.json")),
      defaults: home.defaults)
    let contacts = ContactsImportCoordinator(
      customWords: words,
      stateStore: ImportedContactsStateStore(fileURL: dir.appending(path: "contacts-state.json")))
    let resources = RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
    let checker = LearnedWordCheckerEligibility(
      delivery: ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { Issue.record("render tried a model change"); return false }, end: { true },
          wake: {}, onRefused: { _ in }),
        manifestBundle: try #require(Bundle(url: resources)),
        appSupportOverride: dir.appending(path: "delivery", directoryHint: .isDirectory)),
      engines: [
        .egOne: .init(
          base: nil, promptTemplateID: nil,
          runtime: home.egOne, debugThreshold: nil)
      ])
    let content: AnyView =
      switch tab {
      case .yourWords: AnyView(CustomTermsSection { EmptyView() })
      case .vocabularyPacks: AnyView(VocabPacksSection())
      case .learnFrom: AnyView(LearningSection())
      case .quickAdd: AnyView(QuickAddTeachingSection())
      }
    return await Self.registrations(
      AnyView(
        ScrollView { LazyVStack(alignment: .leading, spacing: 0) { content } }
          .environment(home.settings).environment(words).environment(packs)
          .environment(contacts).environment(checker)
          .environment(LearnFromEditsAvailability(presentation: .unwired))),
      settle: .milliseconds(200))
  }

  @Test(
    "each other Dictionary tab registers what the map says it shows",
    arguments: [DictionaryTab.vocabularyPacks, .learnFrom, .quickAdd])
  func dictionaryTabs(tab: DictionaryTab) async throws {
    let list = try await Self.dictionaryTab(tab)
    let label = "dictionary.\(tab)"
    // Pack lists and details are left out of search (plan §5): the tab itself, registered by
    // the rail in `dictionaryPage`, is the only place a search lands for Vocabulary Packs.
    Self.checkCommon(list, on: .dictionary, label: label, allowEmpty: tab == .vocabularyPacks)
    if tab == .vocabularyPacks { #expect(Self.mapped(list).isEmpty) }
    Self.expectShown(
      Self.alwaysShown(on: .dictionary, dictionaryTab: tab, includeTabs: false), in: list,
      label: label)
    let ids = Self.mapped(list)
    let strays = ids.filter { SettingsMap.node($0).dictionaryTab.map { $0 != tab } ?? false }
    #expect(strays.isEmpty, "\(label): another tab's controls: \(strays.map(\.rawValue))")
    print("MAP-RENDER \(label) mapped=\(ids.map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  // MARK: - Snippets, Keybinds, App Settings, Transcribe a File

  static func snippetsRender(empty: Bool) async throws -> [SettingsMapRegistration] {
    let home = try Home()
    let coordinator = SnippetsCoordinator(
      manager: SnippetsManager(fileURL: home.directory.appending(path: "snippets.json")))
    if empty {
      for snippet in coordinator.vocabulary.snippets { _ = coordinator.delete(snippet) }
      try #require(coordinator.vocabulary.snippets.isEmpty)
    } else {
      try #require(!coordinator.vocabulary.snippets.isEmpty, "the starters were not seeded")
    }
    return await Self.registrations(AnyView(SnippetsView().environment(coordinator)))
  }

  @Test("Snippets registers its controls, and Add first only when the list is empty")
  func snippets() async throws {
    let seeded = try await Self.snippetsRender(empty: false)
    Self.checkCommon(seeded, on: .snippets, label: "snippets")
    Self.expectShown(Self.alwaysShown(on: .snippets), in: seeded, label: "snippets")
    #expect(!Self.mapped(seeded).contains(.snippetsAddFirst))
    let empty = try await Self.snippetsRender(empty: true)
    Self.checkCommon(empty, on: .snippets, label: "snippets.empty")
    #expect(Self.mapped(empty).contains(.snippetsAddFirst), "Add first is missing when empty")
    print("MAP-RENDER snippets mapped=\(Self.mapped(seeded).map(\.rawValue)) exempt=\(Self.exempt(seeded))")
  }

  static func keybindsRender() async throws -> [SettingsMapRegistration] {
    let home = try Home()
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = TranscriptStore(directory: home.directory.appending(path: "history"))
    let recording = LiveRecordingState(
      kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store),
      whisperKitKernelDriver: DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store), audioCapture: audio, asrManager: asr)
    let runtime = DictationSettingsRenderHarness.idleRuntime(
      settings: home.settings, audio: audio, asr: asr, recording: recording, store: store)
    return await Self.registrations(
      AnyView(KeybindsSettingsView().environment(home.settings).environment(runtime)))
  }

  @Test("Keybinds registers every shortcut row")
  func keybinds() async throws {
    let list = try await Self.keybindsRender()
    Self.checkCommon(list, on: .keybinds, label: "keybinds")
    Self.expectShown(Self.alwaysShown(on: .keybinds), in: list, label: "keybinds")
    print("MAP-RENDER keybinds mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  static func appSettingsRender(_ tab: AppSettingsTab, granted: Bool) throws -> AnyView {
    let home = try Home()
    let permissions = PermissionsService(
      accessibilityReader: { granted }, microphoneReader: { granted ? .authorized : .denied },
      openMicrophoneSettings: { _ in })
    return AnyView(
      AppSettingsView(selection: .constant(tab))
        .environment(permissions).environment(home.settings)
        .environment(PillAppearanceModel(settings: home.settings, capability: { .available }))
        .environment(\.settingsNavigate, { _ in }))
  }

  @Test("each App Settings tab registers what the map says it shows", arguments: AppSettingsTab.allCases)
  func appSettings(tab: AppSettingsTab) async throws {
    let list = await Self.registrations(try Self.appSettingsRender(tab, granted: true))
    let label = "appSettings.\(tab.rawValue)"
    Self.checkCommon(list, on: .appSettings(tab), label: label)
    Self.expectShown(Self.alwaysShown(on: .appSettings(tab)), in: list, label: label)
    let ids = Set(Self.mapped(list))
    for each in AppSettingsTab.allCases {
      #expect(ids.contains(each.mapID), "\(label): the \(each.rawValue) tab is not registered")
    }
    print("MAP-RENDER \(label) mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  @Test("missing permissions register their request actions")
  func permissionsMissing() async throws {
    let list = await Self.registrations(try Self.appSettingsRender(.permissions, granted: false))
    Self.checkCommon(list, on: .appSettings(.permissions), label: "appSettings.permissions.denied")
    let ids = Set(Self.mapped(list))
    #expect(ids.contains(.permissionMicrophoneRequest), "the microphone request is missing")
    #expect(ids.contains(.permissionAccessibilityOpenSettings), "Open Settings is missing")
  }

  private enum Unexpected: Error { case work }

  @Test("Transcribe a File registers only its step bar; the wizard is marked exempt")
  func transcribeFile() async throws {
    let home = try Home()
    let coordinator = FileImportCoordinator(
      decode: { _ in throw Unexpected.work },
      transcribe: { _, _ in throw Unexpected.work },
      engineAdmission: .live(lease: EngineLease(), as: .fileImport),
      ensureEngineReady: { .notInstalled },
      beginRun: {
        .init(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: .none,
          ollamaModel: nil, polishModel: "", backendType: .parakeet)
      },
      saveToHistory: { _ in throw Unexpected.work },
      updateHistoryRow: { _ in throw Unexpected.work },
      mergeSpeakerFields: { _, _, _ in throw Unexpected.work },
      historyRowExists: { _ in false },
      processPart: { _, _ in throw Unexpected.work })
    let list = await Self.registrations(
      home.polish(TranscribeFileView().environment(coordinator)))
    Self.checkCommon(list, on: .transcribeFile, label: "transcribeFile")
    #expect(Self.mapped(list) == [.transcribeFileSteps], "\(Self.mapped(list).map(\.rawValue))")
    print("MAP-RENDER transcribeFile mapped=\(Self.mapped(list).map(\.rawValue)) exempt=\(Self.exempt(list))")
  }

  // MARK: - Every landing place

  /// Every render above, plus the conditional Dictation states the harness can stage.
  static func everyRender() async throws -> [SettingsMapRegistration] {
    var all: [SettingsMapRegistration] = []
    func dictation(_ tab: DictationTab, _ change: (inout DictationSettingsRenderHarness.Scenario) -> Void = { _ in }) async throws {
      var scenario = DictationSettingsRenderHarness.Scenario()
      change(&scenario)
      all += await Self.registrations(try await Self.dictationPage(tab, scenario: scenario))
    }
    for tab in DictationTab.allCases { try await dictation(tab) }
    try await dictation(.engine) { $0.expanded = true }
    try await dictation(.livePreview) { $0.expanded = true }
    try await dictation(.engine) { $0.backend = .whisperKit; $0.mode = .auto }
    try await dictation(.engine) { $0.backend = .whisperKit; $0.setupState = .ready }
    try await dictation(.livePreview) { $0.previewOn = false }
    try await dictation(.livePreview) { $0.installed = [] }
    try await dictation(.livePreview) { $0.active = .needsDownload(name: "German") }
    try await dictation(.engine) { $0.stopOnSilence = true; $0.spokenPunctuation = true }
    for state: WhisperKitSetupState in [
      .downloading(progress: 0.4, status: ""), .paused, .error("fixture"),
    ] {
      try await dictation(.engine) { $0.backend = .whisperKit; $0.setupState = state }
    }
    for provider in polishProviders { all += try await Self.aiPolishRender(provider) }
    all += try await Self.aiPolishRender(.openAI, savedKey: true)
    let (home, words) = try Self.dictionaryHome()
    _ = words.add(CustomWord(canonical: "Envious"))
    all += await Self.registrations(
      AnyView(YourWordsView().environment(home.settings).environment(words)))
    for tab in [DictionaryTab.vocabularyPacks, .learnFrom, .quickAdd] {
      all += try await Self.dictionaryTab(tab)
    }
    all += try await Self.snippetsRender(empty: false)
    all += try await Self.snippetsRender(empty: true)
    for tab in AppSettingsTab.allCases {
      all += await Self.registrations(try Self.appSettingsRender(tab, granted: true))
    }
    all += await Self.registrations(try Self.appSettingsRender(.permissions, granted: false))
    return all
  }

  @Test("every place a search can land on is shown by some rendered state")
  func everyTargetRenders() async throws {
    let all = try await Self.everyRender()
    var shown = Set(Self.mapped(all))
    shown.formUnion(Self.mapped(try await Self.keybindsRender()))
    // Transcribe a File registers only its step bar; `transcribeFile` renders it.
    shown.insert(.transcribeFileSteps)
    let targets = Set(SettingsMap.nodes.compactMap(\.target))
    let unseen = targets.subtracting(shown)
    #expect(
      unseen == Set(Self.notStaged.keys),
      "newly unseen: \(unseen.subtracting(Self.notStaged.keys).map(\.rawValue).sorted()); now staged, remove from notStaged: \(Set(Self.notStaged.keys).subtracting(unseen).map(\.rawValue).sorted())"
    )
    #expect(shown.count >= 150, "only \(shown.count) places rendered; the renders stopped matching")
    // When a target is not on screen, an arrival walks its fallbacks; the last one must be on
    // screen whenever its page shows, which the ordinary-state renders above check.
    var terminals = 0
    for node in SettingsMap.nodes {
      guard let last = node.fallbacks.last else { continue }
      terminals += 1
      #expect(
        SettingsMap.node(last).visibility == .always && shown.contains(last),
        "\(node.id.rawValue): its last fallback \(last.rawValue) is not always on screen")
    }
    #expect(terminals > 0, "no node has a fallback; the check read nothing")
  }

  /// Landing places no render here can show, each with the reason. Their registrations are
  /// still checked in source by SettingsMapRegistrationTests, and an arrival falls back along the
  /// node's fallbacks when the control is not on screen. Frozen: staging one removes it here.
  static let notStaged: [SettingsMapID: String] = {
    let ollama = "Ollama's setup service cannot be replaced; selecting it reaches the local daemon and ollama.com"
    let local = "an EG-One or S1 download state needs a delivery manifest the render home does not stage"
    let interaction = "appears only after the person changes something on the page (page-local state)"
    var reasons: [SettingsMapID: String] = [:]
    for id: SettingsMapID in [
      .aiPolishWhyUseOllama, .ollamaBrowseModels, .ollamaCancelPull, .ollamaDownloadModel,
      .ollamaDownloadOllama, .ollamaPrepareModel, .ollamaRecheck, .ollamaServer, .ollamaStart,
      .ollamaTryAgain,
    ] { reasons[id] = ollama }
    for id: SettingsMapID in [.localModelCancel, .localModelResume, .localModelTestLive, .localModelTryAgain] {
      reasons[id] = local
    }
    for id: SettingsMapID in [
      .appLanguageRelaunch, .sendCrashReportsRestart, .snippetsClearSearch, .yourWordsClearSearch,
    ] { reasons[id] = interaction }
    reasons[.fastModelCancelDownload] =
      "a live Fast model download; the Dictation harness reads Fast as not downloaded"
    reasons[.inputSocket] = "needs a microphone with more than one input; the harness lists no devices"
    return reasons
  }()
}
