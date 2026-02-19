import Foundation

/// Manages ASR backend selection and delegates transcription calls.
@MainActor
@Observable
final class ASRManager {
    private(set) var activeBackendType: ASRBackendType = .parakeet
    private(set) var isModelLoaded = false

    private var parakeetBackend = ParakeetBackend()
    private var whisperKitBackend = WhisperKitBackend()

    /// The currently active backend.
    var activeBackend: any ASRBackend {
        switch activeBackendType {
        case .parakeet: return parakeetBackend
        case .whisperKit: return whisperKitBackend
        }
    }

    /// Switch to a different backend. Unloads the previous one.
    func switchBackend(to type: ASRBackendType) async {
        guard type != activeBackendType else { return }
        await activeBackend.unload()
        activeBackendType = type
        isModelLoaded = false
    }

    /// Update the WhisperKit model variant. Requires reloading the model.
    func updateWhisperKitModel(_ variant: String) async {
        await whisperKitBackend.unload()
        whisperKitBackend = WhisperKitBackend(modelVariant: variant)
        if activeBackendType == .whisperKit {
            isModelLoaded = false
        }
    }

    /// Load the active backend's model.
    func loadModel() async throws {
        try await activeBackend.prepare()
        isModelLoaded = await activeBackend.isReady
    }

    /// Transcribe audio from a file URL.
    func transcribe(audioURL: URL, options: TranscriptionOptions = .default) async throws -> ASRResult {
        try await activeBackend.transcribe(audioURL: audioURL, options: options)
    }

    /// Transcribe raw audio samples (16kHz mono Float32).
    func transcribe(audioSamples: [Float], options: TranscriptionOptions = .default) async throws -> ASRResult {
        try await activeBackend.transcribe(audioSamples: audioSamples, options: options)
    }
}
