import SwiftUI
import AppKit

/// LLM provider configuration, API keys, Ollama wizard, and prompt editing.
struct AIPolishSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var showOpenAIKey = false
    @State private var showGeminiKey = false
    @State private var validationStatus: String = ""
    @State private var showPromptEditor = false
    @State private var showManageModels = false

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("LLM Provider") {
                Picker("Provider", selection: $state.settings.llmProvider) {
                    Text("None").tag(LLMProvider.none)
                    Text("OpenAI").tag(LLMProvider.openAI)
                    Text("Google Gemini").tag(LLMProvider.gemini)
                    Text("Ollama (Local)").tag(LLMProvider.ollama)
                    Text("Apple Intelligence").tag(LLMProvider.appleIntelligence)
                }

                if appState.settings.llmProvider == .none {
                    Text("Enable an AI provider to automatically clean up grammar, punctuation, and formatting in your transcriptions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
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

                    if let selectedModel = appState.discoveredModels.first(where: { $0.id == appState.settings.llmModel }),
                       !selectedModel.isAvailable {
                        Text("This model requires a paid API plan.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if appState.settings.llmProvider == .appleIntelligence {
                        Text("Apple Intelligence uses an optimized built-in prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if appState.settings.llmProvider == .ollama &&
                              OllamaSetupService.isWeakModel(appState.settings.llmModel) {
                        Text("This model uses an optimized built-in prompt for best results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if appState.settings.llmProvider != .appleIntelligence {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("System Prompt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(appState.settings.customSystemPrompt.isEmpty
                                     ? "Using built-in default"
                                     : "Custom prompt active")
                                    .font(.caption2)
                                    .foregroundStyle(appState.settings.customSystemPrompt.isEmpty ? Color.secondary : Color.accentColor)
                            }
                            Spacer()
                            Button("Edit Prompt") {
                                showPromptEditor = true
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if appState.settings.llmProvider == .openAI {
                Section("Model Guide") {
                    VStack(alignment: .leading, spacing: 4) {
                        openAIModelGuideRow("GPT-4o Mini", detail: "Fast · Affordable · Great quality", badge: "Recommended", badgeColor: .green)
                        Divider()
                        openAIModelGuideRow("GPT-4.1 Mini", detail: "Fast · Affordable · Newer model", badge: "Also great", badgeColor: .blue)
                        Divider()
                        openAIModelGuideRow("GPT-4o / 4.1", detail: "Medium speed · Higher cost", badge: "Overkill", badgeColor: .orange)
                        Divider()
                        openAIModelGuideRow("GPT-3.5 Turbo", detail: "Fast · Cheapest · Lower quality", badge: "Budget", badgeColor: .secondary)
                    }

                    Text("Transcript polishing is straightforward — smaller models handle it well at a fraction of the cost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if appState.settings.llmProvider == .gemini {
                Section("Model Guide") {
                    VStack(alignment: .leading, spacing: 4) {
                        geminiModelGuideRow("Gemini 2.0 Flash", detail: "Fast · Affordable · Great quality", badge: "Recommended", badgeColor: .green)
                        Divider()
                        geminiModelGuideRow("Gemini 2.5 Flash", detail: "Fast · Newer · Strong reasoning", badge: "Also great", badgeColor: .blue)
                        Divider()
                        geminiModelGuideRow("Gemini 1.5 Flash", detail: "Fast · Older · Still capable", badge: "Budget", badgeColor: .secondary)
                        Divider()
                        geminiModelGuideRow("Gemini 2.5 Pro", detail: "Slower · Expensive · Best quality", badge: "Overkill", badgeColor: .orange)
                    }

                    Text("Transcript polishing is straightforward — Flash models handle it well at a fraction of the cost of Pro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if appState.settings.llmProvider == .gemini || appState.settings.llmProvider == .openAI {
                Section("Advanced") {
                    Toggle("Use extended thinking", isOn: $state.settings.useExtendedThinking)
                    Text("Lets the model reason through complex prompts before responding. Uses more tokens and increases latency. Best for custom prompts with multi-step instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if appState.settings.llmProvider == .openAI {
                Section("OpenAI API Key") {
                    HStack {
                        if showOpenAIKey {
                            TextField("sk-...", text: $openAIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-...", text: $openAIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showOpenAIKey.toggle()
                        } label: {
                            Image(systemName: showOpenAIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Button("Save Key") {
                            guard saveKey(key: openAIKey, keychainId: KeychainManager.openAIKeyID) else { return }
                            if appState.settings.llmProvider == .openAI {
                                Task { await appState.validateKeyAndDiscoverModels(provider: .openAI) }
                            }
                        }
                        .disabled(openAIKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: KeychainManager.openAIKeyID)
                            openAIKey = ""
                            if appState.settings.llmProvider == .openAI {
                                appState.discoveredModels = []
                                appState.keyValidationState = .idle
                            }
                        }

                        validationBadge
                    }

                    HStack(spacing: 4) {
                        Text("Get your API key at")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.caption)
                    }
                }
            }

            if appState.settings.llmProvider == .gemini {
                Section("Gemini API Key") {
                    HStack {
                        if showGeminiKey {
                            TextField("AI...", text: $geminiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("AI...", text: $geminiKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showGeminiKey.toggle()
                        } label: {
                            Image(systemName: showGeminiKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Button("Save Key") {
                            guard saveKey(key: geminiKey, keychainId: KeychainManager.geminiKeyID) else { return }
                            if appState.settings.llmProvider == .gemini {
                                Task { await appState.validateKeyAndDiscoverModels(provider: .gemini) }
                            }
                        }
                        .disabled(geminiKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: KeychainManager.geminiKeyID)
                            geminiKey = ""
                            if appState.settings.llmProvider == .gemini {
                                appState.discoveredModels = []
                                appState.keyValidationState = .idle
                            }
                        }

                        validationBadge
                    }

                    HStack(spacing: 4) {
                        Text("Get your API key at")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.caption)
                    }
                }
            }

            if appState.settings.llmProvider == .ollama {
                Section("Ollama") {
                    switch appState.ollamaSetup.setupState {
                    case .detecting:
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking Ollama installation...")
                                .foregroundStyle(.secondary)
                        }

                    case .notInstalled:
                        VStack(alignment: .leading, spacing: 8) {
                            ollamaStepIndicators(current: 1)

                            Text("Ollama runs AI models privately on your Mac — no cloud, no API keys, completely free.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

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
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                    case .installedNotRunning:
                        VStack(alignment: .leading, spacing: 8) {
                            ollamaStepIndicators(current: 2)

                            Text("Ollama is installed but isn't running yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Start Ollama") {
                                    appState.ollamaSetup.startServer()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                ollamaRefreshButton()
                            }

                            Text("Or run `ollama serve` in Terminal.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                    case .runningNoModels:
                        VStack(alignment: .leading, spacing: 8) {
                            ollamaStepIndicators(current: 3)

                            Text("Ollama needs a language model to polish your text.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Download \(appState.settings.ollamaModel)") {
                                    appState.ollamaSetup.pullModel(appState.settings.ollamaModel)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                ollamaRefreshButton()
                            }

                            Text("About 2 GB download. Runs entirely on your Mac.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                    case .pullingModel(let progress, let status):
                        VStack(alignment: .leading, spacing: 8) {
                            ollamaStepIndicators(current: 3, currentLabel: "Downloading...")

                            ProgressView(value: progress)
                                .progressViewStyle(.linear)

                            HStack {
                                Text(status)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Spacer()
                                if progress > 0 {
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        DisclosureGroup("Manage Models", isExpanded: $showManageModels) {
                            ollamaModelCatalogView
                        }

                    case .error(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)

                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)

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
            }

            if appState.settings.llmProvider == .appleIntelligence {
                Section("Apple Intelligence") {
                    Text("On-device model — no internet or API key required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                                Text("Not checked").foregroundStyle(.secondary)
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
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPromptEditor) {
            PromptEditorView()
                .environment(appState)
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
            // Always clear models and reset model selection to avoid stale state from previous provider
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
                Text("Validating...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private func openAIModelGuideRow(_ name: String, detail: String, badge: String, badgeColor: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(badge)
                .font(.caption2)
                .foregroundStyle(badgeColor)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func geminiModelGuideRow(_ name: String, detail: String, badge: String, badgeColor: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(badge)
                .font(.caption2)
                .foregroundStyle(badgeColor)
        }
        .padding(.vertical, 2)
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
