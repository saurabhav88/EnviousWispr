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
  /// A meeting log is a few kilobytes a minute; this bounds a read of a damaged or hostile file
  /// without limiting any real meeting.
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
  /// disk that a newer build wrote; and a log whose shape is wrong.
  public func saveCallSpeakers(_ log: CallSpeakerLog, meeting id: UUID) throws {
    if let problem = log.shapeProblem { throw CallSpeakersError.invalidLog(problem) }
    try refuseCallSpeakersWrite(id)
    if case .unusable(.newerFormat) = loadCallSpeakers(meeting: id) {
      throw CallSpeakersError.newerFormat
    }
    try Self.atomicWrite(try Self.encoder.encode(log), to: callSpeakersURL(for: id))
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
  /// (`.call-speakers.json.<uuid>.tmp` / `.bak`). Other meeting files are untouched.
  func removeCallSpeakers(meeting id: UUID) throws {
    let fm = FileManager.default
    let dir = folder(for: id)
    let leftoverPrefix = ".\(Self.callSpeakersFileName)."
    for name in try fm.contentsOfDirectory(atPath: dir.path)
    where name == Self.callSpeakersFileName
      || (name.hasPrefix(leftoverPrefix) && (name.hasSuffix(".tmp") || name.hasSuffix(".bak")))
    {
      try fm.removeItem(at: dir.appendingPathComponent(name))
    }
  }

  /// True only when `lstat` says the path does not exist.
  private static func confirmedAbsent(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return false }
    return errno == ENOENT
  }
}
