import AppKit
import EnviousWisprAudio
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

/// #3482 PR A, plan §3a(c) and §3.6 item 4: render the real Settings pages in every state that
/// exposes a conditional control, and collect what each page registers with the Settings Map.
/// What each state must register is frozen in an independent fixture
/// (`Tests/Fixtures/settings-map/render-states.json`), reviewed against the pages and never read
/// from SettingsMap; the map's own claims (always shown, parents, fallbacks) are checked against
/// the same renders as a second, consistency layer.
@MainActor
@Suite("Settings Map rendering (#3482)", .serialized, .tags(.productOutcome))
struct SettingsMapRenderingTests {
  init() { _ = NSApplication.shared }

  @MainActor final class Box { var value: [SettingsMapRegistration] = [] }

  /// Everything a rendered view registers, in render order. When `ready` is given, the read
  /// waits for the page's own preference updates (an appear-time key read, a status probe)
  /// until it holds; the deadline is a hang guard, never a pass condition.
  static func registrations(
    _ view: AnyView, width: CGFloat = 900, height: CGFloat = 2600,
    afterFirstLayout: (@MainActor () -> Void)? = nil,
    until ready: ((Set<SettingsMapID>) -> Bool)? = nil
  ) async throws -> [SettingsMapRegistration] {
    let box = Box()
    let (changes, continuation) = AsyncStream<Void>.makeStream()
    let root =
      view
      .frame(width: width, height: height)
      .onPreferenceChange(SettingsMapRegistrationKey.self) { value in
        MainActor.assumeIsolated { box.value = value }
        continuation.yield()
      }
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    host.layoutSubtreeIfNeeded()
    // A person's action after the page appeared (typing a key, for example).
    afterFirstLayout?()
    host.layoutSubtreeIfNeeded()
    if let ready {
      while !ready(Set(mapped(box.value))) {
        // deadline-fallback: same 5 s hang guard as the advisory harness.
        let signalled = try await withThrowingTimeout(seconds: 5) {
          var iterator = changes.makeAsyncIterator()
          return await iterator.next() != nil
        }
        try #require(signalled, "the page stopped updating before it was ready")
        host.layoutSubtreeIfNeeded()
      }
    }
    continuation.finish()
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
    #expect(
      allowEmpty || !list.isEmpty, "\(label): the page registered nothing, which is not a pass")
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
    // Each row sits under the heading the map names as its parent: the nearest heading drawn
    // before it on the page. Read from the render, so a misplaced parent shows.
    var heading: SettingsMapID?
    for id in ids {
      let node = SettingsMap.node(id)
      if Self.headings.contains(id) {
        heading = id
        continue
      }
      guard let parent = node.parent, Self.headings.contains(parent) else { continue }
      #expect(
        heading == parent,
        "\(label): \(id.rawValue) is drawn under \(heading?.rawValue ?? "no heading"), the map says \(parent.rawValue)"
      )
    }
    for id in ids where !strip.contains(id) {
      let node = SettingsMap.node(id)
      #expect(
        node.destination == destination || node.destination == nil,
        "\(label): \(id.rawValue) belongs to \(String(describing: node.destination))")
    }
  }

  /// Headings that hold rows: the map's sections, and the headings drawn as items.
  static let headings: Set<SettingsMapID> = Set(
    SettingsMap.nodes.filter { $0.structure == .section }.map(\.id)
  ).union([.currentEngineSection, .aiPolishProviderSection, .yourSnippets])

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

  // MARK: - The states

  /// One rendered state: what the page registered and the page it was.
  struct Rendered {
    let list: [SettingsMapRegistration]
    let destination: SettingsDestination
    /// Map nodes this state must show because the map calls them always shown on this page.
    let alwaysOnThisPage: Set<SettingsMapID>
  }

  /// Every state the matrix renders. Labels are the fixture's keys.
  nonisolated static let stateLabels: [String] =
    DictationTab.allCases.map { "dictation.\($0.rawValue)" } + [
      "dictation.engine.choicesOpen", "dictation.engine.allLanguagesAuto",
      "dictation.engine.allLanguagesReady", "dictation.engine.allLanguagesDownloading",
      "dictation.engine.allLanguagesPaused", "dictation.engine.allLanguagesFailed",
      "dictation.engine.switchesOn", "dictation.engine.fastDownloading",
      "dictation.microphone.multiInput", "dictation.pill.off",
      "dictation.livePreview.choicesOpen", "dictation.livePreview.off",
      "dictation.livePreview.noPacks", "dictation.livePreview.languageMissing",
      "dictation.livePreview.appleUnsupported",
      "aiPolish.off", "aiPolish.appleIntelligence", "aiPolish.egOne", "aiPolish.s1Mini",
      "aiPolish.openAI", "aiPolish.gemini", "aiPolish.claude", "aiPolish.openAI.savedKey",
      "aiPolish.openAI.draftKey",
      "aiPolish.egOne.downloading", "aiPolish.egOne.paused", "aiPolish.egOne.failed",
      "aiPolish.egOne.installed",
      "aiPolish.ollama.notInstalled", "aiPolish.ollama.notRunning", "aiPolish.ollama.noModels",
      "aiPolish.ollama.ready", "aiPolish.ollama.error", "aiPolish.ollama.pulling",
      "dictionary.yourWords.empty", "dictionary.yourWords.withWords",
      "dictionary.yourWords.searching", "dictionary.vocabularyPacks", "dictionary.learnFrom",
      "dictionary.quickAdd",
      "snippets", "snippets.empty", "snippets.searching", "keybinds",
    ] + AppSettingsTab.allCases.map { "appSettings.\($0.rawValue)" } + [
      "appSettings.permissions.denied", "appSettings.privacy.restartNeeded",
      "appSettings.appearance.languageChange", "transcribeFile",
    ]

  static func render(_ label: String) async throws -> Rendered {
    let parts = label.split(separator: ".").map(String.init)
    switch parts[0] {
    case "dictation": return try await dictation(label)
    case "aiPolish": return try await aiPolish(label)
    case "dictionary": return try await dictionary(label)
    case "snippets": return try await snippets(label)
    case "keybinds":
      let list = try await keybindsRender()
      return Rendered(
        list: list, destination: .keybinds, alwaysOnThisPage: alwaysShown(on: .keybinds))
    case "appSettings": return try await appSettings(label)
    case "transcribeFile": return try await transcribeFile()
    default: throw StateError.unknown(label)
    }
  }

  enum StateError: Error { case unknown(String) }

  static func dictationPage(
    _ tab: DictationTab, scenario: DictationSettingsRenderHarness.Scenario = .init()
  ) async throws -> AnyView {
    try await DictationSettingsRenderHarness.page(tab: tab, german: false, scenario: scenario)
  }

  static let multiInputDevice = AudioInputDevice(
    id: 7_701, name: "Scarlett 2i2", uid: "fixture-usb-2in", inputChannelCount: 2)

  static func dictation(_ label: String) async throws -> Rendered {
    let parts = label.split(separator: ".").map(String.init)
    let tab = try #require(DictationTab(rawValue: parts[1]))
    var scenario = DictationSettingsRenderHarness.Scenario()
    var ordinary = false
    switch parts.count > 2 ? parts[2] : "" {
    case "": ordinary = true
    case "choicesOpen": scenario.expanded = true
    case "allLanguagesAuto":
      scenario.backend = .whisperKit
      scenario.mode = .auto
    case "allLanguagesReady":
      scenario.backend = .whisperKit
      scenario.setupState = .ready
    case "allLanguagesDownloading":
      scenario.backend = .whisperKit
      scenario.setupState = .downloading(progress: 0.4, status: "")
    case "allLanguagesPaused":
      scenario.backend = .whisperKit
      scenario.setupState = .paused
    case "allLanguagesFailed":
      scenario.backend = .whisperKit
      scenario.setupState = .error("fixture")
    case "switchesOn":
      scenario.stopOnSilence = true
      scenario.spokenPunctuation = true
    case "fastDownloading":
      scenario.fastDelivery = .downloading(fractionCompleted: 0.3, bytesWritten: 3, totalBytes: 10)
    case "multiInput":
      scenario.devices = [multiInputDevice]
      scenario.preferredInputUID = multiInputDevice.uid
    case "off": scenario.previewOn = false
    case "appleUnsupported": scenario.appleSupported = false
    case "noPacks": scenario.installed = []
    case "languageMissing": scenario.active = .needsDownload(name: "German")
    default: throw StateError.unknown(label)
    }
    scenario.label = label
    let list = try await registrations(try await dictationPage(tab, scenario: scenario))
    if ordinary {
      let ids = Set(mapped(list))
      #expect(ids.contains(tab.mapID), "the \(tab.rawValue) tab itself is not registered")
      for required in dictationAlways[tab] ?? [] {
        #expect(ids.contains(required), "\(label): \(required.rawValue) is missing")
      }
    }
    return Rendered(
      list: list, destination: .dictation(tab),
      alwaysOnThisPage: alwaysShown(on: .dictation(tab)))
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

  // MARK: - Isolated environment for the other pages

  static let scratch = FileManager.default.temporaryDirectory
    .appending(path: "ew-settings-map-render-\(UUID().uuidString)")

  /// One isolated home: preferences, key files, words, snippets and runtimes. Nothing reaches
  /// the real Keychain, Application Support, a model server or the network (Ollama renders take
  /// a service whose daemon, catalog, binary lookup and pull are all replaced).
  struct Home {
    let defaults: UserDefaults
    let settings: SettingsManager
    let keys: KeychainManager
    let setup: SetupCoordinator
    let egOne: EGOneRuntime
    let s1: EGOneRuntime
    let directory: URL

    @MainActor init(
      provider: LLMProvider = .none, ollama: OllamaSetupService? = nil,
      seed: (UserDefaults) -> Void = { _ in }
    ) throws {
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
        setupStateReader: { .notDownloaded }, preloadAction: {}, ollamaStatusProbe: { _ in },
        ollamaSetup: ollama)
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
              discoverModels: { _, _ in [] })
          )
          .environment(SavedKeyPresence())
          .environment(egOne).environment(LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1))
          .environment(\.keychainManager, keys))
    }
  }

  // MARK: - AI Polish

  /// The local Ollama daemon as a render sees it: unreachable (nil status), or answering `/`
  /// with `status` and `/api/tags` with `models`. Nothing leaves the process.
  static func daemon(status: Int?, models: [String])
    -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
  {
    { request in
      guard let status, let url = request.url else { throw URLError(.cannotConnectToHost) }
      let body =
        url.path == "/api/tags"
        ? try JSONSerialization.data(withJSONObject: ["models": models.map { ["name": $0] }])
        : Data()
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
      return (body, response)
    }
  }

  /// Ollama in one setup state, with every boundary the page reaches on appear replaced: the
  /// binary lookup, the local daemon, the ollama.com catalog and the model pull.
  static func ollamaRender(_ state: String) async throws -> [SettingsMapRegistration] {
    let installed: Bool
    let daemon: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let expected: SettingsMapID
    switch state {
    case "notInstalled":
      (installed, daemon, expected) = (
        false, Self.daemon(status: nil, models: []), .ollamaDownloadOllama
      )
    case "notRunning":
      (installed, daemon, expected) = (true, Self.daemon(status: nil, models: []), .ollamaStart)
    case "noModels":
      (installed, daemon, expected) = (
        true, Self.daemon(status: 200, models: []), .ollamaDownloadModel
      )
    case "ready":
      (installed, daemon, expected) = (
        true, Self.daemon(status: 200, models: ["fixture:1b"]), .ollamaServer
      )
    case "error":
      (installed, daemon, expected) = (true, Self.daemon(status: 503, models: []), .ollamaTryAgain)
    case "pulling":
      (installed, daemon, expected) = (
        true, Self.daemon(status: 200, models: []), .ollamaCancelPull
      )
    default: throw StateError.unknown(state)
    }
    let service = OllamaSetupService(
      cloudCatalogClient: OllamaCloudCatalogClient { _, _ in throw URLError(.notConnectedToInternet)
      },
      findOllamaBinaryOverride: { installed ? "/fixture/ollama" : nil },
      localDaemonTransport: daemon,
      // Parks until cancelled, so the real pull state holds and nothing is downloaded.
      pullPerformer: { _ in
        try await Task.sleep(for: .seconds(3_600))
        throw CancellationError()
      })
    // Detection records its last verdict in the standard defaults; restore it afterwards.
    let key = "OllamaSetupService.lastKnownReady"
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
      service.cancelPull()
    }
    // An empty model keeps the ready state from warming a model over the network.
    let home = try Home(provider: .ollama, ollama: service) { defaults in
      defaults.set("", forKey: "llmModel")
      defaults.set("", forKey: "ollamaModel")
    }
    if state == "pulling" { service.pullModel("fixture:1b") }
    return try await registrations(
      home.polish(AIPolishSettingsView()), until: { $0.contains(expected) })
  }

  static func aiPolish(_ label: String) async throws -> Rendered {
    let parts = label.split(separator: ".").map(String.init)
    if parts[1] == "ollama" {
      let list = try await ollamaRender(parts[2])
      return Rendered(
        list: list, destination: .aiPolish, alwaysOnThisPage: alwaysShown(on: .aiPolish))
    }
    let provider: LLMProvider =
      parts[1] == "off" ? .none : try #require(LLMProvider(rawValue: parts[1]))
    let home = try Home(provider: provider)
    var ready: ((Set<SettingsMapID>) -> Bool)?
    let model = ProviderSetupModel()
    var afterFirstLayout: (@MainActor () -> Void)?
    switch parts.count > 2 ? parts[2] : "" {
    case "": break
    case "draftKey":
      // Typed after the page loaded its (empty) saved key, and never saved.
      afterFirstLayout = { model.openAIKey = "sk-fixture-draft" }
      ready = { $0.contains(.apiKeyReveal) }
    case "savedKey":
      try home.keys.store(key: KeychainManager.openAIKeyID, value: "fixture-not-a-key")
      ready = { $0.contains(.apiKeyClear) }
    case "downloading":
      home.egOne.applyInstallStateForTesting(.downloading(fractionCompleted: 0.3, upgrade: nil))
    case "paused": home.egOne.applyInstallStateForTesting(.paused)
    case "failed": home.egOne.applyInstallStateForTesting(.failed(.network))
    case "installed": home.egOne.applyInstallStateForTesting(.installed(version: "1"))
    default: throw StateError.unknown(label)
    }
    let list = try await registrations(
      home.polish(AIPolishSettingsView(setupModel: model)), afterFirstLayout: afterFirstLayout,
      until: ready)
    if parts.count > 2, parts[2] == "draftKey" {
      #expect(!Set(mapped(list)).contains(.apiKeyClear), "Clear shows for an unsaved key")
    }
    let ids = Set(mapped(list))
    if provider == .none {
      #expect(!ids.contains(.aiPolishProvider), "the provider list shows while off")
    } else if parts.count == 2 {
      for id: SettingsMapID in [.sectionAiPolishModel, .aiPolishProvider, .aiPolishProviderSection]
      {
        #expect(ids.contains(id), "\(label): \(id.rawValue) is missing")
      }
      for id in providerRows[provider] ?? [] {
        #expect(ids.contains(id), "\(label): \(id.rawValue) is missing")
      }
      let own = Set(providerRows[provider] ?? [])
      let leaked = ids.intersection(providerRows.values.flatMap { $0 }).subtracting(own)
      #expect(
        leaked.isEmpty, "\(label): another provider's rows: \(leaked.map(\.rawValue).sorted())")
    }
    return Rendered(
      list: list, destination: .aiPolish, alwaysOnThisPage: alwaysShown(on: .aiPolish))
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

  // MARK: - Dictionary

  static func dictionaryHome() throws -> (Home, CustomWordsCoordinator) {
    let home = try Home()
    let words = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: home.directory.appending(path: "custom-words.json")))
    return (home, words)
  }

  static func dictionary(_ label: String) async throws -> Rendered {
    let parts = label.split(separator: ".").map(String.init)
    let tab = try #require(DictionaryTab(rawValue: parts[1]))
    if tab == .yourWords {
      let state = parts[2]
      if state == "searching" {
        // The page's own search state cannot be set from outside; the section is hosted as the
        // page hosts it, opening mid-search.
        let list = try await dictionaryTab(.yourWords, searching: true)
        return Rendered(list: list, destination: .dictionary, alwaysOnThisPage: [])
      }
      let (home, words) = try dictionaryHome()
      if state != "empty" { try #require(words.add(CustomWord(canonical: "Envious")) == nil) }
      let list = try await registrations(
        AnyView(YourWordsView().environment(home.settings).environment(words)))
      let always = alwaysShown(on: .dictionary).filter {
        let node = SettingsMap.node($0)
        return node.dictionaryTab == nil || node.dictionaryTab == .yourWords
      }
      return Rendered(list: list, destination: .dictionary, alwaysOnThisPage: always)
    }
    let list = try await dictionaryTab(tab)
    let strays = mapped(list).filter {
      SettingsMap.node($0).dictionaryTab.map { $0 != tab } ?? false
    }
    #expect(strays.isEmpty, "\(label): another tab's controls: \(strays.map(\.rawValue))")
    return Rendered(
      list: list, destination: .dictionary,
      alwaysOnThisPage: alwaysShown(on: .dictionary, dictionaryTab: tab, includeTabs: false))
  }

  /// The other three tabs, hosted as YourWordsView hosts them (its tab is private state).
  static func dictionaryTab(_ tab: DictionaryTab, searching: Bool = false) async throws
    -> [SettingsMapRegistration]
  {
    let (home, words) = try Self.dictionaryHome()
    if searching { try #require(words.add(CustomWord(canonical: "Envious")) == nil) }
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
          tryBegin: {
            Issue.record("render tried a model change")
            return false
          }, end: { true },
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
      case .yourWords:
        AnyView(CustomTermsSection(initialSearchQuery: searching ? "envious" : "") { EmptyView() })
      case .vocabularyPacks: AnyView(VocabPacksSection())
      case .learnFrom: AnyView(LearningSection())
      case .quickAdd: AnyView(QuickAddTeachingSection())
      }
    return try await Self.registrations(
      AnyView(
        ScrollView { LazyVStack(alignment: .leading, spacing: 0) { content } }
          .environment(home.settings).environment(words).environment(packs)
          .environment(contacts).environment(checker)
          .environment(LearnFromEditsAvailability(presentation: .unwired))))
  }

  // MARK: - Snippets, Keybinds, App Settings, Transcribe a File

  static func snippets(_ label: String) async throws -> Rendered {
    let home = try Home()
    let coordinator = SnippetsCoordinator(
      manager: SnippetsManager(fileURL: home.directory.appending(path: "snippets.json")))
    let state = label.split(separator: ".").dropFirst().first.map(String.init) ?? ""
    if state == "empty" {
      for snippet in coordinator.vocabulary.snippets { _ = coordinator.delete(snippet) }
      try #require(coordinator.vocabulary.snippets.isEmpty)
    } else {
      try #require(!coordinator.vocabulary.snippets.isEmpty, "the starters were not seeded")
    }
    let list = try await registrations(
      AnyView(
        SnippetsView(initialQuery: state == "searching" ? "zzz-no-match" : "")
          .environment(coordinator)))
    return Rendered(
      list: list, destination: .snippets,
      alwaysOnThisPage: alwaysShown(on: .snippets))
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
    return try await registrations(
      AnyView(KeybindsSettingsView().environment(home.settings).environment(runtime)))
  }

  static func appSettings(_ label: String) async throws -> Rendered {
    let parts = label.split(separator: ".").map(String.init)
    let tab = try #require(AppSettingsTab(rawValue: parts[1]))
    let state = parts.count > 2 ? parts[2] : ""
    let home = try Home()
    let granted = state != "denied"
    let permissions = PermissionsService(
      accessibilityReader: { granted }, microphoneReader: { granted ? .authorized : .denied },
      openMicrophoneSettings: { _ in })
    let page: AnyView
    switch state {
    case "restartNeeded":
      // The privacy page as App Settings hosts it, in a run that launched with the other
      // crash-report mode.
      let launched = !home.settings.sendCrashReports
      page = AnyView(
        PrivacySettingsView(launchedCrashReports: { launched })
          .environment(\.settingsPR1Density, true))
    case "languageChange":
      // The appearance page with an isolated language preference that already chose German.
      let name = "ew.settingsMapLanguage.\(UUID().uuidString)"
      let defaults = try #require(TestDefaults.suite(name))
      let preference = AppLanguagePreference(
        defaults: defaults, domain: name, shipped: ["en", "de"])
      preference.choose("de")
      try #require(preference.choice == "de")
      page = AnyView(
        AppearanceSettingsView(languagePreference: preference)
          .environment(\.settingsPR1Density, true))
    default:
      page = AnyView(AppSettingsView(selection: .constant(tab)))
    }
    let list = try await registrations(
      AnyView(
        page.environment(permissions).environment(home.settings)
          .environment(PillAppearanceModel(settings: home.settings, capability: { .available }))
          .environment(\.settingsNavigate, { _ in })))
    if state.isEmpty || state == "denied" {
      let ids = Set(mapped(list))
      for each in AppSettingsTab.allCases {
        #expect(ids.contains(each.mapID), "\(label): the \(each.rawValue) tab is not registered")
      }
    }
    return Rendered(
      list: list, destination: .appSettings(tab),
      // The restart and language states render the tab's page alone, without the tab strip.
      alwaysOnThisPage: alwaysShown(
        on: .appSettings(tab), includeTabs: state.isEmpty || state == "denied"))
  }

  private enum Unexpected: Error { case work }

  static func transcribeFile() async throws -> Rendered {
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
    let list = try await registrations(home.polish(TranscribeFileView().environment(coordinator)))
    return Rendered(list: list, destination: .transcribeFile, alwaysOnThisPage: [])
  }

  // MARK: - The fixture

  struct Expected: Decodable {
    let mapped: [String]
    let exempt: [String: Int]
  }

  static func expectedStates() throws -> [String: Expected] {
    let data = try Data(
      contentsOf: RepoRoot.sourceURL("Tests/Fixtures/settings-map/render-states.json"))
    return try JSONDecoder().decode([String: Expected].self, from: data)
  }

  /// One line per state, in the fixture's shape, for review when a state changes.
  static func observed(_ label: String, _ list: [SettingsMapRegistration]) -> String {
    let mapped = Self.mapped(list).map(\.rawValue).sorted()
    let exempt = Dictionary(
      uniqueKeysWithValues: Self.exempt(list).map { ($0.key.rawValue, $0.value) })
    let object: [String: Any] = ["mapped": mapped, "exempt": exempt]
    let data =
      (try? JSONSerialization.data(withJSONObject: [label: object], options: [.sortedKeys]))
      ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  @Test("each state registers exactly what the reviewed fixture lists", arguments: stateLabels)
  func state(label: String) async throws {
    _ = SettingsMap.takeRecordedFaults()
    let rendered = try await Self.render(label)
    // A Release test run does not stop on a wiring fault; it is recorded instead.
    #expect(SettingsMap.takeRecordedFaults() == [], "\(label): Settings Map wiring faults")
    print("MAP-STATE \(Self.observed(label, rendered.list))")
    Self.checkCommon(
      rendered.list, on: rendered.destination, label: label,
      allowEmpty: label == "dictionary.vocabularyPacks")
    Self.expectShown(rendered.alwaysOnThisPage, in: rendered.list, label: label)
    let expected = try #require(try Self.expectedStates()[label], "\(label) is not in the fixture")
    let mapped = Set(Self.mapped(rendered.list).map(\.rawValue))
    let want = Set(expected.mapped)
    #expect(
      mapped == want,
      "\(label): new \(mapped.subtracting(want).sorted()); missing \(want.subtracting(mapped).sorted())"
    )
    let exempt = Dictionary(
      uniqueKeysWithValues: Self.exempt(rendered.list).map { ($0.key.rawValue, $0.value) })
    var wantExempt = expected.exempt
    // The fixture was recorded on a Mac with more than 8 GB. On an 8 GB Mac (the support floor,
    // and the hosted CI runners) EG-1's card adds its low-memory note, one more status line
    // (LocalEngineStatusCard, `showsLowMemoryNote`).
    if label.hasPrefix("aiPolish.egOne"), ProcessInfo.processInfo.physicalMemory <= 8 << 30 {
      wantExempt["statusLine", default: 0] += 1
    }
    #expect(exempt == wantExempt, "\(label): exemptions \(exempt)")
  }

  /// Choosing a local model while a cloud provider's key row is on screen. The leaving row's
  /// "get a key" link once read the NEW provider, which has no key page, and stopped the app
  /// (live check 2026-10-06, OpenAI to EG-1).
  @Test("switching from a cloud provider to a local model shows the local model's rows")
  func cloudToLocalSwitch() async throws {
    let home = try Home(provider: .openAI)
    _ = SettingsMap.takeRecordedFaults()
    let list = try await Self.registrations(
      home.polish(AIPolishSettingsView(setupModel: ProviderSetupModel())),
      afterFirstLayout: { home.settings.llmProvider = .egOne },
      until: { $0.contains(.aiPolishWhyUseEgOne) })
    let ids = Set(Self.mapped(list))
    #expect(!ids.contains(.apiKeyGetKeyLink), "the cloud key link stayed after the switch")
    #expect(!ids.contains(.apiKeyOpenAI), "the OpenAI key row stayed after the switch")
    #expect(SettingsMap.takeRecordedFaults() == [], "Settings Map wiring faults during the switch")
  }

  @Test("the fixture names exactly the rendered states")
  func fixtureCoversTheMatrix() throws {
    #expect(Set(try Self.expectedStates().keys) == Set(Self.stateLabels))
  }

  // MARK: - Every landing place

  @Test("every place a search can land on is shown by some state")
  func everyTargetRenders() throws {
    let states = try Self.expectedStates()
    let shown = Set(states.values.flatMap(\.mapped))
    let targets = Set(SettingsMap.nodes.compactMap(\.target).map(\.rawValue))
    let unseen = targets.subtracting(shown)
    #expect(
      unseen.isEmpty, "targets without exposing-state render proof: \(unseen.sorted())")
    for node in SettingsMap.nodes {
      guard let last = node.fallbacks.last else { continue }
      #expect(shown.contains(last.rawValue), "\(node.id.rawValue): last fallback never renders")
    }
  }

}
