import CryptoKit
import Foundation

/// The user's notes and the meeting summary that live beside `meeting.json` (#3972 R46, R53):
/// `notes.md`, `summary.md` and `documents.json`, which records each document's revision and
/// hash. The Markdown files are the user's text; `documents.json` only describes them, so a
/// disagreement is always settled in favour of the file.
public struct MeetingDocumentsManifest: Sendable, Equatable, Codable {
  public static let currentFormatVersion = 1

  public var formatVersion: Int
  public var notes: Notes?
  public var summary: Summary?
  /// A summary the app owes this meeting (#3972 R50): set when one is scheduled, cleared when
  /// its attempt ends, so a relaunch finishes a summary a quit interrupted. Nil and false mean
  /// none is owed. Optional, so a manifest written before this field decodes unchanged.
  public var summaryPending: Bool?

  public init(notes: Notes? = nil, summary: Summary? = nil, summaryPending: Bool? = nil) {
    formatVersion = Self.currentFormatVersion
    self.notes = notes
    self.summary = summary
    self.summaryPending = summaryPending
  }

  public struct Notes: Sendable, Equatable, Codable {
    /// Counts every saved change, so a summary can name the notes it was written from.
    public var revision: Int
    public var sha256: String

    public init(revision: Int, sha256: String) {
      self.revision = revision
      self.sha256 = sha256
    }
  }

  public struct Summary: Sendable, Equatable, Codable {
    public var sha256: String
    public var origin: Origin
    /// What a generated summary was written from; nil for a summary the user wrote from scratch.
    public var inputs: SummaryInputs?
    /// Whether the generation this text came from summarized in parts (#4044); edits keep it.
    /// Nil when unknown: no inputs, or a file written before this field.
    public var writtenInParts: Bool?

    public init(
      sha256: String, origin: Origin, inputs: SummaryInputs?, writtenInParts: Bool? = nil
    ) {
      self.sha256 = sha256
      self.origin = origin
      self.inputs = inputs
      self.writtenInParts = writtenInParts
    }
  }

  public enum Origin: String, Sendable, Equatable, Codable {
    case generated
    /// The user changed the text; "Write again" asks before replacing it.
    case userEdited
  }
}

/// Everything a generated summary depends on (#3972 R46). A result whose inputs no longer match
/// the meeting is never published, and a summary whose inputs differ is shown as out of date.
public struct SummaryInputs: Sendable, Equatable, Codable {
  public var transcriptSHA256: String
  public var notesRevision: Int
  public var speakerNamesSHA256: String
  public var promptVersion: Int
  public var providerID: String
  /// SHA-256 of the canonical provider configuration the summary was written with (model,
  /// endpoint, generation options; never key bytes), so a model or option change makes the
  /// summary out of date (Codex C7 r1). Built by the summary seam (C12). Nil in a manifest
  /// written before this field existed: the configuration is unknown, so that summary is out
  /// of date (it never equals a current fingerprint).
  public var configurationSHA256: String?
  /// #3973 C2: the transcript attempt the summary was written from, so a Transcribe again makes
  /// a generated summary out of date even when its words come out identical. Nil for a summary
  /// written from a transcript made before attempts (or before this field).
  public var transcriptAttemptID: UUID?
  /// #4286: SHA-256 of the meeting facts block the summary was told (window-independent), so a
  /// changed fact makes a generated summary out of date. Nil when no facts were known, and in a
  /// manifest written before this field.
  public var contextSHA256: String?

  public init(
    transcriptSHA256: String, notesRevision: Int, speakerNamesSHA256: String, promptVersion: Int,
    providerID: String, configurationSHA256: String, transcriptAttemptID: UUID? = nil,
    contextSHA256: String? = nil
  ) {
    self.transcriptSHA256 = transcriptSHA256
    self.notesRevision = notesRevision
    self.speakerNamesSHA256 = speakerNamesSHA256
    self.promptVersion = promptVersion
    self.providerID = providerID
    self.configurationSHA256 = configurationSHA256
    self.transcriptAttemptID = transcriptAttemptID
    self.contextSHA256 = contextSHA256
  }
}

public enum MeetingDocumentHash {
  /// Lowercase hex SHA-256 of the text's UTF-8 bytes.
  public static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Whether two texts have the same UTF-8 bytes, the question a kept hash must ask before it
  /// is reused (#4001). `==` is not it: Swift treats canonically equivalent strings as equal
  /// ("\u{00E9}" and "e\u{0301}"), and their hashes differ.
  public static func sameBytes(_ a: String, _ b: String) -> Bool {
    // One memory compare over the contiguous UTF-8 storage (#4001 H10): a byte-by-byte
    // `elementsEqual` walk cost more than rendering a 600-turn document in a Debug build.
    // `withUTF8` copies only a string that is not already contiguous UTF-8, so the inputs
    // are taken as local copies.
    guard a.utf8.count == b.utf8.count else { return false }
    var a = a
    var b = b
    return a.withUTF8 { x in
      b.withUTF8 { y in
        x.count == 0 || x.baseAddress == y.baseAddress
          || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0
      }
    }
  }

  /// The same question for a key-to-value map, every key and value compared by bytes.
  public static func sameBytes(_ a: [String: String], _ b: [String: String]) -> Bool {
    guard a.count == b.count else { return false }
    func ordered(_ m: [String: String]) -> [(key: String, value: String)] {
      m.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }
    return zip(ordered(a), ordered(b)).allSatisfy { x, y in
      sameBytes(x.key, y.key) && sameBytes(x.value, y.value)
    }
  }
}
