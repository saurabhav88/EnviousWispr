import Foundation

public enum AppConstants {
    public static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "EnviousWispr"
    public static let appVersion: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // Strip leading "v" and git metadata (e.g. "v1.0.6-1-gabcdef-dev" → "1.0.6")
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        return stripped.split(separator: "-").first.map(String.init) ?? stripped
    }()
    public static let appSupportDir = "EnviousWispr"
    public static let transcriptsDir = "transcripts"
    public static let onboardingWindowTitle = "Setup"

    /// Application Support directory for EnviousWispr.
    /// Falls back to a temporary directory if Application Support is unavailable.
    public static var appSupportURL: URL {
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

public enum AudioConstants {
    /// Target sample rate for ASR processing (16kHz mono).
    public static let sampleRate: Double = 16000.0

    /// Audio channels for recording (mono).
    public static let channels: Int = 1

    /// Audio buffer size for capture tap (256ms at 16kHz).
    public static let captureBufferSize: Int = 4096

    /// Minimum samples required for valid transcription (1 second).
    public static let minimumTranscriptionSamples: Int = 16000

}

// MARK: - Timing Constants

public enum TimingConstants {
    /// Delay before clipboard restoration after paste.
    public static let clipboardRestoreDelayMs: Int = 200

    /// Delay after hiding the app before simulating paste (ms).
    public static let appHideBeforePasteDelayMs: Int = 300

    /// Interval between activation-check polls (ms).
    public static let activationPollIntervalMs: Int = 50

    /// Maximum time to wait for target app activation before pasting anyway (ms).
    public static let activationTimeoutMs: Int = 1000

    /// Accessibility permission polling interval (seconds).
    public static let accessibilityPollIntervalSec: Double = 5.0

    /// Minimum recording duration before transcription (seconds).
    /// Recordings shorter than this are silently discarded (accidental taps).
    public static let minimumRecordingDuration: TimeInterval = 0.5

    /// Maximum recording duration before graceful auto-stop (seconds).
    /// Prevents runaway recordings from consuming unbounded memory/CPU.
    /// AudioCaptureManager has a hard emergency limit at 600s; this fires earlier and gracefully.
    public static let maxRecordingDuration: TimeInterval = 300

    /// Double-press detection window for hands-free recording mode (milliseconds).
    /// Release within this window starts a debounce timer; second press within
    /// this window locks recording. Matches Wispr Flow's proven 500ms constant.
    public static let handsFreeDebounceDelayMs: UInt64 = 500
}

// MARK: - LLM Constants

public enum LLMConstants {
    /// Maximum concurrent model probes to avoid rate limiting.
    public static let maxConcurrentProbes: Int = 5

    /// Default max tokens for cloud LLM providers (supports ~5 min dictations with safe headroom).
    /// Thinking models (Gemini 2.5) consume output tokens for reasoning, so this must be generous.
    public static let defaultMaxTokens: Int = 8192

    /// Max tokens for Ollama (local models).
    public static let ollamaMaxTokens: Int = 2048

    /// Default thinking budget for extended thinking models (Gemini 2.5 Flash/Pro).
    public static let defaultThinkingBudget: Int = 8192
}

public enum FormattingConstants {
    /// Format a duration in seconds as "m:ss".
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
