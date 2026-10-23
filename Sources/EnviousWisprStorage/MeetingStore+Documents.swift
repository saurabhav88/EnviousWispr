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
  /// them. `repaired` is true when the manifest had to change to agree; `loadDocuments` has
  /// then already written it, in the same call.
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
  /// A repaired manifest is written in this same call (one file-queue operation), so no other
  /// document write can land between the read and the repair. A meeting that refuses writes
  /// (deleting, gone, newer) is returned as read, unrepaired on disk.
  public func loadDocuments(meeting id: UUID) throws -> LoadedDocuments {
    var loaded = try readDocuments(meeting: id)
    if loaded.repaired {
      do {
        try writeManifest(loaded.manifest, meeting: id)
      } catch let error as DocumentError where error != .newerFormat {
        loaded.repaired = false
      }
    }
    return loaded
  }

  private func readDocuments(meeting id: UUID) throws -> LoadedDocuments {
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
    return try writeNotes(text, revision: revision, base: try currentManifest(id), meeting: id)
  }

  /// The notes file, then the manifest built on `base`.
  private func writeNotes(
    _ text: String, revision: Int, base: MeetingDocumentsManifest, meeting id: UUID
  ) throws -> MeetingDocumentsManifest {
    try refuseDocumentWrite(id)
    var next = base
    next.notes = MeetingDocumentsManifest.Notes(
      revision: revision, sha256: MeetingDocumentHash.sha256(text))
    if text.isEmpty {
      if FileManager.default.fileExists(atPath: notesURL(for: id).path) {
        try FileManager.default.removeItem(at: notesURL(for: id))
      }
    } else {
      try Self.atomicWrite(Data(text.utf8), to: notesURL(for: id))
    }
    try writeManifest(next, meeting: id)
    return next
  }

  /// Saves notes typed before this session read the meeting's notes (the quit path, or a read
  /// that failed earlier): reads and reconciles first, then saves the draft as `edits` changes
  /// after what was on disk. One file-queue operation, so the revision is never guessed. The
  /// manifest it writes keeps the read's reconciliation (a summary changed outside counts as
  /// the user's), and the result carries the documents as now saved, summary included.
  public func saveDraftNotes(_ text: String, edits: Int, meeting id: UUID) throws
    -> LoadedDocuments
  {
    let loaded = try readDocuments(meeting: id)
    let manifest = try writeNotes(
      text, revision: (loaded.manifest.notes?.revision ?? 0) + max(1, edits),
      base: loaded.manifest, meeting: id)
    return LoadedDocuments(
      notes: text, summary: loaded.summary, manifest: manifest, repaired: loaded.repaired)
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
    try writeManifest(next, meeting: id)
    return next
  }

  /// What `saveGeneratedSummary` did.
  public enum GeneratedSummarySave: Sendable, Equatable {
    /// The summary is saved and no longer owed.
    case saved(MeetingDocumentsManifest)
    /// The summary on disk is the user's (edited, or changed outside the app): kept.
    case userEditKept(MeetingDocumentsManifest)
    /// The notes changed since the summary's inputs were read: not saved.
    case notesChanged(MeetingDocumentsManifest)
  }

  /// Saves a generated summary only if it may replace what is there, checked in the same file
  /// operation as the write (#3972 R46): never over the user's own summary unless
  /// `replacingUserEdit` (the "Write again" confirmation), never from notes older than those
  /// on disk. Every outcome clears `summaryPending`: the attempt is over. The files are
  /// reconciled first, as a load does, so a summary or notes changed outside the app count.
  public func saveGeneratedSummary(
    _ text: String, inputs: SummaryInputs, replacingUserEdit: Bool, meeting id: UUID
  ) throws -> GeneratedSummarySave {
    try refuseDocumentWrite(id)
    var manifest = try readDocuments(meeting: id).manifest
    manifest.summaryPending = nil
    if manifest.summary?.origin == .userEdited, !replacingUserEdit {
      try writeManifest(manifest, meeting: id)
      return .userEditKept(manifest)
    }
    if (manifest.notes?.revision ?? 0) != inputs.notesRevision {
      try writeManifest(manifest, meeting: id)
      return .notesChanged(manifest)
    }
    manifest.summary = MeetingDocumentsManifest.Summary(
      sha256: MeetingDocumentHash.sha256(text), origin: .generated, inputs: inputs)
    try Self.atomicWrite(Data(text.utf8), to: summaryURL(for: id))
    try writeManifest(manifest, meeting: id)
    return .saved(manifest)
  }

  /// Marks a summary as owed, or no longer owed (#3972 R50), keeping the rest of the manifest
  /// as on disk.
  public func setSummaryPending(_ pending: Bool, meeting id: UUID) throws
    -> MeetingDocumentsManifest
  {
    try refuseDocumentWrite(id)
    var next = try currentManifest(id)
    next.summaryPending = pending ? true : nil
    try writeManifest(next, meeting: id)
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

  /// Every manifest write: refuses a meeting that is gone, deleting or newer, and a
  /// `documents.json` a newer build wrote.
  private func writeManifest(_ manifest: MeetingDocumentsManifest, meeting id: UUID) throws {
    try refuseDocumentWrite(id)
    _ = try currentManifest(id)
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
