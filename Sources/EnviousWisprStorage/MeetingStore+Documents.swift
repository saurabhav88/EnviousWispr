import EnviousWisprCore
import Foundation

/// The meeting's notes and summary files (#3972 R46, R53). They sit at the folder root, so
/// Delete audio (which removes the segment files and `work/`) keeps them and Delete meeting
/// removes them with the folder.
///
/// Every write checks first that the meeting still exists, is not being deleted, and was not
/// written by a newer build, so a late write never recreates a deleted meeting.
///
/// **Notes v2 (#3147 PR4).** `notes.json` (a `MeetingNotesDocument`) is the notes' authority;
/// `notes.md` is its Markdown projection, rewritten from it. A notes save writes, in order:
/// `documents.json` at the current format when the file on disk is older or absent (so a build
/// from before notes v2 refuses this meeting's documents before any block exists), `notes.json`,
/// `notes.md`, then `documents.json` with the notes' revision and the projection's hash. A crash
/// at any point leaves a projection whose hash disagrees, and `loadDocuments` repairs it from
/// `notes.json`, raising the revision once. A meeting with `notes.md` and no `notes.json` (notes
/// written before v2) is migrated on load: one block per line, no times, the same Markdown, so
/// its revision does not move. An unreadable or newer `notes.json` is never replaced: the read
/// and every notes save fail until it reads. The summary keeps its rules: its Markdown file is
/// the text, and a disagreement is settled in favour of the file.
extension MeetingStore {
  public static let notesFileName = "notes.md"
  public static let notesDocumentFileName = "notes.json"
  public static let summaryFileName = "summary.md"
  public static let documentsFileName = "documents.json"
  /// #3147 PR4A (D5): the summary's reference document, beside `summary.md`. Delete audio keeps
  /// it; Delete meeting removes it with the folder.
  public static let summaryReferencesFileName = "summary-references.json"

  public enum DocumentError: Error, Equatable {
    /// The meeting's folder or `meeting.json` is gone.
    case meetingMissing
    /// The meeting is marked for deletion.
    case meetingDeleting
    /// A newer build wrote the meeting, its `documents.json` or its `notes.json`.
    case newerFormat
    /// `notes.json` exists and cannot be read; it is kept as it is.
    case notesUnreadable
  }

  /// What is on disk, settled: the notes document, its Markdown, the summary as written, and a
  /// manifest that agrees with them. `repaired` is true when a file had to change to agree
  /// (manifest, projection or a migration); `loadDocuments` has then already written it, in the
  /// same call.
  public struct LoadedDocuments: Sendable, Equatable {
    /// The notes' Markdown projection (`notesDocument.markdown`).
    public var notes: String
    public var notesDocument: MeetingNotesDocument
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

  public func notesDocumentURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.notesDocumentFileName)
  }

  /// Reads the documents and reconciles them (#3972 R53). Notes whose projection's hash
  /// disagrees with the manifest are the newest notes: their revision goes up, which makes a
  /// summary written from older notes out of date. A summary whose hash disagrees counts as the
  /// user's own text. Repairs (the manifest, a stale `notes.md`, a migration's first
  /// `notes.json`) are written in this same call (one file-queue operation), so no other
  /// document write can land between the read and the repair. A meeting that refuses writes
  /// (deleting, gone, newer) is returned as read, unrepaired on disk.
  public func loadDocuments(meeting id: UUID) throws -> LoadedDocuments {
    var read = try readDocuments(meeting: id)
    if read.loaded.repaired {
      do {
        try writeRepairs(read, meeting: id)
      } catch let error as DocumentError where error != .newerFormat {
        read.loaded.repaired = false
      }
    }
    return read.loaded
  }

  /// A settled read, and which notes files it found out of step.
  private struct DocumentsRead {
    var loaded: LoadedDocuments
    /// `notes.json` is absent and the document was migrated from `notes.md`.
    var migrated: Bool
    /// `notes.md` differs from the document's projection.
    var projectionStale: Bool
    /// `documents.json` on disk is absent or older than this build's format.
    var manifestFormatOld: Bool
  }

  private func readDocuments(meeting id: UUID) throws -> DocumentsRead {
    let (base, manifestFormatOld) = try currentManifestAndAge(id)
    var manifest = base
    let markdown = try Self.readText(notesURL(for: id))
    let summary = try Self.readText(summaryURL(for: id))
    let document: MeetingNotesDocument
    let migrated: Bool
    if let data = try Self.readData(notesDocumentURL(for: id)) {
      document = try Self.decodeNotes(data)
      migrated = false
    } else {
      document = MeetingNotesDocument(legacyMarkdown: markdown ?? "")
      migrated = !document.blocks.isEmpty
    }
    let projection = document.markdown
    let projectionStale = !MeetingDocumentHash.sameBytes(markdown ?? "", projection)
    var repaired = migrated || projectionStale

    let notesHash = MeetingDocumentHash.sha256(projection)
    // No notes and no entry agree; anything else that differs is newer notes.
    if manifest.notes?.sha256 != notesHash, !(projection.isEmpty && manifest.notes == nil) {
      manifest.notes = MeetingDocumentsManifest.Notes(
        revision: (manifest.notes?.revision ?? 0) + 1, sha256: notesHash)
      repaired = true
    }

    if let summary {
      let summaryHash = MeetingDocumentHash.sha256(summary)
      if manifest.summary?.sha256 != summaryHash {
        manifest.summary = MeetingDocumentsManifest.Summary(
          sha256: summaryHash, origin: .userEdited, inputs: manifest.summary?.inputs,
          writtenInParts: manifest.summary?.writtenInParts)
        repaired = true
      }
    } else if manifest.summary != nil {
      manifest.summary = nil
      repaired = true
    }
    return DocumentsRead(
      loaded: LoadedDocuments(
        notes: projection, notesDocument: document, summary: summary, manifest: manifest,
        repaired: repaired),
      migrated: migrated, projectionStale: projectionStale, manifestFormatOld: manifestFormatOld)
  }

  /// Writes what `read` found out of step, in the notes save's order.
  private func writeRepairs(_ read: DocumentsRead, meeting id: UUID) throws {
    try refuseDocumentWrite(id)
    if read.migrated || read.projectionStale {
      if read.manifestFormatOld { try markCurrentFormat(meeting: id) }
      if read.migrated {
        try Self.atomicWrite(
          try Self.encoder.encode(read.loaded.notesDocument), to: notesDocumentURL(for: id))
      }
      try writeProjection(read.loaded.notes, meeting: id)
    }
    try writeManifest(read.loaded.manifest, meeting: id)
  }

  /// Saves the notes at `revision`: `notes.json`, its projection, then the manifest. The rest
  /// of the manifest is read from disk here, on the one file queue, so a notes save never
  /// overwrites a summary entry written after the caller last read it. Refused while
  /// `notes.json` is unreadable or newer.
  public func saveNotes(_ document: MeetingNotesDocument, revision: Int, meeting id: UUID) throws
    -> MeetingDocumentsManifest
  {
    try refuseDocumentWrite(id)
    let (base, old) = try currentManifestAndAge(id)
    try refuseUnreadableNotes(id)
    return try writeNotes(document, revision: revision, base: base, formatOld: old, meeting: id)
  }

  /// Saves plain Markdown as the notes: its lines are matched to the saved blocks
  /// (`MeetingNotesDocument.replacingMarkdown`), so unchanged lines keep their id and time.
  public func saveNotes(_ text: String, revision: Int, meeting id: UUID) throws
    -> MeetingDocumentsManifest
  {
    try refuseDocumentWrite(id)
    let current = try readDocuments(meeting: id).loaded.notesDocument
    return try saveNotes(current.replacingMarkdown(text, atMs: nil), revision: revision, meeting: id)
  }

  /// The notes document, its projection, then the manifest built on `base`.
  private func writeNotes(
    _ document: MeetingNotesDocument, revision: Int, base: MeetingDocumentsManifest,
    formatOld: Bool, meeting id: UUID
  ) throws -> MeetingDocumentsManifest {
    try refuseDocumentWrite(id)
    let projection = document.markdown
    var next = base
    next.notes = MeetingDocumentsManifest.Notes(
      revision: revision, sha256: MeetingDocumentHash.sha256(projection))
    if formatOld { try markCurrentFormat(meeting: id) }
    var stored = document
    stored.version = MeetingNotesDocument.currentVersion
    try Self.atomicWrite(try Self.encoder.encode(stored), to: notesDocumentURL(for: id))
    try writeProjection(projection, meeting: id)
    try writeManifest(next, meeting: id)
    return next
  }

  /// `notes.md` as `projection`; empty notes remove it (`notes.json` stays, so the notes read
  /// as empty, never as the older Markdown).
  private func writeProjection(_ projection: String, meeting id: UUID) throws {
    if projection.isEmpty {
      if FileManager.default.fileExists(atPath: notesURL(for: id).path) {
        try FileManager.default.removeItem(at: notesURL(for: id))
      }
    } else {
      try Self.atomicWrite(Data(projection.utf8), to: notesURL(for: id))
    }
  }

  /// Saves notes typed before this session read the meeting's notes (the quit path, or a read
  /// that failed earlier): reads and reconciles first, then saves the draft as `edits` changes
  /// after what was on disk. One file-queue operation, so the revision is never guessed. The
  /// manifest it writes keeps the read's reconciliation (a summary changed outside counts as
  /// the user's), and the result carries the documents as now saved, summary included. A read
  /// that fails (an unreadable or newer `notes.json`) fails the save: the draft never replaces
  /// notes this build cannot read.
  public func saveDraftNotes(_ document: MeetingNotesDocument, edits: Int, meeting id: UUID) throws
    -> LoadedDocuments
  {
    try refuseDocumentWrite(id)
    let read = try readDocuments(meeting: id)
    // Notes already on disk (a retry after a save that committed `notes.json` and failed later)
    // were counted by the read's reconciliation: they are not counted again.
    let increment =
      MeetingDocumentHash.sameBytes(read.loaded.notes, document.markdown) ? 0 : max(1, edits)
    let manifest = try writeNotes(
      document, revision: (read.loaded.manifest.notes?.revision ?? 0) + increment,
      base: read.loaded.manifest, formatOld: read.manifestFormatOld, meeting: id)
    var stored = document
    stored.version = MeetingNotesDocument.currentVersion
    return LoadedDocuments(
      notes: document.markdown, notesDocument: stored, summary: read.loaded.summary,
      manifest: manifest, repaired: read.loaded.repaired)
  }

  /// Saves the summary text with its origin and inputs, then the manifest (its notes entry read
  /// from disk, as `saveNotes` does for the summary). `writtenInParts` comes from the caller's
  /// draft, not from disk, which may already hold a newer generation (#4044); text without
  /// inputs has no provenance.
  public func saveSummary(
    _ text: String, origin: MeetingDocumentsManifest.Origin, inputs: SummaryInputs?,
    writtenInParts: Bool? = nil, meeting id: UUID
  ) throws -> MeetingDocumentsManifest {
    try refuseDocumentWrite(id)
    var next = try currentManifest(id)
    next.summary = MeetingDocumentsManifest.Summary(
      sha256: MeetingDocumentHash.sha256(text), origin: origin, inputs: inputs,
      writtenInParts: inputs == nil ? nil : writtenInParts)
    try Self.atomicWrite(Data(text.utf8), to: summaryURL(for: id))
    try writeManifest(next, meeting: id)
    return next
  }

  public func summaryReferencesURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.summaryReferencesFileName)
  }

  /// #3147 PR4A (D5): the saved reference document's bytes, or nil when there is none.
  public func loadSummaryReferences(meeting id: UUID) throws -> Data? {
    try Self.readData(summaryReferencesURL(for: id))
  }

  /// #3147 PR4A (D5): writes the reference document for the summary just saved, or removes an
  /// older one when `data` is nil. Refused like every document write (meeting gone, being
  /// deleted, newer build). The reader checks the document against the shown summary, so a
  /// document left from an older summary only ever means no links.
  public func saveSummaryReferences(_ data: Data?, meeting id: UUID) throws {
    try refuseDocumentWrite(id)
    let url = summaryReferencesURL(for: id)
    if let data {
      try Self.atomicWrite(data, to: url)
    } else if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// What `saveGeneratedSummary` did.
  public enum GeneratedSummarySave: Sendable, Equatable {
    /// The summary is saved and no longer owed.
    case saved(MeetingDocumentsManifest)
    /// The summary on disk is the user's (edited, or changed outside the app): kept.
    case userEditKept(MeetingDocumentsManifest)
    /// The notes changed since the summary's inputs were read: not saved.
    case notesChanged(MeetingDocumentsManifest)
    /// Another save or an external edit changed the summary shown by a manual preview.
    case baseChanged(MeetingDocumentsManifest)
  }

  public enum SummaryPublication: Sendable {
    case automatic
    case replacing(MeetingDocumentsManifest.Summary?)
  }

  /// Saves a generated summary only if it may replace what is there, checked in the same file
  /// operation as the write (#3972 R46): never over the user's own summary unless it is exactly
  /// the text the user confirmed replacing ("Write again": `approvedUserEdit` is its SHA-256, so
  /// an edit made after the confirmation is kept), never from notes older than those on disk. Every outcome clears `summaryPending`: the attempt is over. The files are
  /// reconciled first, as a load does, so a summary or notes changed outside the app count.
  public func saveGeneratedSummary(
    _ text: String, inputs: SummaryInputs, writtenInParts: Bool, approvedUserEdit: String?,
    meeting id: UUID, publication: SummaryPublication = .automatic
  ) throws -> GeneratedSummarySave {
    try refuseDocumentWrite(id)
    var manifest = try readDocuments(meeting: id).loaded.manifest
    if case .replacing(let expected) = publication {
      guard manifest.summary == expected,
        try load(id: id).committedTranscriptGeneration
          == (inputs.transcriptAttemptID ?? MeetingRecord.legacyTranscriptAttemptID)
      else { return .baseChanged(manifest) }
    } else {
      manifest.summaryPending = nil
    }
    if let current = manifest.summary, current.origin == .userEdited,
      current.sha256 != approvedUserEdit
    {
      if case .automatic = publication { try writeManifest(manifest, meeting: id) }
      return .userEditKept(manifest)
    }
    if (manifest.notes?.revision ?? 0) != inputs.notesRevision {
      if case .automatic = publication { try writeManifest(manifest, meeting: id) }
      return .notesChanged(manifest)
    }
    manifest.summaryPending = nil
    manifest.summary = MeetingDocumentsManifest.Summary(
      sha256: MeetingDocumentHash.sha256(text), origin: .generated, inputs: inputs,
      writtenInParts: writtenInParts)
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
    try currentManifestAndAge(id).0
  }

  /// `documents.json` as on disk (an empty manifest when there is none), and whether it is
  /// absent or older than this build's format.
  private func currentManifestAndAge(_ id: UUID) throws -> (MeetingDocumentsManifest, Bool) {
    guard FileManager.default.fileExists(atPath: documentsURL(for: id).path) else {
      return (MeetingDocumentsManifest(), true)
    }
    let manifest = try Self.decoder.decode(
      MeetingDocumentsManifest.self, from: Data(contentsOf: documentsURL(for: id)))
    guard manifest.formatVersion <= MeetingDocumentsManifest.currentFormatVersion else {
      throw DocumentError.newerFormat
    }
    return (manifest, manifest.formatVersion < MeetingDocumentsManifest.currentFormatVersion)
  }

  /// Every manifest write: refuses a meeting that is gone, deleting or newer, and a
  /// `documents.json` a newer build wrote. Always written at this build's format.
  private func writeManifest(_ manifest: MeetingDocumentsManifest, meeting id: UUID) throws {
    try refuseDocumentWrite(id)
    _ = try currentManifest(id)
    var current = manifest
    current.formatVersion = MeetingDocumentsManifest.currentFormatVersion
    try Self.atomicWrite(try Self.encoder.encode(current), to: documentsURL(for: id))
  }

  /// Rewrites `documents.json` unchanged at this build's format, before the first `notes.json`:
  /// a build from before notes v2 then refuses the meeting's documents instead of writing
  /// `notes.md` beside blocks it cannot see.
  private func markCurrentFormat(meeting id: UUID) throws {
    try writeManifest(try currentManifest(id), meeting: id)
  }

  /// Refuses a notes write while `notes.json` exists and does not read.
  private func refuseUnreadableNotes(_ id: UUID) throws {
    if let data = try Self.readData(notesDocumentURL(for: id)) {
      _ = try Self.decodeNotes(data)
    }
  }

  /// `notes.json`'s document: `newerFormat` for a version this build does not know,
  /// `notesUnreadable` when it does not decode.
  private static func decodeNotes(_ data: Data) throws -> MeetingNotesDocument {
    struct Version: Decodable { var version: Int }
    guard let version = try? decoder.decode(Version.self, from: data) else {
      throw DocumentError.notesUnreadable
    }
    guard version.version <= MeetingNotesDocument.currentVersion else {
      throw DocumentError.newerFormat
    }
    guard let document = try? decoder.decode(MeetingNotesDocument.self, from: data) else {
      throw DocumentError.notesUnreadable
    }
    return document
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
    try readData(url).map { String(decoding: $0, as: UTF8.self) }
  }

  /// The file's bytes, or nil when it does not exist.
  private static func readData(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }
}
