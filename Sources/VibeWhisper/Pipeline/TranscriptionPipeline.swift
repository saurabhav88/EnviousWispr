import Foundation

/// Orchestrates the full dictation pipeline: record → transcribe → (polish) → store → copy/paste.
@MainActor
@Observable
final class TranscriptionPipeline {
    private let audioCapture: AudioCaptureManager
    private let asrManager: ASRManager
    private let transcriptStore: TranscriptStore

    private(set) var state: PipelineState = .idle
    private(set) var currentTranscript: Transcript?
    var autoCopyToClipboard: Bool = true

    init(audioCapture: AudioCaptureManager, asrManager: ASRManager, transcriptStore: TranscriptStore) {
        self.audioCapture = audioCapture
        self.asrManager = asrManager
        self.transcriptStore = transcriptStore
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
        } catch {
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Stop recording and transcribe the captured audio.
    func stopAndTranscribe() async {
        guard state == .recording else { return }

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

            let transcript = Transcript(
                text: result.text,
                language: result.language,
                duration: result.duration,
                processingTime: result.processingTime,
                backendType: result.backendType
            )

            // Save to store
            try transcriptStore.save(transcript)

            // Auto-copy to clipboard
            if autoCopyToClipboard {
                PasteService.copyToClipboard(transcript.displayText)
            }

            currentTranscript = transcript
            state = .complete
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Reset pipeline to idle state.
    func reset() {
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        state = .idle
        currentTranscript = nil
    }
}
