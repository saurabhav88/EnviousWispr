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
    try save(record)
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

  /// Bytes used by the meeting's audio files.
  public func audioBytes(meeting id: UUID) throws -> Int64 {
    try segmentFiles(meeting: id).reduce(0) { total, file in
      let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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

  static func atomicWrite(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    let tmp = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).tmp")
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
    do {
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
      } else {
        try fm.moveItem(at: tmp, to: url)
      }
    } catch {
      try? fm.removeItem(at: tmp)
      throw error
    }
    // The rename is durable only once its directory is (#3972 C4a): a meeting marked ready
    // clears its checkpoint right after this returns.
    let dirFD = Foundation.open(url.deletingLastPathComponent().path, O_RDONLY)
    guard dirFD >= 0 else { throw StoreError.syncFailed(errno) }
    defer { Foundation.close(dirFD) }
    if fsync(dirFD) != 0 { throw StoreError.syncFailed(errno) }
  }
}
