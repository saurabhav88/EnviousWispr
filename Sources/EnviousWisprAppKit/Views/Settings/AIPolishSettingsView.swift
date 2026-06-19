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
    settings.llmProvider != .none && settings.llmProvider != .appleIntelligence
  }

  private var ollamaShowsManageModels: Bool {
    switch setup.ollamaSetup.setupState {
    case .ready, .pullingModel, .runningNoModels: return true
    default: return false
    }
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // ── Section 1: LLM Provider ───────────────────────────────
      BrandedSection(
        header: "LLM Provider",
        content: {
          BrandedRow {
            Picker("LLM Provider", selection: $settings.llmProvider) {
              Text("Off").tag(LLMProvider.none)
              Text("OpenAI").tag(LLMProvider.openAI)
              Text("Google Gemini").tag(LLMProvider.gemini)
              Text("Local (Ollama)").tag(LLMProvider.ollama)
              Text("Apple Intelligence").tag(LLMProvider.appleIntelligence)
            }
          }

          if settings.llmProvider == .none {
            BrandedRow {
              Text("Turn on AI polish to automatically fix grammar, punctuation, and formatting.")
                .font(.stHelper)
                .foregroundStyle(Color.stTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          // Nested API key row — only for cloud providers
          if isCloudProvider {
            BrandedRow {
              apiKeyRow
            }
          }

          // Ollama wizard
          if settings.llmProvider == .ollama {
            BrandedRow {
              ollamaSetupContent
            }
          }

          // Apple Intelligence status
          if settings.llmProvider == .appleIntelligence {
            BrandedRow(showDivider: false) {
              appleIntelligenceStatus
            }
          }
        },
        footer: {
          if isCloudProvider {
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
        })

      // ── Section 3: Model ──────────────────────────────────────
      if showModelSection {
        BrandedSection(header: "Model") {
          BrandedRow(showDivider: false) {
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
        } footer: {
          FrozenPerRecordingFootnote()
        }
      }

      // ── Section 3.5: Why use <Provider> (cloud only) ─────────
      if isCloudProvider {
        BrandedSection(header: cloudProviderExplainerHeader) {
          BrandedRow(showDivider: false) {
            cloudProviderExplainer
          }
        }
      }

      // Manage Models for Ollama (always expanded)
      if settings.llmProvider == .ollama,
        ollamaShowsManageModels
      {
        BrandedSection(header: "Manage Models") {
          BrandedRow(showDivider: false) {
            ollamaModelCatalogView
          }
        }
      }

      // ── Section 4: Advanced ───────────────────────────────────
      if isReasoningModel {
        BrandedSection(header: "Advanced") {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 4) {
              Toggle("Deep reasoning", isOn: $settings.useExtendedThinking)
                .toggleStyle(BrandedToggleStyle())
              Text("Takes longer but handles complex formatting instructions better.")
                .font(.stHelper)
                .foregroundStyle(Color.stTextTertiary)
            }
          }
        } footer: {
          FrozenPerRecordingFootnote()
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
        .foregroundStyle(Color.stTextTertiary)
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
                provider: .openAI, settings: settings)
            }
          } else {
            guard saveKey(key: geminiKey, keychainId: KeychainManager.geminiKeyID) else { return }
            Task {
              await llmDiscovery.validateKeyAndDiscoverModels(
                provider: .gemini, settings: settings)
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
      .font(.stHelper)
      .foregroundStyle(Color.stTextTertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Validation Badge

  @ViewBuilder
  private var validationBadge: some View {
    if validationStatus.hasPrefix("Failed") {
      Text(validationStatus)
        .font(.caption)
        .foregroundStyle(.stError)
    } else {
      switch llmDiscovery.keyValidationState {
      case .idle:
        if !validationStatus.isEmpty {
          Text(validationStatus)
            .font(.caption)
            .foregroundStyle(validationStatus.contains("Saved") ? .stSuccess : .stError)
        }
      case .validating:
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("Validating…")
            .font(.stHelper)
            .foregroundStyle(Color.stTextTertiary)
        }
      case .valid:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.stSuccess)
          Text("Valid")
            .font(.caption)
            .foregroundStyle(.stSuccess)
        }
      case .invalid(let message):
        HStack(spacing: 4) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.stError)
          Text(message)
            .font(.caption)
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

  // MARK: - Cloud Provider Explainer (#617)

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
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Picking the right model. OpenAI sells several sizes inside each generation. For dictation cleanup, look for Mini in the name. Those are tuned for fast, light tasks and run roughly 3 to 10 times cheaper than the flagships. Nano is even smaller and faster. The unsuffixed flagships (GPT-5, GPT-4.1) and anything labeled Pro are overkill for this job."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Locked models? Those aren't blocked by EnviousWispr. Your OpenAI API key doesn't currently have access to them. OpenAI gates some models behind spend tier or organization verification."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

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
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Picking the right model. Gemini sells two sizes inside each generation. For dictation cleanup, look for Flash in the name. Those are tuned for fast, light tasks. Pro models are overkill: slightly smarter on hard reasoning, slower and pricier on a job that doesn't need it."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Locked models? Those aren't blocked by EnviousWispr. Your Gemini API key doesn't currently have access to them. Some Gemini models are gated by region, billing tier, or preview status."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

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
          .foregroundStyle(Color.stTextTertiary)
      }

    case .notInstalled:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 1)

        Text(
          "Ollama runs AI models privately on your Mac — no cloud, no API keys, completely free."
        )
        .font(.stHelper)
        .foregroundStyle(Color.stTextTertiary)

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
          .foregroundStyle(Color.stTextTertiary)
      }

    case .installedNotRunning:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 2)

        Text("Ollama is installed but isn't running yet.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextTertiary)

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
          .foregroundStyle(Color.stTextTertiary)
      }

    case .runningNoModels:
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 3)

        Text("Ollama needs a language model to polish your text.")
          .font(.stHelper)
          .foregroundStyle(Color.stTextTertiary)

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
          .foregroundStyle(Color.stTextTertiary)
      }

    case .pullingModel(let progress, let status):
      VStack(alignment: .leading, spacing: 8) {
        ollamaStepIndicators(current: 3, currentLabel: "Downloading...")

        ProgressView(value: progress)
          .progressViewStyle(.linear)

        HStack {
          Text(status)
            .font(.caption2)
            .foregroundStyle(Color.stTextTertiary)
            .lineLimit(1)
          Spacer()
          if progress > 0 {
            Text("\(Int(progress * 100))%")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(Color.stTextTertiary)
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
        .foregroundStyle(Color.stTextTertiary)

    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.stWarning)

        Text(message)
          .font(.stHelper)
          .foregroundStyle(Color.stTextTertiary)

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

  // MARK: - Apple Intelligence Status

  @ViewBuilder
  private var appleIntelligenceStatus: some View {
    Text("On-device model — no internet or API key required.")
      .font(.stHelper)
      .foregroundStyle(Color.stTextTertiary)

    // Status row
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
        .foregroundStyle(Color.stTextTertiary)
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
          .foregroundStyle(Color.stTextTertiary)
      }
    } else {
      Text("Not checked")
        .foregroundStyle(Color.stTextTertiary)
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
                .foregroundStyle(Color.stTextTertiary)
                .lineLimit(1)
              if let ms = gate.result.durationMs {
                Text("\(ms)ms")
                  .font(.caption2)
                  .foregroundStyle(Color.stTextTertiary)
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
          .foregroundStyle(Color.stTextTertiary)

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
          .font(.caption2)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.stError)
          .font(.caption2)
      case .skipped:
        Image(systemName: "minus.circle")
          .foregroundStyle(Color.stTextTertiary)
          .font(.caption2)
      case .timedOut:
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(.stWarning)
          .font(.caption2)
      case .unknown:
        Image(systemName: "questionmark.circle")
          .foregroundStyle(Color.stTextTertiary)
          .font(.caption2)
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
                .font(.caption)
              Text("(\(entry.qualityTier.label))")
                .font(.caption)
                .foregroundStyle(
                  entry.qualityTier == .best
                    ? Color.stAccent
                    : (entry.qualityTier == .medium ? Color.secondary : Color.stWarning))
            }
            Text("\(entry.parameterCount) · \(entry.downloadSize)")
              .font(.caption2)
              .foregroundStyle(Color.stTextTertiary)
          }

          Spacer()

          if setup.ollamaSetup.currentPullingModel == entry.name {
            // Active pull for THIS row: show progress + Cancel.
            HStack(spacing: 8) {
              Text("Downloading… \(Int(setup.ollamaSetup.pullProgress * 100))%")
                .font(.caption)
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
      return true
    } catch {
      aiPolishKeychainUILog.error(
        "Save key failed action=save keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      validationStatus = AIPolishKeychainFailureMessage.text(for: error, action: .save)
      return false
    }
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
      return true
    } catch {
      aiPolishKeychainUILog.error(
        "Clear key failed action=clear keyID=\(keychainId, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      validationStatus = AIPolishKeychainFailureMessage.text(for: error, action: .clear)
      return false
    }
  }

  @ViewBuilder
  private func ollamaStepIndicators(current: Int, currentLabel: String? = nil) -> some View {
    HStack(spacing: 12) {
      if current > 1 {
        Label("Installed", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.caption)
      }
      if current > 2 {
        Label("Running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
          .font(.caption)
      }

      let stepLabels = ["Install Ollama", "Start Ollama", "Download a Model"]
      let label = currentLabel ?? stepLabels[current - 1]
      Label(label, systemImage: "\(current).circle.fill")
        .foregroundStyle(Color.stAccent)
        .font(.caption.bold())
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
