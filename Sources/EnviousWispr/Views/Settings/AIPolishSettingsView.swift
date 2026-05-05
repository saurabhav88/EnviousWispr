import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import SwiftUI

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
  @Environment(AppState.self) private var appState

  @State private var openAIKey: String = ""
  @State private var geminiKey: String = ""
  @State private var validationStatus: String = ""

  private var isCloudProvider: Bool {
    appState.settings.llmProvider == .openAI || appState.settings.llmProvider == .gemini
  }

  private var isReasoningModel: Bool {
    appState.settings.llmProvider.supportsReasoning(model: appState.settings.llmModel)
  }

  private var showModelSection: Bool {
    appState.settings.llmProvider != .none && appState.settings.llmProvider != .appleIntelligence
  }

  private var ollamaShowsManageModels: Bool {
    switch appState.setup.ollamaSetup.setupState {
    case .ready, .pullingModel, .runningNoModels: return true
    default: return false
    }
  }

  var body: some View {
    @Bindable var state = appState

    SettingsContentView {
      // ── Section 1: LLM Provider ───────────────────────────────
      BrandedSection(
        header: "LLM Provider",
        content: {
          BrandedRow {
            Picker("LLM Provider", selection: $state.settings.llmProvider) {
              Text("Off").tag(LLMProvider.none)
              Text("OpenAI").tag(LLMProvider.openAI)
              Text("Google Gemini").tag(LLMProvider.gemini)
              Text("Local (Ollama)").tag(LLMProvider.ollama)
              Text("Apple Intelligence").tag(LLMProvider.appleIntelligence)
            }
          }

          if appState.settings.llmProvider == .none {
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
          if appState.settings.llmProvider == .ollama {
            BrandedRow {
              ollamaSetupContent
            }
          }

          // Apple Intelligence status
          if appState.settings.llmProvider == .appleIntelligence {
            BrandedRow(showDivider: false) {
              appleIntelligenceStatus
            }
          }
        },
        footer: {
          if isCloudProvider {
            if appState.settings.llmProvider == .openAI {
              Link(
                "Get your free API key at platform.openai.com",
                destination: URL(string: "https://platform.openai.com/api-keys")!
              )
              .font(.stHelper)
            } else if appState.settings.llmProvider == .gemini {
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
              Picker("Model", selection: $state.settings.llmModel) {
                if appState.llmDiscovery.discoveredModels.isEmpty
                  && !appState.llmDiscovery.isDiscoveringModels
                {
                  Text(
                    appState.settings.llmModel.isEmpty
                      ? (appState.settings.llmProvider == .ollama
                        ? "No models found"
                        : "Save API key to discover models")
                      : appState.settings.llmModel
                  )
                  .tag(appState.settings.llmModel)
                }

                modelPickerSections
              }

              if appState.settings.llmProvider == .ollama {
                ollamaWarmupIndicator
              } else if appState.llmDiscovery.isDiscoveringModels {
                ProgressView()
                  .controlSize(.small)
              } else {
                Button {
                  Task {
                    await appState.llmDiscovery.validateKeyAndDiscoverModels(
                      provider: appState.settings.llmProvider, settings: appState.settings)
                  }
                } label: {
                  Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh available models")
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
      if appState.settings.llmProvider == .ollama,
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
            @Bindable var state2 = appState
            VStack(alignment: .leading, spacing: 4) {
              Toggle("Deep reasoning", isOn: $state2.settings.useExtendedThinking)
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
      openAIKey = (try? appState.keychainManager.retrieve(key: KeychainManager.openAIKeyID)) ?? ""
      geminiKey = (try? appState.keychainManager.retrieve(key: KeychainManager.geminiKeyID)) ?? ""
      if appState.settings.llmProvider == .ollama {
        appState.llmDiscovery.loadCachedModels(for: .ollama)
        Task {
          await appState.setup.ollamaSetup.detectState()
          if case .ready = appState.setup.ollamaSetup.setupState {
            await appState.llmDiscovery.validateKeyAndDiscoverModels(
              provider: .ollama, settings: appState.settings)
          }
        }
      } else if appState.settings.llmProvider == .appleIntelligence {
        Task { await appState.aiAvailability.checkAvailability(trigger: "settings_open") }
      } else if appState.settings.llmProvider != .none {
        appState.llmDiscovery.loadCachedModels(for: appState.settings.llmProvider)
      }
    }
    .onChange(of: appState.settings.llmProvider) { _, newProvider in
      appState.llmDiscovery.reset()
      // Model canonicalization handled by SettingsManager.llmProvider didSet.
      // Discovery will refine the model async if needed.

      // Clean up Ollama state when switching away
      if newProvider != .ollama {
        appState.setup.ollamaSetup.cancelPull()
        appState.setup.ollamaSetup.resetWarmup()
      }

      switch newProvider {
      case .none:
        break
      case .ollama:
        // detectState() will set setupState, which triggers the onChange handler
        // for discovery + warm-up. Don't duplicate that work here.
        Task { await appState.setup.ollamaSetup.detectState() }
      case .appleIntelligence:
        Task { await appState.aiAvailability.checkAvailability(trigger: "provider_switch") }
      default:
        appState.llmDiscovery.loadCachedModels(for: newProvider)
        Task {
          await appState.llmDiscovery.validateKeyAndDiscoverModels(
            provider: newProvider, settings: appState.settings)
        }
      }
    }
    .onChange(of: appState.setup.ollamaSetup.setupState) { _, newState in
      if case .ready = newState, appState.settings.llmProvider == .ollama {
        Task {
          await appState.llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: appState.settings)
        }
        // Warm up the selected model when Ollama becomes ready
        if !appState.settings.llmModel.isEmpty {
          appState.setup.ollamaSetup.warmUpModel(appState.settings.llmModel)
        }
      } else if appState.settings.llmProvider == .ollama {
        // Reset warmup when Ollama leaves .ready (server died, etc.)
        appState.setup.ollamaSetup.resetWarmup()
      }
    }
    .onChange(of: appState.settings.llmModel) { _, newModel in
      // Warm up when user switches Ollama model
      if appState.settings.llmProvider == .ollama,
        case .ready = appState.setup.ollamaSetup.setupState,
        !newModel.isEmpty
      {
        appState.setup.ollamaSetup.warmUpModel(newModel)
      }
    }
  }

  // MARK: - API Key Row

  @ViewBuilder
  private var apiKeyRow: some View {
    let isOpenAI = appState.settings.llmProvider == .openAI
    VStack(alignment: .leading, spacing: 6) {
      Text(isOpenAI ? "OpenAI API Key" : "Google Gemini API Key")
        .font(.stHelper)
        .foregroundStyle(Color.stTextTertiary)
      HStack(spacing: 8) {
        if isOpenAI {
          SecureField("sk-proj-…", text: $openAIKey)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("OpenAI API Key")
        } else {
          SecureField("AI…", text: $geminiKey)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Google Gemini API Key")
        }

        validationBadge

        Button("Save") {
          if isOpenAI {
            guard saveKey(key: openAIKey, keychainId: KeychainManager.openAIKeyID) else { return }
            Task {
              await appState.llmDiscovery.validateKeyAndDiscoverModels(
                provider: .openAI, settings: appState.settings)
            }
          } else {
            guard saveKey(key: geminiKey, keychainId: KeychainManager.geminiKeyID) else { return }
            Task {
              await appState.llmDiscovery.validateKeyAndDiscoverModels(
                provider: .gemini, settings: appState.settings)
            }
          }
        }
        .disabled(isOpenAI ? openAIKey.isEmpty : geminiKey.isEmpty)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

        Button("Clear") {
          if isOpenAI {
            clearKey(keychainId: KeychainManager.openAIKeyID)
            openAIKey = ""
          } else {
            clearKey(keychainId: KeychainManager.geminiKeyID)
            geminiKey = ""
          }
          appState.llmDiscovery.reset()
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
    switch appState.llmDiscovery.keyValidationState {
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

  // MARK: - Model Picker Sections (#617)

  /// Three labeled groups of discovered models. Empty groups are suppressed.
  /// Locked rows are disabled so a user can't pick something the API will reject.
  @ViewBuilder
  private var modelPickerSections: some View {
    let discovered = appState.llmDiscovery.discoveredModels
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
    appState.settings.llmProvider == .openAI ? "Why use OpenAI" : "Why use Gemini"
  }

  @ViewBuilder
  private var cloudProviderExplainer: some View {
    if appState.settings.llmProvider == .openAI {
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
    } else if appState.settings.llmProvider == .gemini {
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
    switch appState.setup.ollamaSetup.setupState {
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
            appState.setup.ollamaSetup.startServer()
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
          Button("Download \(appState.settings.ollamaModel)") {
            appState.setup.ollamaSetup.pullModel(appState.settings.ollamaModel)
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
            appState.setup.ollamaSetup.cancelPull()
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
            await appState.setup.ollamaSetup.detectState()
            if case .ready = appState.setup.ollamaSetup.setupState {
              await appState.llmDiscovery.validateKeyAndDiscoverModels(
                provider: .ollama, settings: appState.settings)
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
        appState.aiAvailability.debouncedCheck()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(appState.aiAvailability.isChecking)
      .help("Check Apple Intelligence availability")
    }

    // "Why?" detail text
    if let report = appState.aiAvailability.latestReport,
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
      if appState.settings.isDebugModeEnabled, let report = appState.aiAvailability.latestReport {
        aiDebugSection(report: report)
      }
    #endif
  }

  @ViewBuilder
  private var aiStatusLabel: some View {
    if appState.aiAvailability.isChecking {
      ProgressView().controlSize(.small)
    } else if let report = appState.aiAvailability.latestReport {
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
            appState.aiAvailability.copyDiagnosticsToClipboard()
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
    let catalog = appState.setup.ollamaSetup.dynamicCatalog
    let isPulling: Bool = {
      if case .pullingModel = appState.setup.ollamaSetup.setupState { return true }
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

          if appState.setup.ollamaSetup.currentPullingModel == entry.name {
            // Active pull for THIS row: show progress + Cancel.
            HStack(spacing: 8) {
              Text("Downloading… \(Int(appState.setup.ollamaSetup.pullProgress * 100))%")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
              Button {
                appState.setup.ollamaSetup.cancelPull()
              } label: {
                Text("Cancel")
                  .foregroundStyle(.stError)
              }
              .controlSize(.small)
              .buttonStyle(.borderless)
            }
          } else if entry.isDownloaded {
            Button {
              appState.setup.ollamaSetup.deleteModel(name: entry.name)
            } label: {
              Text("Delete")
                .foregroundStyle(.stError)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(isPulling)
          } else {
            Button {
              appState.setup.ollamaSetup.pullModel(entry.name)
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
      try appState.keychainManager.store(key: keychainId, value: key)
      validationStatus = "Saved!"
      Task {
        try? await Task.sleep(for: .seconds(2))
        validationStatus = ""
      }
      return true
    } catch {
      validationStatus = "Failed: \(error.localizedDescription)"
      return false
    }
  }

  private func clearKey(keychainId: String) {
    try? appState.keychainManager.delete(key: keychainId)
    validationStatus = ""
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
        await appState.setup.ollamaSetup.detectState()
        if case .ready = appState.setup.ollamaSetup.setupState {
          await appState.llmDiscovery.validateKeyAndDiscoverModels(
            provider: .ollama, settings: appState.settings)
        }
      }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(.borderless)
    .help("Re-check Ollama status")
  }

  // MARK: - Ollama Warm-up Indicator

  @ViewBuilder
  private var ollamaWarmupIndicator: some View {
    let currentModel = OllamaSetupService.canonicalModelName(appState.settings.llmModel)
    switch appState.setup.ollamaSetup.warmupState {
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
        appState.setup.ollamaSetup.warmUpModel(appState.settings.llmModel)
      } label: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.stWarning)
      }
      .buttonStyle(.borderless)
      .help("Couldn't prepare model. Click to retry.")
    default:
      Button {
        guard !appState.settings.llmModel.isEmpty else { return }
        appState.setup.ollamaSetup.warmUpModel(appState.settings.llmModel)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Prepare model")
    }
  }
}
