@preconcurrency import AVFoundation

/// Handles audio format conversion and buffer processing.
enum AudioBufferProcessor {
    /// Convert an AVAudioPCMBuffer to 16kHz mono Float32 samples.
    static func convertToMono16kHz(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureManager.targetSampleRate,
            channels: AudioCaptureManager.targetChannels,
            interleaved: false
        ) else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        return error == nil ? outputBuffer : nil
    }

    /// Calculate RMS audio level from a buffer (0.0 - 1.0).
    static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }

        let frames = Int(buffer.frameLength)
        let data = channelData[0]

        var sum: Float = 0
        for i in 0..<frames {
            sum += data[i] * data[i]
        }

        let rms = sqrt(sum / Float(frames))
        // Clamp to 0-1 range with a reasonable scaling factor
        return min(rms * 5.0, 1.0)
    }

    /// Write Float32 samples to a temporary WAV file (16kHz mono).
    static func writeToTempWAV(samples: [Float]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("enviouswispr-\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureManager.targetSampleRate,
            channels: AudioCaptureManager.targetChannels,
            interleaved: false
        ) else {
            throw AudioError.formatCreationFailed
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AudioError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)

        return fileURL
    }
}

/// Errors that can occur during audio operations.
enum AudioError: LocalizedError, Sendable {
    case formatCreationFailed
    case bufferCreationFailed
    case captureFailed(String)
    case noMicrophonePermission

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create audio format."
        case .bufferCreationFailed: return "Failed to create audio buffer."
        case .captureFailed(let msg): return "Audio capture failed: \(msg)"
        case .noMicrophonePermission: return "Microphone permission not granted."
        }
    }
}
