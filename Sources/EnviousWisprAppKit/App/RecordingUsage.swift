import EnviousWisprStorage
import Foundation
import Observation

/// How much disk recordings use, at one moment (#3147 §3.1, §3a).
///
/// Byte definition: dictations are every file in the recording archive's folder except its
/// Spotlight marker, so audio, timing sidecars and the small Keep and reason files count, with
/// encodes in progress and interrupted metadata writes as temporary. Meetings are recognized
/// segment files only (finals committed, partials temporary; both tracks and both microphone
/// copies, each file once), never notes, summaries, records, work folders or speaker evidence.
/// The crash-recovery spool, the retired `dictation-audio` folder, imported originals and models
/// are outside both folders and never counted.
struct RecordingUsageSnapshot: Sendable, Equatable {
  enum Part: Sendable, Equatable {
    case measured(committedBytes: Int64, temporaryBytes: Int64)
    /// The folder exists but could not be listed or a file could not be measured.
    case failed

    var bytes: Int64? {
      guard case .measured(let committed, let temporary) = self else { return nil }
      return committed + temporary
    }
  }

  var dictations: Part
  var meetings: Part
  /// Meeting folders whose audio could not be measured; their audio is not in `meetings`.
  var unmeasuredMeetingFolders: Int

  /// Every part measured, nothing left out.
  var isComplete: Bool {
    dictations != .failed && meetings != .failed && unmeasuredMeetingFolders == 0
  }

  /// Total recording bytes, or nil when a part failed. With unmeasured meeting folders it is a
  /// lower bound (`isComplete` is false).
  var totalBytes: Int64? {
    guard let dictationBytes = dictations.bytes, let meetingBytes = meetings.bytes else {
      return nil
    }
    return dictationBytes + meetingBytes
  }
}

/// The read-only view of recording storage across both owners (#3147 §3b): the dictation archive
/// and the meeting folders. It deletes nothing. Every scan runs off the main actor; `latest` is
/// the most recent result for Settings and History, refreshed by `RecordingRetention` on launch,
/// wake, its six-hour timer and recording changes, never by polling.
@MainActor
@Observable
final class RecordingUsage {
  @ObservationIgnored private let archive: RecordingArchive
  @ObservationIgnored private let meetingStore: MeetingStore
  private(set) var latest: RecordingUsageSnapshot?

  init(archive: RecordingArchive, meetingStore: MeetingStore) {
    self.archive = archive
    self.meetingStore = meetingStore
  }

  /// Measures both owners now.
  @discardableResult
  func measure() async -> RecordingUsageSnapshot {
    let dictations = await measureDictations()
    let store = meetingStore
    let meetings = await Task.detached(priority: .utility) {
      () -> (RecordingUsageSnapshot.Part, Int) in
      do {
        guard let usage = try store.audioUsage() else {
          return (.measured(committedBytes: 0, temporaryBytes: 0), 0)
        }
        return (
          .measured(committedBytes: usage.committedBytes, temporaryBytes: usage.temporaryBytes),
          usage.unreadableFolders
        )
      } catch {
        return (.failed, 0)
      }
    }.value
    let snapshot = RecordingUsageSnapshot(
      dictations: dictations, meetings: meetings.0, unmeasuredMeetingFolders: meetings.1)
    latest = snapshot
    return snapshot
  }

  private func measureDictations() async -> RecordingUsageSnapshot.Part {
    do {
      let usage = try await archive.usage()
      return .measured(committedBytes: usage.committedBytes, temporaryBytes: usage.temporaryBytes)
    } catch {
      return .failed
    }
  }
}
