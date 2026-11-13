import EnviousWisprCore
import Foundation

/// #3147 PR4B: compacts finished meetings' audio in the background, one meeting at a time,
/// with no setting, dialog or user-visible step (plan §17 delegated choices).
///
/// It runs only when nothing more important does: dictation is idle, no meeting records or
/// transcribes, and the shared local model lane is free (`mayRun`). Preparation itself runs
/// off the main actor at utility priority (`MeetingAudioCompactor`). Every claim, check and
/// publication belongs to `MeetingCoordinator.compactAudio`; this type only chooses when and
/// which meeting.
///
/// - A meeting whose copy would save nothing is not tried again this session.
/// - A meeting playing when its copy was ready, or one that changed meanwhile, is tried again
///   once the meeting list changes (a later pass), never in a tight loop.
/// - A failed preparation or publication keeps the meeting's usable audio and is tried again at
///   the next launch.
/// - Quit stops it; a cancelled preparation removes its own uncommitted files.
///
/// Observation drives every wait (`MeetingWorkAdmission`): no timer and no polling.
@MainActor
final class MeetingAudioCompactionScheduler {
  struct Dependencies {
    /// Whether background work may run now: dictation idle and the local model lane free.
    var mayRun: @MainActor () -> Bool
    /// Poked when an input `mayRun` reads that is not observable changes.
    var wakes: MeetingWakeSignal?
    var log: @MainActor (String) -> Void
  }

  private weak var coordinator: MeetingCoordinator?
  private let compactor: any MeetingAudioCompacting
  private let deps: Dependencies
  private var task: Task<Void, Never>?
  /// Meetings not tried again this session (no savings, or a failure).
  private var settled: Set<UUID> = []
  /// Meetings tried again only after the meeting list changes (deferred while playing, or
  /// changed under their claim).
  private var deferred: Set<UUID> = []

  init(
    coordinator: MeetingCoordinator, compactor: any MeetingAudioCompacting,
    dependencies: Dependencies
  ) {
    self.coordinator = coordinator
    self.compactor = compactor
    self.deps = dependencies
  }

  /// Starts the background owner (after launch recovery). Repeatable.
  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in await self?.run() }
  }

  /// Stops it for good (Quit). The coordinator withdraws any claim and cancels the running
  /// preparation itself.
  func stop() {
    task?.cancel()
    task = nil
  }

  var isRunning: Bool { task != nil }

  private func run() async {
    while !Task.isCancelled {
      await MeetingWorkAdmission.waitUntil(
        { [weak self] in self?.mayWork ?? true }, wakes: deps.wakes)
      guard !Task.isCancelled, let coordinator else { return }
      let candidates = coordinator.audioCompactionCandidates().filter {
        !settled.contains($0) && !deferred.contains($0)
      }
      guard let meetingID = candidates.first else {
        // Nothing to do until the meeting list changes (a meeting became ready, or one deferred
        // may be tried again).
        let snapshot = coordinator.meetings
        await MeetingWorkAdmission.waitUntil { [weak coordinator] in
          coordinator.map { $0.meetings != snapshot } ?? true
        }
        deferred.removeAll()
        continue
      }
      switch await coordinator.compactAudio(meetingID: meetingID, with: compactor) {
      case .committed:
        deps.log("meeting compaction committed")
      case .noSavings:
        settled.insert(meetingID)
      case .failed:
        settled.insert(meetingID)
      case .deferred, .stale:
        deferred.insert(meetingID)
      }
    }
  }

  /// Background work waits for dictation, the local model lane, recording and every pass.
  private var mayWork: Bool {
    guard let coordinator else { return true }
    return !coordinator.isCapturing && !coordinator.hasFinalPassWork && deps.mayRun()
  }
}
