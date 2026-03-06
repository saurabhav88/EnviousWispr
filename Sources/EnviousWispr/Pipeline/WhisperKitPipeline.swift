import AppKit
import Foundation

/// Internal state machine for the WhisperKit highway — independent of PipelineState.
enum WhisperKitPipelineState: Equatable, Sendable {
    case idle
    case loadingModel
    case ready
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .polishing, .loadingModel:
            return true
        default:
            return false
        }
    }
}

/// Independent WhisperKit dictation pipeline — batch record → transcribe → polish → paste.
///
/// Owns its own 8-state machine, shares only AudioCaptureManager and LLM infrastructure
/// with the Parakeet highway (TranscriptionPipeline). No streaming — batch only.
@MainActor
@Observable
final class WhisperKitPipeline: DictationPipeline {
    private let audioCapture: AudioCaptureManager
    private let backend: WhisperKitBackend
    private let transcriptStore: TranscriptStore
    private let keychainManager: KeychainManager

    private(set) var state: WhisperKitPipelineState = .idle {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }
    var onStateChange: ((WhisperKitPipelineState) -> Void)?
    private(set) var currentTranscript: Transcript?
    var autoCopyToClipboard: Bool = true
    var autoPasteToActiveApp: Bool = false
    var restoreClipboardAfterPaste: Bool = false
    var transcriptionOptions: TranscriptionOptions = .default
    var lastPolishError: String?
    var modelUnloadPolicy: ModelUnloadPolicy = .never

    // Text processing steps (own instances — not shared with Parakeet)
    let wordCorrectionStep = WordCorrectionStep()
    let fillerRemovalStep = FillerRemovalStep()
    let llmPolishStep: LLMPolishStep
    private var textProcessingSteps: [any TextProcessingStep] = []

    /// Access for configuration
    var wordCorrection: WordCorrectionStep { wordCorrectionStep }
    var fillerRemoval: FillerRemovalStep { fillerRemovalStep }
    var llmPolish: LLMPolishStep { llmPolishStep }

    /// The app that was frontmost when recording started.
    private var targetApp: NSRunningApplication?
    private var targetElement: AXUIElement?
    private var recordingStartTime: Date?
    /// Guards against concurrent stopAndTranscribe calls.
    private var isStopping = false
    /// Set by key-up when startRecording() is still in-flight.
    private var stopRequested = false
    /// Whether audio input has been pre-warmed by PTT key-down.
    private var isPreWarmed = false

    init(
        audioCapture: AudioCaptureManager,
        backend: WhisperKitBackend,
        transcriptStore: TranscriptStore,
        keychainManager: KeychainManager
    ) {
        self.audioCapture = audioCapture
        self.backend = backend
        self.transcriptStore = transcriptStore
        self.keychainManager = keychainManager
        self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)

        llmPolishStep.onWillProcess = { [weak self] in
            self?.state = .polishing
        }
        // Activate SSE streaming for Gemini
        llmPolishStep.onToken = { _ in }
        textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]
    }

    // MARK: - DictationPipeline Conformance

    var overlayIntent: OverlayIntent {
        switch state {
        case .loadingModel:
            return .processing(label: "Loading model...")
        case .recording:
            return .recording(audioLevel: 0)
        case .transcribing:
            return .processing(label: "Transcribing...")
        case .polishing:
            return .processing(label: "Polishing...")
        case .idle, .ready, .complete, .error:
            return .hidden
        }
    }

    func handle(event: PipelineEvent) async {
        switch event {
        case .preWarm:
            await preWarmAudioInput()
        case .toggleRecording:
            await toggleRecording()
        case .requestStop:
            await requestStop()
        case .cancelRecording:
            await cancelRecording()
        case .reset:
            reset()
        }
    }

    // MARK: - Recording Lifecycle

    func preWarmAudioInput() async {
        guard !state.isActive, state != .recording else { return }
        await audioCapture.preWarm()
        isPreWarmed = true
    }

    func toggleRecording() async {
        switch state {
        case .idle, .ready, .complete, .error:
            await startRecording()
        case .recording:
            await stopAndTranscribe()
        case .loadingModel, .transcribing, .polishing:
            break
        }
    }

    func startRecording() async {
        guard !state.isActive || state == .complete || state == .ready else { return }

        lastPolishError = nil

        // Load model if not ready — explicit .loadingModel state
        let isBackendReady = await backend.isReady
        if !isBackendReady {
            state = .loadingModel
            do {
                try await backend.prepare()
            } catch {
                state = .error("Model load failed: \(error.localizedDescription)")
                return
            }
        }

        // Check if cancel was requested during model load
        if stopRequested {
            stopRequested = false
            state = .idle
            return
        }

        // Capture target app for paste-back
        targetApp = NSWorkspace.shared.frontmostApplication
        targetElement = PasteService.captureFocusedElement()

        // No streaming buffer forwarding for batch mode
        audioCapture.onBufferCaptured = nil

        do {
            if !isPreWarmed {
                try audioCapture.startEnginePhase()
                let stabilized = await audioCapture.waitForFormatStabilization(
                    maxWait: 1.5,
                    pollInterval: 0.2
                )
                if !stabilized {
                    audioCapture.rebuildEngine()
                    try audioCapture.startEnginePhase()
                }
            }
            isPreWarmed = false

            _ = try audioCapture.beginCapturePhase()
            state = .recording
            recordingStartTime = Date()
            currentTranscript = nil

            if stopRequested {
                stopRequested = false
                await stopAndTranscribe()
                return
            }

            Task { await AppLogger.shared.log(
                "WhisperKit recording started (batch mode)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        } catch {
            stopRequested = false
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    func requestStop() async {
        if state == .recording {
            await stopAndTranscribe()
        } else if state == .loadingModel {
            // PTT cancel during model load → clean idle
            stopRequested = true
        } else {
            stopRequested = true
        }
    }

    func stopAndTranscribe() async {
        guard state == .recording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        let pipelineStart = CFAbsoluteTimeGetCurrent()

        // Discard accidental short recordings
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < TimingConstants.minimumRecordingDuration {
                _ = audioCapture.stopCapture()
                recordingStartTime = nil
                state = .idle
                Task { await AppLogger.shared.log(
                    "WhisperKit recording too short (\(String(format: "%.2f", elapsed))s), discarded",
                    level: .info, category: "WhisperKitPipeline"
                ) }
                return
            }
        }
        recordingStartTime = nil

        let rawSamples = audioCapture.stopCapture()

        // Pre-warm LLM connection while ASR runs
        LLMNetworkSession.shared.preWarmIfConfigured(
            provider: llmPolishStep.llmProvider,
            keychainManager: keychainManager
        )

        guard !rawSamples.isEmpty else {
            state = .error("No audio captured")
            return
        }

        // Pad short recordings
        var samples = rawSamples
        let minimumSamples = AudioConstants.minimumTranscriptionSamples
        if samples.count > 0 && samples.count < minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
        }

        state = .transcribing

        do {
            let asrStart = CFAbsoluteTimeGetCurrent()
            let result = try await backend.transcribe(audioSamples: samples, options: transcriptionOptions)
            let asrEnd = CFAbsoluteTimeGetCurrent()

            let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !asrText.isEmpty else {
                state = .error("No speech detected — try speaking closer to the microphone")
                return
            }

            Task { await AppLogger.shared.log(
                "WhisperKit ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s (\(asrText.count) chars, lang=\(result.language ?? "?"))",
                level: .info, category: "WhisperKitPipeline"
            ) }

            // Run text processing (word correction, filler removal, LLM polish)
            let polishStart = CFAbsoluteTimeGetCurrent()
            var context: TextProcessingContext
            do {
                context = try await runTextProcessing(asrText: asrText, language: result.language)
            } catch {
                lastPolishError = error.localizedDescription
                context = TextProcessingContext(text: asrText, originalASRText: asrText, language: result.language)
            }
            let polishEnd = CFAbsoluteTimeGetCurrent()

            let finalText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                state = .error("No text after processing")
                return
            }

            let transcript = Transcript(
                text: context.text,
                polishedText: context.polishedText,
                language: result.language,
                duration: result.duration,
                processingTime: result.processingTime,
                backendType: .whisperKit,
                llmProvider: context.llmProvider,
                llmModel: context.llmModel
            )

            try transcriptStore.save(transcript)

            // Paste cascade (same tiered approach as TranscriptionPipeline)
            let pasteStart = CFAbsoluteTimeGetCurrent()
            if autoPasteToActiveApp {
                await performPaste(text: transcript.displayText, pasteStart: pasteStart)
            } else if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }
            targetApp = nil
            targetElement = nil

            let pipelineEnd = CFAbsoluteTimeGetCurrent()
            Task { await AppLogger.shared.log(
                "WhisperKit pipeline TOTAL: \(String(format: "%.3f", pipelineEnd - pipelineStart))s " +
                "(ASR=\(String(format: "%.3f", asrEnd - asrStart))s, " +
                "polish=\(String(format: "%.3f", polishEnd - polishStart))s)",
                level: .info, category: "WhisperKitPipeline"
            ) }

            currentTranscript = transcript
            state = .complete
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    func cancelRecording() async {
        stopRequested = false

        if state == .loadingModel {
            // Cancel during model load — transition to idle
            state = .idle
            return
        }

        guard state == .recording else { return }
        _ = audioCapture.stopCapture()
        targetApp = nil
        targetElement = nil
        recordingStartTime = nil
        state = .idle
    }

    func reset() {
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        audioCapture.onBufferCaptured = nil
        recordingStartTime = nil
        state = .idle
        currentTranscript = nil
    }

    // MARK: - Text Processing

    private func runTextProcessing(asrText: String, language: String?) async throws -> TextProcessingContext {
        var context = TextProcessingContext(
            text: asrText,
            originalASRText: asrText,
            language: language
        )
        for step in textProcessingSteps where step.isEnabled {
            context = try await step.process(context)
        }
        return context
    }

    // MARK: - Paste Cascade

    private func performPaste(text: String, pasteStart: CFAbsoluteTime) async {
        let bundleId = targetApp?.bundleIdentifier ?? "unknown"
        var tier: PasteTier = .clipboardOnly

        // Tier 1: AX direct insertion
        if let element = targetElement {
            if PasteService.insertViaAccessibility(text, element: element) {
                tier = .axDirect
            }
        }

        // Tier 2: Activate target app + CGEvent Cmd+V
        if tier == .clipboardOnly, let app = targetApp, !app.isTerminated {
            let pollInterval = TimingConstants.activationPollIntervalMs
            let timeout = TimingConstants.activationTimeoutMs
            app.activate(options: .activateIgnoringOtherApps)
            var elapsed = 0
            while elapsed < timeout {
                try? await Task.sleep(for: .milliseconds(pollInterval))
                elapsed += pollInterval
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    break
                }
                if elapsed % 300 < pollInterval {
                    app.activate(options: .activateIgnoringOtherApps)
                }
            }

            let activated = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier

            if activated {
                let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
                    ? PasteService.saveClipboard()
                    : nil
                let changeCountAfterPaste = PasteService.pasteToActiveApp(text)
                tier = .cgEvent
                if let snapshot {
                    try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
                }
            } else {
                // Tier 2b: AppleScript Edit > Paste
                app.activate(options: .activateIgnoringOtherApps)
                try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
                    ? PasteService.saveClipboard()
                    : nil
                let changeCount = PasteService.copyToClipboardReturningChangeCount(text)
                if PasteService.pasteViaAppleScript(pid: app.processIdentifier) {
                    tier = .appleScript
                }
                if let snapshot {
                    try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCount)
                }
            }
        }

        // Tier 3: Clipboard fallback
        if tier == .clipboardOnly {
            PasteService.copyToClipboard(text)
        }

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - pasteStart) * 1000)
        Task { await AppLogger.shared.log(
            "WhisperKit paste: tier=\(tier.rawValue), app=\(bundleId), duration=\(durationMs)ms",
            level: .info, category: "WhisperKitPipeline"
        ) }
    }
}
