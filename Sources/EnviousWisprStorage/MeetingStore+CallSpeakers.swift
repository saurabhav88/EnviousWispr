import EnviousWisprCore
import Foundation

/// The meeting's call-speaker evidence, `call-speakers.json` (#4013 r2 item 3): who the call app
/// showed as talking, its participant list, the lag and the talker rules frozen at recording
/// start. Kept on this Mac only, beside the audio it describes: Delete audio removes it with the
/// segment files, and Delete meeting removes it with the folder.
///
/// What each boundary checks: decoding checks the log's shape (`CallSpeakerLog.shapeProblem`);
/// the frozen rules' content is judged only by the rules store's decoder when a later pass thaws
/// them, never here. Every write is checked again at the moment it lands, on the meeting file
/// queue, so a write queued before a deletion never recreates the data.
extension MeetingStore {
  public static let callSpeakersFileName = "call-speakers.json"
  /// Bounds every read and every write of the file, so a damaged or hostile file is never loaded
  /// whole and a save never produces a file the loader refuses. A log over it is not saved.
  public static let maximumCallSpeakersBytes = 16 * 1024 * 1024

  public func callSpeakersURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.callSpeakersFileName)
  }

  public enum CallSpeakersError: Error, Equatable {
    /// The meeting's folder or `meeting.json` is gone or unreadable.
    case meetingMissing
    /// The meeting is marked for deletion.
    case meetingDeleting
    /// The meeting's audio was deleted; the evidence went with it.
    case audioDeleted
    /// A newer build wrote the meeting or its `call-speakers.json`.
    case newerFormat
    /// The log's shape is wrong (`CallSpeakerLog.shapeProblem`); nothing is written.
    case invalidLog(String)
    /// The encoded log is over `maximumCallSpeakersBytes`; nothing is written.
    case tooLarge
    /// The file on disk could not be shown to be one this build may replace (unreadable, over
    /// the size bound, not a log, or an unknown version); it is kept.
    case existingUnverifiable
  }

  /// What a read of `call-speakers.json` found. Only `.usable` is evidence; every other answer
  /// means the meeting keeps its fallback speaker labels, and none of them fails transcription.
  public enum CallSpeakersLoad: Sendable, Equatable {
    case usable(CallSpeakerLog)
    /// No file: nothing was observed, or the meeting predates speaker names.
    case absent
    case unusable(Reason)

    public enum Reason: String, Sendable, Equatable {
      case unreadable
      case tooLarge
      case newerFormat
      case invalid
    }
  }

  /// Reads the exact `call-speakers.json` path once, bounded, and validates it.
  public func loadCallSpeakers(meeting id: UUID) -> CallSpeakersLoad {
    let url = callSpeakersURL(for: id)
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      return Self.confirmedAbsent(url) ? .absent : .unusable(.unreadable)
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: Self.maximumCallSpeakersBytes + 1) else {
      return .unusable(.unreadable)
    }
    guard data.count <= Self.maximumCallSpeakersBytes else { return .unusable(.tooLarge) }
    do {
      return .usable(try Self.decoder.decode(CallSpeakerLog.self, from: data))
    } catch CallSpeakerLog.DecodeError.unsupportedFormatVersion {
      return .unusable(.newerFormat)
    } catch {
      return .unusable(.invalid)
    }
  }

  /// Replaces `call-speakers.json` atomically at 0600 (`atomicWrite`, with its documented
  /// outcomes on failure). Refuses, before anything is written: a meeting that is gone,
  /// unreadable, written by a newer build, marked for deletion or without its audio; a file on
  /// disk that a newer build wrote; and a log whose shape is wrong or that the current format
  /// cannot hold.
  public func saveCallSpeakers(_ log: CallSpeakerLog, meeting id: UUID) throws {
    // Written as the current format: a log read from an older one that the current format
    // cannot hold is refused here, and the file it came from stays as it is.
    if let problem = log.currentFormatProblem { throw CallSpeakersError.invalidLog(problem) }
    let data = try Self.encoder.encode(log)
    // A well-formed log always fits (`CallEvidenceLimits`, checked by `CallSpeakerLogSizeTests`);
    // this refuses one only if those caps and this limit ever drift apart.
    guard data.count <= Self.maximumCallSpeakersBytes else { throw CallSpeakersError.tooLarge }
    try refuseCallSpeakersWrite(id)
    try refuseReplacingUnknownCallSpeakers(id)
    try Self.atomicWrite(data, to: callSpeakersURL(for: id))
  }

  /// Replacing is allowed only when nothing is there, or the file states a version this build
  /// reads. Failing to read or recognise the file is never permission to replace it.
  private func refuseReplacingUnknownCallSpeakers(_ id: UUID) throws {
    let url = callSpeakersURL(for: id)
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      if Self.confirmedAbsent(url) { return }
      throw CallSpeakersError.existingUnverifiable
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: Self.maximumCallSpeakersBytes + 1),
      data.count <= Self.maximumCallSpeakersBytes,
      let stated = try? Self.decoder.decode(StatedVersion.self, from: data)
    else { throw CallSpeakersError.existingUnverifiable }
    if stated.formatVersion > CallSpeakerLog.currentFormatVersion {
      throw CallSpeakersError.newerFormat
    }
    // Any version this build reads (format 1 is read as one segment) may be replaced.
    guard stated.formatVersion >= 1 else { throw CallSpeakersError.existingUnverifiable }
  }

  /// Only the version field, so a log whose other fields are damaged can still be recognised
  /// as one this build wrote (and then replaced).
  private struct StatedVersion: Decodable {
    let formatVersion: Int
  }

  private func refuseCallSpeakersWrite(_ id: UUID) throws {
    if let header = try? header(id: id), header.formatVersion > MeetingRecord.currentFormatVersion {
      throw CallSpeakersError.newerFormat
    }
    let record: MeetingRecord
    do {
      record = try load(id: id)
    } catch {
      throw CallSpeakersError.meetingMissing
    }
    guard !record.deletionRequested else { throw CallSpeakersError.meetingDeleting }
    guard record.audioKept else { throw CallSpeakersError.audioDeleted }
  }

  /// Removes `call-speakers.json` and any temp or backup file a failed `atomicWrite` of it left
  /// (exactly `.call-speakers.json.<UUID>.tmp` / `.bak`). Other meeting files are untouched.
  func removeCallSpeakers(meeting id: UUID) throws {
    let fm = FileManager.default
    let dir = folder(for: id)
    for name in try fm.contentsOfDirectory(atPath: dir.path)
    where name == Self.callSpeakersFileName || Self.isCallSpeakersLeftover(name) {
      try fm.removeItem(at: dir.appendingPathComponent(name))
    }
  }

  /// `atomicWrite`'s temp and backup names for this file: the exact prefix, one UUID, then
  /// `.tmp` or `.bak`.
  static func isCallSpeakersLeftover(_ name: String) -> Bool {
    let prefix = ".\(callSpeakersFileName)."
    guard name.hasPrefix(prefix) else { return false }
    let rest = name.dropFirst(prefix.count)
    for suffix in [".tmp", ".bak"] where rest.hasSuffix(suffix) {
      return UUID(uuidString: String(rest.dropLast(suffix.count))) != nil
    }
    return false
  }

  /// True only when `lstat` says the path does not exist.
  private static func confirmedAbsent(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return false }
    return errno == ENOENT
  }
}
