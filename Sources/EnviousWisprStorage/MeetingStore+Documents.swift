import EnviousWisprCore
import Foundation

/// The meeting's notes and summary files (#3972 R46, R53). They sit at the folder root, so
/// Delete audio (which removes the segment files and `work/`) keeps them and Delete meeting
/// removes them with the folder.
///
/// Every write checks first that the meeting still exists, is not being deleted, and was not
/// written by a newer build, so a late write never recreates a deleted meeting. Order: the
/// Markdown file, then `documents.json`; a crash between the two leaves a file whose hash
/// disagrees, and `loadDocuments` settles that in favour of the file.
extension MeetingStore {
  public static let notesFileName = "notes.md"
  public static let summaryFileName = "summary.md"
  public static let documentsFileName = "documents.json"

  public enum DocumentError: Error, Equatable {
    /// The meeting's folder or `meeting.json` is gone.
    case meetingMissing
    /// The meeting is marked for deletion.
    case meetingDeleting
    /// A newer build wrote the meeting or its `documents.json`.
    case newerFormat
  }

  /// What is on disk, settled: the Markdown files as written, and a manifest that agrees with
  /// them. `repaired` is true when the manifest had to change to agree; the caller saves it.
  public struct LoadedDocuments: Sendable, Equatable {
    public var notes: String
    public var summary: String?
    public var manifest: MeetingDocumentsManifest
    public var repaired: Bool
  }

  public func notesURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.notesFileName)
  }

  public func summaryURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.summaryFileName)
  }

  public func documentsURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.documentsFileName)
  }

  /// Reads the documents and reconciles them (#3972 R53). Notes whose hash disagrees with the
  /// manifest are the newest notes: their revision goes up, which makes a summary written from
  /// older notes out of date. A summary whose hash disagrees counts as the user's own text.
  public func loadDocuments(meeting id: UUID) throws -> LoadedDocuments {
    var manifest = try currentManifest(id)
    let notes = try Self.readText(notesURL(for: id)) ?? ""
    let summary = try Self.readText(summaryURL(for: id))
    var repaired = false

    let notesHash = MeetingDocumentHash.sha256(notes)
    // No notes and no entry agree; anything else that differs is newer notes.
    if manifest.notes?.sha256 != notesHash, !(notes.isEmpty && manifest.notes == nil) {
      manifest.notes = MeetingDocumentsManifest.Notes(
        revision: (manifest.notes?.revision ?? 0) + 1, sha256: notesHash)
      repaired = true
    }

    if let summary {
      let summaryHash = MeetingDocumentHash.sha256(summary)
      if manifest.summary?.sha256 != summaryHash {
        manifest.summary = MeetingDocumentsManifest.Summary(
          sha256: summaryHash, origin: .userEdited, inputs: manifest.summary?.inputs)
        repaired = true
      }
    } else if manifest.summary != nil {
      manifest.summary = nil
      repaired = true
    }
    return LoadedDocuments(
      notes: notes, summary: summary, manifest: manifest, repaired: repaired)
  }

  /// Saves the notes at `revision`, then the manifest. Empty notes remove `notes.md`. The rest
  /// of the manifest is read from disk here, on the one file queue, so a notes save never
  /// overwrites a summary entry written after the caller last read it.
  public func saveNotes(_ text: String, revision: Int, meeting id: UUID) throws
    -> MeetingDocumentsManifest
  {
    try refuseDocumentWrite(id)
    var next = try currentManifest(id)
    next.notes = MeetingDocumentsManifest.Notes(
      revision: revision, sha256: MeetingDocumentHash.sha256(text))
    if text.isEmpty {
      if FileManager.default.fileExists(atPath: notesURL(for: id).path) {
        try FileManager.default.removeItem(at: notesURL(for: id))
      }
    } else {
      try Self.atomicWrite(Data(text.utf8), to: notesURL(for: id))
    }
    try saveManifest(next, meeting: id)
    return next
  }

  /// Saves the summary text with its origin and inputs, then the manifest (its notes entry read
  /// from disk, as `saveNotes` does for the summary).
  public func saveSummary(
    _ text: String, origin: MeetingDocumentsManifest.Origin, inputs: SummaryInputs?,
    meeting id: UUID
  ) throws -> MeetingDocumentsManifest {
    try refuseDocumentWrite(id)
    var next = try currentManifest(id)
    next.summary = MeetingDocumentsManifest.Summary(
      sha256: MeetingDocumentHash.sha256(text), origin: origin, inputs: inputs)
    try Self.atomicWrite(Data(text.utf8), to: summaryURL(for: id))
    try saveManifest(next, meeting: id)
    return next
  }

  /// `documents.json` as on disk, or an empty manifest when there is none.
  private func currentManifest(_ id: UUID) throws -> MeetingDocumentsManifest {
    guard FileManager.default.fileExists(atPath: documentsURL(for: id).path) else {
      return MeetingDocumentsManifest()
    }
    let manifest = try Self.decoder.decode(
      MeetingDocumentsManifest.self, from: Data(contentsOf: documentsURL(for: id)))
    guard manifest.formatVersion <= MeetingDocumentsManifest.currentFormatVersion else {
      throw DocumentError.newerFormat
    }
    return manifest
  }

  /// Writes a manifest `loadDocuments` repaired.
  public func saveManifest(_ manifest: MeetingDocumentsManifest, meeting id: UUID) throws {
    try refuseDocumentWrite(id)
    try Self.atomicWrite(try Self.encoder.encode(manifest), to: documentsURL(for: id))
  }

  private func refuseDocumentWrite(_ id: UUID) throws {
    guard FileManager.default.fileExists(atPath: recordURL(for: id).path) else {
      throw DocumentError.meetingMissing
    }
    if let header = try? header(id: id), header.formatVersion > MeetingRecord.currentFormatVersion {
      throw DocumentError.newerFormat
    }
    let record: MeetingRecord
    do {
      record = try load(id: id)
    } catch {
      throw DocumentError.meetingMissing
    }
    guard !record.deletionRequested else { throw DocumentError.meetingDeleting }
  }

  /// The file's UTF-8 text, or nil when it does not exist.
  private static func readText(_ url: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
  }
}
