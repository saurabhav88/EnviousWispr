import AppKit
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
    var vadDualBuffer: Bool = false
    var modelUnloadPolicy: ModelUnloadPolicy = .never
    var restoreClipboardAfterPaste: Bool = false
    var polishInstructions: PolishInstructions = .default

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

        // Filter silence using VAD speech segments
        let samples: [Float]
        if let detector = silenceDetector {
            await detector.finalizeSegments(totalSampleCount: rawSamples.count)
            if vadDualBuffer {
                let voiced = await detector.voicedSamples
                samples = voiced.isEmpty ? rawSamples : voiced
            } else {
                samples = await detector.filterSamples(from: rawSamples)
            }
        } else {
            samples = rawSamples
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
                do {
                    polishedText = try await polishTranscript(result.text)
                } catch {
                    print("LLM polish failed: \(error.localizedDescription)")
                }
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

            // Notify ASR manager that transcription is done; schedules unload timer if configured.
            asrManager.noteTranscriptionComplete(policy: modelUnloadPolicy)

            // Auto-copy/paste
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
        guard llmProvider != .none else { return nil }
        guard !state.isActive || state == .complete else { return nil }

        state = .polishing
        let polishedText: String
        do {
            polishedText = try await polishTranscript(transcript.text)
        } catch {
            print("LLM polish failed: \(error.localizedDescription)")
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
            print("Failed to save polished transcript: \(error)")
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
        // Lazily create detector
        if silenceDetector == nil {
            silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout)
        }
        guard let detector = silenceDetector else { return }

        await detector.reset()
        await detector.setDualBufferMode(vadDualBuffer)

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

                if shouldStop && vadAutoStop && state == .recording {
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
        case .ollama: OllamaConnector()
        case .appleIntelligence: AppleIntelligenceConnector()
        case .none: throw LLMError.providerUnavailable
        }

        let keychainId: String = switch llmProvider {
        case .openAI:  "openai-api-key"
        case .gemini:  "gemini-api-key"
        default:       ""
        }

        let maxTokens = llmProvider == .ollama ? 4096 : 2048

        let config = LLMProviderConfig(
            provider: llmProvider,
            model: llmModel,
            apiKeyKeychainId: keychainId,
            maxTokens: maxTokens,
            temperature: 0.3
        )

        // Resolve ${transcript} placeholder if present in the system prompt
        var resolvedInstructions = polishInstructions
        var userText = text
        if polishInstructions.systemPrompt.contains("${transcript}") {
            let resolved = polishInstructions.systemPrompt.replacingOccurrences(
                of: "${transcript}", with: text
            )
            resolvedInstructions = PolishInstructions(
                systemPrompt: resolved,
                removeFillerWords: polishInstructions.removeFillerWords,
                fixGrammar: polishInstructions.fixGrammar,
                fixPunctuation: polishInstructions.fixPunctuation
            )
            userText = ""
        }

        let result = try await polisher.polish(
            text: userText,
            instructions: resolvedInstructions,
            config: config
        )

        return result.polishedText
    }
}
