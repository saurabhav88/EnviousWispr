import SwiftUI

/// App settings view.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            LLMSettingsView()
                .tabItem {
                    Label("AI Polish", systemImage: "sparkles")
                }

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
        }
        .frame(width: 520, height: 480)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("ASR Backend") {
                Picker("Backend", selection: $state.selectedBackend) {
                    Text("Parakeet v3 (Primary)").tag(ASRBackendType.parakeet)
                    Text("WhisperKit (Fallback)").tag(ASRBackendType.whisperKit)
                }
                .pickerStyle(.segmented)

                if appState.selectedBackend == .parakeet {
                    Text("Fast English transcription with built-in punctuation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Broader language support. No built-in punctuation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.selectedBackend == .whisperKit {
                    Picker("Model Quality", selection: $state.whisperKitModel) {
                        Text("Base (Fast, Lower Quality)").tag("base")
                        Text("Small (Balanced)").tag("small")
                        Text("Large v3 (Best Quality)").tag("large-v3")
                    }
                    Text("Larger models produce better transcription but require more download time and memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recording") {
                Picker("Mode", selection: $state.recordingMode) {
                    Text("Push to Talk").tag(RecordingMode.pushToTalk)
                    Text("Toggle").tag(RecordingMode.toggle)
                }
            }

            Section("Voice Activity Detection") {
                Toggle("Auto-stop on silence", isOn: $state.vadAutoStop)

                if appState.vadAutoStop {
                    HStack {
                        Text("Silence timeout")
                        Slider(value: $state.vadSilenceTimeout, in: 0.5...3.0, step: 0.25)
                        Text(String(format: "%.1fs", appState.vadSilenceTimeout))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 30)
                    }

                    Text("Recording stops automatically after this duration of silence following speech.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Auto-copy to clipboard", isOn: $state.autoCopyToClipboard)
            }

            Section("Performance") {
                if appState.benchmark.isRunning {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(appState.benchmark.progress)
                            .font(.caption)
                    }
                } else {
                    Button("Run Benchmark") {
                        Task { await appState.benchmark.run(using: appState.asrManager) }
                    }
                }

                if !appState.benchmark.results.isEmpty {
                    ForEach(appState.benchmark.results) { result in
                        HStack {
                            Text(result.label)
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2fs", result.processingTime))
                                .font(.caption)
                                .monospacedDigit()
                            Text(String(format: "%.0fx RT", result.rtf))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Global Hotkey") {
                Toggle("Enable global hotkey", isOn: $state.hotkeyEnabled)

                if appState.hotkeyEnabled {
                    HStack {
                        Text("Current hotkey:")
                        Spacer()
                        Text(appState.hotkeyService.hotkeyDescription)
                            .font(.system(.body, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    if appState.recordingMode == .toggle {
                        Text("Press ⌃Space to toggle recording on/off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Hold ⌥Option to record, release to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !appState.permissions.hasAccessibilityPermission {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Accessibility permission required for global hotkey.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Enable") {
                            appState.permissions.promptAccessibilityPermission()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Hotkey Reference") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Toggle mode:")
                            .font(.caption)
                        Spacer()
                        Text("⌃Space")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("Push-to-talk:")
                            .font(.caption)
                        Spacer()
                        Text("Hold ⌥Option")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("Open window:")
                            .font(.caption)
                        Spacer()
                        Text("⌘O (from menu bar)")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("Settings:")
                            .font(.caption)
                        Spacer()
                        Text("⌘, (from menu bar)")
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var showOpenAIKey = false
    @State private var showGeminiKey = false
    @State private var validationStatus: String = ""

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("LLM Provider") {
                Picker("Provider", selection: $state.llmProvider) {
                    Text("None").tag(LLMProvider.none)
                    Text("OpenAI").tag(LLMProvider.openAI)
                    Text("Google Gemini").tag(LLMProvider.gemini)
                }

                if appState.llmProvider != .none {
                    HStack {
                        Picker("Model", selection: $state.llmModel) {
                            if appState.discoveredModels.isEmpty && !appState.isDiscoveringModels {
                                Text(appState.llmModel.isEmpty ? "Save API key to discover models" : appState.llmModel)
                                    .tag(appState.llmModel)
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
                        } else if appState.llmProvider != .none {
                            Button {
                                Task { await appState.validateKeyAndDiscoverModels(provider: appState.llmProvider) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh available models")
                        }
                    }

                    if let selectedModel = appState.discoveredModels.first(where: { $0.id == appState.llmModel }),
                       !selectedModel.isAvailable {
                        Text("This model requires a paid API plan.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if appState.llmProvider == .openAI || appState.llmProvider == .none {
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
                            saveKey(key: openAIKey, keychainId: "openai-api-key")
                            if appState.llmProvider == .openAI {
                                Task { await appState.validateKeyAndDiscoverModels(provider: .openAI) }
                            }
                        }
                        .disabled(openAIKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: "openai-api-key")
                            openAIKey = ""
                            if appState.llmProvider == .openAI {
                                appState.discoveredModels = []
                                appState.keyValidationState = .idle
                            }
                        }

                        validationBadge
                    }
                }
            }

            if appState.llmProvider == .gemini || appState.llmProvider == .none {
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
                            saveKey(key: geminiKey, keychainId: "gemini-api-key")
                            if appState.llmProvider == .gemini {
                                Task { await appState.validateKeyAndDiscoverModels(provider: .gemini) }
                            }
                        }
                        .disabled(geminiKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: "gemini-api-key")
                            geminiKey = ""
                            if appState.llmProvider == .gemini {
                                appState.discoveredModels = []
                                appState.keyValidationState = .idle
                            }
                        }

                        validationBadge
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            openAIKey = (try? appState.keychainManager.retrieve(key: "openai-api-key")) ?? ""
            geminiKey = (try? appState.keychainManager.retrieve(key: "gemini-api-key")) ?? ""
            if appState.llmProvider != .none {
                appState.loadCachedModels(for: appState.llmProvider)
            }
        }
        .onChange(of: appState.llmProvider) { _, newProvider in
            if newProvider != .none {
                appState.loadCachedModels(for: newProvider)
                appState.keyValidationState = .idle
            } else {
                appState.discoveredModels = []
                appState.keyValidationState = .idle
            }
        }
    }

    private func saveKey(key: String, keychainId: String) {
        do {
            try appState.keychainManager.store(key: keychainId, value: key)
            validationStatus = "Saved!"
            Task {
                try? await Task.sleep(for: .seconds(2))
                validationStatus = ""
            }
        } catch {
            validationStatus = "Failed: \(error.localizedDescription)"
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
}

struct PermissionsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Microphone") {
                HStack {
                    Image(systemName: appState.permissions.hasMicrophonePermission
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(appState.permissions.hasMicrophonePermission ? .green : .red)
                    Text(appState.permissions.hasMicrophonePermission
                         ? "Microphone access granted"
                         : "Microphone access denied")

                    Spacer()

                    if !appState.permissions.hasMicrophonePermission {
                        Button("Request Access") {
                            Task {
                                _ = await appState.permissions.requestMicrophoneAccess()
                            }
                        }
                    }
                }
            }

            Section("Accessibility") {
                HStack {
                    Image(systemName: appState.permissions.hasAccessibilityPermission
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(appState.permissions.hasAccessibilityPermission ? .green : .orange)
                    Text(appState.permissions.hasAccessibilityPermission
                         ? "Accessibility access granted"
                         : "Accessibility access needed for paste-to-app")

                    Spacer()

                    if !appState.permissions.hasAccessibilityPermission {
                        Button("Enable") {
                            appState.permissions.promptAccessibilityPermission()
                        }
                    }
                }

                Text("Accessibility permission allows EnviousWispr to paste transcripts directly into the active app and enables global hotkey support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
