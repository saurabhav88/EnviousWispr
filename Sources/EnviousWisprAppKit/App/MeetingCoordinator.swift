import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprStorage
import Foundation
import Observation
import os

/// What the coordinator needs from a meeting recorder (`MeetingRecorder` in production).
@MainActor
protocol MeetingRecording: AnyObject {
  func start() async throws -> MeetingRecorder.StartResult
  func stop() async -> MeetingRecorder.StopReport
  func stopForQuit(deadline: DispatchTime) -> MeetingRecorder.StopReport
  var boundMicrophoneUID: String? { get }
  var microphoneLevel: Float { get }
  var callSoundLevel: Float { get }
}

extension MeetingRecorder: MeetingRecording {}

/// What the coordinator needs from a processing pass (`MeetingTranscriptionJob` in production).
@MainActor
protocol MeetingProcessing: AnyObject {
  func run(
    tracks: [MeetingTrackKind: MeetingTrackAudio],
    checkpoint access: MeetingTranscriptionJob.CheckpointAccess?,
    missingAudio: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]],
    onStage: @escaping @MainActor (MeetingTranscriptionJob.Stage) -> Void
  ) async throws -> MeetingTranscriptionJob.Result
  func cancel()
  var isEngineResident: Bool { get }
  var isUnitInFlight: Bool { get }
  /// Told true while a unit waits for dictation to finish, false when it goes on.
  var onWaitingForDictation: (@MainActor (Bool) -> Void)? { get set }
}

extension MeetingTranscriptionJob: MeetingProcessing {}

/// What the coordinator needs for live words (#3972 R42, R43): `MeetingTranscriptionJob`'s
/// preview units, on a job of their own with its own engine and model claim.
@MainActor
protocol MeetingPreviewing: AnyObject {
  /// The window's words, or nil when its audio cannot be read (counted as skipped).
  func preview(audio: MeetingTrackAudio) async throws -> String?
  func releaseIdle() async
  func cancel()
  var isEngineResident: Bool { get }
  var isUnitInFlight: Bool { get }
  var onWaitingForDictation: (@MainActor (Bool) -> Void)? { get set }
}

extension MeetingTranscriptionJob: MeetingPreviewing {}

/// The one serial queue every ordinary meeting file operation runs on (#3972 C4a): record
/// writes, creation, listing, audio and folder removal. Off the main actor, and in the order
/// they were asked for, so a later write of a meeting can never be overtaken by an earlier one.
/// The quit path and History's Delete All use `runBounded`, which waits behind the writes
/// already queued, but never past a deadline.
final class MeetingFileWriter: Sendable {
  /// One queue for every meeting file in the process, so even two writers (a test's relaunch)
  /// keep one order. Internal so a test can wait for it to drain.
  static let queue = DispatchQueue(label: "com.enviouswispr.meetings.files", qos: .utility)
  private var queue: DispatchQueue { Self.queue }
  let store: MeetingStore
  private let writeRecord: @Sendable (MeetingStore, MeetingRecord) throws -> Void

  init(
    store: MeetingStore,
    writeRecord: @escaping @Sendable (MeetingStore, MeetingRecord) throws -> Void
  ) {
    self.store = store
    self.writeRecord = writeRecord
  }

  /// Operations enqueued and not yet finished: a relaunch waits for them (R4).
  private let pending = OSAllocatedUnfairLock(initialState: 0)
  var pendingCount: Int { pending.withLock { $0 } }

  enum WriterError: Error, Equatable {
    /// A bounded write withdrawn because its deadline passed before it started.
    case withdrawn
  }

  func run<T: Sendable>(_ work: @escaping @Sendable (MeetingStore) throws -> T) async throws -> T {
    pending.withLock { $0 += 1 }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [store, pending] in
        let result = Result { try work(store) }
        pending.withLock { $0 -= 1 }
        continuation.resume(with: result)
      }
    }
  }

  /// How a bounded operation ended for its caller.
  enum BoundedOutcome {
    case finished(Result<Void, Error>)
    /// The deadline passed before it started; it was withdrawn and never runs.
    case withdrawn
    /// The deadline passed while it ran; `late` receives its result exactly once.
    case stillRunning
  }

  /// Runs `work` after everything already queued, waiting for it no later than `deadline`
  /// (quit, Delete All). Never an unbounded join: a stalled earlier write cannot hold the
  /// caller. An operation not started by the deadline is withdrawn; one already running
  /// reports its result to `late` when it ends.
  func runBounded(
    until deadline: DispatchTime, _ work: @escaping @Sendable (MeetingStore) throws -> Void,
    late: @escaping @Sendable (Result<Void, Error>) -> Void
  ) -> BoundedOutcome {
    enum Stage {
      case queued, running, withdrawn, runningAbandoned
      case done(Result<Void, Error>)
    }
    let stage = OSAllocatedUnfairLock<Stage>(initialState: .queued)
    let done = DispatchSemaphore(value: 0)
    pending.withLock { $0 += 1 }
    queue.async { [store, pending] in
      let proceed = stage.withLock { current -> Bool in
        guard case .queued = current else { return false }
        current = .running
        return true
      }
      guard proceed else {
        pending.withLock { $0 -= 1 }
        return
      }
      let result = Result { try work(store) }
      let reportLate = stage.withLock { current -> Bool in
        if case .runningAbandoned = current { return true }
        current = .done(result)
        return false
      }
      pending.withLock { $0 -= 1 }
      if reportLate { late(result) } else { done.signal() }
    }
    if done.wait(timeout: deadline) == .success,
      case .done(let result) = stage.withLock({ $0 })
    {
      return .finished(result)
    }
    return stage.withLock { current -> BoundedOutcome in
      switch current {
      case .queued:
        current = .withdrawn
        return .withdrawn
      case .running:
        current = .runningAbandoned
        return .stillRunning
      case .done(let result):
        // Finished just as the wait gave up.
        return .finished(result)
      case .withdrawn, .runningAbandoned:
        return .stillRunning
      }
    }
  }

  func save(_ record: MeetingRecord) async throws {
    let write = writeRecord
    try await run { try write($0, record) }
  }

  func saveBounded(
    _ record: MeetingRecord, until deadline: DispatchTime,
    late: @escaping @Sendable (Result<Void, Error>) -> Void
  ) -> BoundedOutcome {
    let write = writeRecord
    return runBounded(until: deadline, { try write($0, record) }, late: late)
  }
}

/// Owns EnviousMeet's meetings for the app's lifetime (#3972 §3.3, R3, R4, R12, R15, R18, R19):
/// recording state, one serial processing queue, launch recovery, deletion and quit.
///
/// **One owner, one of each.** At most one recorder and one processing pass exist; repeated
/// calls never create a second of either. Every step after an await re-checks that the
/// meeting it started for is still the current one (`startGeneration`, `isStillOwned`), so a
/// late result or callback is dropped, never applied.
///
/// **Two copies, one truth.** `live` is each meeting's latest intended state: every change is
/// built on it and written through `MeetingFileWriter`, and a step that resumes after an await
/// reads the meeting again from `live`, never a copy it held across the await, so a rename, a
/// deletion mark or another step's change in between is kept. `records` is what is on disk:
/// `meetings` and `record(id:)` show it, so nothing (ready included) is visible before its
/// write succeeded.
///
/// **Durable order.** A finished pass saves the History row, then `meeting.json` as ready, then
/// clears the pass's checkpoint; a failure at either save keeps the checkpoint, so Retry
/// resumes. Deletion persists its marker, cancels the pass and awaits its end (which drains any
/// checkpoint save), removes the History row, then the folder.
@MainActor
@Observable
final class MeetingCoordinator {
  struct Dependencies {
    var store: MeetingStore
    var makeRecorder:
      @MainActor (
        MeetingRecorder.Configuration, @escaping MeetingRecorder.SegmentHandler,
        @escaping MeetingRecorder.FailureHandler
      ) -> MeetingRecording
    var makeJob: @MainActor () -> MeetingProcessing
    /// Live words while a meeting records (#3972 R42): a preview job of its own. Nil shows no
    /// live words.
    var makePreviewJob: (@MainActor () -> MeetingPreviewing)?
    /// The meeting's microphone choice at Start: dictation's input setting (nil = Auto) and
    /// its channel preferences.
    var microphoneSelection: @MainActor () -> (uid: String?, channels: [String: Int])
    var captureCallSound: @MainActor () -> Bool
    var microphoneAuthorized: @MainActor () -> Bool
    /// Ends a dictation's output hold and waits for media to settle; false when it did not
    /// settle in time (R28).
    var settleDictationHold: @MainActor () async -> Bool
    var freeDiskBytes: @MainActor () -> Int64?
    /// Saves the meeting's History row durably, its disk work off the main actor; throws when
    /// it could not.
    var saveTranscript: @MainActor (Transcript) async throws -> Void
    var removeTranscriptRow: @MainActor (UUID) throws -> Void
    var emitEnded: @MainActor (MeetingEndedTelemetry) -> Void
    var log: @MainActor (String) -> Void
    /// Called whenever recording or processing work starts or ends, so admission elsewhere
    /// (dictation's Ultra activation) is offered again.
    var workChanged: @MainActor () -> Void = {}
    var beginActivity: @MainActor () -> NSObjectProtocol? = {
      ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording a meeting")
    }
    var endActivity: @MainActor (NSObjectProtocol) -> Void = {
      ProcessInfo.processInfo.endActivity($0)
    }
    /// Track recovery, run off the main actor by the coordinator.
    var recoverFolder: @Sendable (URL) -> MeetingTrackRecovery.Report = {
      MeetingTrackRecovery.recover(folder: $0)
    }
    /// The pass's checkpoint write (a durable file write), run off the main actor by the job.
    var saveCheckpoint:
      @Sendable (MeetingProcessingCheckpointStore, MeetingProcessingCheckpoint) throws -> Void = {
        try $0.save($1)
      }
    /// One `meeting.json` write, run on `MeetingFileWriter`'s queue.
    var writeRecord: @Sendable (MeetingStore, MeetingRecord) throws -> Void = { try $0.save($1) }
    /// How long the preview engine stays loaded with nothing queued (R43: 20 s). Must return
    /// promptly when its task is cancelled.
    var previewIdleWait: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(20)) }
    /// The wait between the last notes change and its save (#3972 R46).
    var notesDebounce: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
  }

  // MARK: - Observable state

  enum Phase: Equatable {
    case idle
    case starting
    case recording(meetingID: UUID, startedAt: Date)
    case stopping(meetingID: UUID)
  }

  enum Notice: Equatable {
    case microphoneDenied
    case microphoneUnavailable
    case finishDictationFirst
    case lowDisk
    case stoppedLowDisk
    case recordingStoppedFileError
    case callSoundUnavailable
    case callSoundFailed
    /// A meeting's state could not be saved; the last saved state stands.
    case storageFailed
  }

  /// One line of live words: one closed capture file of one track, decoded provisionally
  /// (R42). Never read by the after-recording pass.
  struct LiveLine: Equatable, Identifiable {
    let id: String
    let track: MeetingTrackKind
    let startMs: Int
    let endMs: Int
    let text: String
  }

  /// The recording meeting's live words and how fresh they are (R52).
  struct LiveTranscript: Equatable {
    let meetingID: UUID
    var lines: [LiveLine] = []
    /// The end of the newest decoded stretch, on the meeting timeline.
    var wordsUpToMs: Int?
    /// Closed files waiting for a preview unit.
    var queued = 0
    /// Files dropped from the queue (the cap) or that could not be decoded.
    var skipped = 0
    var waitingForDictation = false
  }

  struct Processing: Equatable {
    let meetingID: UUID
    var stage: MeetingTranscriptionJob.Stage?
    /// The pass is waiting for a dictation to finish (it never runs beside one).
    var waitingForDictation = false
  }

  private(set) var phase: Phase = .idle
  /// Every meeting, newest first: `records`, published.
  private(set) var meetings: [MeetingRecord] = []
  private(set) var newerFormatMeetings: [MeetingRecord.Header] = []
  private(set) var processing: Processing?
  private(set) var notice: Notice?
  private(set) var callSoundStatus: MeetingTrackStatus?
  /// The microphone the current recording actually bound.
  private(set) var boundMicrophoneUID: String?
  /// Live words of the meeting recording now, kept after Stop until its transcript is ready
  /// (R42, R52). Nil without a preview job.
  private(set) var liveTranscript: LiveTranscript?

  // MARK: - Private state

  private let deps: Dependencies
  private let writer: MeetingFileWriter
  /// Each meeting's notes and summary (#3972 R46): drafts, debounce and their file writes.
  let documents: MeetingDocumentsOwner
  /// Writes each ready meeting's summary (#3972 R39). Set by `MeetingWiring`; nil writes none.
  var summaries: MeetingSummaryOwner?

  /// A final pass runs, or the queue is draining runnable meetings: a local summary call waits
  /// for it (R50: final first). Derived from the queue itself, which skips meetings marked for
  /// deletion, being deleted or still closing and stops on low disk, so a meeting the queue
  /// cannot run never holds summaries back.
  var hasFinalPassWork: Bool { processing != nil || queueTask != nil }
  /// Each meeting as last written successfully: what `meetings` and `record(id:)` show, so a
  /// lifecycle step is visible only once it is durable.
  private var records: [UUID: MeetingRecord] = [:]
  /// Each meeting's latest intended state: what every next change is built on (a pending write
  /// included), so two steps in flight never lose each other's change.
  private var live: [UUID: MeetingRecord] = [:]
  /// Per meeting, the number of the latest write asked for, and of the newest one shown.
  private var writeSequence: [UUID: Int] = [:]
  private var durableSequence: [UUID: Int] = [:]
  /// Per meeting, writes asked for and not yet answered, oldest first: what a failed newer
  /// write rolls the live copy back to, so an earlier change still on its way is kept.
  private var unansweredWrites: [UUID: [(sequence: Int, record: MeetingRecord)]] = [:]
  private var recorder: MeetingRecording?
  /// The meeting the recorder writes into, from its creation until its Stop or quit finished.
  private var activeMeetingID: UUID?
  private var activity: NSObjectProtocol?
  private var job: MeetingProcessing?
  private var queueTask: Task<Void, Never>?
  private var quitting = false
  private var launched = false
  private var launchTask: Task<Void, Never>?
  private var committing = false
  private var deleting: Set<UUID> = []
  private var startGeneration = 0
  private var processEndWaiters: [CheckedContinuation<Void, Never>] = []
  /// Open meeting attempts and the facts frozen at their start (#3972 R11). An attempt is one
  /// Start whose meeting exists, one Retry, or a meeting this launch found unfinished; it ends
  /// with exactly one `meeting.ended` row, and is removed then. In memory only: after a
  /// relaunch the facts are unknown (nil), never guessed.
  private var openAttempts: [UUID: AttemptFacts] = [:]

  /// The facts of each meeting's last ended attempt, for a Retry of the same recording.
  private var lastAttemptFacts: [UUID: AttemptFacts] = [:]

  struct AttemptFacts: Equatable {
    var entryPoint: MeetingEntryPoint?
    var diskStopped: Bool?
  }
  /// Meetings whose files a timed-out close still owns this session (only `stopForQuit` can time
  /// out; a normal stop awaits the physical close). Nothing reads, promotes or removes them
  /// until the next launch.
  private var closeOwned: Set<UUID> = []
  /// Listing, recovery and file reads in flight, on the main actor's books.
  private var fileWorkInFlight = 0
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
  /// lane's end. `previewLaneOps` counts operations queued or running on it.
  private var previewLane: Task<Void, Never>?
  private(set) var previewLaneOps = 0
  /// The file the running preview operation decodes, and the track decoded last (round robin).
  private var currentPreviewItem: PreviewItem?
  private var lastPreviewTrack: MeetingTrackKind?
  /// The meeting whose audio the preview job decoded last: deleting it unloads the job even
  /// when idle (Codex C10 r2).
  private var previewJobMeetingID: UUID?
  /// At most this many queued preview files per track (R52); the oldest drops first.
  static let previewQueueCapPerTrack = 3
  /// Checkpoint writes running off the main actor right now.
  @ObservationIgnored private let checkpointWrites = OSAllocatedUnfairLock(initialState: 0)

  /// Minimum free space to start or keep recording, and to start a pass.
  static let diskFloorBytes: Int64 = 1_000_000_000

  init(dependencies: Dependencies) {
    self.deps = dependencies
    let writer = MeetingFileWriter(
      store: dependencies.store, writeRecord: dependencies.writeRecord)
    self.writer = writer
    self.documents = MeetingDocumentsOwner(
      writer: writer,
      dependencies: .init(debounce: dependencies.notesDebounce, log: dependencies.log))
  }

  // MARK: - Queries

  var isRecording: Bool {
    if case .recording = phase { return true }
    return false
  }

  /// True while a meeting is starting, recording or stopping (R10: dictation's output hold
  /// stays off for that whole interval).
  var isCapturing: Bool { phase != .idle }

  /// True while capture, a physical pass unit, file reads, a checkpoint write, a commit, a
  /// deletion or typed notes not yet saved is in progress: a relaunch must wait (R4, R19, R46). A queued meeting alone resumes
  /// after a relaunch.
  var isWorkInFlight: Bool {
    isCapturing || (job?.isUnitInFlight ?? false) || previewLaneOps > 0 || committing
      || !deleting.isEmpty
      || fileWorkInFlight > 0 || checkpointWrites.withLock { $0 } > 0
      || writer.pendingCount > 0 || documents.hasPendingWork
      || (summaries?.hasWorkInFlight ?? false)
  }

  /// Live facts of the running pass for diagnostics (#3972 C6a, DEBUG dev control), or nil when
  /// no pass runs. Read-only views of the job's own state; nothing here is a second copy.
  struct PassDiagnostics: Equatable {
    let isUnitInFlight: Bool
    let isEngineResident: Bool
  }

  var passDiagnostics: PassDiagnostics? {
    job.map {
      PassDiagnostics(isUnitInFlight: $0.isUnitInFlight, isEngineResident: $0.isEngineResident)
    }
  }

  /// Whether a timed-out close still owns this meeting's files until the next launch.
  func isCloseOwned(_ meetingID: UUID) -> Bool { closeOwned.contains(meetingID) }

  /// Meeting file operations asked for and not yet finished (read-only; a test waits on it).
  nonisolated var queuedFileOperations: Int { writer.pendingCount }

  /// A meeting's own engine is loaded or a meeting unit is running: dictation's Ultra
  /// activation waits (C3a, C4a).
  var isMeetingModelWorkActive: Bool {
    (job?.isEngineResident ?? false) || (job?.isUnitInFlight ?? false)
      || (previewJob?.isEngineResident ?? false) || previewLaneOps > 0
  }

  var microphoneLevel: Float { recorder?.microphoneLevel ?? 0 }
  var callSoundLevel: Float { recorder?.callSoundLevel ?? 0 }

  /// The meeting as it is on disk (the last successful write).
  func record(id: UUID) -> MeetingRecord? { records[id] }

  /// What playback may read for this meeting, from the saved record; nil when the meeting is
  /// unknown, keeps no audio, is being deleted, is still recording or saving (its files are
  /// still open), or is held by a timed-out close until the next launch (`closeOwned`). A
  /// meeting being transcribed plays: its files are final.
  func playbackSource(meetingID: UUID) -> MeetingPlaybackSource? {
    guard let record = records[meetingID], record.audioKept, !deleting.contains(meetingID),
      !closeOwned.contains(meetingID), !record.deletionRequested, record.state != .recording,
      record.state != .stopping
    else { return nil }
    switch phase {
    case .recording(let id, _), .stopping(let id):
      if id == meetingID { return nil }
    case .idle, .starting: break
    }
    return MeetingPlaybackSource(record: record, folder: deps.store.folder(for: meetingID))
  }

  /// The kept audio's size for the detail view, read on the meeting file queue (never on the
  /// main actor). A meeting without audio reads `.deleted`; a read that fails says so rather
  /// than showing zero.
  func audioSize(meetingID: UUID) async -> MeetingsPresentation.AudioSize {
    guard let record = records[meetingID] else { return .unreadable }
    guard record.audioKept else { return .deleted }
    do {
      return .bytes(try await writer.run { try $0.audioBytes(meeting: meetingID) })
    } catch {
      return .unreadable
    }
  }

  func dismissNotice() { notice = nil }

  // MARK: - Launch

  /// Lists meetings and recovers any a crash, force quit or quit interrupted (R3, R15). Run
  /// once, after the orphaned dictation hold was restored; the listing runs off the main
  /// actor. Repeatable: a second call changes nothing.
  func launch() {
    guard !launched else { return }
    launched = true
    launchTask = Task { await recoverAtLaunch() }
  }

  private func recoverAtLaunch() async {
    fileWorkInFlight += 1
    let listings: [MeetingStore.Listing]
    do {
      listings = try await writer.run { try $0.loadAll() }
    } catch {
      fileWorkInFlight -= 1
      // Never an empty success: the failure is visible.
      deps.log("meeting list unreadable error=\(type(of: error))")
      notice = .storageFailed
      return
    }
    fileWorkInFlight -= 1
    var loaded: [UUID] = []
    for listing in listings {
      switch listing {
      case .meeting(let record):
        // A meeting started while the listing ran is newer in memory.
        guard live[record.id] == nil else { continue }
        live[record.id] = record
        records[record.id] = record
        loaded.append(record.id)
      case .newerFormat(let header): newerFormatMeetings.append(header)
      case .unreadable(let id): deps.log("meeting folder unreadable id=\(id.uuidString)")
      }
    }
    publish()
    // Notes are searched with their meeting's transcript (R38): read every meeting's notes
    // once, behind the listing, on the file queue.
    let toRead = loaded
    let ready = loaded.filter { live[$0]?.state == .ready && live[$0]?.deletionRequested != true }
    Task { [weak self] in
      for meetingID in toRead { await self?.documents.load(meetingID) }
      // A summary a quit interrupted is finished now (R50), after the notes are read.
      await self?.summaries?.resumeOwed(readyMeetingIDs: ready)
    }
    for meetingID in loaded {
      guard !quitting, var record = live[meetingID], meetingID != activeMeetingID else {
        continue
      }
      if record.deletionRequested {
        // Its attempt ended when it was marked, in the session that marked it.
        Task { await delete(meetingID: meetingID) }
        continue
      }
      if ![.ready, .failed, .notesOnly].contains(record.state) {
        // Unfinished: the same attempt, its start facts unknown after the relaunch.
        openAttempts[meetingID] = openAttempts[meetingID] ?? AttemptFacts()
      }
      switch record.state {
      case .recording, .stopping, .interrupted:
        record.wasInterrupted = true
        record.state = .queued
        if record.endedAt == nil { record.endedAt = Date() }
        await persist(record)
      case .processing:
        record.state = .queued
        await persist(record)
      case .queued, .ready, .failed, .notesOnly:
        // A notes-only meeting has nothing to transcribe and is never queued (R53).
        continue
      }
    }
    startQueueIfNeeded()
  }

  private func publish() {
    meetings = records.values.sorted { $0.createdAt > $1.createdAt }
    onMeetingsPublished?()
  }

  /// Told after `meetings` changes, so History drops a selection whose meeting is gone.
  @ObservationIgnored var onMeetingsPublished: (@MainActor () -> Void)?

  // MARK: - Start and stop

  /// Starts a meeting. `captureCallSound` is the call-sound choice the Start was admitted with
  /// (`MeetingStartFlow` decides the explainer on it); nil reads the setting now. Either way it
  /// is frozen here, before any wait, so a switch flipped during the start never changes this
  /// recording (#3972 C5b review r1).
  /// The result names what this Start did, and the meeting it created when it created one, so a
  /// caller never infers it from the newest meeting.
  @discardableResult
  func start(from entryPoint: MeetingEntryPoint, captureCallSound: Bool? = nil) async
    -> StartOutcome
  {
    guard phase == .idle, !quitting else { return .notIdle }
    let captureCall = captureCallSound ?? deps.captureCallSound()
    notice = nil
    guard deps.microphoneAuthorized() else {
      notice = .microphoneDenied
      emitStartFailed(entryPoint, microphone: .denied)
      return .refused(.microphoneDenied)
    }
    if let free = deps.freeDiskBytes(), free < Self.diskFloorBytes {
      notice = .lowDisk
      emitStartFailed(entryPoint, microphone: .off)
      return .refused(.lowDisk)
    }
    startGeneration += 1
    let generation = startGeneration
    phase = .starting
    workChanged()
    guard await deps.settleDictationHold() else {
      // A Stop or quit while waiting already owns the outcome.
      guard isCurrentStart(generation) else { return .superseded(meetingID: nil) }
      phase = .idle
      notice = .finishDictationFirst
      emitStartFailed(entryPoint, microphone: .off)
      workChanged()
      return .refused(.finishDictationFirst)
    }
    guard isCurrentStart(generation) else { return .superseded(meetingID: nil) }
    var record = MeetingRecord(
      engine: .parakeet,
      trackStatus: [.microphone: .captured, .callSound: captureCall ? .captured : .off])
    let meetingID = record.id
    do {
      let created = record
      try await writer.run { try $0.create(created) }
    } catch {
      guard isCurrentStart(generation) else { return .superseded(meetingID: nil) }
      phase = .idle
      notice = .recordingStoppedFileError
      emitStartFailed(entryPoint, microphone: .off)
      workChanged()
      return .refused(.recordingStoppedFileError)
    }
    guard isCurrentStart(generation) else {
      // Stopped while the folder was created: nothing was recorded into it.
      do {
        try await writer.run { try $0.deleteFolder(meeting: meetingID) }
      } catch {
        // An empty folder left behind; launch recovery lists it as an empty meeting.
        deps.log("meeting start cleanup failed error=\(type(of: error))")
      }
      return .superseded(meetingID: nil)
    }
    // Created durably above. The attempt begins: its facts are frozen here, so a later Start
    // never changes them.
    live[meetingID] = record
    records[meetingID] = record
    openAttempts[meetingID] = AttemptFacts(entryPoint: entryPoint, diskStopped: false)
    publish()
    let mic = deps.microphoneSelection()
    let recorder = deps.makeRecorder(
      MeetingRecorder.Configuration(
        meetingID: meetingID, folder: deps.store.folder(for: meetingID),
        captureCallSound: captureCall, microphoneUID: mic.uid, inputChannelByDeviceUID: mic.channels
      ),
      { [weak self] track, info in
        Task { @MainActor in
          await self?.segmentFinalized(meetingID: meetingID, track: track, info: info)
        }
      },
      { [weak self] track, error in
        Task { await self?.trackFailed(meetingID: meetingID, track: track, error: error) }
      })
    // Reachable while it starts, so a Stop or a quit in the meantime reaches it.
    self.recorder = recorder
    activeMeetingID = meetingID
    let result: MeetingRecorder.StartResult
    do {
      result = try await recorder.start()
    } catch {
      // A stop or quit that took over owns the recorder and the record.
      guard isCurrentStart(generation) else { return .superseded(meetingID: meetingID) }
      deps.log("meeting start failed error=\(String(describing: error).prefix(80))")
      // The current state ends now; the old meeting's files are dealt with apart from it, so a
      // new Start during the inspection below is never touched by it.
      self.recorder = nil
      activeMeetingID = nil
      phase = .idle
      notice = .microphoneUnavailable
      workChanged()
      // Its row is decided by what reached disk: `start_failed` when nothing did, else the
      // attempt goes on to the terminal of the audio it kept.
      await cleanUpFailedStart(meetingID)
      return .failed(meetingID: meetingID)
    }
    guard isCurrentStart(generation) else {
      // A stop or quit took over while starting; it owns the recorder and the record.
      return .superseded(meetingID: meetingID)
    }
    record = live[meetingID] ?? record
    record.trackStatus[.callSound] = result.callSound
    callSoundStatus = result.callSound
    if result.callSound == .failed { notice = .callSoundFailed }
    if result.callSound == .unsupported { notice = .callSoundUnavailable }
    boundMicrophoneUID = recorder.boundMicrophoneUID
    deps.log("meeting recording started bound=\(boundMicrophoneUID ?? "unknown")")
    if let token = deps.beginActivity() { activity = token }
    phase = .recording(meetingID: meetingID, startedAt: record.createdAt)
    if deps.makePreviewJob != nil { liveTranscript = LiveTranscript(meetingID: meetingID) }
    await persist(record)
    return .recording(meetingID: meetingID)
  }

  /// What one `start` did.
  enum StartOutcome: Equatable {
    /// Recording `meetingID`, which this Start created.
    case recording(meetingID: UUID)
    /// Refused before recording; the notice says why.
    case refused(Notice)
    /// A Stop or quit took over while it started; `meetingID` when a meeting was created.
    case superseded(meetingID: UUID?)
    /// The recorder did not start; whatever reached disk for `meetingID` is kept.
    case failed(meetingID: UUID)
    /// A meeting was already starting, recording or stopping, or the app is quitting.
    case notIdle
  }

  private func isCurrentStart(_ generation: Int) -> Bool {
    startGeneration == generation && phase == .starting && !quitting
  }

  /// The recorder closed what it opened before throwing, and the microphone can be lost after
  /// it delivered: keep anything on disk; delete only an attempt that wrote nothing.
  private func cleanUpFailedStart(_ meetingID: UUID) async {
    let folder = deps.store.folder(for: meetingID)
    let recover = deps.recoverFolder
    fileWorkInFlight += 1
    // Detached, not `Task {}`: this type is @MainActor and a plain Task inherits it; recovery
    // reads and syncs files. Awaited at once.
    let report = await Task.detached(priority: .userInitiated) { recover(folder) }.value
    fileWorkInFlight -= 1
    // A quit meanwhile leaves the folder to launch recovery.
    guard !quitting, var record = live[meetingID] else { return }
    let wroteNothing =
      report.problems.isEmpty && report.segments.values.allSatisfy { $0.isEmpty }
    if wroteNothing {
      // Notes typed while it started are saved first; the state then follows what is durable
      // (R53, R56; Codex C7 r1). The meeting is read again after every await, and the folder is
      // removed only once the notes owner fenced it empty in the same step (Codex C7 r2), so a
      // note typed during the removal is never dropped.
      while true {
        let notes = await documents.ensureNotesDurable(meetingID)
        guard !quitting, !deleting.contains(meetingID), var current = live[meetingID],
          !current.deletionRequested
        else { return }
        current.trackStatus[.microphone] = .failed
        switch notes {
        case .saved:
          current.endedAt = Date()
          current.failureCode = "microphone_unavailable"
          current.markNotesOnly()
          if await persist(current) { endAttempt(current, outcome: .startFailed) }
          return
        case .failed, .unknown:
          // Notes may exist and are not proven saved: the folder is kept.
          if notes == .failed { notice = .storageFailed }
          current.endedAt = Date()
          current.state = .failed
          current.failureCode = "microphone_unavailable"
          if await persist(current) { endAttempt(current, outcome: .startFailed) }
          return
        case .none:
          // Notes arrived since the check: decide again on what is saved now.
          guard let fence = documents.fenceEmptyForRemoval(meetingID) else { continue }
          endAttempt(current, outcome: .startFailed)
          do {
            try await writer.run { try $0.deleteFolder(meeting: meetingID) }
            live.removeValue(forKey: meetingID)
            records.removeValue(forKey: meetingID)
            publish()
          } catch {
            deps.log("meeting start cleanup failed error=\(type(of: error))")
            // A quit or a deletion meanwhile owns the meeting now.
            guard !quitting, !deleting.contains(meetingID), var failed = live[meetingID],
              !failed.deletionRequested
            else { return }
            documents.reopen(meetingID, token: fence)
            failed.state = .failed
            failed.failureCode = "microphone_unavailable"
            await persist(failed)
          }
          return
        }
      }
    }
    // What was captured is processed like any interrupted meeting.
    record.trackStatus[.microphone] = .failed
    record.state = .queued
    record.wasInterrupted = true
    record.endedAt = Date()
    record.failureCode = "microphone_lost"
    await persist(record)
    startQueueIfNeeded()
  }

  /// Stops the recording (also while it is still starting) and queues its pass.
  func stop() async {
    let meetingID: UUID
    switch phase {
    case .recording(let id, _): meetingID = id
    case .starting:
      guard let id = activeMeetingID else {
        // Still waiting for the dictation hold or the folder: nothing records yet.
        startGeneration += 1
        phase = .idle
        workChanged()
        return
      }
      meetingID = id
    case .idle, .stopping: return
    }
    startGeneration += 1
    phase = .stopping(meetingID: meetingID)
    // The after-recording pass makes the real words; queued previews are not needed (R42), and
    // one still waiting for admission is called off (a decode already running finishes).
    // Redundant by design with the pass's own `yieldPreviewEngine` and the lane's admission
    // check (the pass sets `processing` before it yields); kept so a Stop never depends on the
    // pass starting. A mutation removing it alone changes nothing a test can see (C10 r4).
    dropQueuedPreviews(of: meetingID)
    if currentPreviewItem?.meetingID == meetingID {
      previewJob?.cancel()
      previewJobCancelled = true
    }
    // Stays reachable until the files are closed, so a quit meanwhile takes it over.
    let recorder = self.recorder
    let report = await recorder?.stop()
    // A quit during the close owns the outcome (interrupted, its own deadline).
    guard !quitting else { return }
    self.recorder = nil
    endActivity()
    if var record = live[meetingID] {
      apply(report, to: &record)
      record.endedAt = Date()
      if report.map(Self.anyCloseTimedOut) ?? false {
        // The writer's queued close still owns that file: never read it now. The next launch
        // recovers it once nothing owns it (R15).
        record.state = .interrupted
        record.wasInterrupted = true
        closeOwned.insert(meetingID)
      } else {
        record.state = .queued
      }
      await persist(record)
    }
    activeMeetingID = nil
    boundMicrophoneUID = nil
    phase = .idle
    workChanged()
    startQueueIfNeeded()
    await documents.flush(meetingID)
  }

  private static func anyCloseTimedOut(_ report: MeetingRecorder.StopReport) -> Bool {
    report.microphone == .timedOut || report.callSound == .timedOut
  }

  /// A track whose file did not close cleanly is marked failed, never reported finished; its
  /// files stay for recovery.
  private func apply(_ report: MeetingRecorder.StopReport?, to record: inout MeetingRecord) {
    guard let report else { return }
    for (track, outcome) in [
      (MeetingTrackKind.microphone, report.microphone), (.callSound, report.callSound),
    ] {
      guard let outcome else { continue }
      switch outcome {
      case .finalized: continue
      case .failed, .timedOut:
        record.trackStatus[track] = .failed
        deps.log("meeting track close outcome=\(outcome) track=\(track.rawValue)")
      }
    }
  }

  private func segmentFinalized(meetingID: UUID, track: MeetingTrackKind, info: MeetingSegmentInfo)
    async
  {
    guard !quitting, meetingID == activeMeetingID, var record = live[meetingID] else { return }
    record.segments[track, default: []].append(info)
    await persist(record)
    if isRecording, meetingID == activeMeetingID { enqueuePreview(meetingID, track: track, info) }
    if let free = deps.freeDiskBytes(), free < Self.diskFloorBytes, isRecording,
      meetingID == activeMeetingID
    {
      notice = .stoppedLowDisk
      openAttempts[meetingID]?.diskStopped = true
      await stop()
    }
  }

  private func trackFailed(meetingID: UUID, track: MeetingTrackKind, error: Error) async {
    deps.log("meeting track failed track=\(track.rawValue) error=\(type(of: error))")
    guard !quitting, meetingID == activeMeetingID, var record = live[meetingID] else { return }
    record.trackStatus[track] = .failed
    if track == .microphone {
      notice = .recordingStoppedFileError
    } else {
      callSoundStatus = .failed
      notice = .callSoundFailed
    }
    await persist(record)
    if track == .microphone, meetingID == activeMeetingID { await stop() }
  }

  private func endActivity() {
    if let activity { deps.endActivity(activity) }
    activity = nil
  }

  // MARK: - Queue

  private func startQueueIfNeeded() {
    guard queueTask == nil, !quitting else { return }
    queueTask = Task { [weak self] in
      await self?.drainQueue()
      self?.queueTask = nil
    }
  }

  private func drainQueue() async {
    // Each meeting at most once per drain, so a meeting whose state could not be saved never
    // makes the queue run it again.
    var attempted: Set<UUID> = []
    while !quitting,
      let next = meetings.last(where: {
        $0.state == .queued && !$0.deletionRequested && !deleting.contains($0.id)
          && !attempted.contains($0.id) && !closeOwned.contains($0.id)
      })
    {
      attempted.insert(next.id)
      if let free = deps.freeDiskBytes(), free < Self.diskFloorBytes {
        // Stays queued; a later launch or Retry tries again.
        notice = .lowDisk
        return
      }
      await process(next.id)
    }
  }

  private func process(_ meetingID: UUID) async {
    guard var record = live[meetingID] else { return }
    record.state = .processing
    guard await persist(record), isStillOwned(meetingID) else { return }
    processing = Processing(meetingID: meetingID, stage: nil)
    workChanged()
    // R50: a final pass comes first. A preview unit already running finishes (its compute
    // cannot stop), then the preview engine unloads before this pass loads its own.
    await yieldPreviewEngine()
    defer {
      processing = nil
      job = nil
      // The pass ended (ready, failed, cancelled): its live words are no longer the newest.
      if liveTranscript?.meetingID == meetingID, !isActive(meetingID) { liveTranscript = nil }
      let waiters = processEndWaiters
      processEndWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      workChanged()
    }

    // Audio from the files themselves (C2a): partials promoted, frame counts real.
    let folder = deps.store.folder(for: meetingID)
    let recover = deps.recoverFolder
    fileWorkInFlight += 1
    // Detached, not `Task {}`: this type is @MainActor and a plain Task inherits it, and these
    // are synchronous file reads and fsyncs (minutes of audio). Awaited at once, so nothing
    // outlives the pass or loses its cancellation (the pass checks ownership after each).
    let report = await Task.detached(priority: .utility) { recover(folder) }.value
    for problem in report.problems { deps.log("meeting recovery problem \(problem)") }
    var tracks: [MeetingTrackKind: MeetingTrackAudio] = [:]
    var damaged: Set<String> = Set(report.problems.compactMap(Self.damagedFileName))
    for kind in MeetingTrackKind.allCases {
      let files = (report.segments[kind] ?? []).map {
        (url: folder.appendingPathComponent($0.fileName), startMs: $0.startMs)
      }
      guard !files.isEmpty else { continue }
      // Detached for the same reason: a synchronous header and frame-count read of every file.
      let audio = await Task.detached(priority: .utility) { MeetingTrackAudio(files: files) }.value
      for problem in audio.problems { deps.log("meeting track problem \(problem)") }
      damaged.formUnion(audio.problems.compactMap(Self.damagedFileName))
      if !audio.isEmpty { tracks[kind] = audio }
    }
    var onDisk: [MeetingStore.SegmentFile] = []
    do {
      onDisk = try await writer.run { try $0.segmentFiles(meeting: meetingID) }
    } catch {
      // Recovery already listed this folder; a second listing failing is reported, and the
      // damaged files then have no known bounds to mark.
      deps.log("meeting folder relisting failed error=\(type(of: error))")
    }
    fileWorkInFlight -= 1
    // Damaged files stay on disk; their stretch of the timeline becomes a visible gap (R3).
    let missingAudio = Self.missingAudio(damaged: damaged, onDisk: onDisk, readable: tracks)
    let started = Date()
    guard isStillOwned(meetingID), var current = live[meetingID] else { return }
    for kind in MeetingTrackKind.allCases { current.segments[kind] = report.segments[kind] }
    guard !tracks.isEmpty else {
      let noAudio = report.problems.isEmpty && damaged.isEmpty
      // Only confirmed absence with SAVED notes is notes-only (R56; Codex C7 r1): unreadable
      // audio may come back, so it stays failed and keeps Retry.
      let notes: MeetingDocumentsOwner.Durability =
        noAudio ? await documents.ensureNotesDurable(meetingID) : .none
      // Read again after the await: a rename or a deletion mark meanwhile stays.
      guard isStillOwned(meetingID), var failed = live[meetingID] else { return }
      for kind in MeetingTrackKind.allCases { failed.segments[kind] = report.segments[kind] }
      failed.failureCode = noAudio ? "no_audio" : "audio_unreadable"
      if notes == .saved {
        failed.markNotesOnly()
      } else {
        if notes == .failed { notice = .storageFailed }
        failed.state = .failed
      }
      if await persist(failed) {
        endAttempt(failed, outcome: .failed, gapCount: Self.markerCount(missingAudio))
      }
      return
    }
    // The inventory rebuilt from the files, durable before the pass reads it.
    guard await persist(current), isStillOwned(meetingID) else { return }

    let job = deps.makeJob()
    self.job = job
    job.onWaitingForDictation = { [weak self] waiting in
      guard self?.processing?.meetingID == meetingID else { return }
      self?.processing?.waitingForDictation = waiting
    }
    let checkpoints = MeetingProcessingCheckpointStore(meetingFolder: folder)
    let access = MeetingTranscriptionJob.CheckpointAccess(
      meetingID: meetingID,
      load: {
        if case .checkpoint(let checkpoint) = checkpoints.load() { return checkpoint }
        return nil
      },
      save: { [checkpointWrites, saveCheckpoint = deps.saveCheckpoint] checkpoint in
        checkpointWrites.withLock { $0 += 1 }
        defer { checkpointWrites.withLock { $0 -= 1 } }
        try saveCheckpoint(checkpoints, checkpoint)
      })
    let result: MeetingTranscriptionJob.Result
    do {
      result = try await job.run(
        tracks: tracks, checkpoint: access, missingAudio: missingAudio
      ) { [weak self] stage in
        self?.processing?.stage = stage
      }
    } catch MeetingTranscriptionJob.JobError.cancelled {
      return
    } catch {
      guard isStillOwned(meetingID), var failed = live[meetingID] else { return }
      failed.state = .failed
      failed.failureCode =
        (error as? MeetingTranscriptionJob.JobError).map { _ in "engine_unavailable" }
        ?? "pass_failed"
      if await persist(failed) {
        endAttempt(
          failed, outcome: .failed, gapCount: Self.markerCount(missingAudio),
          processingSeconds: Date().timeIntervalSince(started))
      }
      return
    }
    guard isStillOwned(meetingID), let finished = live[meetingID] else { return }

    // Commit, in order: History row, then ready, then clear the checkpoint.
    committing = true
    defer { committing = false }
    do {
      try await deps.saveTranscript(Self.transcript(for: finished, result: result))
    } catch {
      deps.log("meeting history save failed error=\(type(of: error))")
      // Read again: a deletion mark or a rename during the save stays.
      guard isStillOwned(meetingID), var failed = live[meetingID] else { return }
      failed.state = .failed
      failed.failureCode = "commit_failed"
      if await persist(failed) {
        endAttempt(
          failed, outcome: .failed, result: result,
          gapCount: result.failedPieces + Self.markerCount(missingAudio),
          processingSeconds: Date().timeIntervalSince(started))
      }
      return
    }
    // The summary decision (R48), taken before the ready barrier so an owed summary is durable
    // before the meeting is ready: a quit right after the barrier never loses it (the relaunch
    // finishes it). Written either way, so an older mark never outlives a decision not to.
    let summaryPlan = summaries?.decide() ?? .off
    // Whether the owed mark is on disk. If it could not be written, nothing durable would let a
    // quit-interrupted attempt resume, so none starts: the failure is settled in the same turn as
    // `meeting.ended` (one `failed` row) and the Summary tab offers Write again. If an older mark
    // could not be cleared, that earlier attempt is still owed and a relaunch settles it (one
    // row); the new decision is still the one `meeting.ended` reports.
    var owedOnDisk = false
    if summaries != nil {
      let wrote = await documents.setSummaryPending(meetingID, summaryPlan == .scheduled)
      owedOnDisk = wrote && summaryPlan == .scheduled
      if !wrote { deps.log("meeting summary mark write failed plan=\(summaryPlan.rawValue)") }
    }
    // Read after that wait: a deletion mark or a rename during it stays.
    guard isStillOwned(meetingID), var ready = live[meetingID] else { return }
    ready.state = .ready
    ready.speakerOutcomes = result.speakerOutcomes
    ready.echoTurnIDs = result.composition.echoTurnIDs
    ready.failureCode =
      !missingAudio.isEmpty ? "audio_damaged" : (result.failedPieces > 0 ? "pieces_failed" : nil)
    // The ready write (file and directory synced) is the barrier before progress is cleared.
    guard await persist(ready) else { return }
    // The attempt ends at the ready barrier, in the same main-actor turn: a deletion during the
    // checkpoint clear below finds no open attempt, so it never reports the ready meeting as
    // deleted before ready.
    let outcome: MeetingEndedTelemetry.Outcome =
      ready.wasInterrupted == true
      ? .interruptedReady
      : (result.failedPieces > 0 || !missingAudio.isEmpty ? .readyWithGaps : .ready)
    endAttempt(
      ready, outcome: outcome, result: result,
      gapCount: result.failedPieces + Self.markerCount(missingAudio),
      processingSeconds: Date().timeIntervalSince(started), summaryPlan: summaryPlan)
    if summaryPlan == .scheduled {
      if owedOnDisk {
        summaries?.startOwed(meetingID)
      } else {
        summaries?.settleUnwritableMark(meetingID)
      }
    }

    do {
      try await writer.run { _ in try checkpoints.clear() }
    } catch {
      deps.log("meeting checkpoint clear failed error=\(type(of: error))")
    }
  }

  /// Damaged-audio markers in the transcript: one per missing stretch, on every track.
  static func markerCount(
    _ missingAudio: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]]
  ) -> Int {
    missingAudio.values.reduce(0) { $0 + $1.count }
  }

  /// The file a recovery problem is about, when the problem means its audio is lost. Empty
  /// files and overlaps lose nothing a listener would hear.
  static func damagedFileName(_ problem: MeetingTrackRecovery.Problem) -> String? {
    switch problem {
    case .unreadablePartial(let name), .unreadableFinal(let name), .incompatibleFinal(let name):
      return name
    case .folderUnreadable, .emptyPartial, .partialBesideFinal, .promotionFailed,
      .directorySyncFailed, .emptyFinal, .duplicateIndex:
      return nil
    }
  }

  static func damagedFileName(_ problem: MeetingTrackAudio.Problem) -> String? {
    switch problem {
    case .unreadable(let name), .incompatibleFormat(let name):
      return name
    case .empty, .overlap:
      return nil
    }
  }

  /// Per track, the stretches only a damaged file claims (milliseconds). A damaged file's
  /// claim runs from its own start to the next file's start on that track; with no next file
  /// its end is unknown (nil), never a guess. Audio a readable file covers is removed from it.
  static func missingAudio(
    damaged: Set<String>, onDisk: [MeetingStore.SegmentFile],
    readable: [MeetingTrackKind: MeetingTrackAudio]
  ) -> [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]] {
    var result: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]] = [:]
    let unbounded = Int.max
    for kind in MeetingTrackKind.allCases {
      let files = onDisk.filter { $0.track == kind }.sorted { $0.startMs < $1.startMs }
      let covered = (readable[kind]?.segments ?? []).map {
        ms($0.readStartSample)..<ms($0.endSample)
      }.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
      for (i, file) in files.enumerated() where damaged.contains(file.url.lastPathComponent) {
        let next = files[(i + 1)...].first { $0.startMs > file.startMs }?.startMs
        var pieces = [file.startMs..<(next ?? unbounded)]
        for cover in covered {
          pieces = pieces.flatMap { piece -> [Range<Int>] in
            guard cover.overlaps(piece) else { return [piece] }
            var left: [Range<Int>] = []
            if piece.lowerBound < cover.lowerBound {
              left.append(piece.lowerBound..<cover.lowerBound)
            }
            if cover.upperBound < piece.upperBound {
              left.append(cover.upperBound..<piece.upperBound)
            }
            return left
          }
        }
        for piece in pieces {
          result[kind, default: []].append(
            .init(
              startMs: piece.lowerBound,
              endMs: piece.upperBound == unbounded ? nil : piece.upperBound))
        }
      }
    }
    return result
  }

  private static func ms(_ sample: Int) -> Int {
    Int((Double(sample) * 1_000 / MeetingAudioFormat.sampleRate).rounded())
  }

  /// False once the meeting is being deleted (or marked for it) or the app is quitting: a late
  /// step then writes nothing. Synchronous, so no deletion can land between this check and the
  /// cache update of the write after it.
  private func isStillOwned(_ meetingID: UUID) -> Bool {
    !quitting && !deleting.contains(meetingID) && live[meetingID]?.deletionRequested != true
  }

  /// The History row a finished meeting is saved as (R5, R19). Always `.labeled` so History keeps
  /// the turns; the truthful per-track outcome lives in the meeting record.
  static func transcript(for record: MeetingRecord, result: MeetingTranscriptionJob.Result)
    -> Transcript
  {
    let composition = result.composition
    return Transcript(
      id: record.transcriptID, text: composition.text, duration: result.audioSeconds,
      processingTime: result.processingSeconds, backendType: .parakeet, createdAt: record.createdAt,
      speakerAnalysis: composition.turns.isEmpty
        ? nil : .labeled(count: max(1, composition.speakerCount)),
      speakerNames: composition.turns.isEmpty ? nil : composition.speakerNames,
      turns: composition.turns.isEmpty ? nil : composition.turns,
      meetingID: record.id)
  }

  // MARK: - User actions on a meeting

  func retry(meetingID: UUID) async {
    guard var record = live[meetingID], record.audioKept,
      [.failed, .ready, .interrupted].contains(record.state), !isActive(meetingID),
      !closeOwned.contains(meetingID)
    else { return }
    record.state = .queued
    guard await persist(record) else { return }
    // A new attempt over the same audio: the recording's facts carry over when known.
    openAttempts[meetingID] =
      openAttempts[meetingID] ?? lastAttemptFacts[meetingID] ?? AttemptFacts()
    startQueueIfNeeded()
  }

  func rename(meetingID: UUID, title: String) async {
    guard var record = live[meetingID] else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    record.title = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    await persist(record)
  }

  func deleteAudio(meetingID: UUID) async {
    guard live[meetingID] != nil, !isActive(meetingID), !closeOwned.contains(meetingID) else {
      return
    }
    do {
      try await writer.run { store in
        try store.deleteAudio(meeting: meetingID)
        try MeetingProcessingCheckpointStore(meetingFolder: store.folder(for: meetingID)).clear()
      }
    } catch {
      deps.log("meeting delete audio failed error=\(type(of: error))")
      notice = .storageFailed
      return
    }
    guard var record = live[meetingID] else { return }
    record.audioKept = false
    if record.state == .queued || record.state == .interrupted {
      record.state = .failed
      record.failureCode = "audio_deleted"
    }
    await persist(record)
  }

  /// The one deletion authority (R12, R19): History's delete of a meeting row comes here too.
  func delete(meetingID: UUID) async {
    // History can ask before the launch listing finished; the meeting is known after it.
    if live[meetingID] == nil, let launchTask { await launchTask.value }
    guard !deleting.contains(meetingID), var record = live[meetingID] else { return }
    deleting.insert(meetingID)
    workChanged()
    defer {
      deleting.remove(meetingID)
      workChanged()
    }
    record.deletionRequested = true
    guard await persist(record) else { return }
    // The notes this session knows, read before they are forgotten (R54 `has_notes`).
    let hadNotes = !documents.notes(meetingID).isEmpty
    // Marked: no draft may be written any more (the store also refuses).
    documents.forget(meetingID)
    // A summary being written ends, and has physically ended before the folder is removed.
    await summaries?.cancelAndWait(meetingID)
    dropQueuedPreviews(of: meetingID)
    if liveTranscript?.meetingID == meetingID { liveTranscript = nil }
    switch phase {
    case .recording(let id, _) where id == meetingID: await stop()
    case .starting where activeMeetingID == meetingID: await stop()
    case .stopping(let id) where id == meetingID:
      // Its files are still closing: wait for the Stop to finish before removing them.
      await MeetingWorkAdmission.waitUntil { [weak self] in
        self?.phase != .stopping(meetingID: meetingID)
      }
    default: break
    }
    // The preview lane lets go of this meeting's files before they are removed.
    await drainPreview(of: meetingID)
    // Ends an attempt still open (recording, queued, processing); a finished one already
    // sent its row.
    endAttempt(record, outcome: .deletedBeforeReady, hasNotes: hadNotes)
    await finishDeletion(record)
  }

  /// History's Delete All (R19): marks every listed meeting for deletion DURABLY before
  /// returning (History empties its own store right after), then finishes each deletion.
  /// Synchronous, like the quit path: each mark waits behind queued writes, all within one
  /// second. Returns false when any meeting could not be marked in time; History then deletes
  /// nothing.
  func deleteForHistoryDeleteAll(meetingIDs: [UUID]) -> Bool {
    let deadline = DispatchTime.now() + 1
    var marked: [UUID] = []
    var allMarked = true
    for meetingID in meetingIDs {
      guard var record = live[meetingID] else {
        // No folder means nothing to delete; a folder this session could not read cannot be
        // marked.
        if FileManager.default.fileExists(atPath: deps.store.folder(for: meetingID).path) {
          allMarked = false
        }
        continue
      }
      record.deletionRequested = true
      if persistBounded(
        record, until: deadline,
        lateSuccess: { [weak self] in
          // Marked after all: finish its deletion (History kept every row this time).
          Task { await self?.delete(meetingID: meetingID) }
        })
      {
        marked.append(meetingID)
      } else {
        allMarked = false
      }
    }
    // Marked meetings are deleted either way; History keeps every row if any mark failed.
    for meetingID in marked { Task { await delete(meetingID: meetingID) } }
    return allMarked
  }

  /// Cancels the meeting's pass, awaits its end (so no checkpoint save is in flight), then
  /// removes the History row and the folder.
  private func finishDeletion(_ record: MeetingRecord) async {
    if processing?.meetingID == record.id { job?.cancel() }
    await waitUntilNotProcessing(record.id)
    guard !closeOwned.contains(record.id) else {
      // A timed-out close still owns its files: the mark stays and the next launch deletes.
      deps.log("meeting delete deferred reason=close_owned")
      return
    }
    do {
      try deps.removeTranscriptRow(record.transcriptID)
      let meetingID = record.id
      try await writer.run { try $0.deleteFolder(meeting: meetingID) }
      live.removeValue(forKey: record.id)
      records.removeValue(forKey: record.id)
      publish()
    } catch {
      // The marker stays in the folder; the next launch finishes the deletion.
      deps.log("meeting delete incomplete error=\(type(of: error))")
    }
  }

  private func waitUntilNotProcessing(_ meetingID: UUID) async {
    while processing?.meetingID == meetingID {
      await withCheckedContinuation { processEndWaiters.append($0) }
    }
  }

  private func isActive(_ meetingID: UUID) -> Bool {
    if processing?.meetingID == meetingID || deleting.contains(meetingID) { return true }
    switch phase {
    case .recording(let id, _), .stopping(let id): return id == meetingID
    case .starting: return activeMeetingID == meetingID
    case .idle: return false
    }
  }

  // MARK: - Live preview (R42, R43, R50, R52)

  /// Queues one closed capture file of the recording meeting. Per track at most
  /// `previewQueueCapPerTrack` wait; the oldest of that track drops first and is counted.
  private func enqueuePreview(_ meetingID: UUID, track: MeetingTrackKind, _ info: MeetingSegmentInfo) {
    guard deps.makePreviewJob != nil, liveTranscript?.meetingID == meetingID else { return }
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

  private func dropQueuedPreviews(of meetingID: UUID) {
    previewQueue.removeAll { $0.meetingID == meetingID }
    if liveTranscript?.meetingID == meetingID { liveTranscript?.queued = previewQueue.count }
  }

  /// Runs `op` on the preview lane after everything already on it, and waits for it.
  private func onPreviewLane(_ op: @escaping @MainActor () async -> Void) async {
    let previous = previewLane
    previewLaneOps += 1
    let task = Task { @MainActor in
      await previous?.value
      await op()
    }
    previewLane = task
    await task.value
    previewLaneOps -= 1
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
      if processing != nil || committing {
        await withCheckedContinuation { processEndWaiters.append($0) }
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
      workChanged()
      guard var transcript = liveTranscript, transcript.meetingID == item.meetingID else {
        continue
      }
      let endMs = item.info.startMs + item.info.durationMs
      switch outcome {
      case .words(let words):
        if !words.isEmpty {
          transcript.lines.append(
            LiveLine(
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
        if isRecording, activeMeetingID == item.meetingID {
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
    guard !quitting, !deleting.contains(item.meetingID),
      liveTranscript?.meetingID == item.meetingID, isRecording,
      activeMeetingID == item.meetingID
    else { return .dropped }
    if processing != nil || committing { return .interrupted }
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
    let url = deps.store.folder(for: item.meetingID).appendingPathComponent(item.info.fileName)
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
    let job = deps.makePreviewJob!()
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
    let wait = deps.previewIdleWait
    previewIdleTask?.cancel()
    previewIdleTask = Task { [weak self] in
      await wait()
      guard !Task.isCancelled, let self, self.previewQueue.isEmpty else { return }
      await self.onPreviewLane { [weak self] in
        guard let self, self.previewQueue.isEmpty else { return }
        await self.previewJob?.releaseIdle()
      }
      self.workChanged()
    }
  }

  /// Before a final pass loads its engine (R50): a preview still waiting for admission is
  /// called off (its file goes back to the queue), one already decoding finishes, then the
  /// preview engine unloads on the lane. Returns once that unload is done.
  private func yieldPreviewEngine() async {
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
  private func drainPreview(of meetingID: UUID) async {
    dropQueuedPreviews(of: meetingID)
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

  // MARK: - Quit (R18)

  /// Synchronous: called from `applicationWillTerminate`. Closes admission, cancels the pass,
  /// stops capture and closes both files against one shared deadline. A file whose close did
  /// not finish in time stays owned by its queued close; launch recovery handles it.
  func prepareForTermination(deadline: DispatchTime = .now() + 1) {
    quitting = true
    summaries?.prepareForTermination()
    queueTask?.cancel()
    job?.cancel()
    previewJob?.cancel()
    previewTask?.cancel()
    previewIdleTask?.cancel()
    guard let recorder, let meetingID = activeMeetingID, var record = live[meetingID] else {
      // Notes save whether or not anything records (R46), inside the same deadline.
      documents.flushForQuit(deadline: deadline)
      endActivity()
      phase = .idle
      return
    }
    // Also a recorder whose Stop is still closing its files: that Stop's continuation returns
    // without writing once `quitting` is set.
    self.recorder = nil
    let report = recorder.stopForQuit(deadline: deadline)
    apply(report, to: &record)
    if Self.anyCloseTimedOut(report) { closeOwned.insert(meetingID) }
    if record.state == .recording || record.state == .stopping {
      record.state = .interrupted
      record.wasInterrupted = true
      record.endedAt = Date()
      persistBounded(record, until: deadline)
    }
    // After the audio files and the record, which matter most, and before the same deadline.
    documents.flushForQuit(deadline: deadline)
    endActivity()
    phase = .idle
  }

  // MARK: - Persistence and telemetry

  /// Makes `record` the live copy, writes it off the main actor in order, and shows it only
  /// once the write succeeded. False (and a visible notice) when it could not be saved; the
  /// live copy then returns to what is on disk, unless a newer change was asked for since.
  @discardableResult
  private func persist(_ record: MeetingRecord) async -> Bool {
    let sequence = beginWrite(record)
    do {
      try await writer.save(record)
      writeSucceeded(record, sequence: sequence)
      return true
    } catch {
      writeFailed(error, record: record, sequence: sequence)
      return false
    }
  }

  /// `persist` bounded by `deadline` on the caller's thread, for the quit path and Delete All.
  /// True only when it landed in time. A write withdrawn before it started counts as failed
  /// and rolls back. A write still running at the deadline keeps the live copy and reports
  /// once when it ends: a success is then shown (and `lateSuccess` runs), a failure rolls back.
  @discardableResult
  private func persistBounded(
    _ record: MeetingRecord, until deadline: DispatchTime,
    lateSuccess: (@MainActor () -> Void)? = nil
  ) -> Bool {
    let sequence = beginWrite(record)
    let outcome = writer.saveBounded(record, until: deadline) { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case .success:
          self.writeSucceeded(record, sequence: sequence)
          lateSuccess?()
        case .failure(let error):
          self.writeFailed(error, record: record, sequence: sequence)
        }
      }
    }
    switch outcome {
    case .finished(.success):
      writeSucceeded(record, sequence: sequence)
      return true
    case .finished(.failure(let error)):
      writeFailed(error, record: record, sequence: sequence)
      return false
    case .withdrawn:
      writeFailed(MeetingFileWriter.WriterError.withdrawn, record: record, sequence: sequence)
      return false
    case .stillRunning:
      deps.log("meeting save still running at its deadline")
      return false
    }
  }

  private func beginWrite(_ record: MeetingRecord) -> Int {
    live[record.id] = record
    let sequence = (writeSequence[record.id] ?? 0) + 1
    writeSequence[record.id] = sequence
    unansweredWrites[record.id, default: []].append((sequence, record))
    return sequence
  }

  /// Settles one write's answer and recomputes the live copy from what is left: the newest
  /// write still unanswered (its change is still on its way) when it is newer than the newest
  /// durable success, else that durable success. Run on
  /// every answer, success or failure, newest or not, so an earlier write that fails after a
  /// newer one was withdrawn rolls back too. A meeting already removed is not brought back.
  private func answered(_ meetingID: UUID, sequence: Int) {
    unansweredWrites[meetingID]?.removeAll { $0.sequence == sequence }
    if unansweredWrites[meetingID]?.isEmpty == true { unansweredWrites[meetingID] = nil }
    guard live[meetingID] != nil else { return }
    // The newer of the two: an unanswered intention older than what is already durable (a
    // bounded write that succeeded first) must not replace it.
    if let pending = unansweredWrites[meetingID]?.last,
      pending.sequence > (durableSequence[meetingID] ?? 0)
    {
      live[meetingID] = pending.record
    } else {
      live[meetingID] = records[meetingID]
    }
  }

  /// Acknowledgements can resume out of order (a bounded write answers on the main actor
  /// before an earlier async write's continuation runs), so only a write newer than the one
  /// already shown may replace it. The disk holds the newest anyway (FIFO).
  private func writeSucceeded(_ record: MeetingRecord, sequence: Int) {
    // A meeting removed meanwhile (its folder deleted) is not brought back.
    if live[record.id] != nil, sequence > (durableSequence[record.id] ?? 0) {
      durableSequence[record.id] = sequence
      records[record.id] = record
      publish()
    }
    answered(record.id, sequence: sequence)
  }

  private func writeFailed(_ error: Error, record: MeetingRecord, sequence: Int) {
    deps.log("meeting save failed error=\(type(of: error))")
    notice = .storageFailed
    answered(record.id, sequence: sequence)
  }

  private func workChanged() { deps.workChanged() }

  /// A Start refused before any meeting existed: its own attempt, ended at once.
  private func emitStartFailed(_ entryPoint: MeetingEntryPoint, microphone: MeetingTrackStatus) {
    deps.emitEnded(
      MeetingEndedTelemetry.startFailed(
        entryPoint: entryPoint, microphone: microphone, callSound: .off))
  }

  /// Sends the attempt's one `meeting.ended` row and closes it. Does nothing when no attempt
  /// is open for the meeting (it already ended), so a repeated callback, a second deletion or
  /// a deletion retried after a relaunch never sends a second row.
  private func endAttempt(
    _ record: MeetingRecord, outcome: MeetingEndedTelemetry.Outcome,
    result: MeetingTranscriptionJob.Result? = nil, gapCount: Int = 0,
    processingSeconds: Double = 0,
    summaryPlan: MeetingEndedTelemetry.SummaryPlan = .notApplicable, hasNotes: Bool? = nil
  ) {
    guard let facts = openAttempts.removeValue(forKey: record.id) else { return }
    lastAttemptFacts[record.id] = facts
    deps.emitEnded(
      MeetingEndedTelemetry(
        outcome: outcome, entryPoint: facts.entryPoint,
        durationSeconds: Double(record.recordedDurationMs) / 1000,
        microphoneTrack: record.trackStatus[.microphone] ?? .off,
        callSoundTrack: record.trackStatus[.callSound] ?? .off,
        engine: record.engine,
        speakerCount: result?.composition.speakerCount ?? 0,
        processingSeconds: processingSeconds,
        audioSeconds: result?.audioSeconds ?? 0,
        yieldCount: result?.yieldCount ?? 0,
        gapCount: gapCount,
        echoHiddenCount: result?.composition.echoTurnIDs.count ?? 0,
        diskStopped: facts.diskStopped,
        summaryPlan: summaryPlan,
        // The notes this session knows (typed, or read at launch); a meeting without a folder
        // has none (R54). A deletion passes what it read before forgetting them.
        hasNotes: hasNotes ?? !documents.notes(record.id).isEmpty))
  }
}
