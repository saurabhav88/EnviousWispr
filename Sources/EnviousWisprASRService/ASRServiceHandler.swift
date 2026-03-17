@preconcurrency import AVFoundation
import Foundation
import EnviousWisprCore
import EnviousWisprASR

/// XPC service handler for ASR transcription.
///
/// Owns ParakeetBackend (and WhisperKitBackend in Stage D). All inference runs in this
/// XPC service process — model memory is isolated from the main app.
final class ASRServiceHandler: NSObject, ASRServiceProtocol, @unchecked Sendable {
    weak var connection: NSXPCConnection?

    /// The active ASR backend — only one loaded at a time.
    private var parakeetBackend: ParakeetBackend?
    private var whisperKitBackend: WhisperKitBackend?
    private var activeBackendType: String?

    /// Streaming state flag — only Parakeet supports streaming.
    private var isStreamingActive = false

    /// Reusable audio format for buffer reconstruction in feedAudioBuffer.
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    // MARK: - Diagnostics

    func ping(reply: @escaping (String) -> Void) {
        let fluidAudioPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
        let whisperKitPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        let fluidAccess = FileManager.default.isReadableFile(atPath: fluidAudioPath.path)
        let whisperAccess = FileManager.default.isReadableFile(atPath: whisperKitPath.path)
        reply("pong — modelAccess: FluidAudio=\(fluidAccess), WhisperKit=\(whisperAccess)")
    }

    // MARK: - Model Lifecycle

    func loadModel(backendType: String, modelVariant: String, reply: @escaping (NSError?) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                // Unload previous backend before loading new one
                self.parakeetBackend = nil
                self.whisperKitBackend = nil

                switch backendType {
                case "parakeet":
                    let backend = ParakeetBackend()
                    try await backend.prepare()
                    self.parakeetBackend = backend
                case "whisperKit":
                    let variant = modelVariant.isEmpty ? "openai_whisper-large-v3_turbo" : modelVariant
                    let backend = WhisperKitBackend(modelVariant: variant)
                    try await backend.prepare()
                    self.whisperKitBackend = backend
                default:
                    safeReply(NSError(domain: "ASRService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown backend: \(backendType)"]))
                    return
                }
                self.activeBackendType = backendType
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func unloadModel(reply: @escaping () -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            if let wk = self.whisperKitBackend {
                await wk.unload()
            }
            self.parakeetBackend = nil
            self.whisperKitBackend = nil
            self.activeBackendType = nil
            safeReply()
        }
    }

    func getModelState(reply: @escaping (Bool, Bool) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            let isLoaded = self.parakeetBackend != nil || self.whisperKitBackend != nil
            safeReply(isLoaded, self.isStreamingActive)
        }
    }

    // MARK: - Batch Transcription

    func transcribeSamples(_ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        nonisolated(unsafe) let safeReply = reply

        // Validate input
        guard data.count == sampleCount * MemoryLayout<Float>.size else {
            safeReply(nil, NSError(domain: "ASRService", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Data size mismatch: expected \(sampleCount * MemoryLayout<Float>.size), got \(data.count)"]))
            return
        }

        Task { @MainActor in
            do {
                // Convert Data → [Float]
                let samples = data.withUnsafeBytes { raw -> [Float] in
                    guard raw.count > 0 else { return [] }
                    return Array(raw.bindMemory(to: Float.self))
                }

                var options = TranscriptionOptions()
                options.language = language.isEmpty ? nil : language
                options.enableTimestamps = enableTimestamps

                // Route to the active backend
                let result: EnviousWisprCore.ASRResult
                if let parakeet = self.parakeetBackend {
                    result = try await parakeet.transcribe(audioSamples: samples, options: options)
                } else if let whisperKit = self.whisperKitBackend {
                    result = try await whisperKit.transcribe(audioSamples: samples, options: options)
                } else {
                    safeReply(nil, NSError(domain: "ASRService", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "No model loaded"]))
                    return
                }

                // Encode ASRResult → Data via PropertyListEncoder
                let encoded = try PropertyListEncoder().encode(result)
                safeReply(encoded, nil)
            } catch {
                safeReply(nil, error as NSError)
            }
        }
    }

    // MARK: - Streaming

    func startStreaming(language: String, enableTimestamps: Bool, reply: @escaping (NSError?) -> Void) {
        guard let parakeet = parakeetBackend else {
            reply(NSError(domain: "ASRService", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No Parakeet model loaded for streaming"]))
            return
        }

        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                var options = TranscriptionOptions()
                options.language = language.isEmpty ? nil : language
                options.enableTimestamps = enableTimestamps
                try await parakeet.startStreaming(options: options)
                self.isStreamingActive = true
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func feedAudioBuffer(_ data: Data, frameCount: Int) {
        guard isStreamingActive, let parakeet = parakeetBackend else { return }
        guard data.count == frameCount * MemoryLayout<Float>.size else { return }

        // Reconstruct AVAudioPCMBuffer from raw Float32 data
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            buffer.floatChannelData![0].update(from: src, count: frameCount)
        }

        nonisolated(unsafe) let unsafeBuffer = buffer
        Task { try? await parakeet.feedAudio(unsafeBuffer) }
    }

    func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void) {
        guard isStreamingActive, let parakeet = parakeetBackend else {
            reply(nil, NSError(domain: "ASRService", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No active streaming session"]))
            return
        }

        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                let result = try await parakeet.finalizeStreaming()
                self.isStreamingActive = false
                let encoded = try PropertyListEncoder().encode(result)
                safeReply(encoded, nil)
            } catch {
                self.isStreamingActive = false
                safeReply(nil, error as NSError)
            }
        }
    }

    func cancelStreaming() {
        guard isStreamingActive, let parakeet = parakeetBackend else { return }
        isStreamingActive = false
        Task { await parakeet.cancelStreaming() }
    }

    // MARK: - Capability

    func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void) {
        reply(backendType == "parakeet")
    }
}
