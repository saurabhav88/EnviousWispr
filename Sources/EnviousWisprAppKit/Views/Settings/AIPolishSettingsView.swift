import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import OSLog
import Security
import SwiftUI

/// Unified log for Save/Clear key failures in the AI Polish settings UI.
/// The user-facing badge intentionally omits the raw OSStatus (#724), so this
/// log keeps the numeric code observable for support and Sentry triage. Never
/// log the key value itself.
private let aiPolishKeychainUILog = Logger(
  subsystem: "com.enviouswispr.app", category: "AIPolishSettings")

// MARK: - Keychain failure → user-facing message (#724)

/// Maps `KeyStoreError` (and the OSStatus values it wraps) to short, action-
/// oriented user-facing text for the API-key field's validation badge.
///
/// Lives at file scope (not private to `AIPolishSettingsView`) so the unit
/// test in `AIPolishKeychainFailureMessageTests` can reach it via
/// `@testable import EnviousWispr`. No other consumers inside the app module;
/// do not adopt elsewhere without revisiting placement.
///
/// Background: `KeyStoreError.errorDescription` returns engineering text like
/// `"Key delete failed: -25291"` which is meaningless to end users. The raw
/// codes still log via Sentry/OSLog from the underlying call sites; the badge
/// only needs to tell the user what to try next. Per #724 / PR #720 review.
enum AIPolishKeychainFailureMessage {
  /// Returns a single short sentence prefixed with `"Failed: "` so existing
  /// `validationStatus.hasPrefix("Failed")` checks in the view still light up
  /// the error styling.
  static func text(for error: any Error, action: Action) -> String {
    "Failed: " + body(for: error, action: action)
  }

  /// The verb the message should suggest. `clear` is the Clear button path;
  /// `save` is the Save button path. The verb only matters for the generic
  /// fallback; specific OSStatus mappings are action-agnostic.
  enum Action {
    case save
    case clear
  }

  private static func body(for error: any Error, action: Action) -> String {
    if let keyStoreError = error as? KeyStoreError {
      switch keyStoreError {
      case .storeFailed(let status), .retrieveFailed(let status), .deleteFailed(let status):
        return message(for: status, action: action)
      case .unsupportedKey:
        // Internal misuse — only the two supported keys ever pass the gate. If
        // a user-facing message ever appears here, it is an engineering bug,
        // not a Keychain state the user can fix.
        return "This key store item is not supported. Please contact support."
      case .rollbackFailed:
        return "We could not finish saving. Restart EnviousWispr and try again."
      }
    }
    // Unexpected error type — generic fallback.
    return genericMessage(for: action)
  }

  /// Maps known Keychain OSStatus values to user-actionable copy. Anything
  /// outside this allowlist falls back to a generic message that omits the
  /// numeric code.
  private static func message(for status: OSStatus, action: Action) -> String {
    switch status {
    case errSecUserCanceled:
      return "Cancelled."
    case errSecAuthFailed:
      return "Could not access the Keychain. Unlock it from Keychain Access and try again."
    case errSecInteractionNotAllowed, errSecInteractionRequired:
      return "Keychain is locked. Unlock it and try again."
    case errSecMissingEntitlement:
      return "EnviousWispr is missing Keychain entitlements. Reinstall the app."
    case errSecNotAvailable:
      return "Keychain is unavailable. Restart EnviousWispr and try again."
    case errSecItemNotFound:
      // Hit only on Save (retrieve path during store's previous-value lookup);
      // the delete path treats not-found as success, so Clear cannot reach
      // here in normal flows.
      return "Key not found. Try again."
    case errSecDuplicateItem:
      return "A duplicate key is already saved. Clear it and try again."
    default:
      return genericMessage(for: action)
    }
  }

  private static func genericMessage(for action: Action) -> String {
    switch action {
    case .save:
      return "Could not save the key. Try again, or restart the app."
    case .clear:
      return "Could not clear the saved key. Try again, or restart the app."
    }
  }
}

// MARK: - Model Recommendation Classifier (#617)

/// Token-based classifier deciding whether a discovered model should land in the
/// "Recommended for cleanup" group of the AI Polish picker. Pure function, no
/// view dependencies. **Lives at file scope (not private to `AIPolishSettingsView`)
/// solely so that `AIPolishClassifierTests` in `Tests/EnviousWisprTests/Settings/`
/// can reach it via `@testable import EnviousWispr`.** Has no other consumers
/// inside the app module; do not adopt it elsewhere without revisiting placement.
///
/// A model is recommended when its lowercased id (split on `-./_/`) contains a
/// positive token (mini, nano, flash) AND no disqualifier token. Disqualifiers
/// rule out specialized variants that would polish poorly (code, audio, image,
/// realtime, search, transcribe, native/live audio variants, music gen).
///
/// Live validation against OpenAI + Gemini APIs (2026-05-04):
/// `docs/audits/2026-05-04-issue-617-classifier-validation.txt`.
enum AIPolishModelClassifier {
  static let positives: Set<String> = ["mini", "nano", "flash"]
  static let disqualifiers: Set<String> = [
    "realtime", "audio", "native", "live",
    "tts", "image", "search", "transcribe", "banana", "codex",
  ]

  /// Returns true if the model id is a Mini/Nano/Flash variant suitable for
  /// transcript cleanup.
  static func isRecommendedForCleanup(_ id: String) -> Bool {
    let tokens = Set(
      id.lowercased()
        .split(whereSeparator: { "-._/".contains($0) })
        .map(String.init)
    )
    return !tokens.isDisjoint(with: positives)
      && tokens.isDisjoint(with: disqualifiers)
  }
}

/// LLM provider configuration, API keys, Ollama wizard, and prompt editing.
struct AIPolishSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(EGOneRuntime.self) private var egOne
  @Environment(\.keychainManager) private var keychainManagerEnv

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var keychainManager: KeychainManager { keychainManagerEnv! }

  @State private var openAIKey: String = ""
  @State private var geminiKey: String = ""
  @State private var validationStatus: String = ""

  private var isCloudProvider: Bool {
    settings.llmProvider == .openAI || settings.llmProvider == .gemini
  }

  private var isReasoningModel: Bool {
    settings.llmProvider.supportsReasoning(model: settings.llmModel)
  }

  private var showModelSection: Bool {
    // EG-1 excluded: one fixed first-party model, no model picker (#1271).
    settings.llmProvider != .none && settings.llmProvider != .appleIntelligence
      && settings.llmProvider != .egOne
  }

  private var ollamaShowsManageModels: Bool {
    switch setup.ollamaSetup.setupState {
    case .ready, .pullingModel, .runningNoModels: return true
    default: return false
    }
  }

  // MARK: - Provider rail (#1286)

  /// The single at-a-glance status for the selected engine, read from the same
  /// coordinators the inline controls use (no cross-provider leak). Rendered
  /// once, in the detail header.
  private var currentProviderStatus: ProviderStatus {
    ProviderStatusMapping.status(
      for: settings.llmProvider,
      egOneInstall: egOne.installState,
      egOneHealth: egOne.health,
      appleStatus: aiAvailability.latestReport?.overallStatus,
      cloudValidation: llmDiscovery.keyValidationState,
      cloudKeyPresent: settings.llmProvider == .openAI
        ? !openAIKey.isEmpty
        : (settings.llmProvider == .gemini ? !geminiKey.isEmpty : false),
      ollamaSetup: setup.ollamaSetup.setupState)
  }

  /// Rail + detail as the two-column master-detail from the approved mockup:
  /// a fixed-width rail on the left, the selected engine's detail on the right.
  /// Always side-by-side (no `HSplitView`, which clips under width pressure —
  /// `hsplitview-never-compresses`); the detail column flexes for wider windows.
  ///
  /// At the settings window's 710pt minimum the usable content width is smaller
  /// than the window (the ~200pt NavigationSplitView sidebar + divider and the
  /// SettingsContentView horizontal padding come off the top), so the detail
  /// column is compact but still functional there; it opens up as the window
  /// widens. The rail is intentionally narrow to hand the detail as much of
  /// that width as possible (cloud review PR #1293, #1286).
  @ViewBuilder
  private var providerSelectionSurface: some View {
    let selection = Binding(
      get: { settings.llmProvider },
      set: { settings.llmProvider = $0 })

    HStack(alignment: .top, spacing: PolishRailMetrics.columnGap) {
      ProviderRail(selection: selection)
        .frame(width: PolishRailMetrics.railWidth, alignment: .leading)
      providerDetailPane
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The full detail column for the selected engine: identity header, then a
  /// stack of cards — setup (key / model download / status), the model picker
  /// (cloud + Ollama), the "Why use ___" explainer (every engine), and the
  /// advanced toggle (reasoning models). Everything for the engine lives in one
  /// column; only Ollama's full model catalog stays below the rail (#1286).
  @ViewBuilder
  private var providerDetailPane: some View {
    @Bindable var settings = settings
    VStack(alignment: .leading, spacing: 14) {
      if let entry = PolishRailCatalog.entry(for: settings.llmProvider) {
        ProviderDetailHeader(entry: entry, status: currentProviderStatus)
      }

      detailCard {
        providerSubConfig
      }

      if showModelSection {
        detailCard(label: "Model") {
          modelSelectorRow
          FrozenPerRecordingFootnote()
        }
      }

      detailCard(label: providerExplainerHeader) {
        providerExplainer
      }

      if isReasoningModel {
        detailCard(label: "Advanced") {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $settings.useExtendedThinking) {
              Text("Deep reasoning").settingsRowLabel()
            }
            .toggleStyle(BrandedToggleStyle())
            Text("Takes longer but handles complex formatting instructions better.")
              .settingsReadingCopy()
          }
          FrozenPerRecordingFootnote()
        }
      }
    }
  }

  /// A titled card in the detail column: an optional uppercase label above a
  /// bordered content box, matching the mockup's stacked-card detail.
  @ViewBuilder
  private func detailCard(
    label: String? = nil, @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let label, !label.isEmpty {
        Text(label.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(Color.stAccent)
      }
      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.stSectionBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )
    }
  }

  /// The setup content for the selected engine (API key, Ollama wizard, Apple
  /// status, or EG-1 status). Behavior, setters, and side effects unchanged;
  /// only the container moved into the detail column (#1286).
  @ViewBuilder
  private var providerSubConfig: some View {
    if isCloudProvider {
      apiKeyRow
      if settings.llmProvider == .openAI {
        Link(
          "Get your free API key at platform.openai.com",
          destination: URL(string: "https://platform.openai.com/api-keys")!
        )
        .font(.stHelper)
      } else if settings.llmProvider == .gemini {
        Link(
          "Get your free API key at aistudio.google.com",
          destination: URL(string: "https://aistudio.google.com/apikey")!
        )
        .font(.stHelper)
      }
    }
    if settings.llmProvider == .ollama {
      ollamaSetupContent
    }
    if settings.llmProvider == .appleIntelligence {
      appleIntelligenceStatus
    }
    if settings.llmProvider == .egOne {
      egOneStatusContent
    }
  }

  /// The model picker row (cloud + Ollama), lifted into the detail column.
  @ViewBuilder
  private var modelSelectorRow: some View {
    @Bindable var settings = settings
    HStack {
      Picker("Model", selection: $settings.llmModel) {
        if llmDiscovery.discoveredModels.isEmpty
          && !llmDiscovery.isDiscoveringModels
        {
          Text(
            settings.llmModel.isEmpty
              ? (settings.llmProvider == .ollama
                ? "No models found"
                : "Save API key to discover models")
              : settings.llmModel
          )
          .tag(settings.llmModel)
        }

        modelPickerSections
      }

      if settings.llmProvider == .ollama {
        ollamaWarmupIndicator
      } else if llmDiscovery.isDiscoveringModels {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          Task {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: settings.llmProvider, settings: settings)
          }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh available models")
        .accessibilityLabel("Refresh available models")
      }
    }
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // ── AI Polish master switch (slide toggle, on its own card) ──
      BrandedSection {
        BrandedRow(showDivider: false) {
          Toggle(
            isOn: Binding(
              get: { settings.llmProvider != .none },
              set: { isOn in
                if isOn {
                  // Restore the last real engine; fall back to the default if
                  // none was ever remembered (guards against `.none`, #1285).
                  settings.llmProvider =
                    settings.lastLLMProvider == .none
                    ? .appleIntelligence : settings.lastLLMProvider
                } else {
                  settings.llmProvider = .none
                }
              }
            )
          ) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Enable AI Polish")
                .settingsRowTitle()
              Text("Automatically fix grammar, punctuation, and formatting.")
                .settingsReadingCopy()
            }
          }
          .toggleStyle(BrandedToggleStyle())
        }
      }

      // ── Engine picker: master-detail rail lifted onto the page so
      // the rail and the detail read as elevated cards, not dark-on-dark
      // nested boxes (#1286 polish pass). Same `llmProvider` setter.
      if settings.llmProvider != .none {
        providerSelectionSurface
      }

      // Manage Models for Ollama stays a full-width section below the rail —
      // the one exception to the single-column detail (the catalog is a long
      // list). Its selected-model setup + explainer live in the detail column.
      if settings.llmProvider == .ollama,
        ollamaShowsManageModels
      {
        BrandedSection(header: "Manage Models") {
          BrandedRow(showDivider: false) {
            ollamaModelCatalogView
          }
        }
      }
    }
    .onAppear {
      openAIKey = (try? keychainManager.retrieve(key: KeychainManager.openAIKeyID)) ?? ""
      geminiKey = (try? keychainManager.retrieve(key: KeychainManager.geminiKeyID)) ?? ""
      if settings.llmProvider == .ollama {
        llmDiscovery.loadCachedModels(for: .ollama)
        Task {
          await setup.ollamaSetup.detectState()
          if case .ready = setup.ollamaSetup.setupState {
            await llmDiscovery.validateKeyAndDiscoverModels(
              provider: .ollama, settings: settings)
          }
        }
      } else if settings.llmProvider == .appleIntelligence {
        Task { await aiAvailability.checkAvailability(trigger: "settings_open") }
      } else if settings.llmProvider == .egOne {
        // #1271: settings-open is one of the two probe moments (the other is
        // provider activation via PipelineSettingsSync). No background polling.
        egOne.activateAndProbe()
      } else if settings.llmProvider != .none {
        llmDiscovery.loadCachedModels(for: settings.llmProvider)
      }
    }
    .onChange(of: settings.llmProvider) { _, newProvider in
      llmDiscovery.reset()
      // Model canonicalization handled by SettingsManager.llmProvider didSet.
      // Discovery will refine the model async if needed.

      // Clean up Ollama state when switching away
      if newProvider != .ollama {
        setup.ollamaSetup.cancelPull()
        setup.ollamaSetup.resetWarmup()
      }

      switch newProvider {
      case .none:
        break
      case .ollama:
        // detectState() will set setupState, which triggers the onChange handler
        // for discovery + warm-up. Don't duplicate that work here.
        Task { await setup.ollamaSetup.detectState() }
      case .appleIntelligence:
        Task { await aiAvailability.checkAvailability(trigger: "provider_switch") }
      case .egOne:
        // Fixed local model — no API key, no model discovery. Routing it
        // into the default key-provider path would hand the discovery
        // coordinator an empty model list and let it overwrite `llmModel`
        // (#1271 Codex r7). Activation/probe rides PipelineSettingsSync;
        // the status section's own onAppear probe covers settings-open.
        break
      default:
        llmDiscovery.loadCachedModels(for: newProvider)
        Task {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: newProvider, settings: settings)
        }
      }
    }
    .onChange(of: setup.ollamaSetup.setupState) { _, newState in
      if case .ready = newState, settings.llmProvider == .ollama {
        Task {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: settings)
        }
        // Warm up the selected model when Ollama becomes ready
        if !settings.llmModel.isEmpty {
          setup.ollamaSetup.warmUpModel(settings.llmModel)
        }
      } else if settings.llmProvider == .ollama {
        // Reset warmup when Ollama leaves .ready (server died, etc.)
        setup.ollamaSetup.resetWarmup()
      }
    }
    .onChange(of: settings.llmModel) { _, newModel in
      // Warm up when user switches Ollama model
      if settings.llmProvider == .ollama,
        case .ready = setup.ollamaSetup.setupState,
        !newModel.isEmpty
      {
        setup.ollamaSetup.warmUpModel(newModel)
      }
    }
  }

  // MARK: - API Key Row

  @ViewBuilder
  private var apiKeyRow: some View {
    let isOpenAI = settings.llmProvider == .openAI
    VStack(alignment: .leading, spacing: 6) {
      Text(isOpenAI ? "OpenAI API Key" : "Google Gemini API Key")
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
      HStack(spacing: 8) {
        if isOpenAI {
          SecureField("sk-proj-…", text: $openAIKey)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("OpenAI API Key")
            .onChange(of: openAIKey) { _, _ in
              dismissStaleFailureStatus()
            }
        } else {
          SecureField("AI…", text: $geminiKey)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Google Gemini API Key")
            .onChange(of: geminiKey) { _, _ in
              dismissStaleFailureStatus()
            }
        }

        validationBadge

        Button("Save") {
          if isOpenAI {
            guard saveKey(key: openAIKey, keychainId: KeychainManager.openAIKeyID) else { return }
            Task {
              await llmDiscovery.validateKeyAndDiscoverModels(
                provider: .openAI, settings: settings, source: .save)
            }
          } else {
            guard saveKey(key: geminiKey, keychainId: KeychainManager.geminiKeyID) else { return }
            Task {
              await llmDiscovery.validateKeyAndDiscoverModels(
                provider: .gemini, settings: settings, source: .save)
            }
          }
        }
        .disabled(isOpenAI ? openAIKey.isEmpty : geminiKey.isEmpty)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("Clear") {
          if isOpenAI {
            guard clearKey(keychainId: KeychainManager.openAIKeyID) else { return }
            openAIKey = ""
          } else {
            guard clearKey(keychainId: KeychainManager.geminiKeyID) else { return }
            geminiKey = ""
          }
          llmDiscovery.reset()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .foregroundStyle(.stError)
      }

      Text(
        "\(isOpenAI ? "OpenAI" : "Gemini") polish sends only transcribed text, never audio. EnviousWispr also sends store: false so the provider is asked not to retain the request or response."
      )
      .settingsReadingCopy()
    }
  }

  // MARK: - Validation Badge

  @ViewBuilder
  private var validationBadge: some View {
    if validationStatus.hasPrefix("Failed") {
      Text(validationStatus)
        .font(.stHelper)
        .foregroundStyle(.stError)
    } else {
      switch llmDiscovery.keyValidationState {
      case .idle:
        if !validationStatus.isEmpty {
          Text(validationStatus)
            .font(.stHelper)
            .foregroundStyle(validationStatus.contains("Saved") ? .stSuccess : .stError)
        }
      case .validating:
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("Validating…")
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
        }
      case .valid:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.stSuccess)
          Text("Valid")
            .font(.stHelper)
            .foregroundStyle(.stSuccess)
        }
      case .invalid(let message):
        HStack(spacing: 4) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.stError)
          Text(message)
            .font(.stHelper)
            .foregroundStyle(.stError)
        }
      }
    }
  }

  // MARK: - Model Picker Sections (#617)

  /// Three labeled groups of discovered models. Empty groups are suppressed.
  /// Locked rows are disabled so a user can't pick something the API will reject.
  @ViewBuilder
  private var modelPickerSections: some View {
    let discovered = llmDiscovery.discoveredModels
    let recommended = discovered.filter {
      $0.isAvailable && AIPolishModelClassifier.isRecommendedForCleanup($0.id)
    }
    let other = discovered.filter {
      $0.isAvailable && !AIPolishModelClassifier.isRecommendedForCleanup($0.id)
    }
    let locked = discovered.filter { !$0.isAvailable }

    if !recommended.isEmpty {
      Section("Recommended for cleanup") {
        ForEach(recommended) { model in
          Text(model.displayName).tag(model.id)
        }
      }
    }
    if !other.isEmpty {
      Section("Other available models") {
        ForEach(other) { model in
          Text(model.displayName).tag(model.id)
        }
      }
    }
    if !locked.isEmpty {
      Section("Not available with your API key") {
        ForEach(locked) { model in
          HStack {
            Image(systemName: "lock.fill").font(.caption2)
            Text(model.displayName)
          }
          .tag(model.id)
          .selectionDisabled(true)
        }
      }
    }
  }

  // MARK: - Provider Explainer ("Why use ___")

  /// The "Why use ___" card label for every engine (#1286). Cloud reuses the
  /// existing #617 header.
  private var providerExplainerHeader: String {
    switch settings.llmProvider {
    case .openAI, .gemini: return cloudProviderExplainerHeader
    case .appleIntelligence: return "Why use Apple Intelligence"
    case .ollama: return "Why use Local (Ollama)"
    case .egOne: return "Why use EG-1"
    case .none: return ""
    }
  }

  /// The explainer body per engine. Cloud reuses the existing #617 copy; the
  /// on-device engines get parallel copy so all five match (#1286). No em or
  /// en dashes in any of these strings.
  @ViewBuilder
  private var providerExplainer: some View {
    switch settings.llmProvider {
    case .openAI, .gemini:
      cloudProviderExplainer
    case .appleIntelligence:
      appleIntelligenceExplainer
    case .ollama:
      ollamaExplainer
    case .egOne:
      egOneExplainer
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var egOneExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "EG-1 is the model we trained ourselves, tuned only for cleaning up dictation. It runs entirely on this Mac, so nothing you say leaves your device, and it is free with no API key to manage."
      )
      .settingsReadingCopy()

      Text(
        "One model, no choices. There are no sizes to pick and no per-use cost. We maintain EG-1 and keep improving it, so you get consistent cleanup without tuning anything."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. EG-1 is the recommended default for most people who want private, free, on-device polish that is tuned for this exact job. If you need a very large general model, the cloud options are there."
      )
      .settingsReadingCopy()
    }
  }

  @ViewBuilder
  private var appleIntelligenceExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Apple Intelligence uses Apple's on-device model, built into macOS. It is free, needs no API key, and nothing you dictate leaves your Mac. It is a solid choice for short, everyday dictation."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. Reach for Apple Intelligence when you want zero setup and clean results on short notes. For longer recordings, lists, or code, EG-1 or a cloud model handles structure better."
      )
      .settingsReadingCopy()

      Text(
        "Requires macOS 26 or later. On earlier versions this option is unavailable and your text is pasted exactly as transcribed."
      )
      .settingsReadingCopy()
    }
  }

  @ViewBuilder
  private var ollamaExplainer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Local (Ollama) runs open models on your Mac through Ollama, a free tool you install once. Nothing you dictate leaves your device, and there is no API key or per-use cost."
      )
      .settingsReadingCopy()

      Text(
        "These are general open models, not tuned for dictation the way EG-1 is. Quality depends on the model you download, and larger models run slower. You pick and manage the models yourself in the list below."
      )
      .settingsReadingCopy()

      Text(
        "When to use it. Choose Ollama if you want to run a specific open model on device or to experiment. For the best on-device cleanup with no setup, EG-1 is simpler."
      )
      .settingsReadingCopy()
    }
  }

  private var cloudProviderExplainerHeader: String {
    settings.llmProvider == .openAI ? "Why use OpenAI" : "Why use Gemini"
  }

  @ViewBuilder
  private var cloudProviderExplainer: some View {
    if settings.llmProvider == .openAI {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Apple Intelligence cleans up short dictation well. OpenAI is a step up for longer recordings, lists, and code. You bring your own API key, you only pay OpenAI for what you use, and most cleanup runs land in well under a second. Cloud polish sends the transcript to OpenAI under your API account."
        )
        .settingsReadingCopy()

        Text(
          "Picking the right model. OpenAI sells several sizes inside each generation. For dictation cleanup, look for Mini in the name. Those are tuned for fast, light tasks and run roughly 3 to 10 times cheaper than the flagships. Nano is even smaller and faster. The unsuffixed flagships (GPT-5, GPT-4.1) and anything labeled Pro are overkill for this job."
        )
        .settingsReadingCopy()

        Text(
          "Locked models? Those aren't blocked by EnviousWispr. Your OpenAI API key doesn't currently have access to them. OpenAI gates some models behind spend tier or organization verification."
        )
        .settingsReadingCopy()

        Link(
          "How OpenAI model availability works by usage tier",
          destination: URL(
            string:
              "https://help.openai.com/en/articles/10362446-api-model-availability-by-usage-tier-and-verification-status"
          )!
        )
        .font(.stHelper)
      }
    } else if settings.llmProvider == .gemini {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Apple Intelligence cleans up short dictation well. Gemini is a step up for longer recordings, lists, and code. You bring your own API key, the free tier is generous for personal use, and most cleanup runs land in well under a second. Cloud polish sends the transcript to Google under your Gemini API account."
        )
        .settingsReadingCopy()

        Text(
          "Picking the right model. Gemini sells two sizes inside each generation. For dictation cleanup, look for Flash in the name. Those are tuned for fast, light tasks. Pro models are overkill: slightly smarter on hard reasoning, slower and pricier on a job that doesn't need it."
        )
        .settingsReadingCopy()

        Text(
          "Locked models? Those aren't blocked by EnviousWispr. Your Gemini API key doesn't currently have access to them. Some Gemini models are gated by region, billing tier, or preview status."
        )
        .settingsReadingCopy()

        Link(
          "Gemini API rate limits by tier",
          destination: URL(string: "https://ai.google.dev/gemini-api/docs/rate-limits")!
        )
        .font(.stHelper)
      }
    }
  }

  // MARK: - Ollama Setup

  @ViewBuilder
  private var ollamaSetupContent: some View {
    switch setup.ollamaSetup.setupState {
    case .detecting:
      HStack {
        ProgressView()
          .controlSize(.small)
        Text("Checking Ollama installation...")
          .foregroundStyle(Color.stTextSecondary)
      }

    case .notInstalled:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 1)

        Text(
          "Ollama runs AI models privately on your Mac. No cloud, no API keys, completely free."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)

        HStack {
          Button("Download Ollama") {
            if let url = URL(string: "https://ollama.com/download") {
              NSWorkspace.shared.open(url)
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)

          ollamaRefreshButton()
        }

        Text("After installing, come back and click refresh.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }

    case .installedNotRunning:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 2)

        Text("Ollama is installed but isn't running yet.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)

        HStack {
          Button("Start Ollama") {
            setup.ollamaSetup.startServer()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)

          ollamaRefreshButton()
        }

        Text("Or run `ollama serve` in Terminal.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }

    case .runningNoModels:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 3)

        Text("Ollama needs a language model to polish your text.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)

        HStack {
          Button("Download \(settings.ollamaModel)") {
            setup.ollamaSetup.pullModel(settings.ollamaModel)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)

          ollamaRefreshButton()
        }

        Text("About 2 GB download. Runs entirely on your Mac.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }

    case .pullingModel(let progress, let status):
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 3, currentLabel: "Downloading...")

        ProgressView(value: progress)
          .progressViewStyle(.linear)

        HStack {
          Text(status)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .lineLimit(1)
          Spacer()
          if progress > 0 {
            Text("\(Int(progress * 100))%")
              .font(.stHelper)
              .monospacedDigit()
              .foregroundStyle(Color.stTextSecondary)
          }
          Button("Cancel") {
            setup.ollamaSetup.cancelPull()
          }
          .controlSize(.small)
          .buttonStyle(.borderless)
          .foregroundStyle(.stError)
        }
      }

    case .ready:
      HStack {
        Text("Status:")
        Spacer()
        Label("Running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)

        ollamaRefreshButton()
      }

      Text("You're all set! Select a model above.")
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)

    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.stWarning)

        Text(message)
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)

        Button("Try Again") {
          Task {
            await setup.ollamaSetup.detectState()
            if case .ready = setup.ollamaSetup.setupState {
              await llmDiscovery.validateKeyAndDiscoverModels(
                provider: .ollama, settings: settings)
            }
          }
        }
        .controlSize(.small)
      }
    }
  }

  // MARK: - EG-1 native model (#1271)

  /// Whole-section content for the EG-1 provider: explainer with the
  /// founder-approved benchmark claim (real numbers, no competitor names),
  /// download flow with size disclosure, the green/yellow/red activation
  /// pill (a REAL inference probe, never process-exists), Remove Model, and
  /// the 8 GB heads-up. Copy rules: no em or en dashes in these strings.
  @ViewBuilder
  private var egOneStatusContent: some View {
    // The pitch (tuned, on-device, benchmark) lives in the "Why use EG-1" card
    // now (#1286); this card is just the actionable status/download/remove.
    if isLowMemoryMac {
      Label(
        "This Mac has 8 GB of memory. EG-1 may run slower here. "
          + "Dictation always works, even when polish is unavailable.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.stHelper)
      .foregroundStyle(.stWarning)
      .fixedSize(horizontal: false, vertical: true)
    }

    switch egOne.installState {
    case .notInstalled:
      HStack {
        Text("One-time download: 2.7 GB")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
        Spacer()
        Button("Download EG-1") { egOne.startDownload() }
      }
    case .downloading(let fraction):
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: max(0, min(1, fraction))) {
          Text("Downloading EG-1 (2.7 GB)")
            .font(.stHelper)
        }
        Button("Cancel") { egOne.cancelDownload() }
          .buttonStyle(.borderless)
          .font(.stHelper)
      }
    case .verifying:
      HStack {
        ProgressView().controlSize(.small)
        Text("Verifying download integrity")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
      }
    case .failed(let failure):
      Text(egOneFailureCopy(failure))
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
      Button("Try Again") { egOne.startDownload() }
    case .installed:
      HStack {
        Text("Status:")
        Spacer()
        egOneHealthLabel
        Button {
          egOne.activateAndProbe()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Test that EG-1 is live")
        .accessibilityLabel("Test that EG-1 is live")
      }
      if let reason = egOneHealthDetail {
        Text(reason)
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Remove Model") {
        egOne.removeModel()
        settings.llmProvider = .appleIntelligence
      }
      .buttonStyle(.borderless)
      .font(.stHelper)
    }
  }

  @ViewBuilder
  private var egOneHealthLabel: some View {
    switch egOne.health {
    case .green:
      Label("Live", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.stSuccess)
    case .yellow:
      Label("Attention", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.stWarning)
    case .red:
      Label("Not working", systemImage: "xmark.circle.fill")
        .foregroundStyle(.stError)
    }
  }

  /// Plain-language reason line under the health pill (nil for green).
  private var egOneHealthDetail: String? {
    switch egOne.health {
    case .green:
      return nil
    case .yellow(let reason):
      switch reason {
      case "starting": return "The model is starting up. This takes a few seconds."
      case "paused_for_memory":
        return "Paused to free memory for other apps. Use the refresh button to restart it."
      case "probe_slow": return "Working, but responding slowly right now."
      case "probe_output_unexpected":
        return "The model responded, but not as expected. Try re-downloading it."
      case "downloading", "verifying": return nil
      default: return "Something needs attention. Try the refresh button."
      }
    case .red(let reason):
      switch reason {
      case "download_required": return "Download the model to get started."
      case "app_update_required":
        return "This model needs a newer version of EnviousWispr."
      case "crashed_twice":
        return "The model stopped twice in a row. Use the refresh button to try again."
      default: return "Not running. Use the refresh button to try again."
      }
    }
  }

  private func egOneFailureCopy(_ failure: EGOneModelStore.EGOneDownloadFailure) -> String {
    switch failure {
    case .network:
      return "Could not download the model from models.enviouslabs.co. "
        + "Check your connection. On a managed network, ask IT to allow this domain."
    case .checksum:
      return "The download did not verify correctly and was discarded. Please try again."
    case .disk:
      return "Not enough free disk space. The download needs about 6 GB free during install."
    case .cancelled:
      return "Download canceled. Your progress is saved."
    case .rangeUnsupported, .http:
      return "The download server had a problem. Please try again in a few minutes."
    case .stubURL:
      return "This build has no download source configured."
    }
  }

  private var isLowMemoryMac: Bool {
    ProcessInfo.processInfo.physicalMemory <= (8 << 30)
  }

  // MARK: - Apple Intelligence Status

  @ViewBuilder
  private var appleIntelligenceStatus: some View {
    // The "no internet or API key" pitch lives in the "Why use Apple
    // Intelligence" card now (#1286); this card is just the status row.
    HStack {
      Text("Status:")
      Spacer()
      aiStatusLabel
      Button {
        aiAvailability.debouncedCheck()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(aiAvailability.isChecking)
      .help("Check Apple Intelligence availability")
      .accessibilityLabel("Check Apple Intelligence availability")
    }

    // "Why?" detail text
    if let report = aiAvailability.latestReport,
      report.overallStatus != .available
    {
      Text(report.userVisibleMessage)
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
    }

    #if DEBUG
      // Debug section — dev builds only. Wrapped with `#if DEBUG` (not just the
      // `isDebugModeEnabled` runtime check) so a release binary inheriting a
      // persisted-true flag from a prior dev session cannot reach
      // `aiDebugSection`.
      if settings.isDebugModeEnabled, let report = aiAvailability.latestReport {
        aiDebugSection(report: report)
      }
    #endif
  }

  @ViewBuilder
  private var aiStatusLabel: some View {
    if aiAvailability.isChecking {
      ProgressView().controlSize(.small)
    } else if let report = aiAvailability.latestReport {
      switch report.overallStatus {
      case .available:
        Label("Available", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
      case .degraded:
        Label("Degraded", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.stWarning)
      case .unavailable:
        Label("Unavailable", systemImage: "xmark.circle.fill")
          .foregroundStyle(.stError)
      case .unknown:
        Label("Unknown", systemImage: "questionmark.circle")
          .foregroundStyle(Color.stTextSecondary)
      }
    } else {
      Text("Not checked")
        .foregroundStyle(Color.stTextSecondary)
    }
  }

  #if DEBUG
    @ViewBuilder
    private func aiDebugSection(report: AppleIntelligenceAvailabilityReport) -> some View {
      DisclosureGroup("Diagnostics") {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(report.gates.allGates, id: \.name) { gate in
            HStack(spacing: 6) {
              gateStatusIcon(gate.result.status)
              Text(gate.name)
                .font(.caption)
                .fontWeight(.medium)
              Spacer()
              Text(gate.result.summary)
                .font(.caption2)
                .foregroundStyle(Color.stTextSecondary)
                .lineLimit(1)
              if let ms = gate.result.durationMs {
                Text("\(ms)ms")
                  .font(.caption2)
                  .foregroundStyle(Color.stTextSecondary)
              }
            }
          }
          HStack {
            Text("OS: \(report.osVersion)")
            Spacer()
            Text("HW: \(report.hardwareClass)")
            Spacer()
            Text("Total: \(report.checkDurationMs)ms")
          }
          .font(.caption2)
          .foregroundStyle(Color.stTextSecondary)

          Button("Copy Diagnostics") {
            aiAvailability.copyDiagnosticsToClipboard()
          }
          .font(.caption)
          .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
      }
      .font(.caption)
    }

    @ViewBuilder
    private func gateStatusIcon(_ status: AIGateStatus) -> some View {
      switch status {
      case .passed:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.stHelper)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.stError)
          .font(.stHelper)
      case .skipped:
        Image(systemName: "minus.circle")
          .foregroundStyle(Color.stTextSecondary)
          .font(.stHelper)
      case .timedOut:
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(.stWarning)
          .font(.stHelper)
      case .unknown:
        Image(systemName: "questionmark.circle")
          .foregroundStyle(Color.stTextSecondary)
          .font(.stHelper)
      }
    }
  #endif

  // MARK: - Ollama Model Catalog

  @ViewBuilder
  private var ollamaModelCatalogView: some View {
    let catalog = setup.ollamaSetup.dynamicCatalog
    let isPulling: Bool = {
      if case .pullingModel = setup.ollamaSetup.setupState { return true }
      return false
    }()

    VStack(alignment: .leading, spacing: 6) {
      ForEach(catalog) { entry in
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
              Text(entry.displayName)
                .font(.stHelper)
              Text("(\(entry.qualityTier.label))")
                .font(.stHelper)
                .foregroundStyle(
                  entry.qualityTier == .best
                    ? Color.stAccent
                    : (entry.qualityTier == .medium ? Color.secondary : Color.stWarning))
            }
            Text("\(entry.parameterCount) · \(entry.downloadSize)")
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
          }

          Spacer()

          if setup.ollamaSetup.currentPullingModel == entry.name {
            // Active pull for THIS row: show progress + Cancel.
            HStack(spacing: 8) {
              Text("Downloading… \(Int(setup.ollamaSetup.pullProgress * 100))%")
                .font(.stHelper)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
              Button {
                setup.ollamaSetup.cancelPull()
              } label: {
                Text("Cancel")
                  .foregroundStyle(.stError)
              }
              .controlSize(.small)
              .buttonStyle(.borderless)
            }
          } else if entry.isDownloaded {
            Button {
              setup.ollamaSetup.deleteModel(name: entry.name)
            } label: {
              Text("Delete")
                .foregroundStyle(.stError)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(isPulling)
          } else {
            Button {
              setup.ollamaSetup.pullModel(entry.name)
            } label: {
              Text("Download")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(isPulling)
          }
        }
        .padding(.vertical, 2)

        if entry.id != catalog.last?.id {
          Divider()
        }
      }
    }
    .padding(.top, 4)
  }

  // MARK: - Helpers

  @discardableResult
  private func saveKey(key: String, keychainId: String) -> Bool {
    do {
      try keychainManager.store(key: keychainId, value: key)
      validationStatus = "Saved!"
      Task {
        try? await Task.sleep(for: .seconds(2))
        validationStatus = ""
      }
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "save", result: "success")
      return true
    } catch {
      aiPolishKeychainUILog.error(
        "Save key failed action=save keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      validationStatus = AIPolishKeychainFailureMessage.text(for: error, action: .save)
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "save", result: "failure")
      return false
    }
  }

  /// #1173: map a keychain id to the provider label used in API-key telemetry —
  /// the same `LLMProvider.rawValue` vocabulary as `api_key.validation_completed`,
  /// so both events group by the same provider. Never the key value.
  private func apiKeyProviderLabel(_ keychainId: String) -> String {
    if keychainId == KeychainManager.openAIKeyID { return LLMProvider.openAI.rawValue }
    if keychainId == KeychainManager.geminiKeyID { return LLMProvider.gemini.rawValue }
    return keychainId
  }

  /// Clears any "Failed: …" validation badge the moment the user resumes
  /// typing in either key field. Without this, a stale clear-failure from a
  /// prior attempt sits next to fresh input until the next save/clear runs.
  /// See #724.
  private func dismissStaleFailureStatus() {
    if validationStatus.hasPrefix("Failed") {
      validationStatus = ""
    }
  }

  @discardableResult
  private func clearKey(keychainId: String) -> Bool {
    do {
      try keychainManager.delete(key: keychainId)
      validationStatus = ""
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "remove", result: "success")
      return true
    } catch {
      aiPolishKeychainUILog.error(
        "Clear key failed action=clear keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      validationStatus = AIPolishKeychainFailureMessage.text(for: error, action: .clear)
      TelemetryService.shared.apiKeyChanged(
        provider: apiKeyProviderLabel(keychainId), action: "remove", result: "failure")
      return false
    }
  }

  @ViewBuilder
  private func ollamaStepIndicators(current: Int, currentLabel: String? = nil) -> some View {
    HStack(spacing: 12) {
      if current > 1 {
        Label("Installed", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.stHelper)
      }
      if current > 2 {
        Label("Running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.stHelper)
      }

      let stepLabels = ["Install Ollama", "Start Ollama", "Download a Model"]
      let label = currentLabel ?? stepLabels[current - 1]
      Label(label, systemImage: "\(current).circle.fill")
        .foregroundStyle(Color.stAccent)
        .font(.stSectionHeader)
    }
  }

  @ViewBuilder
  private func ollamaRefreshButton() -> some View {
    Button {
      Task {
        await setup.ollamaSetup.detectState()
        if case .ready = setup.ollamaSetup.setupState {
          await llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: settings)
        }
      }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(.borderless)
    .help("Re-check Ollama status")
    .accessibilityLabel("Re-check Ollama status")
  }

  // MARK: - Ollama Warm-up Indicator

  @ViewBuilder
  private var ollamaWarmupIndicator: some View {
    let currentModel = OllamaSetupService.canonicalModelName(settings.llmModel)
    switch setup.ollamaSetup.warmupState {
    case .warming(let model) where model == currentModel:
      ProgressView()
        .controlSize(.small)
        .help("Preparing model for faster responses...")
    case .warm(let model, let expires) where model == currentModel && Date() < expires:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.stSuccess)
        .help("Model is ready")
    case .failed(let model) where model == currentModel:
      Button {
        setup.ollamaSetup.warmUpModel(settings.llmModel)
      } label: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.stWarning)
      }
      .buttonStyle(.borderless)
      .help("Couldn't prepare model. Click to retry.")
      .accessibilityLabel("Retry preparing model")
    default:
      Button {
        guard !settings.llmModel.isEmpty else { return }
        setup.ollamaSetup.warmUpModel(settings.llmModel)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Prepare model")
      .accessibilityLabel("Prepare model")
    }
  }
}
