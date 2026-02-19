import Foundation

/// Manages ASR backend selection and delegates transcription calls.
@MainActor
@Observable
final class ASRManager {
    private(set) var activeBackendType: ASRBackendType = .parakeet
    private(set) var isModelLoaded = false
    private var idleTimer: Timer?
    private var lastTranscriptionTime: Date?

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

    /// Unload the active backend, freeing model RAM.
    func unloadModel() async {
        guard isModelLoaded else { return }
        await activeBackend.unload()
        isModelLoaded = false
    }

    /// Called by pipeline after a transcript is saved.
    /// Records the timestamp and schedules/resets the idle timer.
    func noteTranscriptionComplete(policy: ModelUnloadPolicy) {
        lastTranscriptionTime = Date()
        if policy == .immediately {
            Task { await unloadModel() }
            return
        }
        scheduleIdleTimer(policy: policy)
    }

    /// Cancel any pending idle timer (called when recording starts).
    func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Schedule (or reset) the idle timer for timed policies.
    private func scheduleIdleTimer(policy: ModelUnloadPolicy) {
        guard let interval = policy.interval else { return }
        cancelIdleTimer()
        // Timer fires on the main run loop — safe for @MainActor ASRManager.
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task<Void, Never> { await self?.unloadModel() }
            }
        }
    }
}
