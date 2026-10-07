import EnviousWisprAudio
import EnviousWisprCore
import SwiftUI

/// One semantic control on screen, as the Settings Map sees it (#3482 plan §3.6 item 4): a
/// mapped identity, or an approved exemption. Render tests collect these independently of
/// arrival targets, so a control that never registers is caught by the inventory instead.
enum SettingsMapRegistration: Hashable, Sendable {
  case mapped(SettingsMapID)
  case exempt(SettingsMapExemption)
}

/// Collects every registration under a view. Appends, so a container never hides its children.
struct SettingsMapRegistrationKey: PreferenceKey {
  static let defaultValue: [SettingsMapRegistration] = []

  static func reduce(
    value: inout [SettingsMapRegistration], nextValue: () -> [SettingsMapRegistration]
  ) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  /// Registers this control with the Settings Map. A preference only: no layout, hit testing,
  /// accessibility or focus change.
  func settingsMapRegistration(_ id: SettingsMapID) -> some View {
    settingsMapRegistration(.mapped(id))
  }

  func settingsMapRegistration(_ registration: SettingsMapRegistration) -> some View {
    transformPreference(SettingsMapRegistrationKey.self) { $0.append(registration) }
  }

  /// Records that this control deliberately has no map identity, and why.
  /// Inside a region the map leaves out (for example a wizard step that reuses a settings
  /// card), every registration below counts as that exemption instead of its mapped identity.
  func settingsMapExemptScope(_ reason: SettingsMapExemption, when condition: Bool) -> some View {
    transformPreference(SettingsMapRegistrationKey.self) { value in
      if condition { value = value.map { _ in .exempt(reason) } }
    }
  }
}

/// How a mapped control names itself: by id, or by id plus the typed runtime input its node's
/// resolver needs. The title always comes from the node; a control never supplies its own.
enum SettingsMapRef: Sendable {
  case id(SettingsMapID)
  case dynamic(SettingsMapID, SettingsMapTitleContext)

  var id: SettingsMapID {
    switch self {
    case .id(let id), .dynamic(let id, _): id
    }
  }

  /// The visible title, resolved through the node's own owner.
  var title: String { SettingsMap.title(of: self) }

  /// The short line a row shows under its title, from the node's description owner. A node
  /// without a static line is a wiring mistake the row cannot hide.
  var shortLine: String {
    guard case .resource(let resource) = SettingsMap.node(id).description else {
      SettingsMap.wiringFault("Settings Map: \(id.rawValue) has no static short line")
      return ""
    }
    return String(localized: resource)
  }

  /// A wiring fault unless the node declares its short line as composed at runtime.
  func requireRuntimeShortLine() {
    guard case .runtime = SettingsMap.node(id).description else {
      SettingsMap.wiringFault(
        "Settings Map: \(id.rawValue) does not declare a runtime short line")
      return
    }
  }
}

/// Typed runtime inputs for the dynamic resolvers: the state a title depends on, never a title.
/// A context that does not fit the node's resolver is a wiring fault (`SettingsMap.wiringFault`).
enum SettingsMapTitleContext: Sendable {
  case currentEngine(EngineChoicePresentation.Choice)
  case lockedLanguage(code: String, spelling: EnglishSpelling)
  case appleIntelligenceStatus(unavailable: Bool)
  /// The Live Preview language catalog's load state, which renames the install row.
  case livePreviewPacks(loading: Bool, failed: Bool)
  /// A start-word language code from `SpokenPunctuationStartWordEditor.languages`.
  case startWordLanguage(code: String)
  case inputDevice(AudioInputDevice)
  /// A zero-based input on a device with several inputs.
  case inputSocket(index: Int)
  case previewLanguage(LivePreviewStatusBarPresentation.Language)
  /// The chime's display name, as the card shows it.
  case chime(name: String)
  case transcribeFileStep(FileImportCoordinator.Step)
  /// The chosen AI Polish provider (provider card, its section heading, its key link).
  case provider(LLMProvider)
  /// The on-device polish engine (EG-1 or S1-mini).
  case localEngine(name: String)
  /// The Ollama model the setup step offers to download.
  case ollamaModel(name: String)
  case apiKeyReveal(revealed: Bool)
  /// An app language code from the shipped localizations.
  case appLanguage(code: String)
}

extension SettingsMap {
  /// The visible title for a reference. A static node ignores context; a dynamic node requires
  /// the context its resolver takes.
  static func title(of ref: SettingsMapRef) -> String {
    let node = node(ref.id)
    switch (node.title, ref) {
    case (.resource(let resource), .id):
      return String(localized: resource)
    case (.verbatim(let text), .id):
      return text
    case (.dynamic(.currentEngineHeading), .dynamic(_, .currentEngine(let choice))):
      let name = String(localized: choice.title)
      return String(
        localized: "\(name) · \(choice.model)",
        comment:
          "Speech engine settings: heading naming the current engine, then its model. Shown in capitals."
      ).uppercased()
    case (.dynamic(.lockedLanguage), .dynamic(_, .lockedLanguage(let code, let spelling))):
      return LanguageCatalog.lockDisplayName(
        for: LanguageCatalog.entry(forLockedCode: code, spelling: spelling))
    case (
      .dynamic(.appleIntelligenceStatus), .dynamic(_, .appleIntelligenceStatus(let unavailable))
    ):
      return unavailable
        ? String(
          localized: "Not available on this Mac",
          comment:
            "AI Polish, Apple Intelligence: the status row's title when this Mac reports it unavailable."
        )
        : String(
          localized: "Status", comment: "AI Polish, Apple Intelligence: the status row's title.")
    case (.dynamic(.previewLanguagesInstall), .dynamic(_, .livePreviewPacks(let loading, let failed))):
      if loading { return LivePreviewSettingsCopy.packsLoading }
      if failed { return LivePreviewSettingsCopy.packsUnavailable }
      return String(localized: LivePreviewSettingsCopy.packsInstallRowTitleResource)
    case (.dynamic(.startWordLanguage), .dynamic(_, .startWordLanguage(let code))):
      return SpokenPunctuationStartWordEditor.displayName(for: code)
    case (.dynamic(.inputDeviceName), .dynamic(_, .inputDevice(let device))):
      return device.name
    case (.dynamic(.inputSocketOption), .dynamic(_, .inputSocket(let index))):
      return InputSocketCopy.optionLabel(index: index)
    case (.dynamic(.previewLanguage), .dynamic(_, .previewLanguage(let language))):
      return language.name
    case (.dynamic(.chimePreview), .dynamic(_, .chime(let name))):
      return String(localized: "Preview \(name)")
    case (.dynamic(.transcribeFileStep), .dynamic(_, .transcribeFileStep(let step))):
      return step.title
    case (.dynamic(.providerName), .dynamic(_, .provider(let provider))),
      (.dynamic(.providerSection), .dynamic(_, .provider(let provider))):
      return PolishRailCatalog.entry(for: provider)?.name ?? provider.displayName
    case (.dynamic(.apiKeyLink), .dynamic(_, .provider(let provider))):
      return apiKeyLinkTitle(for: provider)
    case (.dynamic(.localModelTest), .dynamic(_, .localEngine(let name))):
      return String(
        localized: "Test that \(name) is live",
        comment: "AI Polish, local model: re-checks that the model answers. %@ is its name.")
    case (.dynamic(.ollamaModelDownload), .dynamic(_, .ollamaModel(let name))):
      return String(localized: "Download \(name)")
    case (.dynamic(.apiKeyReveal), .dynamic(_, .apiKeyReveal(let revealed))):
      return revealed
        ? String(localized: "Hide key", comment: "AI Polish: hides the API key text.")
        : String(localized: "Show key", comment: "AI Polish: shows the API key text.")
    case (.dynamic(.appLanguageName), .dynamic(_, .appLanguage(let code))):
      return AppLanguagePreference.name(of: code)
    default:
      wiringFault("Settings Map: \(ref.id.rawValue) was named with the wrong reference kind")
      return ""
    }
  }

  /// The cloud providers' "get a key" links. Providers without a key page have no link.
  private static func apiKeyLinkTitle(for provider: LLMProvider) -> String {
    switch provider {
    case .openAI:
      return String(
        localized: "Get your free API key at platform.openai.com",
        comment: "AI Polish: link to the OpenAI API key page.")
    case .gemini:
      return String(
        localized: "Get your free API key at aistudio.google.com",
        comment: "AI Polish: link to the Gemini API key page.")
    case .claude:
      return String(
        localized: "Get your Claude API key",
        comment: "AI Polish: link to the Claude Platform API key page.")
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      wiringFault("Settings Map: \(provider) has no API key link")
      return ""
    }
  }
}
