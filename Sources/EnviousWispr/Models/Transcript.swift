import Foundation

/// A completed transcript with metadata.
struct Transcript: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let polishedText: String?
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let backendType: ASRBackendType
    let createdAt: Date
    var isFavorite: Bool
    let llmProvider: String?
    let llmModel: String?

    init(
        id: UUID = UUID(),
        text: String,
        polishedText: String? = nil,
        language: String? = nil,
        duration: TimeInterval = 0,
        processingTime: TimeInterval = 0,
        backendType: ASRBackendType = .parakeet,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
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
        self.isFavorite = isFavorite
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    /// The text to display — polished if available, otherwise raw.
    var displayText: String {
        polishedText ?? text
    }
}
