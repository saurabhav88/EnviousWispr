import Foundation

/// Execution metrics produced by the pipeline — facts the heart reports.
/// Telemetry, diagnostics, debug UI, and exports all consume the same data.
public struct ExecutionMetrics: Codable, Sendable {
  public var asrLatencySeconds: Double?
  public var llmLatencySeconds: Double?
  public var pasteTier: String?
  public var pasteLatencyMs: Int?
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
  /// #1050 honest disaggregation of `polishFellBackToRaw`. Populated only for AFM
  /// polish (nil for cloud / pre-#1050 records); nil also when polish CHANGED the
  /// text (not a fallback). `no_change` (benign — model returned input unchanged),
  /// `guard_discard` (`EnviousOutputFilter` caught bad output), or
  /// `validator_discard` (`validatePolishOutput` caught bad output — invisible to
  /// `polishFilterTripped`). Invariant: present iff `polishFellBackToRaw == true`.
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

  public init(
    asrLatencySeconds: Double? = nil,
    llmLatencySeconds: Double? = nil,
    pasteTier: String? = nil,
    pasteLatencyMs: Int? = nil,
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
    tailRefusedReason: String? = nil
  ) {
    self.asrLatencySeconds = asrLatencySeconds
    self.llmLatencySeconds = llmLatencySeconds
    self.pasteTier = pasteTier
    self.pasteLatencyMs = pasteLatencyMs
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
    isRecovered: Bool? = nil
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
  }

  /// The text to display — polished if available, otherwise raw.
  public var displayText: String {
    polishedText ?? text
  }
}
