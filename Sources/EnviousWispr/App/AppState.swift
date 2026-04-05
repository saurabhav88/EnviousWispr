import SwiftUI
import EnviousWisprCore
import EnviousWisprStorage
import EnviousWisprAudio
import EnviousWisprServices
import EnviousWisprASR
import EnviousWisprLLM
import EnviousWisprPipeline

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
    // Settings
    var settings = SettingsManager()

    // Sub-systems
    let permissions = PermissionsService()
    let audioCapture: any AudioCaptureInterface
    let asrManager: any ASRManagerInterface
    let transcriptStore = TranscriptStore()
    let keychainManager = KeychainManager()
    let hotkeyService = HotkeyService()
    let benchmark = BenchmarkSuite()
    let recordingOverlay = RecordingOverlayPanel()
    let ollamaSetup = OllamaSetupService()
    let whisperKitSetup = WhisperKitSetupService()
    let audioDeviceList = AudioDeviceList()

    /// Background task that observes WhisperKitSetupService.setupState and pre-loads the model when ready.
    private var whisperKitPreloadTask: Task<Void, Never>?

    /// Cancellable task for showing a deferred post-completion warning (e.g. polish failed).
    /// Cancelled when a new recording starts or a higher-priority notification is shown.
    private var postCompletionWarningTask: Task<Void, Never>?

    // Pipelines — initialized after sub-systems
    let pipeline: TranscriptionPipeline
    let whisperKitPipeline: WhisperKitPipeline

    /// Forwards settings changes to pipelines and subsystems.
    private let settingsSync: PipelineSettingsSync

    /// Called when pipeline state changes — set by AppDelegate for icon updates.
    var onPipelineStateChange: ((PipelineState) -> Void)?

    // Transcript history — delegated to coordinator
    let transcriptCoordinator: TranscriptCoordinator
    var pendingNavigationSection: SettingsSection?

    /// True when recording is in hands-free (locked) mode via double-press.
    /// Read by the overlay to switch to the expanded lips visual.
    var isRecordingLocked: Bool = false

    // Feature #8: custom word management — delegated to coordinator
    let customWordsCoordinator = CustomWordsCoordinator()

    // Model discovery — delegated to coordinator
    let llmDiscovery: LLMModelDiscoveryCoordinator

    // Apple Intelligence availability — dedicated coordinator (replaces KeyValidationState proxy)
    let aiAvailability = AIAvailabilityCoordinator()

    init() {
        // XPC audio service — default ON (Step 7). Audio capture runs in a separate XPC
        // service process for crash isolation. Escape hatch: `defaults write ... useXPCAudioService -bool false`
        // Read directly from UserDefaults because `settings` is not yet available (stored
        // properties must all be initialized before `self` is accessible).
        // NOTE: .bool(forKey:) returns false for absent keys — use object() ?? true pattern
        // so existing installs (no key written) get the new default.
        let useXPC = UserDefaults.standard.object(forKey: "useXPCAudioService") as? Bool ?? true
        if useXPC {
            audioCapture = AudioCaptureProxy()
        } else {
            audioCapture = AudioCaptureManager()
        }

        // Phase 5: XPC ASR service — default ON (Stage F). ASR inference runs in a separate
        // XPC service process for memory isolation. Escape hatch: `defaults write ... useXPCASRService -bool false`
        // NOTE: .bool(forKey:) returns false for absent keys — use object() ?? true pattern.
        let useXPCASR = UserDefaults.standard.object(forKey: "useXPCASRService") as? Bool ?? true
        if useXPCASR {
            asrManager = ASRManagerProxy()
        } else {
            asrManager = ASRManager()
        }

        transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
        llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: keychainManager)

        // Both pipeline properties must be initialized before `self` can be used.
        // WhisperKitBackend default is large-v3-turbo; reconfigured from settings below.
        pipeline = TranscriptionPipeline(
            audioCapture: audioCapture,
            asrManager: asrManager,
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        whisperKitPipeline = WhisperKitPipeline(
            audioCapture: audioCapture,
            backend: WhisperKitBackend(),
            transcriptStore: transcriptStore,
            keychainManager: keychainManager
        )
        // Initialize settingsSync and apply initial settings to both pipelines and audio capture
        settingsSync = PipelineSettingsSync(
            pipeline: pipeline,
            whisperKitPipeline: whisperKitPipeline,
            audioCapture: audioCapture,
            asrManager: asrManager,
            hotkeyService: hotkeyService,
            whisperKitSetup: whisperKitSetup
        )
        settingsSync.applyInitialSettings(settings, customWords: customWordsCoordinator.customWords)

        // Unified engine interruption handler — routes to whichever pipeline is actively recording.
        // Both pipelines share the same audioCapture instance. When the audio engine/XPC service
        // is interrupted, we must notify the pipeline that's currently recording, not the one
        // that happened to set onEngineInterrupted last.
        audioCapture.onEngineInterrupted = { [weak self] in
            guard let self else { return }
            let pState = self.pipeline.state
            let wkState = self.whisperKitPipeline.state
            Task { await AppLogger.shared.log(
                "[AppState] Audio onEngineInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
                level: .info, category: "XPC"
            ) }
            SentryBreadcrumb.add(stage: "audio", message: "Audio XPC interrupted", level: .error, data: [
                "parakeet_state": "\(pState)",
                "whisperkit_state": "\(wkState)",
            ])
            if pState == .recording {
                self.pipeline.handleEngineInterruption()
            } else if wkState == .recording {
                self.whisperKitPipeline.handleEngineInterruption()
            }
            // Do NOT hide the overlay here. The pipeline's handleEngineInterruption()
            // sets state = .error(...), which fires onStateChange and shows the error
            // overlay. Calling hide() immediately after would dismiss it before the
            // user can read it. The error overlay auto-dismisses after 3 seconds.
        }

        // Observe audio route changes for Sentry context enrichment.
        // AVAudioEngineSource fires AVAudioEngineConfigurationChange internally and handles
        // recovery, but breadcrumbs live in EnviousWisprServices (unavailable in the audio module).
        // AppState observes here to stay within module boundary rules.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                let route = self?.audioCapture.currentAudioRoute ?? "unknown"
                SentryBreadcrumb.add(stage: "audio", message: "Audio route changed", level: .warning, data: [
                    "audio_route": route,
                ])
                SentryBreadcrumb.updateAudioRoute(route)
            }
        }

        // Unified ASR service crash handler — routes to whichever pipeline is active.
        // Fires when the XPC ASR service dies mid-session (streaming or batch).
        asrManager.onServiceInterrupted = { [weak self] in
            guard let self else { return }
            let pState = self.pipeline.state
            let wkState = self.whisperKitPipeline.state
            Task { await AppLogger.shared.log(
                "[AppState] ASR onServiceInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
                level: .info, category: "XPC"
            ) }
            if pState == .loadingModel || pState == .recording || pState == .transcribing {
                self.pipeline.handleASRServiceInterruption()
            } else if wkState == .recording || wkState == .transcribing {
                self.whisperKitPipeline.handleASRServiceInterruption()
            }
            // Do NOT hide the overlay here. Same reasoning as onEngineInterrupted:
            // the pipeline sets .error(...) state which shows the error overlay via
            // onStateChange. The error overlay auto-dismisses after 3 seconds.
        }

        // Unified VAD auto-stop handler — routes to whichever pipeline is actively recording.
        // Fired by service-side VAD (XPC mode only). Same routing pattern as onEngineInterrupted.
        audioCapture.onVADAutoStop = { [weak self] in
            guard let self else { return }
            if self.pipeline.state == .recording {
                Task { await self.pipeline.stopAndTranscribe() }
            } else if self.whisperKitPipeline.state == .recording {
                Task { await self.whisperKitPipeline.stopAndTranscribe() }
            }
        }
        settingsSync.onNeedsPreloadObservation = { [weak self] in
            self?.startWhisperKitPreloadObservation()
        }

        // Wire custom words changes to pipeline sync
        customWordsCoordinator.onWordsChanged = { [weak self] words in
            guard let self else { return }
            self.pipeline.wordCorrection.customWords = words
            self.pipeline.llmPolish.customWords = words
            self.whisperKitPipeline.wordCorrection.customWords = words
            self.whisperKitPipeline.llmPolish.customWords = words
        }

        // Initialize logger
        Task {
            await AppLogger.shared.setLogLevel(settings.debugLogLevel)
            await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled)
        }

        // Sync WhisperKit setup service model variant
        whisperKitSetup.modelVariant = settings.whisperKitModel

        // Restore persisted backend selection synchronously (no race with first record).
        // setInitialBackendType is safe at startup: nothing loaded, no unload needed.
        asrManager.setInitialBackendType(settings.selectedBackend)
        SentryBreadcrumb.updateASRBackend(settings.selectedBackend == .whisperKit ? "whisperkit" : "parakeet")

        // Wire settings change handler
        settings.onChange = { [weak self] key in
            guard let self else { return }
            self.settingsSync.handleSettingChanged(key, settings: self.settings)
        }

        // Wire pipeline state changes to overlay and icon
        pipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(newState)
            // Hotkey management
            switch newState {
            case .recording:
                self.hotkeyService.registerCancelHotkey()
            case .loadingModel, .transcribing, .polishing, .error, .idle, .complete:
                self.isRecordingLocked = false
                self.hotkeyService.unregisterCancelHotkey()
            }
            // Intent-driven overlay — pipeline.overlayIntent maps state to the correct label.
            // On completion, compute a single post-completion notification by priority:
            //   1. clipboardFallback (paste fell back to clipboard-only)
            //   2. warning (polish failed but text was delivered)
            //   3. hidden (success, no notification needed)
            let overlayIntent: OverlayIntent
            if newState == .complete {
                let isClipboardFallback = self.pipeline.currentTranscript?.metrics?.pasteTier == "clipboard_only"
                let polishFailed = self.pipeline.lastPolishError != nil
                if isClipboardFallback {
                    overlayIntent = .clipboardFallback
                } else if polishFailed {
                    // Show polish warning after a brief delay so the completion
                    // transition feels natural. Cancellable if a new recording starts.
                    overlayIntent = self.pipeline.overlayIntent
                    self.schedulePostCompletionWarning(message: "Polish failed -- using raw text")
                } else {
                    overlayIntent = self.pipeline.overlayIntent
                }
            } else {
                self.postCompletionWarningTask?.cancel()
                overlayIntent = self.pipeline.overlayIntent
            }
            self.recordingOverlay.show(
                intent: overlayIntent,
                audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                isRecordingLocked: self.isRecordingLocked
            )
            if newState == .complete {
                self.transcriptCoordinator.load()
                if let t = self.pipeline.currentTranscript {
                    TelemetryService.shared.reportDictationCompleted(transcript: t, inputMode: self.settings.recordingMode.rawValue)
                }
            }
            if case .error(let msg) = newState {
                TelemetryService.shared.pipelineFailed(stage: "transcription", errorCategory: "pipeline_error", errorCode: msg, recoverable: false, backend: "parakeet")
            }
        }

        // Wire WhisperKit pipeline state changes to overlay and icon
        whisperKitPipeline.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.onPipelineStateChange?(self.pipelineState)
            // Hotkey management
            switch newState {
            case .recording:
                self.hotkeyService.registerCancelHotkey()
            case .startingUp, .loadingModel, .transcribing, .polishing, .error, .idle, .ready, .complete:
                self.isRecordingLocked = false
                self.hotkeyService.unregisterCancelHotkey()
            }
            // Intent-driven overlay — same post-completion priority logic as Parakeet above.
            let wkOverlayIntent: OverlayIntent
            if newState == .complete {
                let isClipboardFallback = self.whisperKitPipeline.currentTranscript?.metrics?.pasteTier == "clipboard_only"
                let polishFailed = self.whisperKitPipeline.lastPolishError != nil
                if isClipboardFallback {
                    wkOverlayIntent = .clipboardFallback
                } else if polishFailed {
                    wkOverlayIntent = self.whisperKitPipeline.overlayIntent
                    self.schedulePostCompletionWarning(message: "Polish failed -- using raw text")
                } else {
                    wkOverlayIntent = self.whisperKitPipeline.overlayIntent
                }
            } else {
                self.postCompletionWarningTask?.cancel()
                wkOverlayIntent = self.whisperKitPipeline.overlayIntent
            }
            self.recordingOverlay.show(
                intent: wkOverlayIntent,
                audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                isRecordingLocked: self.isRecordingLocked
            )
            if newState == .complete {
                self.transcriptCoordinator.load()
                if let t = self.whisperKitPipeline.currentTranscript {
                    TelemetryService.shared.reportDictationCompleted(transcript: t, inputMode: self.settings.recordingMode.rawValue)
                }
            }
            if case .error(let msg) = newState {
                TelemetryService.shared.pipelineFailed(stage: "transcription", errorCategory: "pipeline_error", errorCode: msg, recoverable: false, backend: "whisperKit")
            }
        }

        // Wire hotkey callbacks
        hotkeyService.recordingMode = settings.recordingMode
        hotkeyService.cancelKeyCode = settings.cancelKeyCode
        hotkeyService.cancelModifiers = settings.cancelModifiers
        hotkeyService.toggleKeyCode = settings.toggleKeyCode
        hotkeyService.toggleModifiers = settings.toggleModifiers
        hotkeyService.onToggleRecording = { [weak self] in
            guard let self else { return }
            await self.toggleRecording()
        }
        hotkeyService.onStartRecording = { [weak self] in
            guard let self else { return }
            // Cancel any pending post-completion warning from the previous session
            // before showing the new recording overlay.
            self.postCompletionWarningTask?.cancel()
            let isWhisperKit = self.asrManager.activeBackendType == .whisperKit
            let active = self.activePipeline

            if isWhisperKit {
                guard !self.whisperKitPipeline.state.isActive else { return }
                self.whisperKitPipeline.autoPasteToActiveApp = true
                self.whisperKitPipeline.autoCopyToClipboard = self.settings.autoCopyToClipboard
            } else {
                guard !self.pipelineState.isActive else { return }
                self.pipeline.autoPasteToActiveApp = true
                self.pipeline.autoCopyToClipboard = self.settings.autoCopyToClipboard
            }

            self.permissions.refreshAccessibilityStatus()
            if !self.permissions.hasAccessibilityPermission {
                if isWhisperKit {
                    self.whisperKitPipeline.autoPasteToActiveApp = false
                } else {
                    self.pipeline.autoPasteToActiveApp = false
                }
                self.permissions.restartMonitoringIfNeeded()
            }

            // Show recording overlay IMMEDIATELY for instant visual feedback.
            // The pipeline hasn't started yet, but the user needs to see the
            // overlay now — especially for double-press detection where they
            // need visual confirmation before tapping again.
            self.recordingOverlay.show(
                intent: .recording(audioLevel: 0),
                audioLevelProvider: { self.audioCapture.audioLevel },
                isRecordingLocked: false
            )

            let pttStart = ContinuousClock.now
            await active.handle(event: .preWarm)
            guard !Task.isCancelled else {
                // PTT release arrived during preWarm — stop the engine that preWarm started
                self.audioCapture.abortPreWarm()
                self.recordingOverlay.show(intent: .hidden)
                return
            }
            let preWarmMs = {
                let (s, a) = (ContinuousClock.now - pttStart).components
                return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
            }()
            await active.handle(event: .toggleRecording)
            let totalMs = {
                let (s, a) = (ContinuousClock.now - pttStart).components
                return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
            }()
            Task { await AppLogger.shared.log(
                "COLD-START [AppState] PTT-to-recording: total=\(totalMs)ms preWarm=\(preWarmMs)ms startRecording=\(totalMs - preWarmMs)ms backend=\(isWhisperKit ? "whisperkit" : "parakeet")",
                level: .info, category: "Pipeline"
            ) }

            if isWhisperKit {
                if case .error = self.whisperKitPipeline.state {
                    self.whisperKitPipeline.autoPasteToActiveApp = false
                }
            } else {
                if case .error = self.pipeline.state {
                    self.pipeline.autoPasteToActiveApp = false
                }
            }
        }
        hotkeyService.onStopRecording = { [weak self] in
            guard let self else { return }
            self.isRecordingLocked = false
            await self.activePipeline.handle(event: .requestStop)
            if self.asrManager.activeBackendType == .whisperKit {
                self.whisperKitPipeline.autoPasteToActiveApp = false
            } else {
                self.pipeline.autoPasteToActiveApp = false
            }
        }

        hotkeyService.onCancelRecording = { [weak self] in
            self?.isRecordingLocked = false
            await self?.cancelRecording()
        }

        hotkeyService.onIsProcessing = { [weak self] in
            guard let self else { return false }
            // Block during any state that means "still working on the last recording"
            if self.asrManager.activeBackendType == .whisperKit {
                let state = self.whisperKitPipeline.state
                return state == .transcribing || state == .polishing
            } else {
                let state = self.pipeline.state
                return state == .transcribing || state == .polishing
            }
        }

        hotkeyService.onLocked = { [weak self] in
            guard let self else { return }
            self.isRecordingLocked = true
            self.recordingOverlay.updateLockState(true)
            Task { await AppLogger.shared.log(
                "Hands-free mode activated — overlay expanding",
                level: .info, category: "AppState"
            ) }
        }

        // Pre-load the selected backend's model in the background to eliminate cold-start delay.
        // Parakeet: direct silent load (model files already downloaded during onboarding).
        // WhisperKit: observation-based (waits for setupState to become .ready first).
        if settings.selectedBackend == .parakeet {
            Task { [weak self] in
                await self?.asrManager.loadModelSilently()
            }
        }
        Task { [weak self] in
            await self?.whisperKitSetup.detectState()
            self?.startWhisperKitPreloadObservation()
        }

        // NOTE: hotkey registration is deferred to startHotkeyServiceIfEnabled(),
        // called from applicationDidFinishLaunching. Carbon RegisterEventHotKey
        // requires the NSApplication event loop to be running for event delivery.
    }

    /// Start the hotkey service. Must be called after the NSApplication event loop
    /// is running (e.g., from applicationDidFinishLaunching), because Carbon
    /// RegisterEventHotKey events are only delivered once the run loop is active.
    func startHotkeyServiceIfEnabled() {
        if settings.hotkeyEnabled {
            hotkeyService.start()
        }
    }

    /// Observe WhisperKitSetupService.setupState and pre-load the model when it becomes .ready.
    /// Uses withObservationTracking to react to @Observable property changes outside SwiftUI.
    private func startWhisperKitPreloadObservation() {
        whisperKitPreloadTask?.cancel()
        whisperKitPreloadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Check current state — if already .ready, trigger pre-load
                let currentState = self.whisperKitSetup.setupState
                if currentState == .ready {
                    await self.whisperKitPipeline.prepareBackendSilently()
                    return  // Model loaded — no need to keep observing
                }

                // Wait for the next change to setupState
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.whisperKitSetup.setupState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Active dictation pipeline — routes based on selected backend.
    var activePipeline: any DictationPipeline {
        asrManager.activeBackendType == .whisperKit ? whisperKitPipeline : pipeline
    }

    /// Convenience: current pipeline state — routes through active backend.
    var pipelineState: PipelineState {
        if asrManager.activeBackendType == .whisperKit {
            return whisperKitPipeline.state.asPipelineState
        }
        return pipeline.state
    }

    /// Last polish error from the active pipeline.
    var lastPolishError: String? {
        if asrManager.activeBackendType == .whisperKit {
            return whisperKitPipeline.lastPolishError
        }
        return pipeline.lastPolishError
    }

    /// Convenience: the transcript from the latest recording.
    var activeTranscript: Transcript? {
        if let selected = transcriptCoordinator.selectedTranscriptID {
            return transcriptCoordinator.transcripts.first { $0.id == selected }
        }
        if asrManager.activeBackendType == .whisperKit {
            return whisperKitPipeline.currentTranscript
        }
        return pipeline.currentTranscript
    }

    /// Schedule a deferred post-completion warning overlay. Cancellable and session-scoped:
    /// cancelled if a new recording starts (any non-complete state change cancels it).
    /// Uses the pipeline's current state as a guard to avoid showing stale warnings.
    private func schedulePostCompletionWarning(message: String) {
        postCompletionWarningTask?.cancel()
        postCompletionWarningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            // Only show if we're still in the completed state (no new recording started)
            let parakeetComplete = self.pipeline.state == .complete
            let whisperKitComplete = self.whisperKitPipeline.state == .complete || self.whisperKitPipeline.state == .ready
            guard parakeetComplete || whisperKitComplete else { return }
            self.recordingOverlay.show(intent: .warning(message: message))
        }
    }

    /// Reset the currently active pipeline to idle. Used by UI "dismiss" actions.
    func resetActivePipeline() {
        if asrManager.activeBackendType == .whisperKit {
            whisperKitPipeline.reset()
        } else {
            pipeline.reset()
        }
    }

    /// Convenience: audio level for UI visualization.
    var audioLevel: Float {
        audioCapture.audioLevel
    }

    /// Human-readable model name for display.
    var activeModelName: String {
        settings.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
    }

    var activeLLMDisplayName: String {
        guard settings.llmProvider != .none else { return "LLM Deactivated" }
        let model = settings.llmProvider == .ollama ? settings.ollamaModel : settings.llmModel
        if model.isEmpty { return settings.llmProvider.displayName }
        // Use discoveredModels displayName if available, otherwise raw model ID
        if let info = llmDiscovery.discoveredModels.first(where: { $0.id == model }) {
            return info.displayName
        }
        return model
    }

    /// Model status text for sidebar display.
    var modelStatusText: String {
        if asrManager.activeBackendType == .whisperKit {
            switch whisperKitPipeline.state {
            case .loadingModel: return "Loading Model"
            case .recording: return "Recording"
            case .transcribing: return "Transcribing"
            case .polishing: return "Polishing"
            case .error: return "Error"
            default: break
            }
        } else {
            if pipelineState == .recording { return "Recording" }
            if pipelineState == .transcribing { return "Transcribing" }
            if pipelineState == .polishing { return "Polishing" }
            if case .error = pipelineState { return "Error" }
        }
        return asrManager.isModelLoaded ? "Loaded" : "Unloaded"
    }

    /// Toggle recording on/off (plain, no forced LLM).
    func toggleRecording() async {
        postCompletionWarningTask?.cancel()
        let active = activePipeline
        // Set auto-paste before toggle
        if active is WhisperKitPipeline {
            switch whisperKitPipeline.state {
            case .idle, .ready, .complete, .error:
                whisperKitPipeline.autoPasteToActiveApp = true
                permissions.refreshAccessibilityStatus()
                if !permissions.hasAccessibilityPermission {
                    whisperKitPipeline.autoPasteToActiveApp = false
                    permissions.restartMonitoringIfNeeded()
                }
            default: break
            }
        } else {
            switch pipeline.state {
            case .idle, .complete, .error:
                pipeline.autoPasteToActiveApp = true
                permissions.refreshAccessibilityStatus()
                if !permissions.hasAccessibilityPermission {
                    pipeline.autoPasteToActiveApp = false
                    permissions.restartMonitoringIfNeeded()
                }
            default: break
            }
        }

        // Fire dictation.invoked telemetry when starting (not stopping).
        // Intent event: captures user action before engine/ASR work begins.
        // Check that the active pipeline is NOT already in a recording/processing state.
        let alreadyActive: Bool
        if active is WhisperKitPipeline {
            let s = whisperKitPipeline.state
            alreadyActive = s == .recording || s == .transcribing || s == .polishing || s == .loadingModel || s == .startingUp
        } else {
            let s = pipeline.state
            alreadyActive = s == .recording || s == .transcribing || s == .polishing || s == .loadingModel
        }
        if !alreadyActive {
            let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            TelemetryService.shared.dictationInvoked(
                triggerSource: settings.recordingMode.rawValue,
                inputMode: settings.recordingMode.rawValue,
                targetApp: targetApp
            )
        }

        await active.handle(event: .toggleRecording)

        // Clear auto-paste on completion/error
        if active is WhisperKitPipeline {
            if case .complete = whisperKitPipeline.state { whisperKitPipeline.autoPasteToActiveApp = false }
            if case .error = whisperKitPipeline.state { whisperKitPipeline.autoPasteToActiveApp = false }
        } else {
            if pipeline.state == .complete { pipeline.autoPasteToActiveApp = false }
            if case .error = pipeline.state { pipeline.autoPasteToActiveApp = false }
        }
    }

    /// Cancel an active recording, discarding all captured audio.
    func cancelRecording() async {
        TelemetryService.shared.dictationCanceled(stage: "recording", reason: "user_cancel", durationSeconds: nil)
        isRecordingLocked = false
        recordingOverlay.hide()
        let isWhisperKit = asrManager.activeBackendType == .whisperKit
        if isWhisperKit {
            let wkState = whisperKitPipeline.state
            guard wkState == .recording || wkState == .loadingModel || wkState == .startingUp else { return }
            whisperKitPipeline.autoPasteToActiveApp = false
            await whisperKitPipeline.handle(event: .cancelRecording)
        } else {
            guard pipelineState == .recording || pipelineState == .loadingModel else { return }
            pipeline.autoPasteToActiveApp = false
            await pipeline.cancelRecording()
        }
    }

    /// Polish an existing transcript with LLM. Stays in AppState as pipeline coordination forwarding.
    func polishTranscript(_ transcript: Transcript) async {
        if let updated = await pipeline.polishExistingTranscript(transcript) {
            if let idx = transcriptCoordinator.transcripts.firstIndex(where: { $0.id == updated.id }) {
                transcriptCoordinator.transcripts[idx] = updated
            }
        }
    }

    // Phase 5 B.1 validated 2026-03-16: batch round-trip 51-60ms across XPC.
    // Cold model load: 13,966ms. 3 warm back-to-back runs stable.
    // Test function in git history.
}

extension WhisperKitPipelineState {
    /// One authoritative mapping from WhisperKit's 9-state enum to unified PipelineState.
    var asPipelineState: PipelineState {
        switch self {
        case .idle, .ready:              return .idle
        case .startingUp, .loadingModel: return .loadingModel
        case .recording:                 return .recording
        case .transcribing:              return .transcribing
        case .polishing:                 return .polishing
        case .complete:                  return .complete
        case .error(let msg):            return .error(msg)
        }
    }
}
