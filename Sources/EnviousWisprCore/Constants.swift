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

/// Capture-health facts for one recording, assembled by the ACTIVE SOURCE at
/// stop time (#1434). One object for both the in-process and XPC stop paths —
/// the XPC stop reply encodes/decodes exactly this struct; telemetry
/// properties (`capture_native_rate_hz`, the counters) are DERIVED from it,
/// never plumbed as separate side channels.
public struct CaptureStopMetadata: Sendable, Codable, Equatable {
  /// The native rate the capture's converter ran at — the prepare-time read of
  /// whichever prepare produced this capture (post-rebuild when the format
  /// stabilization check forced a rebuild). Nil when the source doesn't track
  /// a native rate.
  public let nativeRateHz: Double?
  /// Chunks the RT ring refused because the consumer lagged (drop = lost audio).
  public let ringDropCount: Int
  /// AVAudioConverter calls that returned an error (converted chunk lost).
  public let converterErrorCount: Int
  /// Converter calls that produced zero output frames (expected once at
  /// priming; more than ~1 per session is a signal). Deliberately NOT part of
  /// `inputTimelineGapCount`: a priming call CONSUMES its input and emits it on
  /// the following call, so the output timeline stays continuous.
  public let zeroOutputCount: Int
  /// `AudioUnitRender` calls that returned a non-`noErr` status (that whole
  /// callback's frames never reached the ring = lost audio).
  public let renderFailureCount: Int
  /// Render callbacks whose hardware slice exceeded the scratch allocation, so
  /// the excess frames of that callback were clamped away = lost audio.
  ///
  /// This and `renderFailureCount` are dev-log + `inputTimelineGapCount` only.
  /// The three older counters also travel to `dictation.completed`; these two
  /// deliberately do NOT yet, because that chain spans four layers and a PostHog
  /// property-naming decision that is a separate change, not a deferred half of
  /// this one. The asymmetry is recorded so it reads as chosen, not forgotten,
  /// and tracked in #1847.
  public let oversizedSliceCount: Int
  /// Gaps that accrued while the warm unit was PRE-ROLLING, before this session's
  /// counters were reset (#1788 cloud review r4). The other counters are reset per
  /// session on purpose, so idle-time faults cannot bleed into a recording's
  /// #1434 telemetry — but the wake measurement spans retained pre-roll, so for
  /// IT those gaps are inside the window and erasing them would let the line
  /// claim `exact` over a stream that provably lost frames. Carried separately
  /// rather than folded into the four counters above, which must keep meaning
  /// "this session". Deliberately CONSERVATIVE: it spans the whole idle stretch
  /// rather than only the ~500ms the ring still holds, so it can say `floor` when
  /// `exact` was defensible. A measurement authority fails closed.
  public let preRollGapCount: Int
  /// A stream-format / nominal-rate change notification fired for the bound
  /// device while capturing (#1434 — log-and-telemetry only in v1; never
  /// interrupts the recording).
  public let rateDivergenceDetected: Bool
  /// The bound device's total native input channel count, summed across every
  /// input stream at prepare time (#1523 — fleet-visibility for the multi-channel
  /// down-mix. AUHAL always takes channel 0; this records how many channels the
  /// device exposed so a >1-channel population is measurable). Nil when the
  /// source doesn't read a channel count (e.g. proxy-origin stalls).
  public let nativeChannelCount: Int?

  /// Every way the captured stream can lose frames between the microphone and
  /// the pipeline, summed. THE point of this property is to be the one place
  /// that enumerates them, so anything measuring positions in the sample stream
  /// asks one question instead of rediscovering the edges one review round at a
  /// time (#1788 took three rounds of exactly that). Zero means the sample
  /// stream is a faithful, gap-free timeline of what the device delivered, so a
  /// sample INDEX is an exact elapsed time; nonzero makes any such index a lower
  /// bound. The four edges, all in `HALDeviceInputSource`:
  ///   1. `AudioUnitRender` returned an error   -> `renderFailureCount`
  ///   2. slice larger than the scratch buffer  -> `oversizedSliceCount`
  ///   3. RT ring full, consumer lagging        -> `ringDropCount`
  ///   4. `AVAudioConverter` returned an error  -> `converterErrorCount`
  /// A fifth candidate, a zero-frame converter output, is NOT a gap (see
  /// `zeroOutputCount`). Adding a new lossy edge means adding it here too.
  ///
  /// The WINDOW matters as much as the edge list: a measured wake starts inside
  /// retained pre-roll, so `preRollGapCount` is part of the sum even though the
  /// four session counters are reset before that pre-roll is drained. Counting
  /// the right edges over the wrong window was cloud review r4 on #1788, after
  /// r1-r3 each found a different edge — the same root cause four times, which
  /// is why both halves are stated here rather than in a call site.
  public var inputTimelineGapCount: Int {
    renderFailureCount + oversizedSliceCount + ringDropCount + converterErrorCount
      + preRollGapCount
  }

  public init(
    nativeRateHz: Double?,
    ringDropCount: Int = 0,
    converterErrorCount: Int = 0,
    zeroOutputCount: Int = 0,
    renderFailureCount: Int = 0,
    oversizedSliceCount: Int = 0,
    preRollGapCount: Int = 0,
    rateDivergenceDetected: Bool = false,
    nativeChannelCount: Int? = nil
  ) {
    self.nativeRateHz = nativeRateHz
    self.ringDropCount = ringDropCount
    self.converterErrorCount = converterErrorCount
    self.zeroOutputCount = zeroOutputCount
    self.renderFailureCount = renderFailureCount
    self.oversizedSliceCount = oversizedSliceCount
    self.preRollGapCount = preRollGapCount
    self.rateDivergenceDetected = rateDivergenceDetected
    self.nativeChannelCount = nativeChannelCount
  }

  /// Counters decode as ABSENT-MEANS-ZERO rather than as required keys, so a stop
  /// reply produced before a given counter existed still decodes. The synthesized
  /// decoder would instead throw on the missing key, which is how #1788's two new
  /// gap counters would have broken the #1523 forward-compatibility test. Adding
  /// another counter therefore needs a line here as well as in
  /// `inputTimelineGapCount` — both are deliberate, both fail loudly in tests.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    nativeRateHz = try c.decodeIfPresent(Double.self, forKey: .nativeRateHz)
    ringDropCount = try c.decodeIfPresent(Int.self, forKey: .ringDropCount) ?? 0
    converterErrorCount = try c.decodeIfPresent(Int.self, forKey: .converterErrorCount) ?? 0
    zeroOutputCount = try c.decodeIfPresent(Int.self, forKey: .zeroOutputCount) ?? 0
    renderFailureCount = try c.decodeIfPresent(Int.self, forKey: .renderFailureCount) ?? 0
    oversizedSliceCount = try c.decodeIfPresent(Int.self, forKey: .oversizedSliceCount) ?? 0
    preRollGapCount = try c.decodeIfPresent(Int.self, forKey: .preRollGapCount) ?? 0
    rateDivergenceDetected =
      try c.decodeIfPresent(Bool.self, forKey: .rateDivergenceDetected) ?? false
    nativeChannelCount = try c.decodeIfPresent(Int.self, forKey: .nativeChannelCount)
  }
}

/// Atomic result from stopCapture(): audio samples + VAD speech segments.
/// Bundling these together eliminates the ordering dependency between
/// stopCapture() and getVADSegments() across the XPC boundary.
public struct CaptureResult: Sendable {
  public let samples: [Float]
  public let vadSegments: [SpeechSegment]
  /// Capture-health metadata from the active source (#1434); nil on legacy /
  /// unpopulated paths.
  public let metadata: CaptureStopMetadata?
  public init(
    samples: [Float], vadSegments: [SpeechSegment] = [],
    metadata: CaptureStopMetadata? = nil
  ) {
    self.samples = samples
    self.vadSegments = vadSegments
    self.metadata = metadata
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
  /// presence on the next launch means a prior recovery attempt already STARTED
  /// for that spool, so it is abandoned rather than retried (the one-attempt
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

  /// Claude's fixed output-token cap (#1710). The Anthropic API REQUIRES
  /// `max_tokens` (probe-verified: omission is rejected with "max_tokens:
  /// Field required"), so Claude cannot use `.providerDefault`. 8,192 is
  /// generous for polish (output ≈ input length); the value exists only
  /// because the API demands a number, not as a policy ceiling.
  public static let claudeMaxOutputTokens: Int = 8192

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
}

public enum FormattingConstants {
  /// Format a duration in seconds as "m:ss".
  public static func formatDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
