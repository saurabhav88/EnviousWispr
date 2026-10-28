import EnviousWisprCore
import Foundation

/// The folders EnviousMeet keeps on disk (#3972 §3.3, R3, R15): one per meeting, holding
/// `meeting.json` and the track segment files.
///
/// Same privacy posture as `TranscriptStore`: root at 0700 with a Spotlight exclusion marker,
/// files at 0600, `meeting.json` replaced atomically. Not `@MainActor`: the recorder and the
/// after-recording pass call it from their own queues; every operation is a short file
/// transaction, and one meeting folder is written by one owner at a time.
///
/// Never deleted or rewritten here: a meeting whose `meeting.json` was written by a NEWER build
/// (listed read-only), and anything that is not a UUID-named child of the root.
public struct MeetingStore: Sendable {
  public static let recordFileName = "meeting.json"
  public static let workDirectoryName = "work"

  public let root: URL

  public init() {
    self.init(
      root: AppConstants.appSupportURL.appendingPathComponent(
        AppConstants.meetingsDir, isDirectory: true))
  }

  /// Tests point the store at a temporary directory. Creating nothing here: the root is
  /// prepared (and its failures reported) by the first operation that writes.
  public init(root: URL) {
    self.root = root
  }

  /// Creates the root at 0700 with its Spotlight exclusion marker, or throws. Called by every
  /// writing operation, so a privacy setup failure stops the write instead of being ignored.
  public func prepareRoot() throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: root.path) {
      try fm.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let marker = root.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      guard fm.createFile(atPath: marker.path, contents: Data(), attributes: nil) else {
        throw StoreError.privacySetupFailed
      }
    }
  }

  public enum StoreError: Error, Equatable {
    case alreadyExists
    case notAMeetingFolder
    case newerFormat
    case syncFailed(Int32)
    case privacySetupFailed
    /// A listed audio file's size could not be read (gone since the listing, or not a file).
    case unmeasurableAudio
    /// The meeting's `meeting.json` is gone: a late write never recreates the meeting.
    case meetingMissing
  }

  /// One folder found under the root.
  public enum Listing: Sendable, Equatable {
    case meeting(MeetingRecord)
    /// Written by a newer build: shown read-only; this build never changes or deletes it.
    case newerFormat(MeetingRecord.Header)
    /// A UUID folder whose `meeting.json` is missing or does not decode. Left on disk.
    case unreadable(UUID)
  }

  // MARK: - Paths

  public func folder(for id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  public func recordURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.recordFileName)
  }

  public func workDirectory(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.workDirectoryName, isDirectory: true)
  }

  // MARK: - Records

  /// Creates the meeting's folder and writes its first `meeting.json`. Refuses an existing
  /// folder: creation of the leaf directory is the atomic claim, so two creators cannot both
  /// succeed.
  public func create(_ record: MeetingRecord) throws {
    try prepareRoot()
    let dir = folder(for: record.id)
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch CocoaError.fileWriteFileExists {
      throw StoreError.alreadyExists
    }
    do {
      try save(record)
    } catch {
      // The claim failed to become a meeting: the empty folder this call made goes, so a later
      // launch never lists it as unreadable. Best effort; the save's error is the one reported.
      try? FileManager.default.removeItem(at: dir)
      throw error
    }
  }

  /// Replaces `meeting.json` atomically (temp file at 0600, full sync, replace). A failed
  /// replace leaves the previous file intact. Refuses a record from a newer format, and refuses
  /// to overwrite a file on disk that a newer build wrote.
  public func save(_ record: MeetingRecord) throws {
    guard record.isWritableByThisBuild else { throw StoreError.newerFormat }
    try prepareRoot()
    if let header = try? header(id: record.id),
      header.formatVersion > MeetingRecord.currentFormatVersion
    {
      throw StoreError.newerFormat
    }
    let data = try Self.encoder.encode(record)
    try Self.atomicWrite(data, to: recordURL(for: record.id))
  }

  public func load(id: UUID) throws -> MeetingRecord {
    try Self.decoder.decode(MeetingRecord.self, from: Data(contentsOf: recordURL(for: id)))
  }

  public func header(id: UUID) throws -> MeetingRecord.Header {
    try Self.decoder.decode(MeetingRecord.Header.self, from: Data(contentsOf: recordURL(for: id)))
  }

  /// Every UUID folder under the root, newest first where a date is known. Throws when the root
  /// itself cannot be read (never a misleading empty list); a missing root is an empty list.
  public func loadAll() throws -> [Listing] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { return [] }
    let names = try fm.contentsOfDirectory(atPath: root.path)
    var listings: [(Date, Listing)] = []
    for name in names {
      guard let id = UUID(uuidString: name) else { continue }
      if let record = try? load(id: id), record.formatVersion <= MeetingRecord.currentFormatVersion
      {
        listings.append((record.createdAt, .meeting(record)))
      } else if let header = try? header(id: id),
        header.formatVersion > MeetingRecord.currentFormatVersion
      {
        listings.append((header.createdAt, .newerFormat(header)))
      } else {
        listings.append((.distantPast, .unreadable(id)))
      }
    }
    return listings.sorted { $0.0 > $1.0 }.map(\.1)
  }

  // MARK: - Segments on disk

  public struct SegmentFile: Sendable, Equatable {
    public let track: MeetingTrackKind
    public let index: Int
    public let startMs: Int
    public let partial: Bool
    public let url: URL
  }

  /// Every recognized segment file in the folder (finals AND partials, duplicates included), in
  /// (track, numeric index, partial-after-final) order. Throws when the folder cannot be read.
  public func segmentFiles(meeting id: UUID) throws -> [SegmentFile] {
    let dir = folder(for: id)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    return names.compactMap { name -> SegmentFile? in
      guard let parsed = MeetingSegmentNaming.parse(name) else { return nil }
      return SegmentFile(
        track: parsed.track, index: parsed.index, startMs: parsed.startMs, partial: parsed.partial,
        url: dir.appendingPathComponent(name))
    }.sorted { lhs, rhs in
      if lhs.track != rhs.track { return lhs.track.rawValue < rhs.track.rawValue }
      if lhs.index != rhs.index { return lhs.index < rhs.index }
      return !lhs.partial && rhs.partial
    }
  }

  /// The highest index any recognized file of `track` occupies, so a writer continues past
  /// every occupied identity (finals, partials and duplicates alike).
  public func highestIndex(meeting id: UUID, track: MeetingTrackKind) throws -> Int {
    try segmentFiles(meeting: id).filter { $0.track == track }.map(\.index).max() ?? 0
  }

  /// Bytes used by the meeting's audio files. Throws when any listed file cannot be measured,
  /// so a failed read is never shown as a size.
  public func audioBytes(meeting id: UUID) throws -> Int64 {
    try segmentFiles(meeting: id).reduce(0) { total, file in
      guard let size = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw StoreError.unmeasurableAudio
      }
      return total + Int64(size)
    }
  }

  // MARK: - Deletion

  /// Removes every audio file of the meeting (finals and partials) and its work folder; keeps
  /// `meeting.json`. Refuses a meeting a newer build wrote.
  public func deleteAudio(meeting id: UUID) throws {
    try refuseNewerFormat(id)
    for file in try segmentFiles(meeting: id) {
      try FileManager.default.removeItem(at: file.url)
    }
    let work = workDirectory(for: id)
    if FileManager.default.fileExists(atPath: work.path) {
      try FileManager.default.removeItem(at: work)
    }
  }

  /// Removes the meeting's whole folder. Refuses any path that is not a UUID-named child of the
  /// root, and a meeting a newer build wrote.
  public func deleteFolder(meeting id: UUID) throws {
    let dir = folder(for: id).standardizedFileURL
    guard dir.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
      UUID(uuidString: dir.lastPathComponent) == id
    else { throw StoreError.notAMeetingFolder }
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    try refuseNewerFormat(id)
    try FileManager.default.removeItem(at: dir)
  }

  private func refuseNewerFormat(_ id: UUID) throws {
    if let header = try? header(id: id), header.formatVersion > MeetingRecord.currentFormatVersion {
      throw StoreError.newerFormat
    }
  }

  // MARK: - File helpers

  /// Dates are written as exact seconds since the reference date, so a saved record reloads
  /// EQUAL to what was written (ISO 8601 text rounds sub-second precision). The decoder also
  /// accepts ISO 8601 text, so a hand-edited or future file with text dates still reads.
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let seconds = try? container.decode(Double.self) {
        return Date(timeIntervalSinceReferenceDate: seconds)
      }
      let text = try container.decode(String.self)
      if let date = try? Date(
        text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
      {
        return date
      }
      if let date = try? Date(text, strategy: .iso8601) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a date")
    }
    return decoder
  }()

  /// The file system calls `atomicWrite` makes after the temp file is durable, and where it
  /// reports a failed write. A test passes failing steps; production uses `.system`.
  package struct WriteSteps: Sendable {
    package var openDirectory: @Sendable (String) -> Int32
    package var syncDirectory: @Sendable (Int32) -> Int32
    /// Replaces `url` with `tmp`, keeping the previous file as the named backup beside it.
    package var replace: @Sendable (_ url: URL, _ tmp: URL, _ backupName: String) throws -> Void
    package var rename: @Sendable (_ from: String, _ to: String) -> Int32
    package var unlink: @Sendable (String) -> Int32
    /// Removes the backup after a confirmed write; a failure leaves an ignored dot-file.
    package var removeBackup: @Sendable (URL) throws -> Void
    /// One line per failed write: the stage, what the destination holds, whether that is
    /// confirmed durable, and each error number. Never file content.
    package var report: @Sendable (String) -> Void

    package static let system = WriteSteps(
      openDirectory: { Foundation.open($0, O_RDONLY) },
      syncDirectory: { fsync($0) },
      replace: { url, tmp, backupName in
        _ = try FileManager.default.replaceItemAt(
          url, withItemAt: tmp, backupItemName: backupName, options: .withoutDeletingBackupItem)
      },
      rename: { Foundation.rename($0, $1) },
      unlink: { Foundation.unlink($0) },
      removeBackup: { try FileManager.default.removeItem(at: $0) },
      report: { line in
        Task { await AppLogger.shared.log(line, level: .info, category: "MeetingStore") }
      })
  }

  /// The user-info key `replaceItemAt` sets when it moved the original away and failed. The
  /// SDK documents it as a string key (`NSFileManager.h`) with no Swift constant.
  static let originalItemLocationKey = "NSFileOriginalItemLocationKey"

  /// Writes `data` to `url` as one complete file: temp file, `F_FULLFSYNC`, replace, then a
  /// directory sync, because the rename is durable only once its directory is (#3972 C4a): a
  /// meeting marked ready clears its checkpoint right after this returns.
  ///
  /// What a throw means for `url` (#3996), so a caller that rolls back to its last saved copy
  /// agrees with the disk. The errors are the ones callers always saw (`syncFailed`, a POSIX
  /// error, Foundation's replacement error); what is established about `url` is in the
  /// `report` line.
  /// - The directory is opened BEFORE the replacement; a failure there (for example no free
  ///   file descriptors) is a clean throw with `url` untouched.
  /// - A failed directory sync after the replacement restores the previous file (or removes a
  ///   new one) and syncs the directory again: `url` holds its previous content again.
  /// - A failed replacement call puts a displaced original back where Foundation reports it
  ///   moved it, then syncs the directory.
  /// - Residual, not promised away and reported: the restore can fail (`url` may hold the NEW
  ///   content, or nothing; the backup or temp file is kept as evidence), or the restore can
  ///   land without a confirmed directory sync (previous content, durability unknown).
  /// - One file per call: a caller that writes two files (notes then the documents manifest)
  ///   is not rolled back as a whole when its second write fails.
  /// A leftover `.<name>.<uuid>.bak` (a crash between replacement and cleanup) is ignored by
  /// every meeting-folder reader (segment names are parsed; documents, records and the
  /// checkpoint are read by exact path) and goes with the folder on Delete meeting.
  static func atomicWrite(_ data: Data, to url: URL, steps: WriteSteps = .system) throws {
    let fm = FileManager.default
    let directory = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    func report(_ stage: String, holds: String, durable: String, _ numbers: String) {
      steps.report(
        "meeting file write failed file=\(name) stage=\(stage) holds=\(holds) "
          + "durable=\(durable) \(numbers)")
    }
    // A unique temp name per write (#3972 R46): two writers of one file never share a temp.
    let tmp = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
    let fd = Foundation.open(tmp.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    do {
      try handle.write(contentsOf: data)
      if fcntl(fd, F_FULLFSYNC) != 0 { throw StoreError.syncFailed(errno) }
      try handle.close()
    } catch {
      try? handle.close()
      try? fm.removeItem(at: tmp)
      throw error
    }
    let dirFD = steps.openDirectory(directory.path)
    guard dirFD >= 0 else {
      let openErrno = errno
      try? fm.removeItem(at: tmp)
      report("open_directory", holds: "unchanged", durable: "unchanged", "open=\(openErrno)")
      throw StoreError.syncFailed(openErrno)
    }
    defer { Foundation.close(dirFD) }
    let replacing = fm.fileExists(atPath: url.path)
    let backupName = ".\(name).\(UUID().uuidString).bak"
    let backup = directory.appendingPathComponent(backupName)
    do {
      if replacing {
        try steps.replace(url, tmp, backupName)
      } else {
        try fm.moveItem(at: tmp, to: url)
      }
    } catch {
      // What the failed call left at `url` is established only by what Foundation reports and
      // what is there now (#3996): a reported original location is put back; otherwise the
      // destination is read back. The temp file holds only the NEW content, which the caller
      // still has, so it is kept only when nothing is left at `url` (the one copy on disk).
      let failure = error as NSError
      let detail = "error=\(failure.domain):\(failure.code)"
      func leftAtDestination() -> String {
        guard let now = fm.contents(atPath: url.path) else {
          return fm.fileExists(atPath: url.path) ? "unverified" : "absent"
        }
        return now == data ? "new" : "unverified"
      }
      func dropTempUnlessAlone() {
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: tmp) }
      }
      guard replacing else {
        // A new file that failed to move: nothing was there before and nothing is now.
        try? fm.removeItem(at: tmp)
        report("move", holds: "absent", durable: "unchanged", detail)
        throw error
      }
      guard let moved = failure.userInfo[Self.originalItemLocationKey] as? URL else {
        let holds = leftAtDestination()
        dropTempUnlessAlone()
        report("replace", holds: holds, durable: "unknown", detail + " original=unreported")
        throw error
      }
      // Foundation moved the original to `moved` before failing: it goes back over whatever
      // is at `url`, then the directory is synced.
      guard steps.rename(moved.path, url.path) == 0 else {
        let restoreErrno = errno
        let holds = leftAtDestination()
        dropTempUnlessAlone()
        report(
          "replace_restore", holds: holds, durable: "unknown", detail + " restore=\(restoreErrno)")
        throw error
      }
      try? fm.removeItem(at: tmp)
      if steps.syncDirectory(dirFD) != 0 {
        let syncErrno = errno
        report(
          "replace_restore_sync", holds: "previous", durable: "unknown",
          detail + " restore_sync=\(syncErrno)")
      } else {
        report("replace_restore", holds: "previous", durable: "yes", detail)
      }
      throw error
    }
    guard steps.syncDirectory(dirFD) != 0 else {
      if replacing { try? steps.removeBackup(backup) }
      return
    }
    let syncErrno = errno
    guard (replacing ? steps.rename(backup.path, url.path) : steps.unlink(url.path)) == 0 else {
      let undoErrno = errno
      report(
        "undo", holds: "new", durable: "unknown", "sync=\(syncErrno) undo=\(undoErrno)")
      throw StoreError.syncFailed(syncErrno)
    }
    let previous = replacing ? "previous" : "absent"
    guard steps.syncDirectory(dirFD) == 0 else {
      let undoSyncErrno = errno
      report(
        "undo_sync", holds: previous, durable: "unknown",
        "sync=\(syncErrno) undo_sync=\(undoSyncErrno)")
      throw StoreError.syncFailed(syncErrno)
    }
    report("sync", holds: previous, durable: "yes", "sync=\(syncErrno)")
    throw StoreError.syncFailed(syncErrno)
  }
}
