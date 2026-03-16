import Foundation
import EnviousWisprCore

/// XPC service handler for ASR transcription.
///
/// Stub implementation for Stage A — ping only. Backend integration added in Stage B.
final class ASRServiceHandler: NSObject, ASRServiceProtocol, @unchecked Sendable {
    weak var connection: NSXPCConnection?

    // MARK: - Diagnostics

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    // MARK: - Model Lifecycle (Stage B)

    func loadModel(backendType: String, modelVariant: String, reply: @escaping (NSError?) -> Void) {
        // Stub — Stage B
        reply(NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"]))
    }

    func unloadModel(reply: @escaping () -> Void) {
        reply()
    }

    func getModelState(reply: @escaping (Bool, Bool) -> Void) {
        reply(false, false)
    }

    // MARK: - Batch Transcription (Stage B)

    func transcribeSamples(_ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"]))
    }

    // MARK: - Streaming (Stage B)

    func startStreaming(language: String, enableTimestamps: Bool, reply: @escaping (NSError?) -> Void) {
        reply(NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"]))
    }

    func feedAudioBuffer(_ data: Data, frameCount: Int) {
        // Stub — Stage B
    }

    func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"]))
    }

    func cancelStreaming() {
        // Stub — Stage B
    }

    // MARK: - Capability

    func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void) {
        reply(backendType == "parakeet")
    }
}
