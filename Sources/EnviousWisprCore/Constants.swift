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

// MARK: - Crash-Recovery Constants

/// Tuning + format constants for the crash-recovery audio spool (#1063). A
/// recording is streamed to an encrypted, append-only `.ewrec` file while
/// recording so a crash / OS memory-kill / kernel panic / power loss mid-take
/// is recoverable on the next launch. Proposed flush/watermark values; tuned
/// with empirical evidence in PR1/PR3.
public enum RecoveryConstants {
  /// Subdirectory of Application Support holding spool files.
  public static let spoolDirectoryName = "audio_recovery"
  /// File extension for a spool file (named `<recoverySessionID>.ewrec`).
  public static let fileExtension = "ewrec"
  /// File extension for a per-spool recovery-ATTEMPT marker (#1063 PR2). Written
  /// durably (fsync + atomic rename) BEFORE the risky load/transcribe step; its
  /// presence on the next launch means a prior recovery attempt crashed the app,
  /// so that spool is abandoned rather than retried (the one-attempt crash-loop
  /// guard). Named `<recoverySessionID>.attempt`.
  public static let attemptFileExtension = "attempt"
  /// On-disk format version recorded in the header.
  public static let formatVersion = 1

  /// AES-256 key length in bytes.
  public static let aesKeyByteCount = 32
  /// Reserved nonce counter for the header settings block; audio/marker frames
  /// start at `firstFrameNonceCounter`, so no nonce is reused under one key.
  public static let settingsNonceCounter: UInt64 = 0
  /// First nonce counter used by an audio/marker frame.
  public static let firstFrameNonceCounter: UInt64 = 1

  /// Audio chunk cadence — how often captured samples are flushed to a frame.
  public static let chunkIntervalSeconds: Double = 1.0
  /// Durable-checkpoint cadence (fsync). Also the power-loss tail-loss bound.
  public static let flushIntervalSeconds: Double = 3.0
  /// Stop spooling when free space drops below this, so recovery never consumes
  /// the last disk the heart path needs (History save / ASR temp / model cache).
  public static let lowDiskWatermarkBytes: Int64 = 1_500_000_000
  /// Orphan spools older than this are purged on launch (TTL backstop).
  public static let retentionDays = 30
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
  /// AudioCaptureManager has a hard emergency limit at 3660s; this fires earlier and gracefully.
  /// Raised 300→3600 (#1060): 60-minute cap. Memory ~230 MB/copy at 16 kHz mono Float32.
  /// In RELEASE this is always 3600. DEBUG builds honor a `EWDebugMaxRecordingSeconds`
  /// UserDefaults override (>0) so Live UAT can drive the full warning→cap→transcribe
  /// cycle in ~90s instead of an hour; the override cannot exist in release.
  public static var maxRecordingDuration: TimeInterval {
    #if DEBUG
      let override = UserDefaults.standard.double(forKey: "EWDebugMaxRecordingSeconds")
      if override > 0 { return override }
    #endif
    return 3600
  }

  /// Lead time before `maxRecordingDuration` at which the user is warned the
  /// recording is about to auto-stop (seconds). #1060: the 59-minute nudge.
  /// DEBUG-overridable via `EWDebugWarningLeadSeconds` (paired with the cap override).
  public static var maxDurationWarningLeadSeconds: TimeInterval {
    #if DEBUG
      let override = UserDefaults.standard.double(forKey: "EWDebugWarningLeadSeconds")
      if override > 0 { return override }
    #endif
    return 60
  }

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
