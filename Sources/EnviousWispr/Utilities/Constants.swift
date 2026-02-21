import Foundation

enum AppConstants {
    static let appName = "EnviousWispr"
    static let appSupportDir = "EnviousWispr"
    static let transcriptsDir = "transcripts"

    /// Application Support directory for EnviousWispr.
    /// Falls back to a temporary directory if Application Support is unavailable.
    static var appSupportURL: URL {
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return appSupport.appendingPathComponent(appSupportDir, isDirectory: true)
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(appSupportDir, isDirectory: true)
        NSLog("[EnviousWispr] WARNING: Application Support directory unavailable, using fallback: \(fallback.path)")
        return fallback
    }
}

// MARK: - Audio Constants

enum AudioConstants {
    /// Target sample rate for ASR processing (16kHz mono).
    static let sampleRate: Double = 16000.0
    static let sampleRateInt: Int = 16000

    /// Audio channels for recording (mono).
    static let channels: Int = 1

    /// Audio buffer size for capture tap (256ms at 16kHz).
    static let captureBufferSize: Int = 4096

    /// Minimum samples required for valid transcription (1 second).
    static let minimumTranscriptionSamples: Int = 16000

    /// Pre-allocation capacity for ~30 seconds of audio.
    static let preAllocatedCapacity: Int = 16000 * 30
}

// MARK: - Timing Constants

enum TimingConstants {
    /// Delay before app window activation to ensure focus.
    static let appActivationDelayMs: Int = 150

    /// Delay before clipboard restoration after paste.
    static let clipboardRestoreDelayMs: Int = 300

    /// VAD monitoring poll interval.
    static let vadPollIntervalMs: Int = 100

    /// Model loading UI delay for smooth transitions.
    static let modelLoadDelayMs: Int = 500

    /// Accessibility permission polling interval (seconds).
    static let accessibilityPollIntervalSec: Double = 5.0

    /// Recording timer update interval (seconds).
    static let recordingTimerIntervalSec: Double = 1.0
}

// MARK: - LLM Constants

enum LLMConstants {
    /// Maximum concurrent model probes to avoid rate limiting.
    static let maxConcurrentProbes: Int = 5

    /// Default max tokens for cloud LLM providers.
    static let defaultMaxTokens: Int = 2048

    /// Max tokens for Ollama (local models can handle more).
    static let ollamaMaxTokens: Int = 4096
}

enum FormattingConstants {
    /// Format a duration in seconds as "m:ss".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
