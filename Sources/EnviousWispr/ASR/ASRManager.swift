@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// Manages ASR backend selection and delegates transcription calls.
@MainActor
@Observable
final class ASRManager {
    private(set) var activeBackendType: ASRBackendType = .parakeet
    private(set) var isModelLoaded = false
    private(set) var isStreaming = false
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

    /// Whether the active backend supports streaming ASR.
    var activeBackendSupportsStreaming: Bool {
        get async {
            await activeBackend.supportsStreaming
        }
    }

    /// Switch to a different backend. Unloads the previous one.
    func switchBackend(to type: ASRBackendType) async {
        guard type != activeBackendType else { return }
        await activeBackend.unload()
        activeBackendType = type
        isModelLoaded = false
        isStreaming = false
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

    // MARK: - Streaming ASR

    /// Start streaming ASR on the active backend. Falls back silently if unsupported.
    /// If a streaming session is already active, cancels it first to prevent double-session state.
    func startStreaming(options: TranscriptionOptions = .default) async throws {
        guard await activeBackend.supportsStreaming else { return }
        // Cancel any existing session before starting a new one
        if isStreaming {
            await activeBackend.cancelStreaming()
            isStreaming = false
        }
        try await activeBackend.startStreaming(options: options)
        isStreaming = true
    }

    /// Feed an audio buffer to the streaming ASR session.
    func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard isStreaming else { return }
        try await activeBackend.feedAudio(buffer)
    }

    /// Finalize streaming and return the transcript. Falls back to batch if streaming was not active.
    func finalizeStreaming() async throws -> ASRResult {
        guard isStreaming else {
            throw ASRError.streamingNotSupported
        }
        let result = try await activeBackend.finalizeStreaming()
        isStreaming = false
        return result
    }

    /// Cancel an active streaming session, discarding partial results.
    func cancelStreaming() async {
        guard isStreaming else { return }
        await activeBackend.cancelStreaming()
        isStreaming = false
    }

    /// Unload the active backend, freeing model RAM.
    /// Refuses to unload if a streaming session is active — cancel streaming first.
    func unloadModel() async {
        guard isModelLoaded else { return }
        if isStreaming {
            Task { await AppLogger.shared.log(
                "unloadModel() refused — streaming session is active. Cancel streaming first.",
                level: .info, category: "ASR"
            ) }
            return
        }
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
