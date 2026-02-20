import SwiftUI

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
    // Sub-systems
    let permissions = PermissionsService()
    let audioCapture = AudioCaptureManager()
    let asrManager = ASRManager()
    let transcriptStore = TranscriptStore()
    let keychainManager = KeychainManager()
    let hotkeyService = HotkeyService()
    let benchmark = BenchmarkSuite()
    let recordingOverlay = RecordingOverlayPanel()
    let customWordStore = CustomWordStore()
    let ollamaSetup = OllamaSetupService()

    // Pipeline — initialized after sub-systems
    let pipeline: TranscriptionPipeline

    /// Called when pipeline state changes — set by AppDelegate for icon updates.
    var onPipelineStateChange: ((PipelineState) -> Void)?

    // Transcript history
    var transcripts: [Transcript] = []
    var searchQuery: String = ""
    var selectedTranscriptID: UUID?

    var filteredTranscripts: [Transcript] {
        guard !searchQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // Settings (persisted via UserDefaults)
    var selectedBackend: ASRBackendType {
        didSet {
            UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selectedBackend")
            Task { await asrManager.switchBackend(to: selectedBackend) }
        }
    }

    var whisperKitModel: String {
        didSet {
            UserDefaults.standard.set(whisperKitModel, forKey: "whisperKitModel")
            Task { await asrManager.updateWhisperKitModel(whisperKitModel) }
        }
    }

    var recordingMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode")
            hotkeyService.recordingMode = recordingMode
        }
    }

    var llmProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider")
            pipeline.llmProvider = llmProvider
        }
    }

    var llmModel: String {
        didSet {
            UserDefaults.standard.set(llmModel, forKey: "llmModel")
            pipeline.llmModel = llmModel
            if llmProvider == .ollama {
                ollamaModel = llmModel
            }
        }
    }

    var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
            if llmProvider == .ollama {
                pipeline.llmModel = ollamaModel
            }
        }
    }

    var autoCopyToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard")
            pipeline.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    var hotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled")
            if hotkeyEnabled { hotkeyService.start() } else { hotkeyService.stop() }
        }
    }

    var vadAutoStop: Bool {
        didSet {
            UserDefaults.standard.set(vadAutoStop, forKey: "vadAutoStop")
            pipeline.vadAutoStop = vadAutoStop
        }
    }

    var vadSilenceTimeout: Double {
        didSet {
            UserDefaults.standard.set(vadSilenceTimeout, forKey: "vadSilenceTimeout")
            pipeline.vadSilenceTimeout = vadSilenceTimeout
        }
    }

    var vadDualBuffer: Bool {
        didSet {
            UserDefaults.standard.set(vadDualBuffer, forKey: "vadDualBuffer")
        }
    }

    var vadSensitivity: Float {
        didSet {
            UserDefaults.standard.set(vadSensitivity, forKey: "vadSensitivity")
            pipeline.vadSensitivity = vadSensitivity
        }
    }

    var vadEnergyGate: Bool {
        didSet {
            UserDefaults.standard.set(vadEnergyGate, forKey: "vadEnergyGate")
            pipeline.vadEnergyGate = vadEnergyGate
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    var cancelKeyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(cancelKeyCode), forKey: "cancelKeyCode")
            hotkeyService.cancelKeyCode = cancelKeyCode
        }
    }

    var cancelModifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(cancelModifiers.rawValue, forKey: "cancelModifiersRaw")
            hotkeyService.cancelModifiers = cancelModifiers
        }
    }

    // Configurable toggle hotkey (default: Option+Space)
    var toggleKeyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(toggleKeyCode), forKey: "toggleKeyCode")
            hotkeyService.toggleKeyCode = toggleKeyCode
        }
    }

    var toggleModifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(toggleModifiers.rawValue, forKey: "toggleModifiersRaw")
            hotkeyService.toggleModifiers = toggleModifiers
        }
    }

    // Configurable push-to-talk modifier (default: Option)
    var pushToTalkModifier: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(pushToTalkModifier.rawValue, forKey: "pushToTalkModifierRaw")
            hotkeyService.pushToTalkModifier = pushToTalkModifier
        }
    }

    var modelUnloadPolicy: ModelUnloadPolicy {
        didSet {
            UserDefaults.standard.set(modelUnloadPolicy.rawValue, forKey: "modelUnloadPolicy")
            pipeline.modelUnloadPolicy = modelUnloadPolicy
            // If policy changed to Never, cancel any pending timer.
            if modelUnloadPolicy == .never {
                asrManager.cancelIdleTimer()
            }
        }
    }

    var restoreClipboardAfterPaste: Bool {
        didSet {
            UserDefaults.standard.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste")
            pipeline.restoreClipboardAfterPaste = restoreClipboardAfterPaste
        }
    }

    var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt")
            pipeline.polishInstructions = activePolishInstructions
        }
    }

    /// Returns the custom instructions if a prompt is set, otherwise `.default`.
    var activePolishInstructions: PolishInstructions {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .default
            : .custom(systemPrompt: customSystemPrompt)
    }

    // Feature #8: custom word correction
    var wordCorrectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(wordCorrectionEnabled, forKey: "wordCorrectionEnabled")
            pipeline.wordCorrectionEnabled = wordCorrectionEnabled
        }
    }
    var customWords: [String] = []

    // Feature #19: debug mode (not persisted — resets to off on launch)
    var isDebugModeEnabled: Bool = false {
        didSet {
            Task { await AppLogger.shared.setDebugMode(isDebugModeEnabled) }
        }
    }

    var debugLogLevel: DebugLogLevel {
        didSet {
            UserDefaults.standard.set(debugLogLevel.rawValue, forKey: "debugLogLevel")
            Task { await AppLogger.shared.setLogLevel(debugLogLevel) }
        }
    }

    // Model discovery
    var discoveredModels: [LLMModelInfo] = []
    var isDiscoveringModels = false
    var keyValidationState: KeyValidationState = .idle

    enum KeyValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    init() {
        // Load persisted settings
        let defaults = UserDefaults.standard
        selectedBackend = ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
        whisperKitModel = defaults.string(forKey: "whisperKitModel") ?? "large-v3"
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .pushToTalk
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .none
        llmModel = defaults.string(forKey: "llmModel") ?? "gpt-4o-mini"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
        autoCopyToClipboard = defaults.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        hotkeyEnabled = defaults.object(forKey: "hotkeyEnabled") as? Bool ?? true
        vadAutoStop = defaults.object(forKey: "vadAutoStop") as? Bool ?? false
        vadSilenceTimeout = defaults.object(forKey: "vadSilenceTimeout") as? Double ?? 1.5
        vadDualBuffer = defaults.object(forKey: "vadDualBuffer") as? Bool ?? false
        vadSensitivity = defaults.object(forKey: "vadSensitivity") as? Float ?? 0.5
        vadEnergyGate = defaults.object(forKey: "vadEnergyGate") as? Bool ?? false
        hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? false

        let savedCancelKeyCode = defaults.object(forKey: "cancelKeyCode") as? Int
        cancelKeyCode = UInt16(savedCancelKeyCode ?? 53)  // Default: Escape

        let savedCancelModRaw = defaults.object(forKey: "cancelModifiersRaw") as? UInt
        cancelModifiers = NSEvent.ModifierFlags(rawValue: savedCancelModRaw ?? 0)

        // Toggle hotkey (default: Control+Space)
        let savedToggleKeyCode = defaults.object(forKey: "toggleKeyCode") as? Int
        toggleKeyCode = UInt16(savedToggleKeyCode ?? 49)  // Default: Space

        let savedToggleModRaw = defaults.object(forKey: "toggleModifiersRaw") as? UInt
        toggleModifiers = NSEvent.ModifierFlags(rawValue: savedToggleModRaw ?? NSEvent.ModifierFlags.control.rawValue)

        // Push-to-talk modifier (default: Option)
        let savedPTTModRaw = defaults.object(forKey: "pushToTalkModifierRaw") as? UInt
        pushToTalkModifier = NSEvent.ModifierFlags(rawValue: savedPTTModRaw ?? NSEvent.ModifierFlags.option.rawValue)

        modelUnloadPolicy = ModelUnloadPolicy(
            rawValue: defaults.string(forKey: "modelUnloadPolicy") ?? ""
        ) ?? .never
        restoreClipboardAfterPaste = defaults.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? false
        customSystemPrompt = defaults.string(forKey: "customSystemPrompt") ?? ""

        // Feature #8
        wordCorrectionEnabled = defaults.object(forKey: "wordCorrectionEnabled") as? Bool ?? true
        customWords = (try? customWordStore.load()) ?? []

        // Feature #19
        debugLogLevel = DebugLogLevel(
            rawValue: defaults.string(forKey: "debugLogLevel") ?? ""
        ) ?? .info

        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        pipeline.autoCopyToClipboard = autoCopyToClipboard
        pipeline.llmProvider = llmProvider
        pipeline.llmModel = llmModel
        if llmProvider == .ollama {
            pipeline.llmModel = ollamaModel
        }
        pipeline.vadAutoStop = vadAutoStop
        pipeline.vadSilenceTimeout = vadSilenceTimeout
        pipeline.vadSensitivity = vadSensitivity
        pipeline.vadEnergyGate = vadEnergyGate
        pipeline.modelUnloadPolicy = modelUnloadPolicy
        pipeline.restoreClipboardAfterPaste = restoreClipboardAfterPaste
        pipeline.polishInstructions = activePolishInstructions
        pipeline.wordCorrectionEnabled = wordCorrectionEnabled
        pipeline.customWords = customWords

        // Initialize logger level (must be after all stored properties are set)
        Task { await AppLogger.shared.setLogLevel(debugLogLevel) }

        // Wire pipeline state changes to overlay and icon
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(newState)
            switch newState {
            case .recording:
                // Cancel hotkey only makes sense in toggle mode — in push-to-talk
                // the user simply releases the modifier key to stop.
                if self.recordingMode == .toggle {
                    self.hotkeyService.registerCancelHotkey()
                }
                self.recordingOverlay.show(
                    audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                    modeLabel: self.recordingMode.shortLabel
                )
            case .transcribing, .error, .idle:
                self.hotkeyService.unregisterCancelHotkey()
                self.recordingOverlay.hide()
            case .complete, .polishing:
                self.hotkeyService.unregisterCancelHotkey()
            }
        }

        // Wire hotkey callbacks
        hotkeyService.recordingMode = recordingMode
        hotkeyService.cancelKeyCode = cancelKeyCode
        hotkeyService.cancelModifiers = cancelModifiers
        hotkeyService.toggleKeyCode = toggleKeyCode
        hotkeyService.toggleModifiers = toggleModifiers
        hotkeyService.pushToTalkModifier = pushToTalkModifier
        hotkeyService.onToggleRecording = { [weak self] in
            guard let self else { return }
            await self.toggleRecording()
        }
        hotkeyService.onStartRecording = { [weak self] in
            guard let self, !self.pipelineState.isActive else { return }
            // Push-to-talk: paste directly into the active app after transcription
            self.pipeline.autoPasteToActiveApp = true
            await self.pipeline.startRecording()
        }
        hotkeyService.onStopRecording = { [weak self] in
            guard let self, self.pipelineState == .recording else { return }
            await self.pipeline.stopAndTranscribe()
            self.pipeline.autoPasteToActiveApp = false
            self.loadTranscripts()
        }

        hotkeyService.onCancelRecording = { [weak self] in
            await self?.cancelRecording()
        }

        if hotkeyEnabled {
            hotkeyService.start()
        }
    }

    /// Convenience: current pipeline state.
    var pipelineState: PipelineState {
        pipeline.state
    }

    /// Convenience: the transcript from the latest recording.
    var activeTranscript: Transcript? {
        if let selected = selectedTranscriptID {
            return transcripts.first { $0.id == selected }
        }
        return pipeline.currentTranscript
    }

    /// Convenience: audio level for UI visualization.
    var audioLevel: Float {
        audioCapture.audioLevel
    }

    /// Total transcript count for sidebar stats.
    var transcriptCount: Int { transcripts.count }

    /// Average processing speed across all transcripts (seconds).
    var averageProcessingSpeed: Double {
        let withTimes = transcripts.filter { $0.processingTime > 0 }
        guard !withTimes.isEmpty else { return 0 }
        return withTimes.map(\.processingTime).reduce(0, +) / Double(withTimes.count)
    }

    /// Human-readable model name for display.
    var activeModelName: String {
        selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
    }

    /// Model status text for sidebar display.
    var modelStatusText: String {
        if pipelineState == .recording { return "Recording" }
        if pipelineState == .transcribing { return "Transcribing" }
        if pipelineState == .polishing { return "Polishing" }
        return asrManager.isModelLoaded ? "Loaded" : "Unloaded"
    }

    /// Toggle recording on/off (plain, no forced LLM).
    func toggleRecording() async {
        // Enable paste-to-active-app when starting a new recording
        // (push-to-talk sets this in its own callbacks, but toggle/UI buttons need it too)
        switch pipeline.state {
        case .idle, .complete, .error:
            pipeline.autoPasteToActiveApp = true
        default:
            break
        }

        await pipeline.toggleRecording()

        // Reset paste flag and reload transcripts when pipeline finishes
        if pipeline.state == .complete {
            pipeline.autoPasteToActiveApp = false
            loadTranscripts()
        } else if case .error = pipeline.state {
            pipeline.autoPasteToActiveApp = false
        }
    }

    /// Cancel an active recording, discarding all captured audio.
    func cancelRecording() async {
        guard pipelineState == .recording else { return }
        pipeline.autoPasteToActiveApp = false
        pipeline.cancelRecording()
    }

    /// Polish an existing transcript with LLM.
    func polishTranscript(_ transcript: Transcript) async {
        if let updated = await pipeline.polishExistingTranscript(transcript) {
            if let idx = transcripts.firstIndex(where: { $0.id == updated.id }) {
                transcripts[idx] = updated
            }
        }
    }

    /// Delete a transcript.
    func deleteTranscript(_ transcript: Transcript) {
        do {
            try transcriptStore.delete(id: transcript.id)
            transcripts.removeAll { $0.id == transcript.id }
            if selectedTranscriptID == transcript.id {
                selectedTranscriptID = nil
            }
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to delete transcript: \(error)",
                level: .info, category: "AppState"
            ) }
        }
    }

    /// Load transcript history from disk asynchronously.
    /// Heavy IO runs on a background thread to keep UI responsive.
    func loadTranscripts() {
        Task {
            do {
                transcripts = try await transcriptStore.loadAll()
            } catch {
                await AppLogger.shared.log(
                    "Failed to load transcripts: \(error)",
                    level: .info, category: "AppState"
                )
            }
        }
    }

    // Feature #8: custom word management
    func addCustomWord(_ word: String) {
        try? customWordStore.add(word, to: &customWords)
        pipeline.customWords = customWords
    }

    func removeCustomWord(_ word: String) {
        try? customWordStore.remove(word, from: &customWords)
        pipeline.customWords = customWords
    }

    /// Validate an API key and discover available models for the given provider.
    func validateKeyAndDiscoverModels(provider: LLMProvider) async {
        keyValidationState = .validating
        isDiscoveringModels = true

        let apiKey: String
        if provider == .ollama || provider == .appleIntelligence {
            apiKey = ""
        } else {
            let keychainId = provider == .openAI ? "openai-api-key" : "gemini-api-key"
            guard let key = try? keychainManager.retrieve(key: keychainId), !key.isEmpty else {
                keyValidationState = .invalid("No API key found")
                isDiscoveringModels = false
                return
            }
            apiKey = key
        }

        let discovery = LLMModelDiscovery()
        do {
            let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
            discoveredModels = models
            if provider != .appleIntelligence {
                cacheModels(models, for: provider)
            }
            keyValidationState = .valid

            if !models.contains(where: { $0.id == llmModel && $0.isAvailable }) {
                if let firstAvailable = models.first(where: { $0.isAvailable }) {
                    llmModel = firstAvailable.id
                    if provider == .ollama { ollamaModel = firstAvailable.id }
                }
            }
        } catch LLMError.providerUnavailable {
            keyValidationState = .invalid(
                provider == .ollama
                    ? "Ollama is not running. Start it with: ollama serve"
                    : "Apple Intelligence not available on this system."
            )
            discoveredModels = []
        } catch let error as LLMError where error == .invalidAPIKey {
            keyValidationState = .invalid("Invalid API key")
            discoveredModels = []
        } catch {
            keyValidationState = .invalid(error.localizedDescription)
            discoveredModels = []
        }

        isDiscoveringModels = false
    }

    /// Load cached models from UserDefaults for the given provider.
    func loadCachedModels(for provider: LLMProvider) {
        let key = "cachedModels_\(provider.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let models = try? JSONDecoder().decode([LLMModelInfo].self, from: data) else {
            discoveredModels = []
            return
        }
        discoveredModels = models
    }

    private func cacheModels(_ models: [LLMModelInfo], for provider: LLMProvider) {
        let key = "cachedModels_\(provider.rawValue)"
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
