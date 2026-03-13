@preconcurrency import AVFoundation
import EnviousWisprCore

/// Handles audio format conversion and buffer processing.
public enum AudioBufferProcessor {
    /// Calculate RMS audio level from a buffer (0.0 - 1.0).
    public static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }

        let frames = Int(buffer.frameLength)
        let data = channelData[0]

        var sum: Float = 0
        for i in 0..<frames {
            sum += data[i] * data[i]
        }

        let rms = sqrt(sum / Float(frames))
        // Decibel-based scaling: map -60dB..0dB → 0..1 for perceptually correct levels
        let dBFS = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, (dBFS + 60) / 60)
        return min(normalized, 1.0)
    }
}

/// Errors that can occur during audio operations.
public enum AudioError: LocalizedError, Sendable {
    case formatCreationFailed

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create audio format."
        }
    }
}
