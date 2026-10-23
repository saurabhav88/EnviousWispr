import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Observation

/// Decodes closed capture files of the recording meeting into live words, one at a time,
/// yielding to the final pass (#3972 R42, R43, R50, R52). Moved out of `MeetingCoordinator`
/// (#3995), which keeps the live words themselves (`liveTranscript`, created and cleared by
/// the recording lifecycle) and answers this scheduler's questions through `Host`.
///
/// Teardown: a Stop calls off the meeting's queued files and a preview still waiting for
/// admission (`stopRecording(of:)`); a final pass waits for any running unit and the unload
/// before loading its own engine (`yieldEngine`); a deletion waits for the lane to let go of
/// the meeting's files before they are removed (`drain(of:)`); quit only cancels
/// (`cancelForQuit`), as before: it does not wait for an idle engine to unload.
@MainActor
@Observable
final class MeetingLivePreviewScheduler {
  /// What the scheduler asks its meeting owner. Set once by the owner after its own init.
  struct Host {
    var isQuitting: @MainActor () -> Bool = { true }
    var isDeleting: @MainActor (UUID) -> Bool = { _ in true }
    /// The meeting is the one recording now.
    var isRecording: @MainActor (UUID) -> Bool = { _ in false }
    /// A final pass or its commit runs (never "the queue has work").
    var finalPassBusy: @MainActor () -> Bool = { false }
    /// Returns once the running final pass has ended.
    var waitForPassEnd: @MainActor () async -> Void = {}
    var liveTranscript: @MainActor () -> MeetingCoordinator.LiveTranscript? = { nil }
    var setLiveTranscript: @MainActor (MeetingCoordinator.LiveTranscript?) -> Void = { _ in }
    var folder: @MainActor (UUID) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }
    var workChanged: @MainActor () -> Void = {}
  }

  @ObservationIgnored var host = Host()
  /// Nil shows no live words.
  private let makeJob: (@MainActor () -> MeetingPreviewing)?
  private let idleWait: @Sendable () async -> Void

  init(makeJob: (@MainActor () -> MeetingPreviewing)?, idleWait: @escaping @Sendable () async -> Void) {
    self.makeJob = makeJob
    self.idleWait = idleWait
  }

  private var quitting: Bool { host.isQuitting() }

  private var liveTranscript: MeetingCoordinator.LiveTranscript? {
    get { host.liveTranscript() }
    set { host.setLiveTranscript(newValue) }
  }

  /// The preview engine is loaded (dictation's Ultra activation waits, C3a).
  var isEngineResident: Bool { previewJob?.isEngineResident ?? false }

  /// Stop (R42): the after-recording pass makes the real words, so the meeting's queued files
  /// are dropped and a preview still waiting for admission is called off (a decode already
  /// running finishes).
  func stopRecording(of meetingID: UUID) {
    dropQueued(of: meetingID)
    if currentPreviewItem?.meetingID == meetingID {
      previewJob?.cancel()
      previewJobCancelled = true
    }
  }

  /// Quit (R18): cancels the job and the scheduler's tasks; nothing waits.
  func cancelForQuit() {
    previewJob?.cancel()
    previewTask?.cancel()
    previewIdleTask?.cancel()
  }

  /// Closed capture files waiting for a preview unit, oldest first (R42, R43).
  private var previewQueue: [PreviewItem] = []
  private struct PreviewItem {
    let meetingID: UUID
    let track: MeetingTrackKind
    let info: MeetingSegmentInfo
  }
  private var previewJob: MeetingPreviewing?
  /// The preview job was cancelled (deletion, a final pass, quit): it is unloaded and replaced
  /// before the next preview, never reused (its cancel is permanent).
  private var previewJobCancelled = false
  private var previewTask: Task<Void, Never>?
  private var previewIdleTask: Task<Void, Never>?
  /// The preview lane (Codex C10 r1): every preview unit, idle unload and hand-over unload runs
  /// on it, one after another, so an unload never overlaps a unit and a caller can await the
  /// lane's end. `laneOps` counts operations queued or running on it.
  private var previewLane: Task<Void, Never>?
  private(set) var laneOps = 0
  /// The file the running preview operation decodes, and the track decoded last (round robin).
  private var currentPreviewItem: PreviewItem?
  private var lastPreviewTrack: MeetingTrackKind?
  /// The meeting whose audio the preview job decoded last: deleting it unloads the job even
  /// when idle (Codex C10 r2).
  private var previewJobMeetingID: UUID?
  /// At most this many queued preview files per track (R52); the oldest drops first.
  static let previewQueueCapPerTrack = 3
  /// Queues one closed capture file of the recording meeting. Per track at most
  /// `previewQueueCapPerTrack` wait; the oldest of that track drops first and is counted.
  func enqueue(_ meetingID: UUID, track: MeetingTrackKind, _ info: MeetingSegmentInfo) {
    guard makeJob != nil, liveTranscript?.meetingID == meetingID else { return }
    queuePreview(PreviewItem(meetingID: meetingID, track: track, info: info))
    // Ends an idle wait at once. Redundant by design: the queue's end schedules the wait again
    // (cancelling this one), and the unload itself refuses while a unit runs or a file waits;
    // a mutation removing this line alone therefore changes nothing a user sees (C10).
    previewIdleTask?.cancel()
    previewIdleTask = nil
    guard previewTask == nil else { return }
    previewTask = Task { [weak self] in
      await self?.runPreviewQueue()
      self?.previewTask = nil
      self?.schedulePreviewIdleUnload()
    }
  }

  /// Adds a file in timeline order, whatever order the files arrived in (each arrives after its
  /// own record save, and saves of files closed together may finish in any order), then applies
  /// the per-track limit.
  private func queuePreview(_ item: PreviewItem) {
    let index =
      previewQueue.firstIndex { $0.info.startMs > item.info.startMs } ?? previewQueue.endIndex
    previewQueue.insert(item, at: index)
    trimPreviewQueue(track: item.track)
  }

  /// Keeps the newest `previewQueueCapPerTrack` files of `track`, oldest first out, counting
  /// each dropped file as skipped. Every insertion goes through here (Codex C10 r2).
  private func trimPreviewQueue(track: MeetingTrackKind) {
    while previewQueue.filter({ $0.track == track }).count > Self.previewQueueCapPerTrack,
      let oldest = previewQueue.indices.filter({ previewQueue[$0].track == track }).min(by: {
        previewQueue[$0].info.startMs < previewQueue[$1].info.startMs
      })
    {
      previewQueue.remove(at: oldest)
      liveTranscript?.skipped += 1
    }
    liveTranscript?.queued = previewQueue.count
  }

  func dropQueued(of meetingID: UUID) {
    previewQueue.removeAll { $0.meetingID == meetingID }
    if liveTranscript?.meetingID == meetingID { liveTranscript?.queued = previewQueue.count }
  }

  /// Runs `op` on the preview lane after everything already on it, and waits for it.
  private func onPreviewLane(_ op: @escaping @MainActor () async -> Void) async {
    let previous = previewLane
    laneOps += 1
    let task = Task { @MainActor in
      await previous?.value
      await op()
    }
    previewLane = task
    await task.value
    laneOps -= 1
    if previewLane == task { previewLane = nil }
  }

  /// The next queued file: round robin between the tracks when both wait (R52), oldest first
  /// within a track.
  private func nextPreviewItem() -> PreviewItem? {
    if let last = lastPreviewTrack, let other = previewQueue.firstIndex(where: { $0.track != last })
    {
      return previewQueue.remove(at: other)
    }
    return previewQueue.isEmpty ? nil : previewQueue.removeFirst()
  }

  /// One preview unit at a time on the lane, and never while a final pass or its commit runs
  /// (R50: final first). A unit a final pass interrupted while it still waited for admission
  /// goes back to the front of the queue.
  private func runPreviewQueue() async {
    while !quitting, !previewQueue.isEmpty {
      if host.finalPassBusy() {
        await host.waitForPassEnd()
        continue
      }
      guard let item = nextPreviewItem() else { break }
      liveTranscript?.queued = previewQueue.count
      guard liveTranscript?.meetingID == item.meetingID else { continue }
      var outcome: PreviewOutcome = .skipped
      await onPreviewLane { [weak self] in
        guard let self else { return }
        outcome = await self.decodePreview(item)
      }
      lastPreviewTrack = item.track
      host.workChanged()
      guard var transcript = liveTranscript, transcript.meetingID == item.meetingID else {
        continue
      }
      let endMs = item.info.startMs + item.info.durationMs
      switch outcome {
      case .words(let words):
        if !words.isEmpty {
          transcript.lines.append(
            MeetingCoordinator.LiveLine(
              id: "\(item.track.rawValue)-\(item.info.index)", track: item.track,
              startMs: item.info.startMs, endMs: endMs, text: words))
          transcript.lines.sort {
            ($0.startMs, $0.track.rawValue) < ($1.startMs, $1.track.rawValue)
          }
        }
        transcript.wordsUpToMs = max(transcript.wordsUpToMs ?? 0, endMs)
      case .skipped:
        // Unreadable or failed audio never moves the freshness time (Codex C10 r1).
        transcript.skipped += 1
      case .dropped:
        continue
      case .interrupted:
        // A final pass came first while it waited; it is decoded after that pass.
        liveTranscript = transcript
        if host.isRecording(item.meetingID) {
          queuePreview(item)
        }
        continue
      }
      liveTranscript = transcript
    }
  }

  private enum PreviewOutcome: Equatable {
    case words(String)
    case skipped
    case interrupted
    /// The recording ended, the meeting is being deleted or the app quits: nothing to show.
    case dropped
  }

  /// One preview unit, on the lane: the file read, then the job's admission and decode.
  /// Whether `item` may start model work now (Codex C10 r3): its meeting still records, the
  /// app is not quitting, the meeting is not being deleted, and no final pass or commit waits.
  /// Asked when the lane starts the item and again after each wait before model work; work
  /// already running natively may finish.
  private func previewAdmission(_ item: PreviewItem) -> PreviewOutcome? {
    guard !quitting, !host.isDeleting(item.meetingID),
      liveTranscript?.meetingID == item.meetingID, host.isRecording(item.meetingID)
    else { return .dropped }
    if host.finalPassBusy() { return .interrupted }
    return nil
  }

  /// One preview unit, on the lane: the file read, then the job's admission and decode.
  private func decodePreview(_ item: PreviewItem) async -> PreviewOutcome {
    if let refused = previewAdmission(item) { return refused }
    if previewJobCancelled {
      await previewJob?.releaseIdle()
      previewJob = nil
      previewJobCancelled = false
      if let refused = previewAdmission(item) { return refused }
    }
    let url = host.folder(item.meetingID).appendingPathComponent(item.info.fileName)
    // Detached, not `Task {}`: this type is @MainActor and a plain Task inherits it; this is
    // a synchronous header and frame-count read of the file. Awaited at once.
    let audio = await Task.detached(priority: .utility) {
      MeetingTrackAudio(files: [(url: url, startMs: item.info.startMs)])
    }.value
    // Asked again after the read and before any job or engine exists for it.
    if let refused = previewAdmission(item) { return refused }
    let job = previewJob ?? makePreviewJob()
    currentPreviewItem = item
    previewJobMeetingID = item.meetingID
    defer { currentPreviewItem = nil }
    do {
      guard let words = try await job.preview(audio: audio) else { return .skipped }
      return .words(words.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch MeetingTranscriptionJob.JobError.cancelled {
      // Called off while it waited: a final pass came first, or the recording ended.
      return previewAdmission(item) == .dropped ? .dropped : .interrupted
    } catch {
      return .skipped
    }
  }

  private func makePreviewJob() -> MeetingPreviewing {
    let job = makeJob!()
    job.onWaitingForDictation = { [weak self] waiting in
      self?.liveTranscript?.waitingForDictation = waiting
    }
    previewJob = job
    return job
  }

  /// R43: with nothing queued for `previewIdleWait`, the preview engine unloads on the lane and
  /// gives its model use back. A new queued file cancels the wait.
  private func schedulePreviewIdleUnload() {
    guard !quitting, previewQueue.isEmpty, let previewJob, previewJob.isEngineResident else {
      return
    }
    let wait = idleWait
    previewIdleTask?.cancel()
    previewIdleTask = Task { [weak self] in
      await wait()
      guard !Task.isCancelled, let self, self.previewQueue.isEmpty else { return }
      await self.onPreviewLane { [weak self] in
        guard let self, self.previewQueue.isEmpty else { return }
        await self.previewJob?.releaseIdle()
      }
      self.host.workChanged()
    }
  }

  /// Before a final pass loads its engine (R50): a preview still waiting for admission is
  /// called off (its file goes back to the queue), one already decoding finishes, then the
  /// preview engine unloads on the lane. Returns once that unload is done.
  func yieldEngine() async {
    previewIdleTask?.cancel()
    previewIdleTask = nil
    if currentPreviewItem != nil {
      previewJob?.cancel()
      previewJobCancelled = true
    }
    await onPreviewLane { [weak self] in
      guard let self else { return }
      await self.previewJob?.releaseIdle()
      if self.previewJobCancelled {
        self.previewJob = nil
        self.previewJobCancelled = false
      }
    }
  }

  /// Deletion's drain (Codex C10 r1): no new preview of `meetingID` starts, a running one is
  /// called off (admission waits end; a decode already running finishes), and the lane's work
  /// and the unload end before the meeting's files are removed.
  func drain(of meetingID: UUID) async {
    dropQueued(of: meetingID)
    if currentPreviewItem?.meetingID == meetingID {
      previewJob?.cancel()
      previewJobCancelled = true
    }
    await onPreviewLane { [weak self] in
      // Its job is unloaded when it was cancelled, or when it holds this meeting's engine idle;
      // another meeting's preview is left alone.
      guard let self, self.previewJobCancelled || self.previewJobMeetingID == meetingID else {
        return
      }
      await self.previewJob?.releaseIdle()
      if self.previewJobCancelled {
        self.previewJob = nil
        self.previewJobCancelled = false
      }
      self.previewJobMeetingID = nil
    }
    if liveTranscript?.meetingID == meetingID { liveTranscript = nil }
  }
}
