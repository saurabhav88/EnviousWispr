import SwiftUI
import EnviousWisprCore
import EnviousWisprLLM
import AppKit

/// LLM provider configuration, API keys, Ollama wizard, and prompt editing.
struct AIPolishSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var validationStatus: String = ""
    @State private var showManageModels = false

    private var isCloudProvider: Bool {
        appState.settings.llmProvider == .openAI || appState.settings.llmProvider == .gemini
    }

    private var showModelSection: Bool {
        appState.settings.llmProvider != .none && appState.settings.llmProvider != .appleIntelligence
    }

    private var showWritingStyleSection: Bool {
        appState.settings.llmProvider != .none
    }

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            // ── Section 1: Writing Style ──────────────────────────────
            if showWritingStyleSection {
                BrandedSection(header: "Writing Style") {
                    BrandedRow {
                        writingStylePresetCards
                    }
                    BrandedRow(showDivider: false) {
                        Text("Controls how your dictation is cleaned up and formatted.")
                            .font(.stHelper)
                            .foregroundStyle(Color.stTextTertiary)
                    }
                }
            }

            // ── Section 2: LLM Provider ───────────────────────────────
            BrandedSection(header: "LLM Provider", content: {
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
            }, footer: {
                if isCloudProvider {
                    if appState.settings.llmProvider == .openAI {
                        Link("Get your free API key at platform.openai.com",
                             destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.stHelper)
                    } else if appState.settings.llmProvider == .gemini {
                        Link("Get your free API key at aistudio.google.com",
                             destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.stHelper)
                    }
                }
            })

            // ── Section 3: Model ──────────────────────────────────────
            if showModelSection {
                BrandedSection(header: "Model") {
                    BrandedRow {
                        HStack {
                            Picker("Model", selection: $state.settings.llmModel) {
                                if appState.discoveredModels.isEmpty && !appState.isDiscoveringModels {
                                    Text(appState.settings.llmModel.isEmpty
                                         ? (appState.settings.llmProvider == .ollama
                                            ? "No models found"
                                            : "Save API key to discover models")
                                         : appState.settings.llmModel)
                                        .tag(appState.settings.llmModel)
                                }

                                ForEach(appState.discoveredModels) { model in
                                    HStack {
                                        Text(model.displayName)
                                        if !model.isAvailable {
                                            Image(systemName: "lock.fill")
                                                .font(.caption2)
                                        }
                                    }
                                    .tag(model.id)
                                }
                            }

                            if appState.isDiscoveringModels {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    Task { await appState.validateKeyAndDiscoverModels(provider: appState.settings.llmProvider) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Refresh available models")
                            }
                        }
                    }

                    if let selectedModel = appState.discoveredModels.first(where: { $0.id == appState.settings.llmModel }),
                       !selectedModel.isAvailable {
                        BrandedRow {
                            Text("This model requires a paid API plan.")
                                .font(.stHelper)
                                .foregroundStyle(.orange)
                        }
                    }

                    // Model recommendation cards
                    BrandedRow(showDivider: false) {
                        modelRecommendationCards
                    }
                }
            }

            // Manage Models for Ollama (when ready)
            if appState.settings.llmProvider == .ollama,
               case .ready = appState.ollamaSetup.setupState {
                BrandedSection(header: "Manage Models") {
                    BrandedRow(showDivider: false) {
                        DisclosureGroup("Download / Remove Models", isExpanded: $showManageModels) {
                            ollamaModelCatalogView
                        }
                    }
                }
            }

            // ── Section 4: Advanced ───────────────────────────────────
            if isCloudProvider {
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
                }
            }
        }
        .onAppear {
            openAIKey = (try? appState.keychainManager.retrieve(key: KeychainManager.openAIKeyID)) ?? ""
            geminiKey = (try? appState.keychainManager.retrieve(key: KeychainManager.geminiKeyID)) ?? ""
            if appState.settings.llmProvider == .ollama {
                appState.loadCachedModels(for: .ollama)
                Task {
                    await appState.ollamaSetup.detectState()
                    if case .ready = appState.ollamaSetup.setupState {
                        await appState.validateKeyAndDiscoverModels(provider: .ollama)
                    }
                }
            } else if appState.settings.llmProvider == .appleIntelligence {
                Task { await appState.validateKeyAndDiscoverModels(provider: appState.settings.llmProvider) }
            } else if appState.settings.llmProvider != .none {
                appState.loadCachedModels(for: appState.settings.llmProvider)
            }
        }
        .onChange(of: appState.settings.llmProvider) { _, newProvider in
            appState.discoveredModels = []
            appState.keyValidationState = .idle
            appState.settings.llmModel = ""

            switch newProvider {
            case .none:
                appState.ollamaSetup.cancelPull()
            case .ollama:
                Task {
                    await appState.ollamaSetup.detectState()
                    if case .ready = appState.ollamaSetup.setupState {
                        await appState.validateKeyAndDiscoverModels(provider: .ollama)
                    }
                }
            case .appleIntelligence:
                appState.ollamaSetup.cancelPull()
                Task { await appState.validateKeyAndDiscoverModels(provider: newProvider) }
            default:
                appState.ollamaSetup.cancelPull()
                appState.loadCachedModels(for: newProvider)
                Task { await appState.validateKeyAndDiscoverModels(provider: newProvider) }
            }
        }
        .onChange(of: appState.ollamaSetup.setupState) { _, newState in
            if case .ready = newState, appState.settings.llmProvider == .ollama {
                Task { await appState.validateKeyAndDiscoverModels(provider: .ollama) }
            }
        }
        .onChange(of: showManageModels) { _, isOpen in
            if isOpen {
                Task { await appState.ollamaSetup.refreshDownloadedModels() }
            }
        }
    }

    // MARK: - Writing Style Preset Cards

    @ViewBuilder
    private var writingStylePresetCards: some View {
        @Bindable var state = appState
        HStack(spacing: 8) {
            writingStyleCard(preset: .formal, emoji: "👔", name: "Formal", desc: "Professional tone, proper grammar", binding: $state.settings.writingStylePreset)
            writingStyleCard(preset: .standard, emoji: "✨", name: "Standard", desc: "Clean up grammar and punctuation", binding: $state.settings.writingStylePreset)
            writingStyleCard(preset: .friendly, emoji: "💬", name: "Friendly", desc: "Casual, conversational tone", binding: $state.settings.writingStylePreset)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func writingStyleCard(
        preset: WritingStylePreset,
        emoji: String,
        name: String,
        desc: String,
        binding: Binding<WritingStylePreset>
    ) -> some View {
        let isSelected = binding.wrappedValue == preset
        Button {
            binding.wrappedValue = preset
        } label: {
            VStack(spacing: 5) {
                Text(emoji)
                    .font(.title2)
                Text(name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? Color.stAccent : .primary)
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.stAccent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected ? Color.stAccent : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "selected" : "")
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
                } else {
                    SecureField("AI…", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                }

                validationBadge

                Button("Save") {
                    if isOpenAI {
                        guard saveKey(key: openAIKey, keychainId: KeychainManager.openAIKeyID) else { return }
                        Task { await appState.validateKeyAndDiscoverModels(provider: .openAI) }
                    } else {
                        guard saveKey(key: geminiKey, keychainId: KeychainManager.geminiKeyID) else { return }
                        Task { await appState.validateKeyAndDiscoverModels(provider: .gemini) }
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
                    appState.discoveredModels = []
                    appState.keyValidationState = .idle
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Validation Badge

    @ViewBuilder
    private var validationBadge: some View {
        switch appState.keyValidationState {
        case .idle:
            if !validationStatus.isEmpty {
                Text(validationStatus)
                    .font(.caption)
                    .foregroundStyle(validationStatus.contains("Saved") ? .green : .red)
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
                    .foregroundStyle(.green)
                Text("Valid")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .invalid(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Model Recommendation Cards

    @ViewBuilder
    private var modelRecommendationCards: some View {
        let cards = modelCards(for: appState.settings.llmProvider)
        if !cards.isEmpty {
            VStack(spacing: 0) {
                ForEach(cards.indices, id: \.self) { index in
                    let card = cards[index]
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(card.iconBg)
                                .frame(width: 28, height: 28)
                            Text(card.icon)
                                .font(.system(size: 13))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.name)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(card.desc)
                                .font(.caption2)
                                .foregroundStyle(Color.stTextTertiary)
                        }

                        Spacer()

                        Text(card.badge)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(card.badgeBg)
                            )
                            .overlay(
                                Capsule().strokeBorder(card.badgeBorder, lineWidth: 1)
                            )
                            .foregroundStyle(card.badgeFg)
                    }
                    .padding(.vertical, 6)

                    if index < cards.count - 1 {
                        Divider()
                    }
                }
            }

            Text("Transcript cleanup is straightforward — smaller models handle it well at a fraction of the cost.")
                .font(.stHelper)
                .foregroundStyle(Color.stTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct ModelCardInfo {
        let name: String
        let desc: String
        let badge: String
        let icon: String
        let iconBg: Color
        let badgeBg: Color
        let badgeBorder: Color
        let badgeFg: Color
    }

    private func modelCards(for provider: LLMProvider) -> [ModelCardInfo] {
        switch provider {
        case .openAI:
            return [
                ModelCardInfo(name: "GPT-4o Mini",    desc: "Fast · Affordable · Great quality", badge: "Best value", icon: "⚡", iconBg: Color.green.opacity(0.10),   badgeBg: Color.green.opacity(0.12),  badgeBorder: Color.green.opacity(0.22),  badgeFg: Color(hex: "007a4d")),
                ModelCardInfo(name: "GPT-4.1 Mini",   desc: "Fast · Affordable · Newer",         badge: "Also great", icon: "✦", iconBg: Color.cyan.opacity(0.10),    badgeBg: Color.cyan.opacity(0.12),   badgeBorder: Color.cyan.opacity(0.22),   badgeFg: Color(hex: "006f7a")),
                ModelCardInfo(name: "GPT-4o / 4.1",   desc: "Slower · Higher cost",              badge: "Premium",    icon: "◈", iconBg: Color.primary.opacity(0.05), badgeBg: Color.primary.opacity(0.05), badgeBorder: Color.primary.opacity(0.09), badgeFg: Color.secondary),
                ModelCardInfo(name: "GPT-3.5 Turbo",  desc: "Cheapest · Lower quality",          badge: "Budget",     icon: "◇", iconBg: Color.primary.opacity(0.05), badgeBg: Color.primary.opacity(0.05), badgeBorder: Color.primary.opacity(0.09), badgeFg: Color.secondary),
            ]
        case .gemini:
            return [
                ModelCardInfo(name: "Gemini 2.0 Flash", desc: "Fast · Affordable · Great quality", badge: "Best value", icon: "⚡", iconBg: Color.green.opacity(0.10),   badgeBg: Color.green.opacity(0.12),  badgeBorder: Color.green.opacity(0.22),  badgeFg: Color(hex: "007a4d")),
                ModelCardInfo(name: "Gemini 1.5 Flash", desc: "Fast · Stable · Proven",            badge: "Also great", icon: "✦", iconBg: Color.cyan.opacity(0.10),    badgeBg: Color.cyan.opacity(0.12),   badgeBorder: Color.cyan.opacity(0.22),   badgeFg: Color(hex: "006f7a")),
                ModelCardInfo(name: "Gemini 2.0 Pro",   desc: "Slower · Higher cost",              badge: "Premium",    icon: "◈", iconBg: Color.primary.opacity(0.05), badgeBg: Color.primary.opacity(0.05), badgeBorder: Color.primary.opacity(0.09), badgeFg: Color.secondary),
            ]
        case .ollama:
            return [
                ModelCardInfo(name: "Llama 3.2",  desc: "Fast · Private · No internet needed",  badge: "Recommended", icon: "⚡", iconBg: Color.green.opacity(0.10),   badgeBg: Color.green.opacity(0.12),  badgeBorder: Color.green.opacity(0.22),  badgeFg: Color(hex: "007a4d")),
                ModelCardInfo(name: "Llama 3.1",  desc: "Stable · Well tested",                 badge: "Also great",  icon: "✦", iconBg: Color.cyan.opacity(0.10),    badgeBg: Color.cyan.opacity(0.12),   badgeBorder: Color.cyan.opacity(0.22),   badgeFg: Color(hex: "006f7a")),
                ModelCardInfo(name: "Phi-3 Mini", desc: "Smallest · Fastest on older Macs",     badge: "Lightweight", icon: "◇", iconBg: Color.primary.opacity(0.05), badgeBg: Color.primary.opacity(0.05), badgeBorder: Color.primary.opacity(0.09), badgeFg: Color.secondary),
            ]
        default:
            return []
        }
    }

    // MARK: - Ollama Setup

    @ViewBuilder
    private var ollamaSetupContent: some View {
        switch appState.ollamaSetup.setupState {
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

                Text("Ollama runs AI models privately on your Mac — no cloud, no API keys, completely free.")
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
                        appState.ollamaSetup.startServer()
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
                        appState.ollamaSetup.pullModel(appState.settings.ollamaModel)
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
                        appState.ollamaSetup.cancelPull()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }

        case .ready:
            HStack {
                Text("Status:")
                Spacer()
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                ollamaRefreshButton()
            }

            Text("You're all set! Select a model above.")
                .font(.stHelper)
                .foregroundStyle(Color.stTextTertiary)

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.stHelper)
                    .foregroundStyle(Color.stTextTertiary)

                Button("Try Again") {
                    Task {
                        await appState.ollamaSetup.detectState()
                        if case .ready = appState.ollamaSetup.setupState {
                            await appState.validateKeyAndDiscoverModels(provider: .ollama)
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

        if #available(macOS 26.0, *) {
            HStack {
                Text("Status:")
                Spacer()
                switch appState.keyValidationState {
                case .valid:
                    Label("Available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .invalid(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                case .validating:
                    ProgressView().controlSize(.small)
                case .idle:
                    Text("Not checked").foregroundStyle(Color.stTextTertiary)
                }

                Button {
                    Task { await appState.validateKeyAndDiscoverModels(provider: .appleIntelligence) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check Apple Intelligence availability")
            }
        } else {
            Label("Requires macOS 26 or later.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.stHelper)
        }
    }

    // MARK: - Ollama Model Catalog

    @ViewBuilder
    private var ollamaModelCatalogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(OllamaSetupService.modelCatalog) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(entry.displayName)
                                .font(.caption)
                            Text("(\(entry.qualityTier.label))")
                                .font(.caption)
                                .foregroundStyle(entry.qualityTier == .best ? Color.accentColor : (entry.qualityTier == .medium ? Color.secondary : Color.orange))
                        }
                        Text("\(entry.parameterCount) · \(entry.downloadSize)")
                            .font(.caption2)
                            .foregroundStyle(Color.stTextTertiary)
                    }

                    Spacer()

                    if appState.ollamaSetup.downloadedModelNames.contains(entry.name) {
                        Button {
                            appState.ollamaSetup.deleteModel(name: entry.name)
                        } label: {
                            Text("Delete")
                                .foregroundStyle(.red)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    } else {
                        Button {
                            appState.ollamaSetup.pullModel(entry.name)
                        } label: {
                            Text("Download")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)

                if entry.id != OllamaSetupService.modelCatalog.last?.id {
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
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            if current > 2 {
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            let stepLabels = ["Install Ollama", "Start Ollama", "Download a Model"]
            let label = currentLabel ?? stepLabels[current - 1]
            Label(label, systemImage: "\(current).circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.caption.bold())
        }
    }

    @ViewBuilder
    private func ollamaRefreshButton() -> some View {
        Button {
            Task {
                await appState.ollamaSetup.detectState()
                if case .ready = appState.ollamaSetup.setupState {
                    await appState.validateKeyAndDiscoverModels(provider: .ollama)
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Re-check Ollama status")
    }
}
