import AppKit
import Foundation
@preconcurrency import WhisperKit

/// Internal state machine for the WhisperKit highway — independent of PipelineState.
enum WhisperKitPipelineState: Equatable, Sendable {
    case idle
    case startingUp       // engine warm-up / pre-capture setup
    case loadingModel
    case ready
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)

    var isActive: Bool {
        switch self {
        case .startingUp, .recording, .transcribing, .polishing, .loadingModel:
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
    /// Whether audio input has been pre-warmed by PTT key-down.
    private var isPreWarmed = false

    // VAD properties
    var vadAutoStop: Bool = false
    var vadSilenceTimeout: Double = 1.5
    var vadSensitivity: Float = 0.5
    var vadEnergyGate: Bool = false

    private var silenceDetector: SilenceDetector?
    private var vadMonitorTask: Task<Void, Never>?
    private var incrementalWorker: WhisperKitIncrementalWorker?
    private var modelUnloadTask: Task<Void, Never>?

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

        // Handle audio engine interruption (device disconnect, max duration cap).
        // Mirrors TranscriptionPipeline's handler — clean up VAD, reset state.
        audioCapture.onEngineInterrupted = { [weak self] in
            guard let self else { return }
            self.vadMonitorTask?.cancel()
            self.vadMonitorTask = nil
            self.silenceDetector = nil
            self.targetApp = nil
            self.targetElement = nil
            self.recordingStartTime = nil
            self.isStopping = false
            self.isPreWarmed = false
            self.state = .error("Audio device disconnected")
        }

        // Activate SSE streaming for Gemini
        llmPolishStep.onToken = { _ in }
        textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]
    }

    // MARK: - DictationPipeline Conformance

    var overlayIntent: OverlayIntent {
        switch state {
        case .startingUp:
            return .processing(label: "Starting...")
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

    // MARK: - Background Pre-load

    /// Silently load the WhisperKit model into RAM without changing pipeline state.
    /// Called after model download completes or on launch if model is already cached.
    /// If user presses record before this finishes, startRecording() handles it with its own .loadingModel flow.
    func prepareBackendSilently() async {
        let isBackendReady = await backend.isReady
        guard !isBackendReady else { return }
        do {
            try await backend.prepare()
            Task { await AppLogger.shared.log(
                "WhisperKit model pre-loaded successfully (background)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        } catch {
            Task { await AppLogger.shared.log(
                "WhisperKit model pre-load failed: \(error.localizedDescription)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        }
    }

    // MARK: - Recording Lifecycle

    func preWarmAudioInput() async {
        guard !state.isActive, state != .recording else { return }
        await audioCapture.preWarm()
        guard !Task.isCancelled else { return }
        isPreWarmed = true
        // Defense-in-depth: ensure model is loaded (idempotent, no-op if ready)
        Task { try? await backend.prepare() }
    }

    func toggleRecording() async {
        switch state {
        case .idle, .ready, .complete, .error:
            await startRecording()
        case .recording:
            await stopAndTranscribe()
        case .loadingModel, .startingUp, .transcribing, .polishing:
            break
        }
    }

    func startRecording() async {
        guard !state.isActive || state == .complete || state == .ready else { return }

        // Cancel any pending model unload — keep model loaded during recording.
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        state = .startingUp
        lastPolishError = nil

        // Load model if not ready
        let isBackendReady = await backend.isReady
        guard state == .startingUp else { return }  // cancelled during await

        if !isBackendReady {
            state = .loadingModel
            do {
                try await backend.prepare()
            } catch {
                state = .error("Model load failed: \(error.localizedDescription)")
                return
            }
            guard state == .loadingModel else { return }  // cancelled during model load
            state = .startingUp  // back to startingUp for engine setup
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
                guard state == .startingUp else { return }  // cancelled during stabilization
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
            startVADMonitoring()
            await startIncrementalWorker()

            Task { await AppLogger.shared.log(
                "WhisperKit recording started (batch mode, incremental worker active)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        } catch {
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    func requestStop() async {
        switch state {
        case .recording:
            await stopAndTranscribe()
        case .startingUp, .loadingModel:
            // Clean abort — startRecording() checks state after each await suspension point.
            state = .idle
        case .idle, .ready, .complete, .error:
            // PTT release before recording started — clean up pre-warmed audio engine
            if isPreWarmed {
                isPreWarmed = false
                audioCapture.abortPreWarm()
            }
        case .transcribing, .polishing:
            // Pipeline is past the point of no return — ignore.
            break
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
                vadMonitorTask?.cancel()
                vadMonitorTask = nil
                await incrementalWorker?.cancel()
                incrementalWorker = nil
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
        vadMonitorTask?.cancel()
        vadMonitorTask = nil

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

        // Post-capture VAD filtering — remove silence segments
        var samples: [Float]
        if let detector = silenceDetector {
            await detector.finalizeSegments(totalSampleCount: rawSamples.count)
            samples = await detector.filterSamples(from: rawSamples)
            let pct = String(format: "%.1f", Double(samples.count) / Double(max(rawSamples.count, 1)) * 100)
            Task { await AppLogger.shared.log(
                "WhisperKit VAD filtered to \(samples.count) samples (\(pct)% voiced)",
                level: .info, category: "WhisperKitPipeline"
            ) }
        } else {
            samples = rawSamples
        }

        // Fallback: if VAD was too aggressive, use raw
        let minimumSamples = AudioConstants.minimumTranscriptionSamples
        if samples.count < minimumSamples && rawSamples.count >= minimumSamples {
            samples = rawSamples
        }

        // Pad short recordings
        if samples.count > 0 && samples.count < minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
        }

        state = .transcribing

        do {
            let asrStart = CFAbsoluteTimeGetCurrent()

            // Try background worker result first, batch fallback if stale/empty
            let asrText: String
            let asrLanguage: String?
            var usedIncremental = false

            if let worker = incrementalWorker {
                let segments = await silenceDetector?.speechSegments ?? []
                let result = await worker.finalize(finalSamples: rawSamples, speechSegments: segments)
                incrementalWorker = nil

                let coveragePct = rawSamples.count > 0
                    ? String(format: "%.1f", Double(result.samplesCovered) / Double(rawSamples.count) * 100)
                    : "0"

                if result.accepted, let text = result.text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    asrText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    asrLanguage = transcriptionOptions.language
                    usedIncremental = true

                    Task { await AppLogger.shared.log(
                        "WhisperKit finalize: strategy=\(result.strategy), mode=\(result.mode), " +
                        "decodes=\(result.decodeCount), tailDecodeMs=\(result.tailDecodeMs), " +
                        "coverage=\(result.samplesCovered)/\(rawSamples.count) (\(coveragePct)%)",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                } else {
                    Task { await AppLogger.shared.log(
                        "WhisperKit finalize: strategy=\(result.strategy), " +
                        "workerDecodes=\(result.decodeCount), workerCoverage=\(coveragePct)%, " +
                        "falling back to batch",
                        level: .info, category: "WhisperKitPipeline"
                    ) }

                    let batchStart = CFAbsoluteTimeGetCurrent()
                    let batchResult = try await backend.transcribe(audioSamples: samples, options: transcriptionOptions)
                    let batchMs = Int((CFAbsoluteTimeGetCurrent() - batchStart) * 1000)
                    asrText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    asrLanguage = batchResult.language

                    Task { await AppLogger.shared.log(
                        "WhisperKit finalize: strategy=\(result.strategy), batchMs=\(batchMs), " +
                        "workerDecodes=\(result.decodeCount), workerCoverage=\(coveragePct)%",
                        level: .info, category: "WhisperKitPipeline"
                    ) }
                }
            } else {
                let batchResult = try await backend.transcribe(audioSamples: samples, options: transcriptionOptions)
                asrText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                asrLanguage = batchResult.language
            }

            let asrEnd = CFAbsoluteTimeGetCurrent()

            guard !asrText.isEmpty else {
                state = .error("No speech detected — try speaking closer to the microphone")
                return
            }

            Task { await AppLogger.shared.log(
                "WhisperKit ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s " +
                "(\(asrText.count) chars, lang=\(asrLanguage ?? "?"), incremental=\(usedIncremental))",
                level: .info, category: "WhisperKitPipeline"
            ) }

            // Run text processing (word correction, filler removal, LLM polish)
            let polishStart = CFAbsoluteTimeGetCurrent()
            var context: TextProcessingContext
            do {
                context = try await runTextProcessing(asrText: asrText, language: asrLanguage)
            } catch {
                lastPolishError = error.localizedDescription
                context = TextProcessingContext(text: asrText, originalASRText: asrText, language: asrLanguage)
            }
            let polishEnd = CFAbsoluteTimeGetCurrent()

            let finalText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                state = .error("No text after processing")
                return
            }

            let recordingDuration = Double(rawSamples.count) / 16000.0
            let transcript = Transcript(
                text: context.text,
                polishedText: context.polishedText,
                language: asrLanguage,
                duration: recordingDuration,
                processingTime: asrEnd - asrStart,
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
            scheduleModelUnloadIfNeeded()
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    func cancelRecording() async {
        if state == .startingUp || state == .loadingModel {
            // Cancel during startup or model load — transition to idle
            state = .idle
            return
        }

        guard state == .recording else { return }
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        await incrementalWorker?.cancel()
        incrementalWorker = nil
        silenceDetector = nil
        _ = audioCapture.stopCapture()
        targetApp = nil
        targetElement = nil
        recordingStartTime = nil
        state = .idle
    }

    func reset() {
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        // Fire-and-forget cancel — reset() is synchronous, worker cancel is safe to defer
        if let worker = incrementalWorker {
            incrementalWorker = nil
            Task { await worker.cancel() }
        }
        silenceDetector = nil
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        audioCapture.onBufferCaptured = nil
        recordingStartTime = nil
        state = .idle
        currentTranscript = nil
    }

    // MARK: - Incremental Worker

    private func startIncrementalWorker() async {
        guard let kit = await backend.whisperKitInstance else { return }
        let opts = await backend.makeDecodeOptions(from: transcriptionOptions, sampleCount: 0)
        // BRAIN: gotcha id=nonisolated-unsafe-tokenizer
        // nonisolated(unsafe): WhisperTokenizer is not Sendable but is safe to transfer —
        // the backend is the sole owner and we pass it to a single actor that holds it for its lifetime.
        nonisolated(unsafe) let tokenizer = await backend.whisperKitTokenizer
        let worker = WhisperKitIncrementalWorker(whisperKit: kit, decodingOptions: opts, tokenizer: tokenizer)
        self.incrementalWorker = worker

        // Provide audio samples from MainActor-isolated audioCapture
        let capture = audioCapture
        await worker.start(audioSamplesProvider: { @MainActor in
            let samples = capture.capturedSamples
            return (samples: samples, count: samples.count)
        })
    }

    // MARK: - VAD Monitoring

    private func startVADMonitoring() {
        vadMonitorTask = Task { [weak self] in
            await self?.monitorVAD()
        }
    }

    private func monitorVAD() async {
        var config = SmoothedVADConfig.fromSensitivity(vadSensitivity)
        if vadEnergyGate {
            config.energyGateThreshold = 0.005
        }

        if silenceDetector == nil {
            silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
        }
        guard let detector = silenceDetector else { return }

        await detector.reset()
        await detector.updateConfig(config)

        if !(await detector.isReady) {
            do {
                try await detector.prepare()
            } catch {
                Task { await AppLogger.shared.log(
                    "WhisperKit VAD preparation failed: \(error)",
                    level: .info, category: "WhisperKitPipeline"
                ) }
                return
            }
        }

        var processedSampleCount = 0
        let chunkSize = SilenceDetector.chunkSize

        while state == .recording && !Task.isCancelled {
            // Graceful max duration check — auto-stop before AudioCaptureManager's hard limit.
            if let startTime = recordingStartTime,
               Date().timeIntervalSince(startTime) >= TimingConstants.maxRecordingDuration {
                Task { [weak self] in await self?.stopAndTranscribe() }
                return
            }

            let currentCount = audioCapture.capturedSamples.count

            while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
                let endIdx = processedSampleCount + chunkSize
                let chunk = Array(audioCapture.capturedSamples[processedSampleCount..<endIdx])
                let autoStop = vadAutoStop

                let shouldStop = await detector.processChunk(chunk)

                if shouldStop && autoStop && state == .recording {
                    Task { [weak self] in await self?.stopAndTranscribe() }
                    return
                }

                processedSampleCount += chunkSize
                await Task.yield()
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Model Lifecycle

    private func scheduleModelUnloadIfNeeded() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        switch modelUnloadPolicy {
        case .never:
            return
        case .immediately:
            modelUnloadTask = Task { [weak self] in
                await self?.backend.unload()
            }
        default:
            guard let interval = modelUnloadPolicy.interval else { return }
            modelUnloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.backend.unload()
            }
        }
    }

    // MARK: - Text Processing

    private func runTextProcessing(asrText: String, language: String?) async throws -> TextProcessingContext {
        var context = TextProcessingContext(
            text: asrText,
            originalASRText: asrText,
            language: language
        )
        for step in textProcessingSteps where step.isEnabled {
            let stepName = String(describing: type(of: step))
            let input = context
            // nonisolated(unsafe) is safe: the task group inherits @MainActor isolation,
            // so step.process() still runs on MainActor — no real isolation crossing.
            nonisolated(unsafe) let unsafeStep = step
            do {
                context = try await withThrowingTimeout(seconds: 10) {
                    try await unsafeStep.process(input)
                }
            } catch is TimeoutError {
                Task {
                    await AppLogger.shared.log(
                        "\(stepName) timed out after 10s — skipping",
                        level: .info, category: "TextProcessing"
                    )
                }
                // Heart & Limbs: limb failed, continue with input text
            }
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
