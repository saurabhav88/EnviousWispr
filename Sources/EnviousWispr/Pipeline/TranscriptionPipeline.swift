import Foundation

/// Orchestrates the full dictation pipeline: record → transcribe → (polish) → store → copy/paste.
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
    var llmProvider: LLMProvider = .none
    var llmModel: String = "gpt-4o-mini"
    var vadAutoStop: Bool = false
    var vadSilenceTimeout: Double = 1.5

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

        do {
            _ = try audioCapture.startCapture()
            state = .recording
            currentTranscript = nil

            // Start VAD monitoring if enabled
            if vadAutoStop {
                startVADMonitoring()
            }
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

        let samples = audioCapture.stopCapture()
        guard !samples.isEmpty else {
            state = .error("No audio captured")
            return
        }

        state = .transcribing

        do {
            let result = try await asrManager.transcribe(audioSamples: samples)

            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .error("No speech detected")
                return
            }

            // Optionally polish with LLM
            var polishedText: String?
            if llmProvider != .none {
                state = .polishing
                polishedText = try? await polishTranscript(result.text)
            }

            let transcript = Transcript(
                text: result.text,
                polishedText: polishedText,
                language: result.language,
                duration: result.duration,
                processingTime: result.processingTime,
                backendType: result.backendType
            )

            // Save to store
            try transcriptStore.save(transcript)

            // Auto-copy/paste
            if autoPasteToActiveApp {
                PasteService.pasteToActiveApp(transcript.displayText)
            } else if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }

            currentTranscript = transcript
            state = .complete
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Polish a single transcript on demand (from detail view).
    func polishExistingTranscript(_ transcript: Transcript) async -> Transcript? {
        guard llmProvider != .none else { return nil }

        state = .polishing
        guard let polishedText = try? await polishTranscript(transcript.text) else {
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

        try? transcriptStore.save(updated)
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

    // MARK: - VAD Monitoring

    private func startVADMonitoring() {
        vadMonitorTask = Task { [weak self] in
            await self?.monitorVAD()
        }
    }

    private func monitorVAD() async {
        // Lazily create detector
        if silenceDetector == nil {
            silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout)
        }
        guard let detector = silenceDetector else { return }

        await detector.reset()

        // Prepare VAD model if needed
        if !(await detector.isReady) {
            do {
                try await detector.prepare()
            } catch {
                print("VAD preparation failed: \(error)")
                return
            }
        }

        var processedSampleCount = 0
        let chunkSize = SilenceDetector.chunkSize

        while state == .recording && !Task.isCancelled {
            let currentCount = audioCapture.capturedSamples.count

            while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
                let endIdx = processedSampleCount + chunkSize
                let chunk = Array(audioCapture.capturedSamples[processedSampleCount..<endIdx])
                let shouldStop = await detector.processChunk(chunk)

                if shouldStop && state == .recording {
                    await stopAndTranscribe()
                    return
                }

                processedSampleCount += chunkSize
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Private

    private func polishTranscript(_ text: String) async throws -> String {
        let polisher: any TranscriptPolisher = switch llmProvider {
        case .openAI: OpenAIConnector(keychainManager: keychainManager)
        case .gemini: GeminiConnector(keychainManager: keychainManager)
        case .none: throw LLMError.providerUnavailable
        }

        let config = LLMProviderConfig(
            provider: llmProvider,
            model: llmModel,
            apiKeyKeychainId: llmProvider == .openAI ? "openai-api-key" : "gemini-api-key",
            maxTokens: 2048,
            temperature: 0.3
        )

        let result = try await polisher.polish(
            text: text,
            instructions: .default,
            config: config
        )

        return result.polishedText
    }
}
