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
  /// Meeting-timeline milliseconds when this block's first character was typed:
  /// recording time while recording, or playback position after Stop.
  /// Nil for migrated notes or when no timeline position is available.
  /// Once assigned, later edits do not change it.
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

// MARK: - Markdown projection, migration and whole-text updates (#3147 PR4 lane B)

extension MeetingNoteBlock {
  /// This block's line in `notes.md`: a task as `- [ ] ` or `- [x] `, a quote as `> `, any
  /// other block as its text. Block text holds no line break (Return splits a block).
  public var markdownLine: String {
    switch kind {
    case .text, .mark: return text
    case .task: return (done ? "- [x] " : "- [ ] ") + text
    case .quote: return "> " + text
    }
  }
}

extension MeetingNotesDocument {
  /// The notes as Markdown, one line per block: `notes.md`, the summary's notes input, Save
  /// and Share. Empty when there are no blocks or only one empty text block.
  public var markdown: String { blocks.map(\.markdownLine).joined(separator: "\n") }

  /// A meeting's notes written before notes v2 (`notes.md` alone): one text block per line,
  /// no time (when each was typed is unknown). Lossless: `markdown` gives back the same text,
  /// so migrating never changes what a summary was written from. Empty text has no blocks.
  public init(legacyMarkdown text: String, newID: () -> UUID = { UUID() }) {
    self.init(blocks: Self.lines(text).map { MeetingNoteBlock(id: newID(), text: $0) })
  }

  /// The text split into lines at line feeds, every line kept (a trailing line feed is a last
  /// empty line); no lines for empty text. Split by scalar, not by `Character`: Swift reads CR LF
  /// as one character, which a character split would leave inside a line.
  static func lines(_ text: String) -> [String] {
    text.isEmpty
      ? []
      : text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        .map { String(String.UnicodeScalarView($0)) }
  }

  /// The notes after the whole Markdown text was replaced (the plain notes box, which edits one
  /// string). Lines that did not change keep their block, id and time; changed lines in between
  /// keep the block at their position (its id, kind and time); added lines become new blocks,
  /// which start at `atMs` once they hold text. A block's time, once set, never changes.
  public func replacingMarkdown(
    _ text: String, atMs: Int?, newID: () -> UUID = { UUID() }
  ) -> MeetingNotesDocument {
    let old = blocks.map(\.markdownLine)
    let new = Self.lines(text)
    var prefix = 0
    while prefix < old.count, prefix < new.count,
      MeetingDocumentHash.sameBytes(old[prefix], new[prefix])
    {
      prefix += 1
    }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix,
      MeetingDocumentHash.sameBytes(old[old.count - 1 - suffix], new[new.count - 1 - suffix])
    {
      suffix += 1
    }
    let oldMiddle = blocks[prefix..<(old.count - suffix)]
    let newMiddle = new[prefix..<(new.count - suffix)]
    var middle: [MeetingNoteBlock] = []
    for (offset, line) in newMiddle.enumerated() {
      let index = oldMiddle.startIndex + offset
      if index < oldMiddle.endIndex {
        middle.append(oldMiddle[index].replacingLine(line, atMs: atMs))
      } else {
        middle.append(
          MeetingNoteBlock(id: newID(), startedAtMs: line.isEmpty ? nil : atMs, text: line))
      }
    }
    return MeetingNotesDocument(
      version: version,
      blocks: Array(blocks[..<prefix]) + middle + Array(blocks[(old.count - suffix)...]))
  }
}

extension MeetingNoteBlock {
  /// This block holding `line`, its Markdown line: a task or quote keeps its kind while the
  /// line keeps the marker, and becomes text when the marker was removed.
  func replacingLine(_ line: String, atMs: Int?) -> MeetingNoteBlock {
    var next = self
    switch kind {
    case .task where line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] "):
      next.done = line.hasPrefix("- [x] ")
      next.text = String(line.dropFirst(6))
    case .quote where line.hasPrefix("> "):
      next.text = String(line.dropFirst(2))
    case .task, .quote:
      next.kind = .text
      next.done = false
      next.text = line
    case .text, .mark:
      next.text = line
    }
    return next.typed(after: self, atMs: atMs)
  }

  /// Sets the block's time when its first character was just typed (it held no text and had no
  /// time); a time once set, or a block migrated with text, keeps what it had.
  func typed(after before: MeetingNoteBlock, atMs: Int?) -> MeetingNoteBlock {
    var next = self
    if next.startedAtMs == nil, before.text.isEmpty, !next.text.isEmpty {
      next.startedAtMs = atMs
    }
    return next
  }
}
