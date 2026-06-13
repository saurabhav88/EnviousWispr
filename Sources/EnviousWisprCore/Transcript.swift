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
  /// Dual-mode polish telemetry (#429). Populated only for AFM polish; nil for
  /// cloud providers and pre-AFM dictations on disk. `polishFellBackToRaw` is
  /// the FINAL pipeline outcome (filter OR validator), not just the filter result.
  public var polishRouterMode: String?
  public var polishRouterBasis: String?
  public var polishFilterTripped: String?
  public var polishFellBackToRaw: Bool?
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
    polishRouterMode: String? = nil,
    polishRouterBasis: String? = nil,
    polishFilterTripped: String? = nil,
    polishFellBackToRaw: Bool? = nil,
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
    self.polishRouterMode = polishRouterMode
    self.polishRouterBasis = polishRouterBasis
    self.polishFilterTripped = polishFilterTripped
    self.polishFellBackToRaw = polishFellBackToRaw
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
    metrics: ExecutionMetrics? = nil
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
  }

  /// The text to display — polished if available, otherwise raw.
  public var displayText: String {
    polishedText ?? text
  }
}

/// Protocol for checking whether live dictation is in progress.
/// Narrow contract injected into services that must guard against concurrent dictation.
@MainActor
public protocol DictationActivityProviding: AnyObject {
  var isDictationActive: Bool { get }
}

/// Error context scoped to a specific transcript enhancement attempt.
/// Lives in Core because it's a simple value type shared between Pipeline and App layers.
public struct EnhancementError: Sendable {
  public let transcriptID: UUID
  public let message: String

  public init(transcriptID: UUID, message: String) {
    self.transcriptID = transcriptID
    self.message = message
  }
}
