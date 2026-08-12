import EnviousWisprCore
import EnviousWisprFluidAudioBridge
import Foundation

/// #1654: pinned Sentry identity for FluidAudio's raw `SlidingWindowAsrError` (streaming
/// path), built from `FluidAudioStreamingErrorKind` — never from the vendor type directly
/// (see `EnviousWisprFluidAudioBridge`'s naming-trap doc comment). Mirrors
/// `ParakeetTranscriptionSentryError`, which does the same job for the batch path.
///
/// **Every description here is APP-AUTHORED, and that is the deliberate difference from
/// the batch conformer.** The batch kind carries the vendor's `localizedDescription` on
/// every case; the streaming kind carries no vendor text at all, because four of the
/// vendor's seven `errorDescription` cases interpolate text we do not control (three of
/// them an inner error's own description). So the string a reader sees is written here,
/// and the identity is the case.
///
/// **The inner cause rides the `errorCode`, and it has to.** `XPCErrorSanitizer` rebuilds
/// every error crossing the boundary with `userInfo` reduced to exactly one key
/// (`NSLocalizedDescriptionKey`) — that is a stated invariant of that type, not an
/// accident — so domain, code and description are the ONLY channels that survive. The
/// inner cause is the whole diagnostic point of `allWindowsFailed`, and Sentry emission
/// happens app-side after the crossing, so encoding it in the code is what makes it
/// reachable at all. Hence the block allocation below rather than a flat ordinal list.
enum ParakeetStreamingSentryError: Error, LocalizedError, CustomNSError, Sendable, Equatable {
  case modelsNotLoaded
  case streamAlreadyExists
  case audioBufferProcessingFailed
  case audioConversionFailed
  case bufferOverflow
  case invalidConfiguration
  /// Every window failed. `inner` names why when we can name it, and is `nil` when the
  /// wrapped error is not one we recognise — the outer identity stands either way.
  case allWindowsFailed(inner: FluidAudioStreamingInnerCause?)
  /// The streaming session failed to START, where the vendor throws a bare `ASRError`
  /// rather than a `SlidingWindowAsrError`.
  ///
  /// **Correction to the plan, made at build time.** §3 said the start path should use
  /// `classifyFluidAudioASRError` "unchanged", and mapping through that classifier lands
  /// in `ParakeetTranscriptionSentryError`, every one of whose semantic IDs reads
  /// `parakeet_transcribe.*`. A failure to open a stream would then have arrived in
  /// Sentry under a name describing transcription — a reason whose name does not predict
  /// its cause, which is the exact trap `classify-by-producer-not-by-name` exists for.
  /// The plan's instruction is honoured where it is load-bearing (the CLASSIFIER is
  /// reused, so no second vendor switch exists) and the IDENTITY stays in this namespace.
  case startFailed(inner: FluidAudioStreamingInnerCause?)
  case unknownStreamingFailure

  static let errorDomain = "EnviousWisprASR.ParakeetStreamingSentryError"

  /// Pinned code allocation. **Never renumber; append only.** Codes 0-6 are the flat
  /// cases. Code 100 upward is the `allWindowsFailed` block, whose offset carries the
  /// inner cause; 100 itself means "every window failed, cause unrecognised".
  private enum Code {
    static let modelsNotLoaded = 0
    static let streamAlreadyExists = 1
    static let audioBufferProcessingFailed = 2
    static let audioConversionFailed = 3
    static let bufferOverflow = 4
    static let invalidConfiguration = 5
    static let unknownStreamingFailure = 6
    /// `allWindowsFailed` with no recognised inner cause. Recognised causes are
    /// `allWindowsFailedBase + innerOffset`.
    static let allWindowsFailedBase = 100
    /// The block is bounded so that a code from some FUTURE block cannot be misread as
    /// an `allWindowsFailed` with an unknown inner cause. An unbounded `> base` test
    /// would silently absorb every code we later allocate above it — including the
    /// `startFailed` block directly below, which is what makes the bound load-bearing
    /// rather than theoretical.
    static let allWindowsFailedBlockEnd = 199
    /// Same shape, separate block: `startFailed` with no recognised inner cause.
    static let startFailedBase = 200
    static let startFailedBlockEnd = 299
  }

  /// Pinned offset for each inner cause inside the `allWindowsFailed` block.
  /// **Never renumber; append only.** Kept as an explicit switch rather than a raw-value
  /// enum so that adding a vendor case is a compile error here, not a silent shift.
  private static func innerOffset(_ cause: FluidAudioStreamingInnerCause) -> Int {
    switch cause {
    case .notInitialized: return 1
    case .invalidAudioData: return 2
    case .modelLoadFailed: return 3
    case .processingFailed: return 4
    case .modelCompilationFailed: return 5
    case .unsupportedPlatform: return 6
    case .streamingConversionFailed: return 7
    case .fileAccessFailed: return 8
    case .encoderInstantiationFailed: return 9
    case .unknownFutureCase: return 10
    }
  }

  private static func innerCause(fromOffset offset: Int) -> FluidAudioStreamingInnerCause? {
    switch offset {
    case 1: return .notInitialized
    case 2: return .invalidAudioData
    case 3: return .modelLoadFailed
    case 4: return .processingFailed
    case 5: return .modelCompilationFailed
    case 6: return .unsupportedPlatform
    case 7: return .streamingConversionFailed
    case 8: return .fileAccessFailed
    case 9: return .encoderInstantiationFailed
    case 10: return .unknownFutureCase
    default: return nil
    }
  }

  var errorCode: Int {
    switch self {
    case .modelsNotLoaded: return Code.modelsNotLoaded
    case .streamAlreadyExists: return Code.streamAlreadyExists
    case .audioBufferProcessingFailed: return Code.audioBufferProcessingFailed
    case .audioConversionFailed: return Code.audioConversionFailed
    case .bufferOverflow: return Code.bufferOverflow
    case .invalidConfiguration: return Code.invalidConfiguration
    case .unknownStreamingFailure: return Code.unknownStreamingFailure
    case .allWindowsFailed(let inner):
      guard let inner else { return Code.allWindowsFailedBase }
      return Code.allWindowsFailedBase + Self.innerOffset(inner)
    case .startFailed(let inner):
      guard let inner else { return Code.startFailedBase }
      return Code.startFailedBase + Self.innerOffset(inner)
    }
  }

  /// App-authored. No vendor string reaches this.
  var errorDescription: String? {
    switch self {
    case .modelsNotLoaded:
      return "Live transcription could not start: the speech models were not loaded."
    case .streamAlreadyExists:
      return "Live transcription could not start: a stream was already open."
    case .audioBufferProcessingFailed:
      return "Live transcription failed while processing captured audio."
    case .audioConversionFailed:
      return "Live transcription failed while converting captured audio."
    case .bufferOverflow:
      return "Live transcription failed: the audio buffer overflowed."
    case .invalidConfiguration:
      return "Live transcription could not start: the streaming window is misconfigured."
    case .allWindowsFailed(let inner):
      guard let inner else {
        return "Live transcription failed: every audio window failed, cause unrecognised."
      }
      return "Live transcription failed: every audio window failed (\(Self.innerLabel(inner)))."
    case .startFailed(let inner):
      guard let inner else {
        return "Live transcription could not start, for an unrecognised reason."
      }
      return "Live transcription could not start (\(Self.innerLabel(inner)))."
    case .unknownStreamingFailure:
      return "Live transcription failed for an unrecognised reason."
    }
  }

  /// App-authored label for an inner cause. Low cardinality by construction.
  private static func innerLabel(_ cause: FluidAudioStreamingInnerCause) -> String {
    switch cause {
    case .notInitialized: return "engine not initialised"
    case .invalidAudioData: return "invalid audio data"
    case .modelLoadFailed: return "model load failed"
    case .processingFailed: return "processing failed"
    case .modelCompilationFailed: return "model compilation failed"
    case .unsupportedPlatform: return "unsupported platform"
    case .streamingConversionFailed: return "audio conversion failed"
    case .fileAccessFailed: return "file access failed"
    case .encoderInstantiationFailed: return "encoder instantiation failed"
    case .unknownFutureCase: return "unrecognised engine failure"
    }
  }

  /// Same reason as the batch conformer: `CustomNSError`'s default `errorUserInfo` is
  /// empty, and an empty `userInfo` does not survive the XPC archive round-trip with the
  /// description intact — the receiving process falls back to Foundation's generic
  /// "operation couldn't be completed". Baking the description into `userInfo` is what
  /// preserves it.
  var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? ""]
  }

  init(mapping kind: FluidAudioStreamingErrorKind) {
    switch kind {
    case .modelsNotLoaded: self = .modelsNotLoaded
    case .streamAlreadyExists: self = .streamAlreadyExists
    case .audioBufferProcessingFailed: self = .audioBufferProcessingFailed
    case .audioConversionFailed: self = .audioConversionFailed
    case .allWindowsFailed(let inner): self = .allWindowsFailed(inner: inner)
    case .bufferOverflow: self = .bufferOverflow
    case .invalidConfiguration: self = .invalidConfiguration
    case .unknownFutureCase: self = .unknownStreamingFailure
    }
  }

  /// The streaming START path: the vendor throws a bare `ASRError` here, classified into
  /// the same text-free inner vocabulary. A foreign error yields `nil` and the caller
  /// leaves it raw rather than giving it a streaming identity it has not earned.
  init?(mappingStartFailure error: any Error) {
    guard let cause = fluidAudioStreamingInnerCause(error) else { return nil }
    self = .startFailed(inner: cause)
  }

  /// Reconstructs the typed, conforming error from an NSError that survived the XPC
  /// round-trip. Returns `nil` for a foreign domain — a genuinely unrelated XPC-layer
  /// error, which must keep its own identity rather than acquire this one.
  init?(reconstructingFrom error: NSError) {
    guard error.domain == Self.errorDomain else { return nil }
    switch error.code {
    case Code.modelsNotLoaded: self = .modelsNotLoaded
    case Code.streamAlreadyExists: self = .streamAlreadyExists
    case Code.audioBufferProcessingFailed: self = .audioBufferProcessingFailed
    case Code.audioConversionFailed: self = .audioConversionFailed
    case Code.bufferOverflow: self = .bufferOverflow
    case Code.invalidConfiguration: self = .invalidConfiguration
    case Code.unknownStreamingFailure: self = .unknownStreamingFailure
    case Code.allWindowsFailedBase...Code.allWindowsFailedBlockEnd:
      // An offset this build does not know maps to nil rather than to a wrong cause:
      // a newer service reporting a newer inner case must not be read as an older one.
      // (`allWindowsFailedBase` itself yields nil through the same path, since offset 0
      // is deliberately unallocated.)
      self = .allWindowsFailed(
        inner: Self.innerCause(fromOffset: error.code - Code.allWindowsFailedBase))
    case Code.startFailedBase...Code.startFailedBlockEnd:
      self = .startFailed(
        inner: Self.innerCause(fromOffset: error.code - Code.startFailedBase))
    default: return nil
    }
  }
}

extension ParakeetStreamingSentryError: StableSentryErrorIdentity {
  /// **Measured, not reasoned about** (epic protocol, `BIBLE.md` §5), 2026-08-12:
  /// a 90-day Sentry search returns ZERO issues matching "SlidingWindow" or "streaming",
  /// against a working positive control ("Parakeet" returns ENVIOUSWISPR-16). The
  /// mechanism agrees with the search rather than merely failing to contradict it: the
  /// only streaming failure PostHog has ever recorded (one event, one person, 2026-07-30,
  /// v2.4.1) was `result: rescued`, and a rescued failure produces no terminal, hence no
  /// Sentry event.
  ///
  /// So there is no shipped grouping to preserve and these descriptors are free choices
  /// rather than defensive pins. They are app-owned strings for that reason: inventing a
  /// vendor-ordinal-shaped descriptor we have never actually sent would fabricate a
  /// history, which is worse than a clean name. Once shipped they are frozen forever.
  var sentryFingerprintDescriptor: String {
    let base = "EnviousWisprASR.ParakeetStreamingSentryError"
    switch self {
    case .modelsNotLoaded: return "\(base).modelsNotLoaded"
    case .streamAlreadyExists: return "\(base).streamAlreadyExists"
    case .audioBufferProcessingFailed: return "\(base).audioBufferProcessingFailed"
    case .audioConversionFailed: return "\(base).audioConversionFailed"
    case .bufferOverflow: return "\(base).bufferOverflow"
    case .invalidConfiguration: return "\(base).invalidConfiguration"
    case .unknownStreamingFailure: return "\(base).unknownStreamingFailure"
    case .allWindowsFailed(let inner):
      // The inner cause participates in the fingerprint deliberately: separating
      // all-windows-failed-because-processing-failed from
      // all-windows-failed-because-not-initialised is the entire diagnostic value here.
      guard let inner else { return "\(base).allWindowsFailed.unrecognised" }
      return "\(base).allWindowsFailed.\(Self.innerDescriptorToken(inner))"
    case .startFailed(let inner):
      guard let inner else { return "\(base).startFailed.unrecognised" }
      return "\(base).startFailed.\(Self.innerDescriptorToken(inner))"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .modelsNotLoaded: return "parakeet_streaming.models_not_loaded"
    case .streamAlreadyExists: return "parakeet_streaming.stream_already_exists"
    case .audioBufferProcessingFailed: return "parakeet_streaming.audio_buffer_processing_failed"
    case .audioConversionFailed: return "parakeet_streaming.audio_conversion_failed"
    case .bufferOverflow: return "parakeet_streaming.buffer_overflow"
    case .invalidConfiguration: return "parakeet_streaming.invalid_configuration"
    case .unknownStreamingFailure: return "parakeet_streaming.unknown_streaming_failure"
    case .allWindowsFailed(let inner):
      guard let inner else { return "parakeet_streaming.all_windows_failed.unrecognised" }
      return "parakeet_streaming.all_windows_failed.\(Self.innerSemanticToken(inner))"
    case .startFailed(let inner):
      guard let inner else { return "parakeet_streaming.start_failed.unrecognised" }
      return "parakeet_streaming.start_failed.\(Self.innerSemanticToken(inner))"
    }
  }

  /// Pinned descriptor token per inner cause. **Frozen once shipped**, same contract as
  /// the descriptor itself — this is part of the fingerprint, not metadata.
  private static func innerDescriptorToken(_ cause: FluidAudioStreamingInnerCause) -> String {
    switch cause {
    case .notInitialized: return "notInitialized"
    case .invalidAudioData: return "invalidAudioData"
    case .modelLoadFailed: return "modelLoadFailed"
    case .processingFailed: return "processingFailed"
    case .modelCompilationFailed: return "modelCompilationFailed"
    case .unsupportedPlatform: return "unsupportedPlatform"
    case .streamingConversionFailed: return "streamingConversionFailed"
    case .fileAccessFailed: return "fileAccessFailed"
    case .encoderInstantiationFailed: return "encoderInstantiationFailed"
    case .unknownFutureCase: return "unknownFutureCase"
    }
  }

  /// Renameable, unlike the descriptor token above: the semantic ID is metadata and
  /// never enters the fingerprint.
  private static func innerSemanticToken(_ cause: FluidAudioStreamingInnerCause) -> String {
    switch cause {
    case .notInitialized: return "not_initialized"
    case .invalidAudioData: return "invalid_audio_data"
    case .modelLoadFailed: return "model_load_failed"
    case .processingFailed: return "processing_failed"
    case .modelCompilationFailed: return "model_compilation_failed"
    case .unsupportedPlatform: return "unsupported_platform"
    case .streamingConversionFailed: return "streaming_conversion_failed"
    case .fileAccessFailed: return "file_access_failed"
    case .encoderInstantiationFailed: return "encoder_instantiation_failed"
    case .unknownFutureCase: return "unknown_future_case"
    }
  }
}
