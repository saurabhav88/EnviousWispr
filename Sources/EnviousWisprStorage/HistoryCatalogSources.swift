import Darwin
import EnviousWisprCore
import Foundation

/// Identity and change metadata are checked before and after a source read. Missing optional
/// inputs are recorded explicitly, so a newly created notes or context file invalidates old text.
extension HistoryCatalog.SourceVersion {
  package static func read(_ url: URL) throws -> Self {
    var info = stat()
    let path = url.path
    if lstat(path, &info) != 0 {
      guard errno == ENOENT else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return Self(name: path, fingerprint: Data())
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
    let words = [
      Int64(info.st_dev), Int64(info.st_ino), info.st_size,
      Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
      Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec),
    ].map(\.littleEndian)
    return Self(name: path, fingerprint: words.withUnsafeBytes { Data($0) })
  }

  package func stillMatches() throws -> Bool {
    try Self.read(URL(fileURLWithPath: name)) == self
  }
}

extension HistoryCatalog.Summary {
  package func sourcesStillMatch() throws -> Bool {
    try sources.allSatisfy { try $0.stillMatches() }
  }
}

/// Reads the saved sources with the stores' existing decoders. In particular this never calls
/// the meeting document reader that repairs files, or constructs a store that migrates files.
package struct HistoryCatalogSources: Sendable {
  package struct Saved: Sendable {
    package let transcript: Transcript?
    package let meeting: MeetingRecord?
    package let documents: MeetingStore.LoadedDocuments?
    package let context: MeetingContext?
    package let versions: [HistoryCatalog.SourceVersion]
  }

  let transcriptDirectory: URL
  private let readTranscript: @Sendable (UUID) throws -> Transcript?
  private let meetings: MeetingStore

  enum SourceError: Error { case changedDuringRead, unreadable }

  package init(
    transcriptDirectory: URL, readTranscript: @escaping @Sendable (UUID) throws -> Transcript?,
    meetings: MeetingStore
  ) {
    self.transcriptDirectory = transcriptDirectory
    self.readTranscript = readTranscript
    self.meetings = meetings
  }

  private var pendingDirectory: URL {
    transcriptDirectory.appendingPathComponent(AppConstants.pendingTranscriptsDir, isDirectory: true)
  }

  func isMeetingPath(_ path: String) -> Bool {
    path.hasPrefix(meetings.root.path + "/")
  }

  func paths(requireMeetings: Bool) throws -> [URL] {
    try files(in: transcriptDirectory, allowMissing: false).filter(Self.isTranscript)
      + files(in: pendingDirectory, allowMissing: true).filter(Self.isTranscript).map {
        transcriptDirectory.appendingPathComponent($0.lastPathComponent)
      }
      + files(in: meetings.root, allowMissing: !requireMeetings).compactMap { folder in
        UUID(uuidString: folder.lastPathComponent).map { meetings.recordURL(for: $0) }
      }
  }

  private static func isTranscript(_ url: URL) -> Bool {
    url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
  }

  private func files(in directory: URL, allowMissing: Bool) throws -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    } catch let error as CocoaError where allowMissing && (error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile) {
      return []
    }
  }

  func snapshot(of url: URL, at now: Date) throws -> (saved: Saved?, versions: [HistoryCatalog.SourceVersion]) {
    if url.lastPathComponent == MeetingStore.recordFileName {
      guard let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) else { throw SourceError.unreadable }
      return try meeting(id)
    }
    guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
      throw SourceError.unreadable
    }
    let canonical = transcriptDirectory.appendingPathComponent(url.lastPathComponent)
    let pending = pendingDirectory.appendingPathComponent(url.lastPathComponent)
    var proofs = try [canonical, pending].map(HistoryCatalog.SourceVersion.read)
    let row: Transcript?
    if proofs[0].fingerprint.isEmpty == false {
      guard let saved = try readTranscript(id), saved.id == id else {
        throw SourceError.changedDuringRead
      }
      row = saved
    } else if proofs[1].fingerprint.isEmpty == false {
      row = try TranscriptStore.historyPendingRow(at: pending, now: now)
    } else {
      throw SourceError.changedDuringRead
    }
    if let row, let meetingID = row.meetingID {
      let record = try HistoryCatalog.SourceVersion.read(meetings.recordURL(for: meetingID))
      proofs.append(record)
      if record.fingerprint.isEmpty == false {
        return try verified(nil, versions: proofs)
      }
    }
    let saved = row.map {
      Saved(transcript: $0, meeting: nil, documents: nil, context: nil, versions: proofs)
    }
    return try verified(saved, versions: proofs)
  }

  private func verified(
    _ saved: Saved?, versions: [HistoryCatalog.SourceVersion]
  ) throws -> (Saved?, [HistoryCatalog.SourceVersion]) {
    guard try versions.allSatisfy({ try $0.stillMatches() }) else {
      throw SourceError.changedDuringRead
    }
    return (saved, versions)
  }

  private func meeting(
    _ id: UUID
  ) throws -> (Saved?, [HistoryCatalog.SourceVersion]) {
    let recordVersion = try HistoryCatalog.SourceVersion.read(meetings.recordURL(for: id))
    guard recordVersion.fingerprint.isEmpty == false else {
      throw SourceError.changedDuringRead
    }
    let record = try meetings.load(id: id)
    guard record.id == id, record.isWritableByThisBuild else {
      throw SourceError.unreadable
    }
    guard record.deletionRequested == false else {
      return try verified(nil, versions: [recordVersion])
    }
    let rowURL = transcriptDirectory.appendingPathComponent("\(record.transcriptID.uuidString).json")
    let inputs = [
      rowURL, meetings.documentsURL(for: id), meetings.notesURL(for: id),
      meetings.notesDocumentURL(for: id), meetings.summaryURL(for: id), meetings.contextURL(for: id),
    ]
    let proofs = [recordVersion] + (try inputs.map(HistoryCatalog.SourceVersion.read))
    let candidate = record.committedTranscriptGeneration == nil ? nil : try readTranscript(record.transcriptID)
    let row = candidate.flatMap { transcript in
      transcript.id == record.transcriptID && transcript.meetingID == id
        && transcript.meetingTranscriptGeneration == record.committedTranscriptGeneration ? transcript : nil
    }
    let documents = try meetings.historyDocuments(meeting: id)
    let context: MeetingContext?
    switch meetings.loadContext(meeting: id) {
    case .loaded(let value): context = value
    case .absent: context = nil
    case .unreadable: throw MeetingStore.ContextError.existingUnreadable
    }
    return try verified(
      Saved(transcript: row, meeting: record, documents: documents, context: context, versions: proofs),
      versions: proofs)
  }
}
