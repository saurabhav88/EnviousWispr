import EnviousWisprCore
import Foundation

/// Keeps one meeting's processing checkpoint in `<meeting folder>/work/checkpoint.json`
/// (#3972 C3b), apart from its audio and from dictation's recovery files.
///
/// Every save publishes a complete private file atomically (`MeetingStore.atomicWrite`: write,
/// `F_FULLFSYNC`, replace), so a crash or failed save leaves the previous valid checkpoint. An
/// unreadable file is reported as such, never as "no checkpoint".
public struct MeetingProcessingCheckpointStore: Sendable {
  public enum Loaded: Equatable, Sendable {
    case none
    case checkpoint(MeetingProcessingCheckpoint)
    /// Present but not decodable, or written by a newer format: ignored, not trusted.
    case unusable
  }

  public let directory: URL
  public var fileURL: URL { directory.appendingPathComponent("checkpoint.json") }

  public init(meetingFolder: URL) {
    directory = meetingFolder.appendingPathComponent("work", isDirectory: true)
  }

  public func load() -> Loaded {
    load(acceptingFormatVersion: MeetingProcessingCheckpoint.currentFormatVersion)
  }

  /// `load()` as a build that reads only `acceptingFormatVersion` would: the rollback check
  /// (#4105) drives this same reader with the old version, so it proves what an older build
  /// does with a newer file.
  package func load(acceptingFormatVersion: Int) -> Loaded {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .none
    } catch {
      return .unusable
    }
    guard
      let checkpoint = try? JSONDecoder().decode(MeetingProcessingCheckpoint.self, from: data),
      checkpoint.formatVersion == acceptingFormatVersion
    else { return .unusable }
    return .checkpoint(checkpoint)
  }

  public enum SaveError: Error, Equatable {
    /// The meeting folder is gone (deleted): a late save never recreates it.
    case meetingFolderMissing
  }

  public func save(_ checkpoint: MeetingProcessingCheckpoint) throws {
    let meetingFolder = directory.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: meetingFolder.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw SaveError.meetingFolderMissing }
    // Only `work/` itself is created; never the meeting folder above it.
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try MeetingStore.atomicWrite(try encoder.encode(checkpoint), to: fileURL)
  }

  /// Removes the checkpoint once the finished transcript is durably committed (C4a/C4b).
  public func clear() throws {
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}
