import Foundation

/// Execution metrics produced by the pipeline — facts the heart reports.
/// Telemetry, diagnostics, debug UI, and exports all consume the same data.
public struct ExecutionMetrics: Codable, Sendable {
  public var asrLatencySeconds: Double?
  public var llmLatencySeconds: Double?
  public var pasteTier: String?
  public var pasteLatencyMs: Int?
  /// Cursor-aware insertion (#1785, extended by #1921 and #1980). All eight are
  /// optional and additive, so a transcript written before any of these features
  /// decodes with them nil rather than failing. Shapes and closed-set names only — a wrong-case report carries no
  /// text, and these are what make it answerable:
  ///
  /// - `smartInsertionEnabled`: the setting as frozen for that recording,
  ///   separating "off" from "on but it could not act".
  /// - `caretContextOutcome`: `setting_off` / `no_target` / `unreadable` /
  ///   `read` — where the feature stopped, if it stopped early.
  /// - `repairRules`: the rules the repair proposed, comma-joined
  ///   (`leading_space,case_skipped:not_ordinary_word`). The reason travels
  ///   without the word it applied to.
  /// - `pastePayloadKind`: `legacy` / `repaired`, or nil when no route reached a
  ///   write. What was SUBMITTED, never proof of what landed.
  /// - `languageResolutionSource` / `languageConfidenceBucket` (#1921): WHY the
  ///   language question got the answer it did — `locked` / `engine` /
  ///   `dictation` / `document` / `none`, and a confidence band. Without them
  ///   `case_skipped:language_not_supported` looks identical whether the user
  ///   locked a language, the engine reported one, or the recogniser was unsure.
  ///
  ///   Both stay OPTIONAL, and nil is not the same as `"none"`: `"none"` means
  ///   the app measured and found nothing, nil means the fact was never
  ///   recorded — which is every transcript written before #1921.
  ///
  ///   `public` is required, not preferred: `ExecutionMetrics` is the existing
  ///   public carrier across Core -> Pipeline and Core -> Services.
  public var smartInsertionEnabled: Bool?
  public var caretContextOutcome: String?
  /// #1980. `caretCaptureRetried` is `nil` when this delivery never recorded
  /// the fact (an older transcript, or auto-paste never entered), `false`
  /// when it recorded that no delivery-time retry was needed or possible, and
  /// `true` when a retry was ATTEMPTED — independent of whether it recovered
  /// an element. Combine with `caretContextOutcome` to distinguish "retried
  /// and still nothing" from "retried and recovered". `caretCaptureRetryMs`
  /// is present only when `caretCaptureRetried == true`.
  public var caretCaptureRetried: Bool?
  public var caretCaptureRetryMs: Double?
  public var repairRules: String?
  public var pastePayloadKind: String?
  public var languageResolutionSource: String?
  public var languageConfidenceBucket: String?
  public var targetApp: String?
  public var coldStart: Bool
  public var streamingMode: Bool
  public var e2eSeconds: Double?
  public var errorStage: String?
  public var errorCode: String?
  /// AFM polish telemetry (#429; single-prompt since #1072). Populated only for
  /// AFM polish; nil for cloud providers and pre-AFM dictations on disk.
  /// `polishFellBackToRaw` is the FINAL pipeline outcome (filter OR validator),
  /// not just the filter result.
  public var polishFilterTripped: String?
  public var polishFellBackToRaw: Bool?
  /// #1050 honest disaggregation of `polishFellBackToRaw`. Populated for AFM
  /// polish (nil for cloud / pre-#1050 records) and for the #1358 empty-output
  /// recovery (any provider); nil also when polish CHANGED the text (not a
  /// fallback). `no_change` (benign — model returned input unchanged),
  /// `guard_discard` (`EnviousOutputFilter` caught bad output),
  /// `validator_discard` (`validatePolishOutput` caught bad output — invisible to
  /// `polishFilterTripped`), or `empty_output_floor` (#1358 — the limb chain
  /// produced empty text and the wiring delivered a deterministic raw floor).
  /// Invariant: present iff `polishFellBackToRaw == true`.
  public var polishFallbackReason: String?
  /// Deterministic ITN telemetry (#145). Populated per dictation; nil on
  /// pre-#145 transcripts on disk (additive optional Codable, back-compatible).
  /// `itnFloorDelivered` = ITN changed the text AND polish did not deliver a
  /// distinct polished result (disabled/unavailable/rejected) — the user got the
  /// raw-fallback floor. Metadata only (`telemetry-privacy-boundary`).
  public var itnRan: Bool?
  public var itnChanged: Bool?
  public var itnFloorDelivered: Bool?
  public var itnSkipReason: String?
  public var itnLatencyMs: Double?
  public var itnLenBefore: Int?
  public var itnLenAfter: Int?
  /// #950 tail-trim diagnostic. Populated only for eligible Parakeet batch
  /// successes; nil for streaming, WhisperKit, non-success, and pre-#950
  /// transcripts on disk (additive optional Codable, back-compatible).
  /// `tailDroppedMs` = trailing audio (ms) the VAD trim discarded after the last
  /// detected word (0 = ran, nothing dropped). `tailHadEnergy` = that discarded
  /// tail was above the dead-air floor (non-dead-air energy, NOT confirmed voice);
  /// nil when `tailDroppedMs == 0` (no tail slice). Metadata only.
  public var tailDroppedMs: Int?
  public var tailHadEnergy: Bool?
  /// #950 tail-preserve recovery + tuning signals. Populated only for eligible
  /// Parakeet batch; nil for streaming / WhisperKit / non-success / pre-#950
  /// transcripts on disk (additive optional Codable, back-compatible).
  /// `usedTailPreservation`: nil=ineligible, false=eligible-not-preserved,
  /// true=recovered a sustained-voice dropped tail. `recoveredTailMs`: ms appended
  /// back on a fire. `tailVoicedFraction`: sustained-voice ratio [0,1] of the
  /// dropped tail. `tailRefusedReason`: why an eligible tail was refused
  /// (too_short/too_long/low_voiced_fraction/not_filtered/no_tail). Metadata only.
  public var usedTailPreservation: Bool?
  public var recoveredTailMs: Int?
  public var tailVoicedFraction: Double?
  public var tailRefusedReason: String?
  /// #1232 tail-clip telemetry (recalibrated #1236): release-safe classifier + lead
  /// signals carried onto `asr.completed`. Numbers/booleans only — no audio or text.
  /// All optional (additive Codable, back-compatible with pre-#1232 transcripts on
  /// disk). `tailClipClassification` = asr_complete / suspected_asr_drop / unknown.
  /// `asrLastTokenGapMs` = untranscribed tail on the decoded timeline (headline
  /// ASR-drop metric).
  public var tailClipClassification: String?
  public var captureTrailingSilenceMs: Int?
  public var captureTail200Rms: Double?
  public var captureTail200Peak: Double?
  public var asrInputDurationMs: Int?
  public var asrLastTokenEndMs: Int?
  public var asrLastTokenGapMs: Int?
  public var asrChunked: Bool?
  /// Deterministic post-polish emoji-restore telemetry (#761). Populated for the RESTORING
  /// paths only: Apple on-device (AFM) polish, and local Ollama on the fixed L3 prompt since
  /// #1948. Nil for cloud providers, hosted Ollama, EG-1, no-polish dictations, and pre-#761
  /// transcripts on disk (additive optional Codable, back-compatible).
  /// `emojiInInput` = emoji the converter inserted pre-polish; `emojiDropped` =
  /// glyphs the polish model stripped (Apple Intelligence, or Ollama since #1948);
  /// `emojiRestored` = glyphs the guard re-inserted (== dropped
  /// by construction); `emojiRestoreIncomplete` = restored < dropped (anomaly).
  /// Counts only (`telemetry-privacy-boundary`).
  public var emojiInInput: Int?
  public var emojiDropped: Int?
  public var emojiRestored: Int?
  public var emojiRestoreIncomplete: Bool?
  public var emojiLatencyMs: Double?
  /// #1309 effective-path streaming telemetry (WhisperKit only; nil for
  /// Parakeet and pre-#1309 transcripts on disk — additive optional Codable,
  /// back-compatible). `streamingMode` above is the REQUESTED mode (kernel
  /// capability gate); these describe what actually ran. Metadata only.
  /// `streamingDegradeReason` = none / disabled / auto_language /
  /// model_not_ready / flush_empty / flush_throw. `streamingFinalPath` =
  /// streaming_flush / clean_batch / fallback_batch / failed.
  public var streamingEffective: Bool?
  public var streamingDegradeReason: String?
  public var streamingFinalPath: String?
  public var streamingDecodeCount: Int?
  public var streamingCoveredSec: Double?
  public var tailDecodeSec: Double?
  public var maxUnconfirmedWindowSec: Double?
  public var stopWhileDecodeInFlight: Bool?
  /// #1914: whether a SUCCESSFUL Ollama polish ran on Ollama's servers rather
  /// than on this Mac. Nil for every other case — non-Ollama providers, failed
  /// or skipped polish, and pre-#1914 transcripts on disk (additive optional
  /// Codable, back-compatible). Metadata only: this is a boolean about where the
  /// model ran, never the `remote_host` value the daemon reported.
  ///
  /// `false` means the daemon did not report this model as remote. It is not an
  /// independent proof of local execution, and telemetry must not read it as one.
  public var polishRanRemote: Bool?

  public init(
    asrLatencySeconds: Double? = nil,
    llmLatencySeconds: Double? = nil,
    pasteTier: String? = nil,
    pasteLatencyMs: Int? = nil,
    smartInsertionEnabled: Bool? = nil,
    caretContextOutcome: String? = nil,
    caretCaptureRetried: Bool? = nil,
    caretCaptureRetryMs: Double? = nil,
    repairRules: String? = nil,
    pastePayloadKind: String? = nil,
    languageResolutionSource: String? = nil,
    languageConfidenceBucket: String? = nil,
    targetApp: String? = nil,
    coldStart: Bool = false,
    streamingMode: Bool = false,
    e2eSeconds: Double? = nil,
    errorStage: String? = nil,
    errorCode: String? = nil,
    polishFilterTripped: String? = nil,
    polishFellBackToRaw: Bool? = nil,
    polishFallbackReason: String? = nil,
    itnRan: Bool? = nil,
    itnChanged: Bool? = nil,
    itnFloorDelivered: Bool? = nil,
    itnSkipReason: String? = nil,
    itnLatencyMs: Double? = nil,
    itnLenBefore: Int? = nil,
    itnLenAfter: Int? = nil,
    tailDroppedMs: Int? = nil,
    tailHadEnergy: Bool? = nil,
    usedTailPreservation: Bool? = nil,
    recoveredTailMs: Int? = nil,
    tailVoicedFraction: Double? = nil,
    tailRefusedReason: String? = nil,
    tailClipClassification: String? = nil,
    captureTrailingSilenceMs: Int? = nil,
    captureTail200Rms: Double? = nil,
    captureTail200Peak: Double? = nil,
    asrInputDurationMs: Int? = nil,
    asrLastTokenEndMs: Int? = nil,
    asrLastTokenGapMs: Int? = nil,
    asrChunked: Bool? = nil,
    emojiInInput: Int? = nil,
    emojiDropped: Int? = nil,
    emojiRestored: Int? = nil,
    emojiRestoreIncomplete: Bool? = nil,
    emojiLatencyMs: Double? = nil,
    streamingEffective: Bool? = nil,
    streamingDegradeReason: String? = nil,
    streamingFinalPath: String? = nil,
    streamingDecodeCount: Int? = nil,
    streamingCoveredSec: Double? = nil,
    tailDecodeSec: Double? = nil,
    maxUnconfirmedWindowSec: Double? = nil,
    stopWhileDecodeInFlight: Bool? = nil,
    polishRanRemote: Bool? = nil
  ) {
    self.asrLatencySeconds = asrLatencySeconds
    self.llmLatencySeconds = llmLatencySeconds
    self.pasteTier = pasteTier
    self.pasteLatencyMs = pasteLatencyMs
    self.smartInsertionEnabled = smartInsertionEnabled
    self.caretContextOutcome = caretContextOutcome
    self.caretCaptureRetried = caretCaptureRetried
    self.caretCaptureRetryMs = caretCaptureRetryMs
    self.repairRules = repairRules
    self.pastePayloadKind = pastePayloadKind
    self.languageResolutionSource = languageResolutionSource
    self.languageConfidenceBucket = languageConfidenceBucket
    self.targetApp = targetApp
    self.coldStart = coldStart
    self.streamingMode = streamingMode
    self.e2eSeconds = e2eSeconds
    self.errorStage = errorStage
    self.errorCode = errorCode
    self.polishFilterTripped = polishFilterTripped
    self.polishFellBackToRaw = polishFellBackToRaw
    self.polishFallbackReason = polishFallbackReason
    self.itnRan = itnRan
    self.itnChanged = itnChanged
    self.itnFloorDelivered = itnFloorDelivered
    self.itnSkipReason = itnSkipReason
    self.itnLatencyMs = itnLatencyMs
    self.itnLenBefore = itnLenBefore
    self.itnLenAfter = itnLenAfter
    self.tailDroppedMs = tailDroppedMs
    self.tailHadEnergy = tailHadEnergy
    self.usedTailPreservation = usedTailPreservation
    self.recoveredTailMs = recoveredTailMs
    self.tailVoicedFraction = tailVoicedFraction
    self.tailRefusedReason = tailRefusedReason
    self.tailClipClassification = tailClipClassification
    self.captureTrailingSilenceMs = captureTrailingSilenceMs
    self.captureTail200Rms = captureTail200Rms
    self.captureTail200Peak = captureTail200Peak
    self.asrInputDurationMs = asrInputDurationMs
    self.asrLastTokenEndMs = asrLastTokenEndMs
    self.asrLastTokenGapMs = asrLastTokenGapMs
    self.asrChunked = asrChunked
    self.emojiInInput = emojiInInput
    self.emojiDropped = emojiDropped
    self.emojiRestored = emojiRestored
    self.emojiRestoreIncomplete = emojiRestoreIncomplete
    self.emojiLatencyMs = emojiLatencyMs
    self.streamingEffective = streamingEffective
    self.streamingDegradeReason = streamingDegradeReason
    self.streamingFinalPath = streamingFinalPath
    self.streamingDecodeCount = streamingDecodeCount
    self.streamingCoveredSec = streamingCoveredSec
    self.tailDecodeSec = tailDecodeSec
    self.maxUnconfirmedWindowSec = maxUnconfirmedWindowSec
    self.stopWhileDecodeInFlight = stopWhileDecodeInFlight
    self.polishRanRemote = polishRanRemote
  }
}

/// A completed transcript with metadata.
public struct Transcript: Codable, Identifiable, Sendable {
  public let id: UUID
  public let text: String
  public let polishedText: String?
  public let language: String?
  public let duration: TimeInterval
  public let processingTime: TimeInterval
  public let backendType: ASRBackendType
  public let createdAt: Date
  public let llmProvider: String?
  public let llmModel: String?
  public var metrics: ExecutionMetrics?
  /// Links a transcript to its crash-recovery spool (the durable kernel
  /// `SessionID`). On a live transcript it lets the recovery scan dedup — a
  /// spool whose id already appears in History is deleted, never re-transcribed.
  /// On a recovered transcript it records which spool produced it. Optional for
  /// decode-safety: pre-#1063 JSON has no key and decodes to nil (synthesized
  /// Codable, no custom decode). #1063.
  public let recoverySessionID: String?
  /// True when this transcript was reconstructed from a recovered recording
  /// after an abnormal exit — drives the History "Recovered" badge. Optional so
  /// legacy JSON decodes to nil (treated as not-recovered). #1063.
  public let isRecovered: Bool?
  /// True when this recording's input device was VERIFIED REMOVED mid-recording
  /// (`EngineInterruptionCause.isDeviceLoss`) and this transcript is what
  /// survived — drives the History "Interrupted" badge (a crossed-out mic, so it
  /// takes the strictest predicate: the icon must never claim a removal that was
  /// not verified). `false` covers both normal takes and takes interrupted by a
  /// non-removal cause; `nil` means unknown, which is what a spool-recovered
  /// transcript gets (the spool records why the WRITER exited, not why the
  /// recording ended). Optional so pre-#1408 JSON decodes to nil (synthesized
  /// `Codable`, no custom decode). #1408; renamed from `isInterrupted` pre-ship
  /// (grounded review: the old name promised every interruption while the value
  /// carried one).
  public let inputDeviceWasRemoved: Bool?

  public init(
    id: UUID = UUID(),
    text: String,
    polishedText: String? = nil,
    language: String? = nil,
    duration: TimeInterval = 0,
    processingTime: TimeInterval = 0,
    backendType: ASRBackendType = .parakeet,
    createdAt: Date = Date(),
    llmProvider: String? = nil,
    llmModel: String? = nil,
    metrics: ExecutionMetrics? = nil,
    recoverySessionID: String? = nil,
    isRecovered: Bool? = nil,
    inputDeviceWasRemoved: Bool? = nil
  ) {
    self.id = id
    self.text = text
    self.polishedText = polishedText
    self.language = language
    self.duration = duration
    self.processingTime = processingTime
    self.backendType = backendType
    self.createdAt = createdAt
    self.llmProvider = llmProvider
    self.llmModel = llmModel
    self.metrics = metrics
    self.recoverySessionID = recoverySessionID
    self.isRecovered = isRecovered
    self.inputDeviceWasRemoved = inputDeviceWasRemoved
  }

  /// The text to display — polished if available, otherwise raw.
  public var displayText: String {
    polishedText ?? text
  }
}
