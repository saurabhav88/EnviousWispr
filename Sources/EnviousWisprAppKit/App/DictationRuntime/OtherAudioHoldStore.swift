import Foundation

// #1413 — the recovery copy of a hold. One hardened JSON file per hold id under
// Application Support, written BEFORE the device is touched, so a process that
// dies mid-take leaves a record the next launch can act on. The live owners of
// the facts are `OtherAudioHold` (the take) and the media effect (which players
// it paused); this file never decides anything on its own (plan §4 R1-R6).

/// Per-property disposition, the closed vocabulary of plan §4. `applied` carries
/// its confirmed read-back in the record's `appliedVolume` / `appliedMute`.
enum OtherAudioPropertyDisposition: String, Codable, Equatable, Sendable {
  case notApplied = "not_applied"
  case appliedUnconfirmed = "applied_unconfirmed"
  case applied
  case restored
  case skippedUserChanged = "skipped_user_changed"
  case skippedDeviceGone = "skipped_device_gone"
  case unresolved

  /// R1: a property blocks retirement while its application is still live.
  var blocksRetirement: Bool { self == .appliedUnconfirmed || self == .applied }
}

enum OtherAudioMediaDisposition: String, Codable, Equatable, Sendable {
  case pending
  case resumed
  case nothingPaused = "nothing_paused"
  case resumeFailed = "resume_failed"
}

/// The persisted record. `version` gates decoding (R6): an unknown version is
/// invalid-file disposal, never a disposition-based retirement.
struct OtherAudioHoldRecord: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int = OtherAudioHoldRecord.currentVersion
  var id: UUID
  var pid: Int32
  var mode: String
  var createdAt: Date
  var original: OutputVolumeSnapshot
  var intendedVolume: Float?
  var intendedMute: Bool?
  var volume: OtherAudioPropertyDisposition
  var mute: OtherAudioPropertyDisposition
  var appliedVolume: Float?
  var appliedMute: Bool?
  var media: OtherAudioMediaDisposition
  var pausedTargets: [String] = []

  /// R1 for a decoded record of the current version.
  var mayRetire: Bool {
    !volume.blocksRetirement && !mute.blocksRetirement && media != .pending
  }
}

/// One file per hold id; every read-modify-write for one id runs under one lock
/// so a late media completion for hold A can never clobber hold B (R5).
final class OtherAudioHoldStore: @unchecked Sendable {
  private let directory: URL
  private let lock = NSLock()

  /// Production location: `~/Library/Application Support/EnviousWispr/other-audio-holds/`.
  convenience init() {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    self.init(
      directory: base.appendingPathComponent("EnviousWispr", isDirectory: true)
        .appendingPathComponent("other-audio-holds", isDirectory: true))
  }

  /// Test seam: a per-test temporary directory.
  init(directory: URL) {
    self.directory = directory
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func url(for id: UUID) -> URL {
    directory.appendingPathComponent("\(id.uuidString).json")
  }

  /// The hardened write (`ImportedContactsStateStore` sequence): temp file created
  /// with mode 0600, written, closed, then atomically replaced into place. A throw
  /// means the caller must not mutate the device (P1 requires the acknowledgement).
  func write(_ record: OtherAudioHoldRecord) throws {
    try lock.withLock { try writeUnlocked(record) }
  }

  /// Read-modify-write under the lock. Returns false when no record exists for
  /// the id (already retired), in which case nothing is written.
  @discardableResult
  func update(id: UUID, _ mutate: (inout OtherAudioHoldRecord) -> Void) throws -> Bool {
    try lock.withLock {
      guard var record = try Self.decode(at: url(for: id)) else { return false }
      mutate(&record)
      try writeUnlocked(record)
      return true
    }
  }

  private func writeUnlocked(_ record: OtherAudioHoldRecord) throws {
    // Caller holds the lock.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let final = url(for: record.id)
    let tmp = directory.appendingPathComponent(".\(record.id.uuidString).json.tmp")
    let fm = FileManager.default
    do {
      // POSIX write + `Darwin.close`, not `FileHandle.close()`: this module's
      // overlay freeze (`OverlayRetainedWindowTests.nothingClosesAWindow`) bans
      // every `.close()` member call in AppKit sources, and a file descriptor is
      // not a window.
      let fd = Foundation.open(tmp.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      var written = 0
      try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        while written < buffer.count {
          let n = Darwin.write(fd, buffer.baseAddress! + written, buffer.count - written)
          guard n > 0 else {
            _ = Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
          }
          written += n
        }
      }
      guard Darwin.close(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
      if fm.fileExists(atPath: final.path) {
        _ = try fm.replaceItemAt(final, withItemAt: tmp)
      } else {
        try fm.moveItem(at: tmp, to: final)
      }
    } catch {
      try? fm.removeItem(at: tmp)
      throw error
    }
  }

  /// nil when absent or not a current-version record (the caller then has no
  /// obligation it can act on).
  func read(id: UUID) -> OtherAudioHoldRecord? {
    lock.withLock { (try? Self.decode(at: url(for: id))) ?? nil }
  }

  /// Retires a record. Removing a file that is already gone is not an error.
  func remove(id: UUID) {
    lock.withLock {
      try? FileManager.default.removeItem(at: url(for: id))
    }
  }

  /// Every decodable record of the current version. An undecodable or
  /// unknown-version file is R6: deleted and reported through `rejected`, with
  /// no device or media command ever issued for it.
  func readAll(rejected: (String) -> Void = { _ in }) -> [OtherAudioHoldRecord] {
    lock.withLock {
      let fm = FileManager.default
      guard
        let names = try? fm.contentsOfDirectory(atPath: directory.path)
      else { return [] }
      var out: [OtherAudioHoldRecord] = []
      for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
        let fileURL = directory.appendingPathComponent(name)
        if let record = try? Self.decode(at: fileURL) {
          out.append(record)
        } else {
          try? fm.removeItem(at: fileURL)
          rejected(name)
        }
      }
      return out
    }
  }

  /// nil when the file does not exist; throws when it exists and is not a
  /// current-version record.
  private static func decode(at fileURL: URL) throws -> OtherAudioHoldRecord? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    let record = try JSONDecoder().decode(OtherAudioHoldRecord.self, from: data)
    guard record.version == OtherAudioHoldRecord.currentVersion else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return record
  }
}
