import Foundation

public enum AppConstants {
  public static let appName =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "EnviousWispr"
  public static let appVersion: String = {
    let raw =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
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
    let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(
      appSupportDir, isDirectory: true)
    NSLog(
      "[EnviousWispr] WARNING: Application Support directory unavailable, using fallback: \(fallback.path)"
    )
    return fallback
  }
}

// MARK: - Speech Segment

/// A contiguous range of audio samples identified as speech by VAD.
public struct SpeechSegment: Sendable, Codable {
  public let startSample: Int
  public let endSample: Int
  public init(startSample: Int, endSample: Int) {
    self.startSample = startSample
    self.endSample = endSample
  }
}

// MARK: - Capture Result

/// Atomic result from stopCapture(): audio samples + VAD speech segments.
/// Bundling these together eliminates the ordering dependency between
/// stopCapture() and getVADSegments() across the XPC boundary.
public struct CaptureResult: Sendable {
  public let samples: [Float]
  public let vadSegments: [SpeechSegment]
  public init(samples: [Float], vadSegments: [SpeechSegment] = []) {
    self.samples = samples
    self.vadSegments = vadSegments
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

  /// Maximum recording duration before graceful auto-stop (seconds).
  /// Prevents runaway recordings from consuming unbounded memory/CPU.
  /// AudioCaptureManager has a hard emergency limit at 600s; this fires earlier and gracefully.
  public static let maxRecordingDuration: TimeInterval = 300

  /// Double-press detection window for hands-free recording mode (milliseconds).
  /// Release within this window starts a debounce timer; second press within
  /// this window locks recording. Matches Wispr Flow's proven 500ms constant.
  public static let handsFreeDebounceDelayMs: UInt64 = 500

  /// Audio capture stall-detection window (milliseconds). A capture session that
  /// reports `engine.start` success and installs a tap but delivers zero buffers
  /// within this window fires `onCaptureStalled`. Pre-roll ringbuffer is 1.5s;
  /// healthy cold-start delivers first buffer ~200ms; 800ms is a 4x margin.
  public static let audioCaptureStallWindowMs: Int = 800
}

// MARK: - LLM Constants

public enum LLMConstants {
  /// Maximum concurrent model probes to avoid rate limiting.
  public static let maxConcurrentProbes: Int = 5

  /// Default max tokens for cloud LLM providers (supports ~5 min dictations with safe headroom).
  /// Thinking models (Gemini 2.5) consume output tokens for reasoning, so this must be generous.
  public static let defaultMaxTokens: Int = 8192

  /// Floor for Ollama max tokens on non-thinking-capable models (weak/small
  /// models, plain completion models like llama3.2). Actual cap scales with
  /// input length (charCount) to handle long dictations. Kept small so a
  /// rambly small model can't outrun the 15s pipeline timeout.
  public static let ollamaMaxTokens: Int = 256

  /// Floor for Ollama max tokens on thinking-capable models (e.g. Gemma4).
  /// These models emit reasoning into `message.thinking` separately from the
  /// final answer in `message.content`, but the reasoning still counts
  /// against `num_predict`. With the 256 floor, Gemma4's internal reasoning
  /// exhausted the budget and left `message.content` empty on ~50% of polish
  /// calls (#272). 2048 gives thinking models enough headroom to complete
  /// reasoning and emit a clean answer; `done_reason=stop` ends generation
  /// early for short transcripts so latency is bounded.
  public static let ollamaThinkingMaxTokens: Int = 2048

  /// Default thinking budget for extended thinking models (Gemini 2.5 Flash/Pro).
  public static let defaultThinkingBudget: Int = 8192

  /// Floor for dynamic output token cap. Ensures short transcripts have room to expand.
  public static let polishMaxTokensFloor: Int = 512
}

public enum FormattingConstants {
  /// Format a duration in seconds as "m:ss".
  public static func formatDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
