@preconcurrency import AVFoundation

/// Handles audio format conversion and buffer processing.
enum AudioBufferProcessor {
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
}

/// Errors that can occur during audio operations.
enum AudioError: LocalizedError, Sendable {
    case formatCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create audio format."
        }
    }
}
