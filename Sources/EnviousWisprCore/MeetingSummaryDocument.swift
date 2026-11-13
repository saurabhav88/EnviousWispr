import Foundation

/// #3147 PR4 (D5): a structured, versioned meeting summary whose items can point back to the
/// transcript turns or note blocks they came from. Citations here are CANDIDATES; the app shows a
/// link only for an item the validator accepted.
public enum MeetingSummarySource: Codable, Equatable, Sendable {
  case turn(id: String, textSHA256: String)
  case note(blockID: UUID, textSHA256: String)
}

public struct MeetingSummaryCitation: Codable, Equatable, Sendable {
  public let source: MeetingSummarySource
  public let quote: String
  public let rangeUTF16: Range<Int>

  public init(source: MeetingSummarySource, quote: String, rangeUTF16: Range<Int>) {
    self.source = source
    self.quote = quote
    self.rangeUTF16 = rangeUTF16
  }
}

public struct MeetingSummaryItem: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let text: String
  /// Candidates from the model, never permission to show a link.
  public let citations: [MeetingSummaryCitation]

  public init(id: UUID, text: String, citations: [MeetingSummaryCitation]) {
    self.id = id
    self.text = text
    self.citations = citations
  }
}

public struct MeetingSummarySection: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let items: [MeetingSummaryItem]

  public init(id: UUID, title: String, items: [MeetingSummaryItem]) {
    self.id = id
    self.title = title
    self.items = items
  }
}

public struct MeetingSummaryDocument: Codable, Equatable, Sendable {
  public let version: Int
  /// What the summary was written from; the same freshness authority as the Markdown summary.
  public let inputs: SummaryInputs
  /// SHA-256 of the Markdown the user sees, so an edited summary no longer matches its document.
  public let renderedMarkdownSHA256: String
  public let sections: [MeetingSummarySection]

  public static let currentVersion = 1

  public init(
    version: Int = MeetingSummaryDocument.currentVersion, inputs: SummaryInputs,
    renderedMarkdownSHA256: String, sections: [MeetingSummarySection]
  ) {
    self.version = version
    self.inputs = inputs
    self.renderedMarkdownSHA256 = renderedMarkdownSHA256
    self.sections = sections
  }
}
