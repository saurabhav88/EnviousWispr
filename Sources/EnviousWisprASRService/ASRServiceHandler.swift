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
    private var activeBackendType: String?

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
                switch backendType {
                case "parakeet":
                    let backend = ParakeetBackend()
                    try await backend.prepare()
                    self.parakeetBackend = backend
                    self.activeBackendType = "parakeet"
                    safeReply(nil)
                default:
                    safeReply(NSError(domain: "ASRService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown backend: \(backendType)"]))
                }
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func unloadModel(reply: @escaping () -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            // ParakeetBackend has no explicit unload — nil the reference to release the actor.
            // In an XPC service, this drops the model from the service process's memory.
            self.parakeetBackend = nil
            self.activeBackendType = nil
            safeReply()
        }
    }

    func getModelState(reply: @escaping (Bool, Bool) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            let isLoaded = self.parakeetBackend != nil
            // Streaming state — Stage B streaming not yet implemented
            safeReply(isLoaded, false)
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
            guard let backend = self.parakeetBackend else {
                safeReply(nil, NSError(domain: "ASRService", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "No model loaded"]))
                return
            }

            do {
                // Convert Data → [Float]
                let samples = data.withUnsafeBytes { raw -> [Float] in
                    guard raw.count > 0 else { return [] }
                    return Array(raw.bindMemory(to: Float.self))
                }

                var options = TranscriptionOptions()
                options.language = language.isEmpty ? nil : language
                options.enableTimestamps = enableTimestamps

                let result = try await backend.transcribe(audioSamples: samples, options: options)

                // Encode ASRResult → Data via PropertyListEncoder
                let encoded = try PropertyListEncoder().encode(result)
                safeReply(encoded, nil)
            } catch {
                safeReply(nil, error as NSError)
            }
        }
    }

    // MARK: - Streaming (Stage B.2 — stubs for now)

    func startStreaming(language: String, enableTimestamps: Bool, reply: @escaping (NSError?) -> Void) {
        reply(NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Streaming not yet implemented"]))
    }

    func feedAudioBuffer(_ data: Data, frameCount: Int) {
        // Stub — Stage B.2
    }

    func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Streaming not yet implemented"]))
    }

    func cancelStreaming() {
        // Stub
    }

    // MARK: - Capability

    func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void) {
        reply(backendType == "parakeet")
    }
}
