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

  public init(notes: Notes? = nil, summary: Summary? = nil) {
    formatVersion = Self.currentFormatVersion
    self.notes = notes
    self.summary = summary
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

    public init(sha256: String, origin: Origin, inputs: SummaryInputs?) {
      self.sha256 = sha256
      self.origin = origin
      self.inputs = inputs
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

  public init(
    transcriptSHA256: String, notesRevision: Int, speakerNamesSHA256: String, promptVersion: Int,
    providerID: String, configurationSHA256: String
  ) {
    self.transcriptSHA256 = transcriptSHA256
    self.notesRevision = notesRevision
    self.speakerNamesSHA256 = speakerNamesSHA256
    self.promptVersion = promptVersion
    self.providerID = providerID
    self.configurationSHA256 = configurationSHA256
  }
}

public enum MeetingDocumentHash {
  /// Lowercase hex SHA-256 of the text's UTF-8 bytes.
  public static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
