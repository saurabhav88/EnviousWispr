import Foundation

/// #3147 PR4: a meeting's notes as blocks (notes v2). The committed `notes.json` is the authority;
/// the Markdown file is its repairable projection. Each block keeps when it was first written in
/// the meeting, so a note can sit beside the moment it was taken.
public struct MeetingNotesDocument: Codable, Equatable, Sendable {
  /// The schema version of this document. `currentVersion` for documents this build writes.
  public var version: Int
  public var blocks: [MeetingNoteBlock]

  public static let currentVersion = 2

  public init(version: Int = MeetingNotesDocument.currentVersion, blocks: [MeetingNoteBlock]) {
    self.version = version
    self.blocks = blocks
  }
}

/// One block of meeting notes.
public struct MeetingNoteBlock: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case text, task, mark, quote
  }

  public var id: UUID
  /// Milliseconds into the meeting when this block was first written; nil when it was written
  /// outside a recording (before, after, or a note migrated from v1 Markdown).
  public var startedAtMs: Int?
  public var kind: Kind
  /// For a task block: whether it is ticked. False for every other kind.
  public var done: Bool
  public var text: String
  /// For a quote block: the speaker the words were taken from.
  public var sourceSpeaker: String?
  /// For a quote block: where in the meeting the quoted words were spoken.
  public var sourceMs: Int?

  public init(
    id: UUID = UUID(), startedAtMs: Int? = nil, kind: Kind = .text, done: Bool = false,
    text: String, sourceSpeaker: String? = nil, sourceMs: Int? = nil
  ) {
    self.id = id
    self.startedAtMs = startedAtMs
    self.kind = kind
    self.done = done
    self.text = text
    self.sourceSpeaker = sourceSpeaker
    self.sourceMs = sourceMs
  }
}
