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
    var lastPolishError: String?

    // Text processing steps
    private let wordCorrectionStep = WordCorrectionStep()
    private let llmPolishStep: LLMPolishStep
    private var textProcessingSteps: [any TextProcessingStep] = []

    /// Access word correction step for configuration.
    var wordCorrection: WordCorrectionStep { wordCorrectionStep }
    /// Access LLM polish step for configuration.
    var llmPolish: LLMPolishStep { llmPolishStep }

    /// The app that was frontmost when recording started — re-activated before pasting.
    private var targetApp: NSRunningApplication?
    private var silenceDetector: SilenceDetector?
    private var vadMonitorTask: Task<Void, Never>?

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
        textProcessingSteps = [wordCorrectionStep, llmPolishStep]
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

        do {
            _ = try audioCapture.startCapture()
            state = .recording
            currentTranscript = nil

            Task { await AppLogger.shared.log(
                "Recording started. Backend: \(asrManager.activeBackendType.rawValue)",
                level: .info, category: "Pipeline"
            ) }

            // Always start VAD monitoring for silence removal
            startVADMonitoring()
        } catch {
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Stop recording and transcribe the captured audio.
    func stopAndTranscribe() async {
        guard state == .recording else { return }

        // Cancel VAD monitoring
        vadMonitorTask?.cancel()
        vadMonitorTask = nil

        let rawSamples = audioCapture.stopCapture()

        guard !rawSamples.isEmpty else {
            state = .error("No audio captured")
            return
        }

        Task { await AppLogger.shared.log(
            "Captured \(rawSamples.count) samples (\(String(format: "%.2f", Double(rawSamples.count)/16000))s)",
            level: .verbose, category: "Pipeline"
        ) }

        // Filter silence using VAD speech segments.
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
            let result = try await asrManager.transcribe(audioSamples: samples)

            let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !asrText.isEmpty else {
                state = .error("No speech detected")
                return
            }

            Task { await AppLogger.shared.log(
                "ASR complete: \(asrText.count) chars, lang=\(result.language ?? "?"), " +
                "duration=\(String(format: "%.2f", result.duration))s, " +
                "processingTime=\(String(format: "%.2f", result.processingTime))s",
                level: .info, category: "Pipeline"
            ) }

            // Run pluggable text processing steps (word correction, LLM polish, etc.)
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
                backendType: result.backendType
            )

            // Save to store
            try transcriptStore.save(transcript)

            // Notify ASR manager that transcription is done; schedules unload timer if configured.
            asrManager.noteTranscriptionComplete(policy: modelUnloadPolicy)

            // Auto-copy/paste + auto-submit
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

                // Restore after a 300 ms delay — long enough for the target app to
                // consume the pasteboard contents but short enough to feel instant.
                if let snapshot {
                    try? await Task.sleep(for: .milliseconds(300))
                    PasteService.restoreClipboard(snapshot, changeCountAfterPaste: changeCountAfterPaste)
                }

            } else if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }
            targetApp = nil

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
            isFavorite: transcript.isFavorite
        )

        do {
            try transcriptStore.save(updated)
        } catch {
            Task { await AppLogger.shared.log(
                "Failed to save polished transcript: \(error)",
                level: .info, category: "Pipeline"
            ) }
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
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        state = .idle
        currentTranscript = nil
    }

    /// Cancel an active recording immediately without transcribing.
    /// Guards on `.recording` state — safe to call from any other state.
    func cancelRecording() {
        guard state == .recording else { return }

        // Stop VAD monitoring task immediately
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        silenceDetector = nil

        // Stop audio engine and explicitly discard all captured samples
        _ = audioCapture.stopCapture()

        // Clear target app reference — nothing will be pasted
        targetApp = nil

        // Transition to idle without saving any transcript
        state = .idle
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
