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
        errorCode: String? = nil
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
