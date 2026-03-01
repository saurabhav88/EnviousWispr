import AppKit
import Foundation

/// Orchestrates the full dictation pipeline: record → transcribe → (correct) → (polish) → store → copy/paste.
@MainActor
@Observable
final class TranscriptionPipeline {
    private let audioCapture: AudioCaptureManager
    private let asrManager: ASRManager
    private let transcriptStore: TranscriptStore
    private let keychainManager: KeychainManager

    private(set) var state: PipelineState = .idle {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }
    var onStateChange: ((PipelineState) -> Void)?
    private(set) var currentTranscript: Transcript?
    var autoCopyToClipboard: Bool = true
    var autoPasteToActiveApp: Bool = false
    var vadAutoStop: Bool = false
    var vadSilenceTimeout: Double = 1.5
    var vadSensitivity: Float = 0.5
    var vadEnergyGate: Bool = false
    var modelUnloadPolicy: ModelUnloadPolicy = .never
    var restoreClipboardAfterPaste: Bool = false
    var transcriptionOptions: TranscriptionOptions = .default
    var lastPolishError: String?

    // Text processing steps
    private let wordCorrectionStep = WordCorrectionStep()
    private let fillerRemovalStep = FillerRemovalStep()
    private let llmPolishStep: LLMPolishStep
    private var textProcessingSteps: [any TextProcessingStep] = []

    /// Access word correction step for configuration.
    var wordCorrection: WordCorrectionStep { wordCorrectionStep }
    /// Access filler removal step for configuration.
    var fillerRemoval: FillerRemovalStep { fillerRemovalStep }
    /// Access LLM polish step for configuration.
    var llmPolish: LLMPolishStep { llmPolishStep }

    /// The app that was frontmost when recording started — re-activated before pasting.
    private var targetApp: NSRunningApplication?
    private var silenceDetector: SilenceDetector?
    private var vadMonitorTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    /// Whether streaming ASR was successfully started for the current recording.
    private var streamingASRActive = false

    init(
        audioCapture: AudioCaptureManager,
        asrManager: ASRManager,
        transcriptStore: TranscriptStore,
        keychainManager: KeychainManager = KeychainManager()
    ) {
        self.audioCapture = audioCapture
        self.asrManager = asrManager
        self.transcriptStore = transcriptStore
        self.keychainManager = keychainManager
        self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)
        llmPolishStep.onWillProcess = { [weak self] in
            self?.state = .polishing
        }
        // Activate SSE streaming for Gemini — a non-nil onToken causes GeminiConnector
        // to use streamGenerateContent instead of batch generateContent.
        // No-op callback is correct; live token display in overlay is a future follow-up.
        llmPolishStep.onToken = { _ in }
        textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]
    }

    /// Toggle recording: start if idle, stop if recording.
    func toggleRecording() async {
        switch state {
        case .idle, .complete, .error:
            await startRecording()
        case .recording:
            await stopAndTranscribe()
        case .transcribing, .polishing:
            break // Don't interrupt processing
        }
    }

    /// Start recording audio from the microphone.
    func startRecording() async {
        guard !state.isActive || state == .complete else { return }

        lastPolishError = nil
        deactivateStreamingForwarding()

        // Cancel idle timer so model stays loaded during recording.
        asrManager.cancelIdleTimer()

        // Ensure model is loaded
        if !asrManager.isModelLoaded {
            state = .transcribing // Show "loading" state
            do {
                try await asrManager.loadModel()
            } catch {
                state = .error("Model load failed: \(error.localizedDescription)")
                return
            }
        }

        // Remember the frontmost app so we can re-activate it before pasting
        // (LLM polishing can take seconds, during which focus may shift)
        targetApp = NSWorkspace.shared.frontmostApplication

        // Start streaming ASR if the backend supports it — feed audio buffers
        // to the ASR model during recording so transcription overlaps with capture.
        let supportsStreaming = await asrManager.activeBackendSupportsStreaming
        if supportsStreaming {
            do {
                try await asrManager.startStreaming(options: transcriptionOptions)
                streamingASRActive = true

                // Wire audio buffer forwarding: each converted buffer goes to streaming ASR
                audioCapture.onBufferCaptured = { [weak self] buffer in
                    guard let self else { return }
                    // AVAudioPCMBuffer isn't Sendable but is consumed immediately
                    // on the main actor — safe to suppress the data race diagnostic.
                    nonisolated(unsafe) let safeBuffer = buffer
                    Task { @MainActor in
                        guard self.streamingASRActive else { return }
                        try? await self.asrManager.feedAudio(safeBuffer)
                    }
                }

                Task { await AppLogger.shared.log(
                    "Streaming ASR started during recording",
                    level: .info, category: "Pipeline"
                ) }
            } catch {
                // Streaming init failed — fall back to batch after recording
                deactivateStreamingForwarding()
                Task { await AppLogger.shared.log(
                    "Streaming ASR failed to start, will use batch: \(error.localizedDescription)",
                    level: .info, category: "Pipeline"
                ) }
            }
        }

        do {
            _ = try audioCapture.startCapture()
            state = .recording
            recordingStartTime = Date()
            currentTranscript = nil

            Task { await AppLogger.shared.log(
                "Recording started. Backend: \(asrManager.activeBackendType.rawValue), streaming=\(streamingASRActive)",
                level: .info, category: "Pipeline"
            ) }

            // Always start VAD monitoring for silence removal
            startVADMonitoring()
        } catch {
            deactivateStreamingForwarding()
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Stop recording and transcribe the captured audio.
    func stopAndTranscribe() async {
        guard state == .recording else { return }

        let pipelineStart = CFAbsoluteTimeGetCurrent()

        // Silently discard recordings shorter than minimum duration (accidental taps)
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < TimingConstants.minimumRecordingDuration {
                vadMonitorTask?.cancel()
                vadMonitorTask = nil
                if streamingASRActive {
                    await asrManager.cancelStreaming()
                }
                deactivateStreamingForwarding()
                _ = audioCapture.stopCapture()
                recordingStartTime = nil
                state = .idle
                Task { await AppLogger.shared.log(
                    "Recording too short (\(String(format: "%.2f", elapsed))s), discarded silently",
                    level: .info, category: "Pipeline"
                ) }
                return
            }
        }
        recordingStartTime = nil

        // Cancel VAD monitoring
        vadMonitorTask?.cancel()
        vadMonitorTask = nil

        // Stop buffer forwarding to streaming ASR
        let wasStreaming = streamingASRActive
        deactivateStreamingForwarding()

        let rawSamples = audioCapture.stopCapture()

        // Pre-warm the LLM connection while ASR is still running (fire-and-forget).
        // Establishes TLS + HTTP/2 so the polish request skips the handshake.
        LLMNetworkSession.shared.preWarmIfConfigured(
            provider: llmPolishStep.llmProvider,
            keychainManager: keychainManager
        )

        guard !rawSamples.isEmpty else {
            state = .error("No audio captured")
            return
        }

        Task { await AppLogger.shared.log(
            "Captured \(rawSamples.count) samples (\(String(format: "%.2f", Double(rawSamples.count)/16000))s)",
            level: .verbose, category: "Pipeline"
        ) }

        // Filter silence using VAD speech segments (used for batch fallback and logging).
        var samples: [Float]
        if let detector = silenceDetector {
            await detector.finalizeSegments(totalSampleCount: rawSamples.count)
            samples = await detector.filterSamples(from: rawSamples)
        } else {
            samples = rawSamples
        }

        Task { await AppLogger.shared.log(
            "VAD filtered to \(samples.count) samples (\(String(format: "%.1f", Double(samples.count)/Double(max(rawSamples.count, 1))*100))% voiced)",
            level: .verbose, category: "Pipeline"
        ) }

        // ASR backends require >= 1 second of audio.
        // If VAD filtering was too aggressive, fall back to raw samples.
        let minimumSamples = AudioConstants.minimumTranscriptionSamples
        if samples.count < minimumSamples && rawSamples.count >= minimumSamples {
            samples = rawSamples
        }

        // Pad short recordings with silence so single-word inputs ("hey", "hi") work.
        if samples.count > 0 && samples.count < minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
        }

        state = .transcribing

        do {
            let asrStart = CFAbsoluteTimeGetCurrent()

            // If streaming ASR was active, finalize it (fast — just the last chunk).
            // Otherwise fall back to batch transcription on the VAD-filtered audio.
            let result: ASRResult
            if wasStreaming {
                do {
                    result = try await asrManager.finalizeStreaming()
                    Task { await AppLogger.shared.log(
                        "Pipeline timing: streaming ASR finalized in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - asrStart))s",
                        level: .info, category: "PipelineTiming"
                    ) }
                } catch {
                    // Streaming finalization failed — fall back to batch
                    Task { await AppLogger.shared.log(
                        "Streaming ASR finalize failed, falling back to batch: \(error.localizedDescription)",
                        level: .info, category: "Pipeline"
                    ) }
                    result = try await asrManager.transcribe(audioSamples: samples, options: transcriptionOptions)
                }
            } else {
                result = try await asrManager.transcribe(audioSamples: samples, options: transcriptionOptions)
            }

            let asrEnd = CFAbsoluteTimeGetCurrent()

            let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !asrText.isEmpty else {
                state = .error("No speech detected — try speaking closer to the microphone")
                Task { await AppLogger.shared.log(
                    "ASR returned empty text, showing error to user",
                    level: .info, category: "Pipeline"
                ) }
                return
            }

            Task { await AppLogger.shared.log(
                "Pipeline timing: ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s " +
                "(mode=\(wasStreaming ? "streaming" : "batch"), \(asrText.count) chars, lang=\(result.language ?? "?"))",
                level: .info, category: "PipelineTiming"
            ) }

            // Run pluggable text processing steps (word correction, LLM polish, etc.)
            let polishStart = CFAbsoluteTimeGetCurrent()
            var context: TextProcessingContext
            do {
                context = try await runTextProcessing(asrText: asrText, language: result.language)
            } catch {
                Task { await AppLogger.shared.log(
                    "Text processing failed: \(error.localizedDescription)",
                    level: .info, category: "Pipeline"
                ) }
                lastPolishError = error.localizedDescription
                context = TextProcessingContext(text: asrText, originalASRText: asrText, language: result.language)
            }
            let polishEnd = CFAbsoluteTimeGetCurrent()

            Task { await AppLogger.shared.log(
                "Pipeline timing: text processing completed in \(String(format: "%.3f", polishEnd - polishStart))s",
                level: .info, category: "PipelineTiming"
            ) }

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
                backendType: result.backendType,
                llmProvider: context.llmProvider,
                llmModel: context.llmModel
            )

            // Save to store
            try transcriptStore.save(transcript)

            // Notify ASR manager that transcription is done; schedules unload timer if configured.
            asrManager.noteTranscriptionComplete(policy: modelUnloadPolicy)

            // Auto-copy/paste + auto-submit
            let pasteStart = CFAbsoluteTimeGetCurrent()
            if autoPasteToActiveApp {
                // Re-activate the app that was frontmost when recording started,
                // since focus may have shifted during transcription/polishing.
                if let app = targetApp, !app.isTerminated {
                    app.activate()
                    try? await Task.sleep(for: .milliseconds(150))
                }

                // Optionally snapshot the clipboard before writing the transcript.
                let snapshot: ClipboardSnapshot? = restoreClipboardAfterPaste
                    ? PasteService.saveClipboard()
                    : nil

                let changeCountAfterPaste = PasteService.pasteToActiveApp(transcript.displayText)

                // Restore after a delay — long enough for the target app to
                // consume the pasteboard contents but short enough to feel instant.
                if let snapshot {
                    try? await Task.sleep(for: .milliseconds(TimingConstants.clipboardRestoreDelayMs))
                    let changeCountBeforeRestore = NSPasteboard.general.changeCount
                    if changeCountBeforeRestore != changeCountAfterPaste {
                        Task { await AppLogger.shared.log(
                            "Pipeline timing: clipboard race detected — changeCount moved from \(changeCountAfterPaste) to \(changeCountBeforeRestore) before restore",
                            level: .info, category: "PipelineTiming"
                        ) }
                    }
                    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
                }

            } else if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }
            let pasteEnd = CFAbsoluteTimeGetCurrent()
            targetApp = nil

            let pipelineEnd = CFAbsoluteTimeGetCurrent()
            Task { await AppLogger.shared.log(
                "Pipeline timing TOTAL: \(String(format: "%.3f", pipelineEnd - pipelineStart))s " +
                "(ASR=\(String(format: "%.3f", asrEnd - asrStart))s, " +
                "polish=\(String(format: "%.3f", polishEnd - polishStart))s, " +
                "paste=\(String(format: "%.3f", pasteEnd - pasteStart))s)",
                level: .info, category: "PipelineTiming"
            ) }

            currentTranscript = transcript
            state = .complete
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Polish a single transcript on demand (from detail view).
    func polishExistingTranscript(_ transcript: Transcript) async -> Transcript? {
        guard llmPolishStep.isEnabled else { return nil }
        guard !state.isActive || state == .complete else { return nil }

        state = .polishing
        let polishedText: String
        do {
            var context = TextProcessingContext(
                text: transcript.text,
                originalASRText: transcript.text,
                language: transcript.language
            )
            context = try await llmPolishStep.process(context)
            polishedText = context.polishedText ?? context.text
        } catch {
            Task { await AppLogger.shared.log(
                "LLM polish failed: \(error.localizedDescription)",
                level: .info, category: "Pipeline"
            ) }
            lastPolishError = error.localizedDescription
            state = .complete
            return nil
        }

        let updated = Transcript(
            id: transcript.id,
            text: transcript.text,
            polishedText: polishedText,
            language: transcript.language,
            duration: transcript.duration,
            processingTime: transcript.processingTime,
            backendType: transcript.backendType,
            createdAt: transcript.createdAt,
            llmProvider: llmPolishStep.llmProvider.rawValue,
            llmModel: llmPolishStep.llmModel
        )

        do {
            try transcriptStore.save(updated)
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to save polished transcript: \(error)",
                level: .info, category: "Pipeline"
            ) }
            lastPolishError = error.localizedDescription
            state = .error("Failed to save: \(error.localizedDescription)")
            return nil
        }
        currentTranscript = updated
        state = .complete
        return updated
    }

    /// Reset pipeline to idle state.
    func reset() {
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        deactivateStreamingForwarding()
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        recordingStartTime = nil
        state = .idle
        currentTranscript = nil
    }

    /// Cancel an active recording immediately without transcribing.
    /// Guards on `.recording` state — safe to call from any other state.
    func cancelRecording() async {
        guard state == .recording else { return }

        // Stop VAD monitoring task immediately
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        silenceDetector = nil

        // Cancel streaming ASR session on the backend (discards partial results)
        if streamingASRActive {
            await asrManager.cancelStreaming()
        }
        deactivateStreamingForwarding()

        // Stop audio engine and explicitly discard all captured samples
        _ = audioCapture.stopCapture()

        // Clear target app reference — nothing will be pasted
        targetApp = nil
        recordingStartTime = nil

        // Transition to idle without saving any transcript
        state = .idle
    }

    /// Deactivate streaming ASR buffer forwarding. Does not cancel the backend session.
    private func deactivateStreamingForwarding() {
        streamingASRActive = false
        audioCapture.onBufferCaptured = nil
    }

    // MARK: - VAD Monitoring

    private func startVADMonitoring() {
        vadMonitorTask = Task { [weak self] in
            await self?.monitorVAD()
        }
    }

    private func monitorVAD() async {
        // Build SmoothedVAD config from sensitivity setting
        var config = SmoothedVADConfig.fromSensitivity(vadSensitivity)
        if vadEnergyGate {
            config.energyGateThreshold = 0.005
        }

        // Lazily create detector
        if silenceDetector == nil {
            silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
        }
        guard let detector = silenceDetector else { return }

        await detector.reset()
        await detector.updateConfig(config)

        // Prepare VAD model if needed
        if !(await detector.isReady) {
            do {
                try await detector.prepare()
            } catch {
                Task { await AppLogger.shared.log(
                    "VAD preparation failed: \(error)",
                    level: .info, category: "VAD"
                ) }
                return
            }
        }

        var processedSampleCount = 0
        let chunkSize = SilenceDetector.chunkSize

        while state == .recording && !Task.isCancelled {
            // Snapshot @MainActor-isolated data before any await suspension.
            let currentCount = audioCapture.capturedSamples.count

            while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
                let endIdx = processedSampleCount + chunkSize
                // Snapshot the chunk on @MainActor before crossing into the detector actor.
                let chunk = Array(audioCapture.capturedSamples[processedSampleCount..<endIdx])
                let autoStop = vadAutoStop

                let shouldStop = await detector.processChunk(chunk)

                if shouldStop && autoStop && state == .recording {
                    // Run in a new Task so cancelling vadMonitorTask
                    // doesn't propagate CancellationError into transcription.
                    Task { [weak self] in await self?.stopAndTranscribe() }
                    return
                }

                processedSampleCount += chunkSize
            }

            try? await Task.sleep(for: .milliseconds(100))
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
            context = try await step.process(context)
        }
        return context
    }
}
