import Foundation

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
        llmModel: String? = nil
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
    }

    /// The text to display — polished if available, otherwise raw.
    public var displayText: String {
        polishedText ?? text
    }
}
