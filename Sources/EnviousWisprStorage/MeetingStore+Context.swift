import EnviousWisprCore
import Foundation

/// The meeting's facts, `context.json` (#4286): the calendar event it matched and who was
/// invited, each fact stamped with its source. Kept on this Mac only, beside `meeting.json`.
/// Delete audio keeps it (it holds no audio); Delete meeting removes it with the folder.
///
/// The file's own `formatVersion` is never a reason to refuse: its vocabulary is open
/// (`MeetingContext`), so any readable file is read and appended to. Every append is checked
/// against the meeting at the moment it lands, on the caller's serial meeting file operation, so
/// an append queued before a deletion never recreates the folder or its files.
extension MeetingStore {
  public static let contextFileName = "context.json"

  public func contextURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.contextFileName)
  }

  public enum ContextError: Error, Equatable {
    /// The meeting's folder or `meeting.json` is gone or unreadable.
    case meetingMissing
    /// The meeting is marked for deletion.
    case meetingDeleting
    /// A newer build wrote the meeting's `meeting.json`.
    case newerFormat
    /// The existing `context.json` could not be read as a context; it is kept as it is.
    case existingUnreadable
  }

  /// What a read of `context.json` found.
  public enum MeetingContextLoad: Sendable, Equatable {
    case loaded(MeetingContext)
    /// No file: no facts were captured for this meeting.
    case absent
    /// Something is at the path but could not be read or decoded as a context.
    case unreadable
  }

  /// Reads the exact `context.json` path once. Never creates, repairs or writes anything.
  public func loadContext(meeting id: UUID) -> MeetingContextLoad {
    let url = contextURL(for: id)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return Self.contextConfirmedAbsent(url) ? .absent : .unreadable
    }
    guard let context = try? Self.decoder.decode(MeetingContext.self, from: data) else {
      return .unreadable
    }
    return .loaded(context)
  }

  /// Adds `facts` after the existing ones and replaces `context.json` atomically at 0600
  /// (`atomicWrite`, with its documented outcomes on failure). Existing facts are written back
  /// from their raw values, never rebuilt. Refuses, before anything is written: a meeting whose
  /// folder or `meeting.json` is gone or unreadable, one a newer build wrote, one marked for
  /// deletion, and an existing `context.json` that cannot be read.
  public func appendFacts(_ facts: [MeetingFact], meeting id: UUID) throws {
    try refuseContextWrite(id)
    var context: MeetingContext
    switch loadContext(meeting: id) {
    case .absent: context = MeetingContext()
    case .loaded(let existing): context = existing
    case .unreadable: throw ContextError.existingUnreadable
    }
    context.append(facts)
    try Self.atomicWrite(try Self.encoder.encode(context), to: contextURL(for: id))
  }

  private func refuseContextWrite(_ id: UUID) throws {
    // Checked first so a missing folder is never recreated by the write below.
    guard FileManager.default.fileExists(atPath: recordURL(for: id).path) else {
      throw ContextError.meetingMissing
    }
    if let header = try? header(id: id), header.formatVersion > MeetingRecord.currentFormatVersion {
      throw ContextError.newerFormat
    }
    let record: MeetingRecord
    do {
      record = try load(id: id)
    } catch {
      throw ContextError.meetingMissing
    }
    guard !record.deletionRequested else { throw ContextError.meetingDeleting }
  }

  /// True only when `lstat` says the path does not exist.
  private static func contextConfirmedAbsent(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return false }
    return errno == ENOENT
  }
}
