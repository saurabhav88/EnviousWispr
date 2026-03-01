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

    /// Audio channels for recording (mono).
    static let channels: Int = 1

    /// Audio buffer size for capture tap (256ms at 16kHz).
    static let captureBufferSize: Int = 4096

    /// Minimum samples required for valid transcription (1 second).
    static let minimumTranscriptionSamples: Int = 16000

}

// MARK: - Timing Constants

enum TimingConstants {
    /// Delay before clipboard restoration after paste.
    static let clipboardRestoreDelayMs: Int = 200

    /// Delay after hiding the app before simulating paste (ms).
    static let appHideBeforePasteDelayMs: Int = 300

    /// Accessibility permission polling interval (seconds).
    static let accessibilityPollIntervalSec: Double = 5.0

    /// Minimum recording duration before transcription (seconds).
    /// Recordings shorter than this are silently discarded (accidental taps).
    static let minimumRecordingDuration: TimeInterval = 0.5
}

// MARK: - LLM Constants

enum LLMConstants {
    /// Maximum concurrent model probes to avoid rate limiting.
    static let maxConcurrentProbes: Int = 5

    /// Default max tokens for cloud LLM providers (supports ~5 min dictations with safe headroom).
    /// Thinking models (Gemini 2.5) consume output tokens for reasoning, so this must be generous.
    static let defaultMaxTokens: Int = 8192

    /// Max tokens for Ollama (local models).
    static let ollamaMaxTokens: Int = 2048

    /// Default thinking budget for extended thinking models (Gemini 2.5 Flash/Pro).
    static let defaultThinkingBudget: Int = 8192
}

enum FormattingConstants {
    /// Format a duration in seconds as "m:ss".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
