import EnviousWisprCore
import Foundation

/// Why a dictation has no recording (#3147 §3.4), recorded when it happens so History never
/// guesses from today's settings. A row with no recorded reason is a legacy row
/// ("Recording unavailable").
public enum RecordingAbsence: String, Codable, Sendable, CaseIterable {
  /// Recordings were off when the dictation started.
  case recordingsOff
  /// Encoding or saving the recording failed (for example, the disk was full).
  case saveFailed
  /// The user deleted the recording and kept the text.
  case deleted
  /// Retention removed it after the user's chosen period.
  case expired
  /// The storage threshold's automatic mode removed it.
  case removedForSpace
}

/// Sentence timings for one recording (#3147 §3.2), stored beside the audio and deleted with it.
/// This chunk stores and reads them back exactly; it never invents anchors.
public struct RecordingTiming: Codable, Sendable, Equatable {
  public static let currentVersion = 1

  /// One timed passage: a UTF-16 range of the text version named by `textVersion`, and where it
  /// is heard in this recording.
  public struct Anchor: Codable, Sendable, Equatable {
    public let utf16Start: Int
    public let utf16End: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(utf16Start: Int, utf16End: Int, startSeconds: Double, endSeconds: Double) {
      self.utf16Start = utf16Start
      self.utf16End = utf16End
      self.startSeconds = startSeconds
      self.endSeconds = endSeconds
    }
  }

  public let version: Int
  /// The untouched speech-engine text, when the engine supplied it for this take.
  public let exactASRText: String?
  /// Identity of the text the anchors index (for example a hash of that text), so anchors are
  /// never applied to a different version.
  public let textVersion: String
  public let anchors: [Anchor]

  public init(exactASRText: String?, textVersion: String, anchors: [Anchor]) {
    self.version = Self.currentVersion
    self.exactASRText = exactASRText
    self.textVersion = textVersion
    self.anchors = anchors
  }
}

/// The saved recordings of dictations (#3147 §3.1). Owns `recordings/dictations/` under the app's
/// support folder and nothing else: meeting audio stays with `MeetingStore`.
///
/// Layout: `<rowID>.m4a`, optional `<rowID>.timing.json`, `pins.json` (recordings the user chose
/// to keep) and `absences.json` (why a row has no recording). Folder 0700 with a Spotlight
/// exclusion marker, files 0600, metadata replaced atomically. Nothing here ever leaves the Mac.
///
/// **Integration boundary.** This type keeps files consistent with each other; it does not
/// decide whether a mutation is still wanted. AppKit admits every mutation (store, delete,
/// deleteAll, pin, unpin, forget) through HistoryTransactionExecutor and, before `store`, checks
/// that the row still exists and that the audio mutation generation captured when encoding was
/// admitted is still current (#3147 §3.1 "Archive durability"). Orphan reconciliation against
/// the row inventory also lives there. Retention policy (expiry, thresholds) lives in
/// `RecordingRetention`; nothing in this type deletes by age or size.
public actor RecordingArchive {
  public static let audioExtension = "m4a"
  public static let partialExtension = "partial"
  static let timingSuffix = ".timing.json"
  static let pinsFileName = "pins.json"
  static let absencesFileName = "absences.json"
  static let spotlightMarkerName = ".metadata_never_index"

  public enum ArchiveError: Error, Equatable {
    /// The folder could not be created at 0700 with its Spotlight marker.
    case privacySetupFailed
    /// The file to store is missing.
    case missingSource
    /// The folder or a file in it could not be listed or measured.
    case unmeasurable
    /// A metadata file exists but cannot be read; it is left untouched.
    case unreadableMetadata(String)
  }

  /// Bytes on disk, split so Settings can show finished recordings and the storage policy can
  /// count encodes in progress.
  public struct Usage: Sendable, Equatable {
    /// Finished recordings, their timing files and the archive's metadata.
    public let committedBytes: Int64
    /// Encodes in progress or interrupted (`.partial`).
    public let temporaryBytes: Int64

    public var totalBytes: Int64 { committedBytes + temporaryBytes }
  }

  public let directory: URL

  /// The standard location: `<app support>/recordings/dictations/`.
  public init() {
    self.init(
      directory: AppConstants.appSupportURL
        .appendingPathComponent("recordings", isDirectory: true)
        .appendingPathComponent("dictations", isDirectory: true))
  }

  /// Tests point the archive at a temporary folder. Nothing is created until a write.
  public init(directory: URL) {
    self.directory = directory
  }

  // MARK: - Writing

  /// A fresh, unused path inside the archive for an encode in progress. Encoding there means an
  /// interrupted encode is counted by `usage()` and removed by `removeInterruptedPartials()`.
  public func partialURL(for rowID: UUID) throws -> URL {
    try prepareDirectory()
    return directory.appendingPathComponent(
      "\(rowID.uuidString).\(UUID().uuidString).\(Self.audioExtension).\(Self.partialExtension)")
  }

  /// What `store` published.
  public enum StoreOutcome: Sendable, Equatable {
    case stored
    /// The audio was published but its timings could not be written, so it plays untimed.
    case storedWithoutTimings
  }

  /// Publishes a finished encode as this row's recording, replacing an earlier one, with its
  /// timings (or none), and clears any recorded absence. The audio file is moved, not copied.
  ///
  /// Order, so no recording is ever paired with another take's timings: the old timing file is
  /// removed first, the audio is moved in, then the new timing file is written. If the move
  /// fails the call throws and the earlier recording stays, untimed; the caller still owns
  /// `fileURL` (a `.partial` left behind is counted and removed at launch). If only the timing
  /// write fails, the recording is kept untimed and `.storedWithoutTimings` is returned.
  @discardableResult
  public func store(rowID: UUID, fileURL: URL, timing: RecordingTiming?) throws -> StoreOutcome {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { throw ArchiveError.missingSource }
    try prepareDirectory()
    let audio = audioURL(rowID)
    let timingFile = timingURL(rowID)
    var absences = try readAbsences()
    if fm.fileExists(atPath: timingFile.path) {
      try fm.removeItem(at: timingFile)
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    if fm.fileExists(atPath: audio.path) {
      _ = try fm.replaceItemAt(audio, withItemAt: fileURL)
    } else {
      try fm.moveItem(at: fileURL, to: audio)
    }
    var outcome = StoreOutcome.stored
    if let timing {
      do {
        try writeAtomically(JSONEncoder().encode(timing), to: timingFile)
      } catch {
        outcome = .storedWithoutTimings
      }
    }
    if absences.removeValue(forKey: rowID) != nil {
      try writeAbsences(absences)
    }
    return outcome
  }

  /// Records why this row has no recording (recordings off, or a failed save) without touching
  /// any audio.
  public func recordAbsence(_ reason: RecordingAbsence, for rowID: UUID) throws {
    try prepareDirectory()
    var absences = try readAbsences()
    absences[rowID] = reason
    try writeAbsences(absences)
  }

  /// Removes this row's recording and timings, keeps its text (which this type never touches),
  /// drops its Keep flag and records `reason`. Unreadable metadata or a file that cannot be
  /// removed throws before the recording is gone, leaving the Keep flag and no recorded reason.
  /// If the metadata write after a successful removal fails, the recording is gone, the error
  /// is thrown and History shows the row as "Recording unavailable".
  public func delete(rowID: UUID, reason: RecordingAbsence) throws {
    // Metadata is read before anything is removed, so damaged metadata stops the deletion
    // while the recording is still there.
    var pins = try readPins()
    var absences = try readAbsences()
    try removeFiles(of: rowID)
    pins.remove(rowID)
    absences[rowID] = reason
    try writePins(pins)
    try writeAbsences(absences)
  }

  /// Deletes every recording, each recorded as `reason`. Returns how many recordings were
  /// removed. Stops at the first failure and throws, having recorded only what was removed.
  @discardableResult
  public func deleteAll(reason: RecordingAbsence) throws -> Int {
    let ids = try index()
    var pins = try readPins()
    var absences = try readAbsences()
    var removed = 0
    do {
      for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
        try removeFiles(of: id)
        pins.remove(id)
        absences[id] = reason
        removed += 1
      }
    } catch {
      // Record what was removed before reporting the failure.
      if removed > 0 {
        try? writePins(pins)
        try? writeAbsences(absences)
      }
      throw error
    }
    if removed > 0 {
      try writePins(pins)
      try writeAbsences(absences)
    }
    return removed
  }

  /// The row itself was deleted: remove its recording, timings, Keep flag and recorded absence.
  public func forget(rowID: UUID) throws {
    var pins = try readPins()
    var absences = try readAbsences()
    try removeFiles(of: rowID)
    let hadPin = pins.remove(rowID) != nil
    let hadAbsence = absences.removeValue(forKey: rowID) != nil
    if hadPin { try writePins(pins) }
    if hadAbsence { try writeAbsences(absences) }
  }

  /// Marks a recording to keep ("Keep this recording"): retention never removes it.
  public func pin(rowID: UUID) throws {
    try prepareDirectory()
    var pins = try readPins()
    guard pins.insert(rowID).inserted else { return }
    try writePins(pins)
  }

  public func unpin(rowID: UUID) throws {
    var pins = try readPins()
    guard pins.remove(rowID) != nil else { return }
    try writePins(pins)
  }

  /// Removes encodes a previous run left behind. Call once at launch, before any encode starts:
  /// it removes every `.partial` file in the archive, including one being written.
  @discardableResult
  public func removeInterruptedPartials() throws -> Int {
    var removed = 0
    for name in try listing()
    where name.hasSuffix(".\(Self.partialExtension)") || isMetadataTemp(name) {
      try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
      removed += 1
    }
    return removed
  }

  // MARK: - Reading

  /// This row's recording, or nil when there is none.
  public func url(for rowID: UUID) -> URL? {
    let url = audioURL(rowID)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  public func timing(for rowID: UUID) throws -> RecordingTiming? {
    let url = timingURL(rowID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(RecordingTiming.self, from: Data(contentsOf: url))
  }

  /// Why this row has no recording, when one was recorded.
  public func absence(for rowID: UUID) throws -> RecordingAbsence? {
    try readAbsences()[rowID]
  }

  public func isPinned(_ rowID: UUID) throws -> Bool {
    try readPins().contains(rowID)
  }

  public func pinnedRowIDs() throws -> Set<UUID> {
    try readPins()
  }

  /// Every row that has a finished recording. Throws when the folder cannot be listed, so a
  /// failure is never mistaken for an empty archive. A folder that was never created is empty.
  public func index() throws -> Set<UUID> {
    var ids = Set<UUID>()
    for name in try listing() where name.hasSuffix(".\(Self.audioExtension)") {
      if let id = UUID(uuidString: String(name.dropLast(Self.audioExtension.count + 1))) {
        ids.insert(id)
      }
    }
    return ids
  }

  /// Bytes used, including encodes in progress. Throws when any file cannot be measured.
  public func usage() throws -> Usage {
    var committed: Int64 = 0
    var temporary: Int64 = 0
    for name in try listing() where name != Self.spotlightMarkerName {
      let attributes: [FileAttributeKey: Any]
      do {
        attributes = try FileManager.default.attributesOfItem(
          atPath: directory.appendingPathComponent(name).path)
      } catch {
        throw ArchiveError.unmeasurable
      }
      guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
        throw ArchiveError.unmeasurable
      }
      if name.hasSuffix(".\(Self.partialExtension)") || isMetadataTemp(name) {
        temporary += size
      } else {
        committed += size
      }
    }
    return Usage(committedBytes: committed, temporaryBytes: temporary)
  }

  // MARK: - Files

  private func audioURL(_ rowID: UUID) -> URL {
    directory.appendingPathComponent("\(rowID.uuidString).\(Self.audioExtension)")
  }

  private func timingURL(_ rowID: UUID) -> URL {
    directory.appendingPathComponent("\(rowID.uuidString)\(Self.timingSuffix)")
  }

  /// Timings first, audio last: if the timing file cannot be removed, the recording still plays.
  private func removeFiles(of rowID: UUID) throws {
    let fm = FileManager.default
    for url in [timingURL(rowID), audioURL(rowID)] where fm.fileExists(atPath: url.path) {
      try fm.removeItem(at: url)
    }
  }

  /// Names in the folder; empty when the folder was never created; throws on any other failure.
  private func listing() throws -> [String] {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else { throw ArchiveError.unmeasurable }
    do {
      return try fm.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw ArchiveError.unmeasurable
    }
  }

  private func isMetadataTemp(_ name: String) -> Bool {
    name.hasPrefix(".") && name.hasSuffix(".tmp")
  }

  /// Creates the folder at 0700 with its Spotlight exclusion marker, or throws, so a privacy
  /// setup failure stops the write instead of being ignored.
  private func prepareDirectory() throws {
    let fm = FileManager.default
    do {
      if !fm.fileExists(atPath: directory.path) {
        try fm.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      }
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      throw ArchiveError.privacySetupFailed
    }
    let marker = directory.appendingPathComponent(Self.spotlightMarkerName)
    if !fm.fileExists(atPath: marker.path) {
      guard fm.createFile(atPath: marker.path, contents: Data(), attributes: nil) else {
        throw ArchiveError.privacySetupFailed
      }
    }
  }

  /// 0600 temporary file, then an atomic replace, so a reader sees the old or the new metadata.
  private func writeAtomically(_ data: Data, to url: URL) throws {
    try prepareDirectory()
    let fm = FileManager.default
    let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown) }
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
      } else {
        try fm.moveItem(at: tmp, to: url)
      }
    } catch {
      try? fm.removeItem(at: tmp)
      throw error
    }
  }

  // MARK: - Metadata

  private func readPins() throws -> Set<UUID> {
    Set(try readMetadata([UUID].self, named: Self.pinsFileName) ?? [])
  }

  private func writePins(_ pins: Set<UUID>) throws {
    try writeAtomically(
      JSONEncoder().encode(pins.sorted { $0.uuidString < $1.uuidString }),
      to: directory.appendingPathComponent(Self.pinsFileName))
  }

  /// Stored as a JSON object keyed by the row's UUID string.
  private func readAbsences() throws -> [UUID: RecordingAbsence] {
    let stored = try readMetadata([String: RecordingAbsence].self, named: Self.absencesFileName) ?? [:]
    var absences: [UUID: RecordingAbsence] = [:]
    for (key, value) in stored {
      guard let id = UUID(uuidString: key) else {
        throw ArchiveError.unreadableMetadata(Self.absencesFileName)
      }
      absences[id] = value
    }
    return absences
  }

  private func writeAbsences(_ absences: [UUID: RecordingAbsence]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let stored = Dictionary(uniqueKeysWithValues: absences.map { ($0.key.uuidString, $0.value) })
    try writeAtomically(
      encoder.encode(stored), to: directory.appendingPathComponent(Self.absencesFileName))
  }

  /// Nil when the file does not exist. A file that exists but cannot be read or decoded throws
  /// and is never overwritten by a caller, so a damaged Keep list is not silently emptied.
  private func readMetadata<T: Decodable>(_ type: T.Type, named name: String) throws -> T? {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    } catch {
      throw ArchiveError.unreadableMetadata(name)
    }
  }
}
