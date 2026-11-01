import ApplicationServices
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprPipeline
import EnviousWisprServices
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
  /// #3973: each recorded chunk for live words (`MeetingRecorder.liveSamples`).
  var liveSamples: MeetingRecorder.LiveSamplesObserver? { get set }
  /// #4013 chunk 13A: the host time the meeting's timeline starts at (`MeetingRecorder.anchor`).
  var anchor: UInt64 { get }
  /// #4248: mute decisions, run on the microphone writer's queue (`MeetingRecorder`).
  func applySilenceStep(_ step: @escaping MeetingSilenceStep)
  func setSilenceClock(_ step: MeetingSilenceStep?)
  func setMicrophoneMuted(_ muted: Bool)
}

extension MeetingRecorder: MeetingRecording {}

/// What the coordinator needs from a processing pass (`MeetingTranscriptionJob` in production).
@MainActor
protocol MeetingProcessing: AnyObject {
  func run(
    tracks: [MeetingTrackKind: MeetingTrackAudio], language: String?,
    checkpoint access: MeetingTranscriptionJob.CheckpointAccess?,
    missingAudio: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]],
    callSpeakers: MeetingCallSpeakerEvidence,
    onStage: @escaping @MainActor (MeetingTranscriptionJob.Stage) -> Void,
    attempt: MeetingAttemptConfiguration
  ) async throws -> MeetingTranscriptionJob.Result
  func cancel()
  var isEngineResident: Bool { get }
  var isUnitInFlight: Bool { get }
  /// #4052: the pass holds its own separate Parakeet (dictation runs Whisper).
  var isOwnModelResident: Bool { get }
  /// Told true while a unit waits for dictation to finish, false when it goes on.
  var onWaitingForDictation: (@MainActor (Bool) -> Void)? { get set }
}

extension MeetingTranscriptionJob: MeetingProcessing {}

/// The one serial queue every ordinary meeting file operation runs on (#3972 C4a): record
/// writes, creation, listing, audio and folder removal. Off the main actor, and in the order
/// they were asked for, so a later write of a meeting can never be overtaken by an earlier one.
/// The quit path uses `runBounded`, which blocks behind the writes already queued, but never
/// past a deadline; History's Delete All uses `runWithin`, the same wait suspended instead of
/// blocked, so the window keeps working while a meeting write is slow (#4102).
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
  enum BoundedOutcome: Sendable {
    case finished(Result<Void, Error>)
    /// The deadline passed before it started; it was withdrawn and never runs.
    case withdrawn
    /// The deadline passed while it ran; `late` receives its result exactly once.
    case stillRunning
  }

  /// Where a bounded operation's deadline is judged (#4102): its own queue, never the writer
  /// queue (which may be running the very write being timed) and never the main actor.
  private static let deadlineQueue = DispatchQueue(
    label: "com.enviouswispr.meetings.deadlines", qos: .utility)

  /// The stages of one bounded operation. The waiting caller (`runBounded`) and the suspending
  /// caller (`runWithin`) share it, so both withdraw, abandon and report late the same way.
  /// Internal, not private, so a test can drive the deadline against completion in either order.
  final class BoundedOperation: Sendable {
    enum Stage {
      case queued, running, withdrawn, runningAbandoned
      case done(Result<Void, Error>)
    }
    private let stage = OSAllocatedUnfairLock<Stage>(initialState: .queued)

    /// Runs on the writer queue. A withdrawn operation never runs `work`. One that finishes
    /// while its caller still waits calls `inTime`; one whose caller gave up reports to `late`.
    /// `pending` drops once either way, when this block is done.
    func execute(
      store: MeetingStore, pending: OSAllocatedUnfairLock<Int>,
      _ work: @Sendable (MeetingStore) throws -> Void, inTime: () -> Void,
      late: @Sendable (Result<Void, Error>) -> Void
    ) {
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
      if reportLate { late(result) } else { inTime() }
    }

    /// The result, once the operation finished while its caller still waited.
    var finishedResult: Result<Void, Error>? {
      if case .done(let result) = stage.withLock({ $0 }) { return result }
      return nil
    }

    /// The deadline passed: withdraw a queued operation, abandon a running one, or answer the
    /// result of one that finished just as the wait gave up.
    func deadlinePassed() -> BoundedOutcome {
      stage.withLock { current -> BoundedOutcome in
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
  }

  /// Runs `work` after everything already queued, waiting for it no later than `deadline`
  /// (quit, which cannot suspend). Never an unbounded join: a stalled earlier write cannot hold
  /// the caller. An operation not started by the deadline is withdrawn; one already running
  /// reports its result to `late` when it ends.
  func runBounded(
    until deadline: DispatchTime, _ work: @escaping @Sendable (MeetingStore) throws -> Void,
    late: @escaping @Sendable (Result<Void, Error>) -> Void
  ) -> BoundedOutcome {
    let operation = BoundedOperation()
    let done = DispatchSemaphore(value: 0)
    pending.withLock { $0 += 1 }
    queue.async { [store, pending] in
      operation.execute(store: store, pending: pending, work, inTime: { done.signal() }, late: late)
    }
    if done.wait(timeout: deadline) == .success, let result = operation.finishedResult {
      return .finished(result)
    }
    return operation.deadlinePassed()
  }

  /// `runBounded` for a caller that may suspend (#4102, History's Delete All): the same queue,
  /// the same stages and the same deadline, but the caller is resumed rather than blocked, so
  /// the main actor keeps running while a meeting write is slow. The deadline is judged on its
  /// own queue, so it answers even while the writer queue is still busy. Resumed exactly once:
  /// `answered` lets only the first of the two answers through.
  ///
  /// An unsafe continuation on purpose (#3925): `withCheckedContinuation` in this `-O` module
  /// crashed the `-Onone` Release test lane in `TranscriptCoordinator.Receipt` (PR #4095).
  func runWithin(
    until deadline: DispatchTime, _ work: @escaping @Sendable (MeetingStore) throws -> Void,
    late: @escaping @Sendable (Result<Void, Error>) -> Void
  ) async -> BoundedOutcome {
    let operation = BoundedOperation()
    pending.withLock { $0 += 1 }
    return await withUnsafeContinuation {
      (continuation: UnsafeContinuation<BoundedOutcome, Never>) in
      let answered = OSAllocatedUnfairLock(initialState: false)
      let answer: @Sendable (BoundedOutcome) -> Void = { outcome in
        let first = answered.withLock { done -> Bool in
          guard !done else { return false }
          done = true
          return true
        }
        if first { continuation.resume(returning: outcome) }
      }
      queue.async { [store, pending] in
        operation.execute(
          store: store, pending: pending, work,
          inTime: { if let result = operation.finishedResult { answer(.finished(result)) } },
          late: late)
      }
      Self.deadlineQueue.asyncAfter(deadline: deadline) { answer(operation.deadlinePassed()) }
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

  /// #4013: saves the meeting's call-speaker evidence on this queue, so it lands in order with
  /// the record writes and deletions around it; `saveCallSpeakers` refuses a meeting deleted or
  /// without audio by then.
  func saveCallSpeakers(_ log: CallSpeakerLog, meeting id: UUID) async throws {
    try await run { try $0.saveCallSpeakers(log, meeting: id) }
  }

  /// #4013: the meeting's call-speaker evidence, read on this queue after every write before it.
  func loadCallSpeakers(meeting id: UUID) async throws -> MeetingStore.CallSpeakersLoad {
    try await run { $0.loadCallSpeakers(meeting: id) }
  }

  /// `saveBounded` for a caller that may suspend (#4102).
  func saveWithin(
    _ record: MeetingRecord, until deadline: DispatchTime,
    late: @escaping @Sendable (Result<Void, Error>) -> Void
  ) async -> BoundedOutcome {
    let write = writeRecord
    return await runWithin(until: deadline, { try write($0, record) }, late: late)
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
    /// #3973 C3: builds a pass that decodes with the resolved engine.
    var makeJob: @MainActor (MeetingEngineResolution) -> MeetingProcessing
    /// #3973 C3: the engine a pass of an attempt that asked for `engine` runs on, decided from
    /// current availability without downloading: Whisper when it is ready, else Parakeet with
    /// the reason. Never reads Settings.
    var resolveEngine:
      @MainActor (_ attempt: MeetingAttemptConfiguration) async -> MeetingEngineResolution = {
        MeetingEngineResolution(
          engine: $0.requestedEngine, effectiveLanguage: $0.requestedEffectiveLanguage)
      }
    /// #3973 C3: whether `engine` can decode `language` (a code). A language it cannot is asked
    /// as Auto (`MeetingAttemptConfiguration`).
    var engineSupportsLanguage: @Sendable (MeetingEngineChoice, String) -> Bool = { _, _ in true }
    /// Live words while a meeting records (#3973): nil shows none.
    var liveWords: MeetingLiveWords?
    /// The meeting transcript's language (`meetingLanguageMode`, decision 16), read once per
    /// Start and stored on the record (#4105). Live words never read it; they have their own
    /// engine and language (`MeetingLiveWordsChoice`).
    var meetingLanguage: @MainActor () -> LanguageMode = { .auto }
    /// #3973 C3: the final transcript's engine (`meetingTranscriptEngine`), read once per Start
    /// beside the language.
    var meetingTranscriptEngine: @MainActor () -> MeetingEngineChoice = { .parakeet }
    /// #3973 C3: whether `engine`'s model is ready now, for the Transcribe again menu (the pass
    /// checks again and falls back when it is gone by then).
    var isEngineReady: @MainActor (MeetingEngineChoice) -> Bool = { $0 == .parakeet }
    /// Custom Words for live words, read once at each recording's start.
    var liveVocabulary: @MainActor () -> LivePreviewVocabulary = {
      LivePreviewVocabulary(lookups: nil, contextualPhrases: [], dictionaryEnabled: false)
    }
    /// The meeting's microphone choice at Start: dictation's input setting (nil = Auto) and
    /// its channel preferences.
    var microphoneSelection: @MainActor () -> (uid: String?, channels: [String: Int])
    var captureCallSound: @MainActor () -> Bool
    var microphoneAuthorized: @MainActor () -> Bool
    /// Ends a dictation's output hold and waits for media to settle; false when it did not
    /// settle in time (R28).
    var settleDictationHold: @MainActor () async -> Bool
    var freeDiskBytes: @MainActor () -> Int64?
    /// A name for a meeting starting at this time, from the user's calendar (#4017 R5, R11);
    /// nil when the setting is off, access is missing, nothing matches or the bounded lookup
    /// gave up. It must return within its own bound and never throw.
    var meetingTitleAtStart: @MainActor (Date) async -> String? = { _ in nil }
    /// #4012: whether a detected Start is still wanted (detection and its app still on, the
    /// call still going), asked after the waits and before anything is created.
    var detectedStartWanted: @MainActor () async -> Bool = { true }
    /// Saves the meeting's History row durably, its disk work off the main actor; throws when
    /// it could not. #4013 chunk 12B: with the naming pass that proposed the row's automatic
    /// names, returns what naming achieved in the row written (nil when not known).
    var saveTranscript:
      @MainActor (Transcript, SpeakerNamingPass?) async throws -> SpeakerNamingSummary?
    /// #3973 C2: the History row as History holds it now, kept in the commit receipt as the
    /// previous generation's row. Nil when History has none.
    var historyRow: @MainActor (UUID) -> Transcript? = { _ in nil }
    /// #3973 C2: the History row as its file holds it, read in History's command order. Nil
    /// when there is no file; throws when it cannot be read.
    var durableHistoryRow: @MainActor (UUID) async throws -> Transcript? = { _ in nil }
    var removeTranscriptRow: @MainActor (UUID) async throws -> Void
    /// The History rows that name this meeting, for a row whose meeting record is gone.
    var meetingRowIDs: @MainActor (UUID) -> [UUID] = { _ in [] }
    var emitEnded: @MainActor (MeetingEndedTelemetry) -> Void
    var log: @MainActor (String) -> Void
    /// Called whenever recording or processing work starts or ends, so admission elsewhere
    /// (dictation's Ultra activation) is offered again.
    var workChanged: @MainActor () -> Void = {}
    /// Dictation is idle (the same fact meeting work admits on), so a wait can be told apart
    /// from a wait for a meeting summary.
    var isDictationIdle: @MainActor () -> Bool = { true }
    /// #4013 13B: which single call is live now, for every recording's speaker session
    /// (`CallSourceDiscovery`). Nil: no speaker capture.
    var callSources: (any CallSpeakerSources)?
    /// #4013 chunk 13A: the speaker rules in force now and the bundled ones, read without the
    /// network; frozen at recording start. Nil: no speaker capture for this recording.
    var talkerRules: @MainActor () async -> (selected: TalkerRulesSnapshot, bundled: TalkerRules)? =
      { nil }
    /// #4013 chunk 13A: whether this app may read other apps through Accessibility.
    var isAccessibilityTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    /// #4013 chunk 13A: one bounded copy of a call app (run off the main actor).
    var captureCallApp: @Sendable (CallSpeakerTarget, CallAppFamily) -> CallAXCapture = {
      target, family in
      CallSpeakerCapture.live(
        pid: target.pid,
        bounds: CallSpeakerSurfaceChoice.captureBounds(family: family, rule: target.rule),
        policy: CallSpeakerSurfaceChoice.capturePolicy(family: family, rule: target.rule),
        keepPage: { CallSpeakerSurfaceChoice.keepsPage($0, family: family, rule: target.rule) })
    }
    /// #4013 chunk 13A: where speaker copies run; the app shares one, a test makes its own.
    var speakerCaptureLane: CallSpeakerObserver.Lane = .shared
    /// #4248: whether "Leave my voice out when I'm muted" is on (`meetingFollowsCallMute`); the
    /// settings change route calls `muteFollowingChanged()` when it changes.
    var muteFollowingEnabled: @MainActor () -> Bool = { true }
    /// #4248: the host clock mute changes are stamped with.
    var hostTime: @Sendable () -> UInt64 = { mach_absolute_time() }
    /// #4013 13B: the speaker session's timing (tests shorten it).
    var speakerSessionTiming: (tick: Duration, settle: Duration, observerTick: Duration) = (
      .milliseconds(500), .seconds(2), .milliseconds(500)
    )
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
    /// #3973 C2: the commit receipt's write, run on `MeetingFileWriter`'s queue.
    var writeCommitReceipt: @Sendable (MeetingStore, MeetingTranscriptReplacement) throws -> Void =
      {
        try $0.saveTranscriptReplacement($1)
      }
    /// One `meeting.json` write, run on `MeetingFileWriter`'s queue.
    var writeRecord: @Sendable (MeetingStore, MeetingRecord) throws -> Void = { try $0.save($1) }
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
  /// The queue stopped because the disk was almost full: queued meetings wait for space, and
  /// Transcribe again restarts the queue once the user freed some (whole-diff review r1 F3).
  private(set) var queueWaitsForSpace = false
  private(set) var notice: Notice?
  private(set) var callSoundStatus: MeetingTrackStatus?
  /// #4124: the starting meeting's call-sound track failed before Start applied the recorder's
  /// result. Kept apart from the live record, which a failed save rolls back.
  @ObservationIgnored private var callSoundFailedWhileStarting = false
  /// The microphone the current recording actually bound.
  private(set) var boundMicrophoneUID: String?
  /// Live words of the meeting recording now, kept after Stop until its transcript is ready
  /// (#3973). Nil without live words.
  var liveTranscript: MeetingLiveWords.Transcript? { deps.liveWords?.transcript }
  /// The live-words owner, for the DEBUG door's engine report and override.
  var liveWords: MeetingLiveWords? { deps.liveWords }

  // MARK: - Private state

  private let deps: Dependencies
  private let writer: MeetingFileWriter
  /// Each meeting's notes and summary (#3972 R46): drafts, debounce and their file writes.
  let documents: MeetingDocumentsOwner
  /// Writes each ready meeting's summary (#3972 R39). Set by `MeetingWiring`; nil writes none.
  var summaries: MeetingSummaryOwner?

  /// The final pass waits for a meeting summary call, not for dictation (R50).
  var passWaitsOnSummary: Bool {
    (summaries?.localSummaryCallRunning ?? false) && deps.isDictationIdle()
  }

  /// A final pass runs, or the queue is draining runnable meetings: a local summary call waits
  /// for it (R50: final first). Derived from the queue itself, which skips meetings marked for
  /// deletion, being deleted or still closing and stops on low disk, so a meeting the queue
  /// cannot run never holds summaries back.
  var hasFinalPassWork: Bool { processing != nil || queueTask != nil }
  /// #4105: a meeting is starting, recording, stopping, or its final pass runs or is draining
  /// the queue. A live words download is refused meanwhile (`MeetingDownloadAdmission`).
  var isMeetingActive: Bool { phase != .idle || hasFinalPassWork }
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
  /// #4118: each recording meeting's segment list, kept in memory until Stop or quit; while it
  /// exists, every save of that meeting writes only its checkpoint.
  @ObservationIgnored private var segmentSaves: [UUID: MeetingSegmentSaves] = [:]
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
  /// #3973 C2: committed transcripts not yet published to History, by meeting. While one is
  /// here History still holds the previous row, which pairs with the receipt's previous facts
  /// (`historyPrevious`). Observable: History redraws when one is published.
  private var unpublishedReceipts: [UUID: MeetingTranscriptReplacement] = [:]
  /// #3973 C2: meetings whose commit receipt is not settled in this session (unpublished, a
  /// ready write that failed, or a receipt this build cannot read). Transcribe again waits for
  /// the next launch's reconciliation rather than write a second receipt over it. Observable:
  /// the detail view's Transcribe again follows it.
  private var unresolvedReceipts: Set<UUID> = []
  /// #3973 C2: meetings whose failed ready write is being read back, with the edits waiting.
  @ObservationIgnored private var settlingCommits: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  /// #3973 C2: meetings whose failed ready write could not be read back: whether it landed is
  /// unknown for this session, so no edit writes their record until the next launch decides
  /// (rename, AI title and Delete audio refuse; Transcribe again waits on `unresolvedReceipts`;
  /// deleting the meeting removes it whatever it holds).
  @ObservationIgnored private var unknownCommits: Set<UUID> = []
  private var deleting: Set<UUID> = []
  /// Meetings whose Delete audio is under way, from its guard until its files are gone (#3994):
  /// claimed synchronously, so no pass can start on audio that is being removed.
  private var removingAudio: Set<UUID> = []
  private var startGeneration = 0
  /// Meetings an explicit Transcribe again queued while a drain ran (#4008): each gets one more
  /// opportunity in that drain. Emptied at every selection and when the drain starts and ends.
  @ObservationIgnored private var retriedDuringDrain: Set<UUID> = []
  private var processEndWaiters: [CheckedContinuation<Void, Never>] = []
  /// Open meeting attempts and the facts frozen at their start (#3972 R11). An attempt is one
  /// Start whose meeting exists, one Retry, or a meeting this launch found unfinished; it ends
  /// with exactly one `meeting.ended` row, and is removed then. In memory only: after a
  /// relaunch the facts are unknown (nil), never guessed.
  private var openAttempts: [UUID: AttemptFacts] = [:]

  /// The facts of each meeting's last ended attempt, for a Retry of the same recording.
  private var lastAttemptFacts: [UUID: AttemptFacts] = [:]

  /// #4013 chunk 12B: ready attempts closed at the ready barrier whose `meeting.ended` row waits
  /// for the History publication's result, so it can report the names actually written. Only
  /// frozen, content-free facts; settled once (`settleEnded`), at the latest at quit.
  private var pendingEnded: [UUID: PendingEnded] = [:]

  /// #4013 chunk 13A: the recording's speaker observer and the meeting it belongs to.
  private var speakerSession: (meetingID: UUID, session: CallSpeakerSession)?
  /// #4248: the recording's mute follower and the newest state it published.
  private var muteFollow: MuteFollow?
  /// #4248: what the live card shows about the call's mute button; nil while not recording.
  private(set) var muteState: MeetingMuteFollower.State?
  /// #4248: audio the hold had already released when a mute change that would alter it arrived.
  private(set) var muteMissed = MeetingMuteFollower.Missed()
  /// #4248: the call app of the binding `muteState` describes, for the live card's muted line.
  private(set) var muteCallApp: CallAppFamily?
  #if DEBUG
    /// The call app recorded for each binding generation of the current recording.
    var muteCallAppsForTesting: [UInt64: CallAppFamily] { muteFollow?.callApps ?? [:] }
    /// Mute readings the current recording handed to its writer.
    var muteReadingsSentForTesting: Int {
      muteFollow.flatMap { muteCaptureCounts[$0.meetingID]?.delivered } ?? 0
    }
    /// Every snapshot that reached the MainActor, accepted by the fence or not.
    private(set) var muteSnapshotsDeliveredForTesting = 0
  #endif

  private struct MuteFollow {
    let meetingID: UUID
    let gate: MeetingMuteGate
    var fence: MeetingMuteGate.SnapshotFence
    /// Each binding generation's call app, so a snapshot names the call it was decided for.
    var callApps: [UInt64: CallAppFamily] = [:]
  }
  /// #4248 timing receipt: each recording's chances to read the mute button, kept until its
  /// gate reports the `.end` decision (after the follower itself was released).
  private var muteCaptureCounts: [UUID: MuteCaptureCounts] = [:]

  struct MuteCaptureCounts: Equatable {
    var started = 0
    var dictationSkip = 0
    var noPermission = 0
    var busySkip = 0
    var staleDrop = 0
    var delivered = 0
  }
  /// Sessions whose final log is not on disk yet: a Stop is saving it, or that save failed.
  /// A quit saves them within its deadline; deleting the meeting drops its own.
  private var unsavedSpeakerSessions: [UUID: CallSpeakerSession] = [:]

  private struct PendingEnded {
    let attemptID: UUID
    let event: FrozenEnded
  }

  /// One attempt's terminal facts, frozen when it closes: everything `meeting.ended` reports
  /// except the naming summary.
  private struct FrozenEnded {
    let outcome: MeetingEndedTelemetry.Outcome
    let facts: AttemptFacts
    let durationSeconds: Double
    let microphoneTrack: MeetingTrackStatus
    let callSoundTrack: MeetingTrackStatus
    let engine: MeetingEngineChoice?
    let speakerCount: Int
    let processingSeconds: Double
    let audioSeconds: Double
    let yieldCount: Int
    let gapCount: Int
    let echoHiddenCount: Int
    let summaryPlan: MeetingEndedTelemetry.SummaryPlan
    let hasNotes: Bool

    func event(speakerNaming: SpeakerNamingSummary?) -> MeetingEndedTelemetry {
      MeetingEndedTelemetry(
        outcome: outcome, entryPoint: facts.entryPoint, durationSeconds: durationSeconds,
        microphoneTrack: microphoneTrack, callSoundTrack: callSoundTrack, engine: engine,
        speakerCount: speakerCount, processingSeconds: processingSeconds,
        audioSeconds: audioSeconds, yieldCount: yieldCount, gapCount: gapCount,
        echoHiddenCount: echoHiddenCount, diskStopped: facts.diskStopped,
        summaryPlan: summaryPlan, hasNotes: hasNotes, callSound: facts.callSound,
        speakerNaming: speakerNaming)
    }
  }

  struct AttemptFacts: Equatable {
    var entryPoint: MeetingEntryPoint?
    var diskStopped: Bool?
    /// #4121: the recorder's call-sound summary, frozen at stop; nil when none.
    var callSound: CallSoundSummary?
    /// #3973 C3: the engine this attempt's pass resolved to, once it did.
    var resolvedEngine: MeetingEngineChoice?
  }
  /// Meetings whose files a timed-out close still owns this session (only `stopForQuit` can time
  /// out; a normal stop awaits the physical close). Nothing reads, promotes or removes them
  /// until the next launch.
  private var closeOwned: Set<UUID> = []
  /// Listing, recovery and file reads in flight, on the main actor's books.
  private var fileWorkInFlight = 0
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
    isCapturing || (job?.isUnitInFlight ?? false) || committing
      || !deleting.isEmpty || !removingAudio.isEmpty
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
  /// #4052, #3973 C3: the final pass is transcribing on its own copy of `backend`. An engine
  /// switch of dictation into that engine waits until it is released (gate 6d), so two copies
  /// never coexist. Live words run on Apple speech or the Universal engine, never a meeting
  /// final engine.
  func isFinalPassOwnModelResident(_ backend: ASRBackendType) -> Bool {
    guard job?.isOwnModelResident == true else { return false }
    return processingResolution?.engine.backendType == backend
  }
  /// #3973 C3: the engine the running pass decodes with.
  private var processingResolution: MeetingEngineResolution?

  var isMeetingModelWorkActive: Bool {
    (job?.isEngineResident ?? false) || (job?.isUnitInFlight ?? false)
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
      record.state != .stopping,
      // #4118: an interrupted meeting's saved list may be only its recording checkpoint until
      // its pass rebuilds the list from the files.
      !(record.wasInterrupted == true
        && ([.queued, .processing, .interrupted] as [MeetingState]).contains(record.state))
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

  /// #4013 r3 F3: the participant list saved with the meeting, for the rename suggestions.
  /// Read on the meeting file queue. `nil` when the meeting is unknown, being deleted or losing
  /// its audio (the list goes with the audio), at the start of the read OR when it returns, or
  /// when the file is missing or unusable.
  func callSpeakerEvidence(meetingID: UUID) async -> CallSpeakerEvidence? {
    guard rosterReadable(meetingID) else { return nil }
    #if DEBUG
      rosterReadAdmittedForTesting?()
    #endif
    guard case .usable(let log)? = try? await writer.loadCallSpeakers(meeting: meetingID),
      rosterReadable(meetingID)
    else { return nil }
    return CallSpeakerEvidence(log)
  }

  /// The latest intended state (`live`) and the open claims, not only what is on disk: a
  /// deletion or Delete audio counts from the moment it starts.
  private func rosterReadable(_ meetingID: UUID) -> Bool {
    guard let record = live[meetingID], record.audioKept, !record.deletionRequested else {
      return false
    }
    return !deleting.contains(meetingID) && !removingAudio.contains(meetingID)
  }

  func dismissNotice() { notice = nil }

  // MARK: - Launch

  /// Lists meetings and recovers any a crash, force quit or quit interrupted (R3, R15). Run
  /// once, after the orphaned dictation hold was restored; the listing runs off the main
  /// actor. Repeatable: a second call changes nothing.
  func launch() {
    guard !launched else { return }
    launched = true
    launchTask = Task { [weak self] in
      await self?.recoverAtLaunch()
      // Cleared on every way recovery ends: `canTranscribeAgain` reads it (#4008).
      self?.launchTask = nil
    }
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
    // #3973 C2: commit receipts are settled before History, the queue, summaries or audio
    // cleanup read these meetings. Committed ones pair History's previous row with its own
    // facts until published below; uncommitted ones are dropped.
    let committedReceipts = await reconcileReceipts(loaded)
    publish()
    for receipt in committedReceipts where isStillOwned(receipt.meetingID) {
      _ = await publishCommitted(receipt, atLaunch: true)
    }
    // Notes are searched with their meeting's transcript (R38): read every meeting's notes
    // once, behind the listing, on the file queue.
    let toRead = loaded
    // #3973 C2: a meeting whose committed row could not be published keeps its owed summary
    // for the launch that publishes it; resumed now it would find no transcript and drop it.
    let ready = loaded.filter {
      live[$0]?.state == .ready && live[$0]?.deletionRequested != true
        && unpublishedReceipts[$0] == nil
    }
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
      // An audio deletion an exit or a failure cut short is finished (its record already says
      // the audio is gone).
      if !record.audioKept, record.isWritableByThisBuild {
        await finishAudioDeletion(meetingID)
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

  /// #3973 C2: reads each meeting's commit receipt. A receipt whose candidate the record on disk
  /// committed (the ready barrier passed) is returned for publication; one it did not commit is
  /// removed (nothing was committed; History and the record still agree on the previous
  /// generation). A receipt that cannot be read, or removed, is kept and blocks Transcribe again
  /// for this session. A meeting marked for deletion is left to its deletion.
  private func reconcileReceipts(_ meetingIDs: [UUID]) async -> [MeetingTranscriptReplacement] {
    var committed: [MeetingTranscriptReplacement] = []
    for meetingID in meetingIDs {
      guard let record = live[meetingID], !record.deletionRequested, record.isWritableByThisBuild
      else { continue }
      let loaded: MeetingStore.ReplacementLoad
      do {
        loaded = try await writer.run { $0.loadTranscriptReplacement(meeting: meetingID) }
      } catch {
        loaded = .unusable
      }
      switch loaded {
      case .none:
        continue
      case .unusable where record.state != .ready:
        // Only the ready write commits a receipt, so a meeting that is not ready committed
        // none: the receipt is dropped like an uncommitted one, unread.
        deps.log("meeting commit receipt unreadable id=\(meetingID.uuidString) committed=false")
        do {
          try await writer.run { try $0.clearTranscriptReplacement(meeting: meetingID) }
        } catch {
          // Kept out of the queue until a launch removes it; the failure is shown.
          deps.log("meeting commit receipt clear failed error=\(type(of: error))")
          unresolvedReceipts.insert(meetingID)
          notice = .storageFailed
        }
      case .unusable:
        deps.log("meeting commit receipt unreadable id=\(meetingID.uuidString)")
        unresolvedReceipts.insert(meetingID)
        notice = .storageFailed
      case .receipt(let receipt):
        if record.committedTranscriptGeneration == receipt.candidate.generation {
          unpublishedReceipts[meetingID] = receipt
          unresolvedReceipts.insert(meetingID)
          committed.append(receipt)
        } else {
          do {
            try await writer.run { try $0.clearTranscriptReplacement(meeting: meetingID) }
          } catch {
            deps.log("meeting commit receipt clear failed error=\(type(of: error))")
            unresolvedReceipts.insert(meetingID)
          }
        }
      }
    }
    return committed
  }

  private func publish() {
    meetings = records.values.sorted { $0.createdAt > $1.createdAt }
    onMeetingsPublished?()
  }

  /// Told after `meetings` changes, so History drops a selection whose meeting is gone.
  @ObservationIgnored var onMeetingsPublished: (@MainActor () -> Void)?

  #if DEBUG
    /// The deadline each Delete All mark was given, in order (#4102), so a test can see one
    /// deadline shared by every meeting rather than read the clock.
    @ObservationIgnored private(set) var deleteAllMarkDeadlinesForTesting: [DispatchTime] = []
    /// Runs after an ordinary write landed and before its answer is applied, so a test can
    /// hold that answer behind later writes in a chosen order (#4102).
    @ObservationIgnored var writeWillAnswerForTesting: (@MainActor (MeetingRecord) async -> Void)?
    /// The live copy and an open deletion, so a test can see a change has reached the
    /// coordinator before it releases a held write (#4102).
    func liveRecordForTesting(_ id: UUID) -> MeetingRecord? { live[id] }
    func isDeletingForTesting(_ id: UUID) -> Bool { deleting.contains(id) }
    /// #4013: called when a roster read has passed its first check and is about to wait on the
    /// file queue, so a test can start a deletion exactly then.
    @ObservationIgnored var rosterReadAdmittedForTesting: (@MainActor () -> Void)?
  #endif

  // MARK: - Start and stop

  /// Starts a meeting. `captureCallSound` is the call-sound choice the Start was admitted with
  /// (`MeetingStartFlow` decides the explainer on it); nil reads the setting now. Either way it
  /// is frozen here, before any wait, so a switch flipped during the start never changes this
  /// recording (#3972 C5b review r1).
  /// The result names what this Start did, and the meeting it created when it created one, so a
  /// caller never infers it from the newest meeting.
  @discardableResult
  func start(
    from entryPoint: MeetingEntryPoint, captureCallSound: Bool? = nil,
    callApp: CallAppFamily? = nil
  ) async
    -> StartOutcome
  {
    guard phase == .idle, !quitting else { return .notIdle }
    let captureCall = captureCallSound ?? deps.captureCallSound()
    // #4105: the transcript language this Start asked for, read before any wait so a change
    // during the waits belongs to the next meeting.
    let transcriptLanguage = deps.meetingLanguage()
    let transcriptEngine = deps.meetingTranscriptEngine()
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
    callSoundFailedWhileStarting = false
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
    // #4017 R11: one start time for the calendar lookup and the record; the name is set on the
    // record before it is first written, so no published record is ever renamed from here.
    let startedAt = Date()
    let calendarTitle = await deps.meetingTitleAtStart(startedAt)
    // A Stop or quit during the lookup owns the outcome: nothing was created.
    guard isCurrentStart(generation) else { return .superseded(meetingID: nil) }
    // A detected Start whose detection, app switch or call changed during the waits starts
    // nothing (review r4 F1).
    if entryPoint == .detected {
      let wanted = await deps.detectedStartWanted()
      // A Stop or a newer Start during that read owns the state (review r13 F1).
      guard isCurrentStart(generation) else { return .superseded(meetingID: nil) }
      if !wanted {
        phase = .idle
        workChanged()
        return .superseded(meetingID: nil)
      }
    }
    var record = MeetingRecord(
      title: calendarTitle, createdAt: startedAt, engine: transcriptEngine,
      trackStatus: [.microphone: .captured, .callSound: captureCall ? .captured : .off])
    // #4012: the call app a detected Start was for, so the fallback name says "Zoom call".
    record.callApp = callApp
    // #4105: in the record before its first save, so recovery and retry use this value.
    record.transcriptLanguageMode = transcriptLanguage
    // #3973 C2: the attempt this Start asked for, frozen from the same read.
    record.beginAttempt(record.attemptFromStartValues(supports: deps.engineSupportsLanguage))
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
    // Stopped while the folder was created, or (a detected Start) detection, its app switch or
    // the call changed meanwhile (review r5 F2): nothing was recorded into it.
    var withdrawn = false
    if entryPoint == .detected { withdrawn = !(await deps.detectedStartWanted()) }
    guard isCurrentStart(generation), !withdrawn else {
      do {
        try await writer.run { try $0.deleteFolder(meeting: meetingID) }
      } catch {
        // An empty folder left behind; launch recovery lists it as an empty meeting.
        deps.log("meeting start cleanup failed error=\(type(of: error))")
      }
      if withdrawn, isCurrentStart(generation) {
        phase = .idle
        workChanged()
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
    let saves = MeetingSegmentSaves()
    segmentSaves[meetingID] = saves
    let recorder = deps.makeRecorder(
      MeetingRecorder.Configuration(
        meetingID: meetingID, folder: deps.store.folder(for: meetingID),
        captureCallSound: captureCall, microphoneUID: mic.uid, inputChannelByDeviceUID: mic.channels
      ),
      { [weak self] track, info in
        // #4118: taken in here, on the writer's thread; one main-actor update per burst.
        guard saves.append(track: track, info: info) else { return }
        Task { @MainActor in
          await self?.segmentFinalized(meetingID: meetingID, saves: saves)
        }
      },
      { [weak self] track, error in
        Task { await self?.trackFailed(meetingID: meetingID, track: track, error: error) }
      })
    // #3973: live words' inputs are this recording's, read once now. Their pumps and the
    // recorder's observer exist before capture starts, so the first samples are buffered;
    // engines start only once capture did.
    let liveVocabulary = deps.liveVocabulary()
    let liveClockStart = ContinuousClock.now
    recorder.liveSamples = deps.liveWords?.prepareCapture(meetingID: meetingID)
    // Reachable while it starts, so a Stop or a quit in the meantime reaches it.
    self.recorder = recorder
    activeMeetingID = meetingID
    let result: MeetingRecorder.StartResult
    do {
      result = try await recorder.start()
    } catch {
      // No engine starts for a recording that never captured (a Stop that took over already
      // retired them).
      deps.liveWords?.captureFailed(meetingID: meetingID)
      // A stop or quit that took over owns the recorder and the record.
      guard isCurrentStart(generation) else { return .superseded(meetingID: meetingID) }
      deps.log("meeting start failed error=\(String(describing: error).prefix(80))")
      discardSegmentSaves(meetingID)
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
    // A detected Start withdrawn while capture started (review r6 F1): the attempt is stopped
    // and removed, so nothing it captured becomes a meeting.
    var wantedAfterCapture = true
    if entryPoint == .detected { wantedAfterCapture = await deps.detectedStartWanted() }
    // A Stop or a newer Start during that read owns the recorder and the record (r13 F1).
    guard isCurrentStart(generation) else { return .superseded(meetingID: meetingID) }
    if !wantedAfterCapture {
      // Still `.starting` with this meeting active: Stop closes its recorder.
      await stop()
      await delete(meetingID: meetingID)
      return .superseded(meetingID: nil)
    }
    record = live[meetingID] ?? record
    // #4124: a call-sound failure the recorder reported during the waits above wins over the
    // startup answer, even when saving that failure failed and rolled the live record back.
    let callSound: MeetingTrackStatus =
      callSoundFailedWhileStarting ? .failed : result.callSound
    record.trackStatus[.callSound] = callSound
    callSoundStatus = callSound
    if callSound == .failed { notice = .callSoundFailed }
    if callSound == .unsupported { notice = .callSoundUnavailable }
    boundMicrophoneUID = recorder.boundMicrophoneUID
    deps.log("meeting recording started bound=\(boundMicrophoneUID ?? "unknown")")
    if let token = deps.beginActivity() { activity = token }
    phase = .recording(meetingID: meetingID, startedAt: record.createdAt)
    startMuteFollow(meetingID: meetingID, recorder: recorder)
    // #4013 13B: every recording, however it started, gets one speaker session. Not awaited:
    // Start goes on at once, and the session checks after its own wait that this recording is
    // still the one recording.
    Task { [weak self] in
      await self?.startSpeakerSession(meetingID: meetingID, recorder: recorder)
    }
    var captured: Set<MeetingTrackKind> = [.microphone]
    if callSound == .captured { captured.insert(.callSound) }
    deps.liveWords?.captureStarted(
      meetingID: meetingID, captured: captured, vocabulary: liveVocabulary,
      clock: { Int((ContinuousClock.now - liveClockStart) / .milliseconds(1)) })
    await persist(record)
    return .recording(meetingID: meetingID)
  }

  /// #4012: whether a Start now would be refused for a reason known before it begins (the
  /// microphone refused, too little disk). A switch to a new call checks this before it stops
  /// the meeting recording now. Asks and changes nothing.
  /// #4232: where one transcription attempt's notes stand, for the call panel's notes card.
  enum NotesFact: Equatable {
    /// Still to be written, or written but not yet in History (Open could not show it yet).
    case writing
    /// The attempt's transcript is committed and its History row is published.
    case ready
    /// Nothing more to say: the meeting is gone or being deleted, failed, notes-only,
    /// interrupted, or another attempt replaced this one (Transcribe again).
    case ended
  }

  /// #4232: the attempt a recording will transcribe; nil when the meeting has none pending.
  func pendingAttemptID(meetingID: UUID) -> UUID? {
    live[meetingID]?.pendingAttempt?.attemptID
  }

  /// #4232: the notes card's one read. Ready uses the same published-row test as the launch
  /// summary resume (`live[...].state == .ready`, not deleting, no unpublished receipt).
  func notesFollowUp(meetingID: UUID, followedAttemptID: UUID) -> NotesFact {
    Self.notesFact(
      record: live[meetingID], followedAttemptID: followedAttemptID,
      published: unpublishedReceipts[meetingID] == nil)
  }

  /// The decision behind `notesFollowUp`, on one record. `published`: no History publication
  /// is still owed for this meeting.
  nonisolated static func notesFact(
    record: MeetingRecord?, followedAttemptID: UUID, published: Bool
  ) -> NotesFact {
    guard let record, !record.deletionRequested else { return .ended }
    // Another attempt pending (Transcribe again) or committed means this one was replaced.
    if let pending = record.pendingAttempt?.attemptID, pending != followedAttemptID {
      return .ended
    }
    switch record.state {
    case .failed, .notesOnly, .interrupted: return .ended
    case .ready:
      guard record.committedTranscriptAttemptID == followedAttemptID else { return .ended }
      return published ? .ready : .writing
    case .recording, .stopping, .queued, .processing: return .writing
    }
  }

  /// #4232: whether the Mac's sound is being captured for `meetingID`, the recording now.
  func callSoundCaptured(meetingID: UUID) -> Bool {
    guard case .recording(meetingID, _) = phase else { return false }
    return callSoundStatus == .captured
  }

  func startWouldBeRefused() -> Bool {
    if !deps.microphoneAuthorized() { return true }
    if let free = deps.freeDiskBytes(), free < Self.diskFloorBytes { return true }
    return false
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
        // The durable mark decides, like `isStillOwned` (#4102).
        guard !quitting, !deleting.contains(meetingID), var current = live[meetingID],
          records[meetingID]?.deletionRequested != true
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
              records[meetingID]?.deletionRequested != true
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
    // #4013 chunk 13A: speaker capture closes now; its final save lands before the pass reads it.
    let session = takeSpeakerSession(meetingID)
    session?.closeAdmission()
    if let session { unsavedSpeakerSessions[meetingID] = session }
    // #4248: the follower's final stretch is queued on the microphone writer before its close,
    // so the held tail is released against it.
    endMuteFollow(meetingID)
    // Stays reachable until the files are closed, so a quit meanwhile takes it over.
    let recorder = self.recorder
    // #4248: the recorder stops first. Its microphone writer releases the held tail (the last
    // 3 s, with muted stretches silenced) to live words while it closes the files; only then do
    // live words seal their pumps and drain them. Stop never waits for recognition.
    let report = await recorder?.stop()
    // Tests' fake recorders have no writer; the receipt reads the production recorder only.
    traceMuteWriter((recorder as? MeetingRecorder)?.microphoneHealth)
    // #3973, #4097: then live words retire without waiting; their cleanup drains held audio and
    // kept events and closes admission. The lines stay until the transcript is ready. A quit
    // during the close already retired them (`quit()`), so this changes nothing then.
    deps.liveWords?.stop()
    // A quit during the close owns the outcome (interrupted, its own deadline).
    guard !quitting else { return }
    // A final log that could not be saved stays owned here, for a quit to save.
    if let session, await session.finish(), unsavedSpeakerSessions[meetingID] === session {
      unsavedSpeakerSessions[meetingID] = nil
    }
    guard !quitting else { return }
    adoptCallSoundSummary(report, for: meetingID)
    self.recorder = nil
    endActivity()
    if var record = live[meetingID] {
      finishSegmentSaves(meetingID, into: &record)
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
      if await persist(record) == false, !quitting, live[meetingID] != nil {
        // #4267: retry the same stopped record once before leaving recovery to the next launch.
        preserveEditsDuringStop(into: &record)
        if await persist(record) == false, !quitting, live[meetingID] != nil {
          record.state = .interrupted
          record.wasInterrupted = true
          closeOwned.insert(meetingID)
          preserveEditsDuringStop(into: &record)
          live[meetingID] = record
        }
      }
    }
    activeMeetingID = nil
    boundMicrophoneUID = nil
    phase = .idle
    workChanged()
    startQueueIfNeeded()
    await documents.flush(meetingID)
  }

  // #4267: keep concurrent edits without replacing Stop's final state or capture report.
  private func preserveEditsDuringStop(into record: inout MeetingRecord) {
    guard let current = live[record.id] else { return }
    record.title = current.title
    record.deletionRequested = current.deletionRequested
  }

  /// #4121: keeps the recorder's frozen call-sound summary on the open attempt, for its
  /// `meeting.ended` row. A report without one changes nothing.
  private func adoptCallSoundSummary(_ report: MeetingRecorder.StopReport?, for meetingID: UUID) {
    guard let summary = report?.callSoundSummary else { return }
    openAttempts[meetingID]?.callSound = summary
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

  private func segmentFinalized(meetingID: UUID, saves: MeetingSegmentSaves) async {
    guard !quitting, meetingID == activeMeetingID, segmentSaves[meetingID] === saves,
      let record = live[meetingID]
    else { return }
    let update = saves.update()
    for track in MeetingTrackKind.allCases {
      if let count = update.notes[track] {
        deps.log(
          "meeting segment rate high track=\(track.rawValue) segmentsAtLeast=\(count) "
            + "windowMs=\(MeetingSegmentSaves.rateWindowMs)")
      }
    }
    // The checkpoint itself comes from `persist`'s projection.
    if update.shouldSave { await persist(record) }
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
    if track == .callSound, phase == .starting { callSoundFailedWhileStarting = true }
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
    retriedDuringDrain = []
    defer { retriedDuringDrain = [] }
    queueWaitsForSpace = false
    while !quitting {
      // A meeting the user asked to transcribe again during this drain gets one more turn; a
      // failed pass never adds one (#4008).
      attempted.subtract(retriedDuringDrain)
      retriedDuringDrain = []
      guard
        let next = meetings.last(where: {
          $0.state == .queued && !$0.deletionRequested && !deleting.contains($0.id)
            && !attempted.contains($0.id) && !closeOwned.contains($0.id)
            // The live copy decides (#3994): a Delete audio whose save is still on its way has
            // already changed it, while `meetings` still shows the meeting queued.
            && live[$0.id]?.state == .queued && live[$0.id]?.audioKept == true
            && !removingAudio.contains($0.id)
            // #3973 C2: a receipt this launch could not settle is never written over; the
            // meeting waits for the next launch.
            && !unresolvedReceipts.contains($0.id)
        })
      else { break }
      attempted.insert(next.id)
      if let free = deps.freeDiskBytes(), free < Self.diskFloorBytes {
        // Stays queued; Transcribe again (offered while the queue waits for space), a later
        // launch or a new Stop tries again, each through this same disk check.
        notice = .lowDisk
        queueWaitsForSpace = true
        return
      }
      await process(next.id)
    }
  }

  private func process(_ meetingID: UUID) async {
    // The claim is synchronous and comes before the first await (#3994): from here no Delete
    // audio, Retry or second pass can start on this meeting (`isActive`), and a meeting whose
    // audio removal began is never claimed.
    guard var record = live[meetingID], record.state == .queued, record.audioKept,
      !isActive(meetingID), isStillOwned(meetingID)
    else { return }
    processing = Processing(meetingID: meetingID, stage: nil)
    workChanged()
    // #3973 C2: a meeting queued before attempts existed runs its saved Start values as an
    // attempt, saved with this write; Settings are never read here.
    if record.pendingAttempt == nil { record.beginAttempt(record.attemptFromStartValues()) }
    let attempt = record.pendingAttempt ?? record.attemptFromStartValues()
    record.state = .processing
    guard await persist(record), isStillOwned(meetingID) else {
      // The pass never began: the claim is released without the pass's own ending (its live
      // words stay, nothing was decoded). A deletion waiting on the claim goes on.
      releaseProcessingClaim()
      return
    }
    defer {
      processing = nil
      job = nil
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
    var damaged: Set<String> = Set(
      report.problems.compactMap(MeetingDamagedAudio.damagedFileName))
    for kind in MeetingTrackKind.allCases {
      let files = (report.segments[kind] ?? []).map {
        (url: folder.appendingPathComponent($0.fileName), startMs: $0.startMs)
      }
      guard !files.isEmpty else { continue }
      // Detached for the same reason: a synchronous header and frame-count read of every file.
      let audio = await Task.detached(priority: .utility) { MeetingTrackAudio(files: files) }.value
      for problem in audio.problems { deps.log("meeting track problem \(problem)") }
      damaged.formUnion(audio.problems.compactMap(MeetingDamagedAudio.damagedFileName))
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
    let missingAudio = MeetingDamagedAudio.missingAudio(
      damaged: damaged, onDisk: onDisk, readable: tracks)
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
        endAttempt(
          failed, outcome: .failed, gapCount: MeetingDamagedAudio.markerCount(missingAudio))
      }
      return
    }
    // The inventory rebuilt from the files, durable before the pass reads it.
    guard await persist(current), isStillOwned(meetingID) else { return }
    // #4013 chunk 12A: the saved speaker evidence, read once through the file queue; the pass
    // names from this snapshot even if the file changes while it runs.
    let callSpeakers = await callSpeakerEvidenceForPass(meetingID)
    guard isStillOwned(meetingID) else { return }

    let resolution = await deps.resolveEngine(attempt)
    // Read again after the await: a deletion mark or a quit meanwhile wins.
    guard isStillOwned(meetingID) else { return }
    if let reason = resolution.fallbackReason {
      deps.log(
        "meeting engine fallback requested=\(attempt.requestedEngine.rawValue) resolved=\(resolution.engine.rawValue) reason=\(reason.rawValue)"
      )
    }
    openAttempts[meetingID]?.resolvedEngine = resolution.engine
    processingResolution = resolution
    let job = deps.makeJob(resolution)
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
      // #4105, #3973 C2: the saved attempt's language and engine, from the record only.
      result = try await job.run(
        tracks: tracks, language: resolution.effectiveLanguage, checkpoint: access,
        missingAudio: missingAudio, callSpeakers: callSpeakers,
        onStage: { [weak self] stage in self?.processing?.stage = stage },
        attempt: attempt)
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
          failed, outcome: .failed, gapCount: MeetingDamagedAudio.markerCount(missingAudio),
          processingSeconds: Date().timeIntervalSince(started))
      }
      return
    }
    guard isStillOwned(meetingID), let finished = live[meetingID] else { return }

    // #3973 C2 (plan §3 item 5) commit, in order: the receipt (the new History row and the
    // previous generation's facts), the ready barrier, then the History row, then the receipt
    // and the checkpoint are cleared. Before the barrier nothing changed for the user: the
    // previous transcript stays shown and paired with its own facts. After it, the committed
    // transcript is published, now or by the next launch, never rolled back.
    committing = true
    defer { committing = false }
    if let naming = result.naming?.result {
      // Counts only: never a name or a speaker.
      deps.log(
        "meeting speaker names proposed=\(naming.proposals.count) pairs=\(naming.pairProposals)")
    }
    let previousGeneration = finished.committedTranscriptGeneration
    let receipt = MeetingTranscriptReplacement(
      meetingID: meetingID,
      previous: previousGeneration.map {
        .init(
          generation: $0, echoTurnIDs: finished.echoTurnIDs,
          speakerOutcomes: finished.speakerOutcomes)
      },
      previousRow: previousGeneration == nil ? nil : deps.historyRow(finished.transcriptID),
      candidate: .init(
        generation: result.resolved.attemptID, echoTurnIDs: result.composition.echoTurnIDs,
        speakerOutcomes: result.speakerOutcomes),
      candidateRow: Self.transcript(for: finished, result: result))
    do {
      try await writer.run { [write = deps.writeCommitReceipt] in try write($0, receipt) }
    } catch {
      deps.log("meeting commit receipt save failed error=\(type(of: error))")
      // Read again: a deletion mark or a rename during the save stays.
      guard isStillOwned(meetingID), var failed = live[meetingID] else { return }
      failed.state = .failed
      failed.failureCode = "commit_failed"
      if await persist(failed) {
        endAttempt(
          failed, outcome: .failed, result: result,
          gapCount: result.failedPieces + MeetingDamagedAudio.markerCount(missingAudio),
          processingSeconds: Date().timeIntervalSince(started))
      }
      return
    }
    // The summary decision (R48), taken before the ready barrier so an owed summary is durable
    // before the meeting is ready: a quit right after the barrier never loses it (the relaunch
    // finishes it). Written either way, so an older mark never outlives a decision not to.
    // #3973 C2 (plan §3 item 6): only a first transcript schedules a summary. A replacement
    // keeps the existing summary, which its new transcript generation marks out of date; Write
    // again replaces it.
    let summaryPlan: MeetingEndedTelemetry.SummaryPlan =
      previousGeneration == nil ? (summaries?.decide() ?? .off) : .notApplicable
    // A summary still being written over the previous transcript (Transcribe again) ends and
    // settles first: it clears its own owed mark and sends its one row before the new decision
    // writes the new mark, so it can never clear the new one (whole-diff review r1 F1).
    await summaries?.settleBeforeNewTranscript(meetingID)
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
    // #3973 C2: the ready barrier commits this attempt as the shown transcript's generation.
    ready.commitAttempt(result.resolved)
    ready.speakerOutcomes = result.speakerOutcomes
    ready.echoTurnIDs = result.composition.echoTurnIDs
    ready.failureCode =
      !missingAudio.isEmpty ? "audio_damaged" : (result.failedPieces > 0 ? "pieces_failed" : nil)
    // History keeps the previous row, paired with its own facts, until the new one is published.
    unpublishedReceipts[meetingID] = receipt
    unresolvedReceipts.insert(meetingID)
    // The ready write (file and directory synced) is the barrier before progress is cleared. A
    // failed write is no proof the file is unchanged: the record on disk decides.
    if !(await persist(ready)) {
      guard await settleAfterFailedBarrier(receipt) else {
        unpublishedReceipts[meetingID] = nil
        return
      }
      // The write landed and only its report failed: the adopted record is committed.
      ready = live[meetingID] ?? ready
    }
    // #3973: the transcript now replaces this meeting's live words. A failed, cancelled or
    // uncommitted pass keeps them.
    deps.liveWords?.transcriptReady(meetingID: meetingID)
    // The attempt ends at the ready barrier, in the same main-actor turn: a deletion during the
    // checkpoint clear below finds no open attempt, so it never reports the ready meeting as
    // deleted before ready.
    let outcome: MeetingEndedTelemetry.Outcome =
      ready.wasInterrupted == true
      ? .interruptedReady
      : (result.failedPieces > 0 || !missingAudio.isEmpty ? .readyWithGaps : .ready)
    // #4013 chunk 12B: its `meeting.ended` row waits for the History publication below, which
    // says what naming achieved in the row written; the attempt itself is closed now.
    let attemptID = result.resolved.attemptID
    if let frozen = closeAttempt(
      ready, outcome: outcome, result: result,
      gapCount: result.failedPieces + MeetingDamagedAudio.markerCount(missingAudio),
      processingSeconds: Date().timeIntervalSince(started), summaryPlan: summaryPlan)
    {
      pendingEnded[meetingID] = PendingEnded(attemptID: attemptID, event: frozen)
    }
    // A deletion meanwhile removes the folder, receipt included, and the row.
    let published =
      isStillOwned(meetingID)
      ? await publishCommitted(
        receipt, naming: Self.namingPass(result: result, record: ready), settling: attemptID)
      : false
    // Published rows settled it with their summary; anything else reports no naming.
    settleEnded(meetingID, attemptID: attemptID, speakerNaming: nil)
    if summaryPlan == .scheduled {
      if !owedOnDisk {
        summaries?.settleUnwritableMark(meetingID)
      } else if published {
        // A first transcript's summary starts once its row is in History. An unpublished one
        // stays owed; the next launch publishes the row, then resumes the summary.
        summaries?.startOwed(meetingID)
      }
    }

    do {
      try await writer.run { _ in try checkpoints.clear() }
    } catch {
      deps.log("meeting checkpoint clear failed error=\(type(of: error))")
    }
  }

  /// #3973 C2: publishes a committed receipt's History row, then clears the receipt. False
  /// (receipt kept, storage failure shown) when the row could not be written: History keeps
  /// the previous row with its own facts, and the next launch publishes again.
  ///
  /// At launch the row may already be published (only the receipt's removal failed) and since
  /// edited, such as its speaker names. A History file that already holds this generation is
  /// kept, not rewritten from the receipt; one that cannot be read publishes nothing.
  ///
  /// #4013 chunk 12B: `settling` is the attempt whose `meeting.ended` row waits on this
  /// publication; it is settled with the naming summary the History write returned as soon as
  /// the row is written, before the receipt is cleared.
  private func publishCommitted(
    _ receipt: MeetingTranscriptReplacement, atLaunch: Bool = false,
    naming: SpeakerNamingPass? = nil, settling attemptID: UUID? = nil
  ) async -> Bool {
    let meetingID = receipt.meetingID
    do {
      let held = atLaunch ? try await deps.durableHistoryRow(receipt.candidateRow.id) : nil
      // A deletion that began during the read owns the row now. Checked in the same main-actor
      // turn the save is admitted to History's queue, so a later deletion's removal runs after it.
      guard isStillOwned(meetingID) else { return false }
      var summary: SpeakerNamingSummary?
      if held?.meetingTranscriptGeneration != receipt.candidate.generation {
        summary = try await deps.saveTranscript(receipt.candidateRow, naming)
      }
      if let attemptID { settleEnded(meetingID, attemptID: attemptID, speakerNaming: summary) }
    } catch {
      deps.log("meeting history publish failed error=\(type(of: error))")
      notice = .storageFailed
      return false
    }
    unpublishedReceipts[meetingID] = nil
    do {
      try await writer.run { try $0.clearTranscriptReplacement(meeting: meetingID) }
      unresolvedReceipts.remove(meetingID)
    } catch {
      // History is right; the next launch publishes the same row again and clears it.
      deps.log("meeting commit receipt clear failed error=\(type(of: error))")
    }
    return true
  }

  /// #3973 C2: a ready write failed, which proves nothing about the file. The record is read
  /// back. One that committed the candidate (the write landed and only its report failed) is
  /// adopted as the durable copy, so no later edit writes the older record back over it, and
  /// the commit goes on (true). One that did not means nothing was committed: the receipt is
  /// removed and Transcribe again works as before (false). One that cannot be read keeps the
  /// receipt and blocks Transcribe again for the next launch, which decides from the file.
  ///
  /// Edits that build on the live copy (rename, AI title) wait for it (`waitForCommitSettlement`):
  /// live has rolled back to the earlier record, so one written meanwhile could put that record
  /// back over a commit that landed. Set in the same main-actor turn the ready write failed in;
  /// the read is queued on the file writer after every write already sent, so it sees them.
  private func settleAfterFailedBarrier(_ receipt: MeetingTranscriptReplacement) async -> Bool {
    let meetingID = receipt.meetingID
    settlingCommits[meetingID] = []
    defer {
      let waiters = settlingCommits.removeValue(forKey: meetingID) ?? []
      for waiter in waiters { waiter.resume() }
    }
    guard let onDisk = try? await writer.run({ try $0.load(id: meetingID) }) else {
      deps.log("meeting commit unsettled; next launch reconciles")
      unknownCommits.insert(meetingID)
      notice = .storageFailed
      return false
    }
    if onDisk.committedTranscriptGeneration == receipt.candidate.generation {
      records[meetingID] = onDisk
      live[meetingID] = onDisk
      publish()
      return true
    }
    do {
      try await writer.run { try $0.clearTranscriptReplacement(meeting: meetingID) }
      unresolvedReceipts.remove(meetingID)
    } catch {
      deps.log("meeting commit receipt clear failed error=\(type(of: error))")
      notice = .storageFailed
    }
    return false
  }

  /// #3973 C2: waits while the meeting's failed ready write is being settled
  /// (`settleAfterFailedBarrier`).
  private func waitForCommitSettlement(_ meetingID: UUID) async {
    guard settlingCommits[meetingID] != nil else { return }
    await withCheckedContinuation { settlingCommits[meetingID, default: []].append($0) }
  }

  /// #3973 C2: whether the meeting's commit receipt is not settled in this session.
  func isCommitReceiptPending(_ meetingID: UUID) -> Bool { unresolvedReceipts.contains(meetingID) }

  /// #3973 C2: the previous generation's History facts while a committed transcript is not
  /// yet published (`MeetingHistoryInfo.paired(with:previous:)`).
  func historyPrevious(_ meetingID: UUID) -> MeetingHistoryInfo.Previous? {
    guard let previous = unpublishedReceipts[meetingID]?.previous else { return nil }
    return MeetingHistoryInfo.Previous(
      generation: previous.generation, echoTurnIDs: Set(previous.echoTurnIDs),
      speakerOutcomes: previous.speakerOutcomes)
  }

  /// False once the meeting is being deleted (or durably marked for it) or the app is quitting: a
  /// late step then writes nothing. Synchronous, so no deletion can land between this check and
  /// the cache update of the write after it.
  ///
  /// The mark is read from the durable copy, not `live` (#4102 cloud review): Delete All's mark
  /// sits in `live` while it is awaited, and a step that gave up on it would strand the meeting
  /// if the mark then failed or was withdrawn. A step that carries on writes on the live copy,
  /// mark included, so a mark that lands that way still deletes the meeting (`persist`).
  private func isStillOwned(_ meetingID: UUID) -> Bool {
    // A meeting whose deletion already finished is gone from `records`: not owned either.
    guard let record = records[meetingID] else { return false }
    return !quitting && !deleting.contains(meetingID) && !record.deletionRequested
  }

  /// The saved speaker evidence as a pass receives it. A failure to read is unusable evidence,
  /// never a failed pass: naming then leaves the fallback labels.
  private func callSpeakerEvidenceForPass(_ meetingID: UUID) async -> MeetingCallSpeakerEvidence {
    let load: MeetingStore.CallSpeakersLoad
    do {
      load = try await writer.loadCallSpeakers(meeting: meetingID)
    } catch {
      deps.log("meeting call speakers read failed error=\(type(of: error))")
      return .unusable(.unreadable)
    }
    switch load {
    case .usable(let log): return .usable(log)
    case .absent: return .absent
    case .unusable(let reason):
      switch reason {
      case .unreadable: return .unusable(.unreadable)
      case .tooLarge: return .unusable(.tooLarge)
      case .newerFormat: return .unusable(.newerFormat)
      case .invalid: return .unusable(.invalid)
      }
    }
  }

  /// The History row a finished meeting is saved as (R5, R19). Always `.labeled` so History keeps
  /// the turns; the truthful per-track outcome lives in the meeting record.
  ///
  /// #4013 chunk 12A: the pass's proposed names replace the display names of the speakers they
  /// were proposed for, marked `.auto`; nothing else about the composition changes. The user's
  /// own names are applied later, by the durable History write.
  static func transcript(for record: MeetingRecord, result: MeetingTranscriptionJob.Result)
    -> Transcript
  {
    let composition = result.composition
    var names = composition.speakerNames
    var sources: [String: SpeakerNameSource] = [:]
    let present = Set(composition.turns.map(\.speakerId))
    for (speaker, name) in result.naming?.result.proposals ?? [:] where present.contains(speaker) {
      names[speaker] = name
      sources[speaker] = .auto
    }
    return Transcript(
      id: record.transcriptID, text: composition.text, duration: result.audioSeconds,
      processingTime: result.processingSeconds,
      backendType: result.resolved.resolvedEngine.backendType, createdAt: record.createdAt,
      speakerAnalysis: composition.turns.isEmpty
        ? nil : .labeled(count: max(1, composition.speakerCount)),
      speakerNames: composition.turns.isEmpty ? nil : names,
      turns: composition.turns.isEmpty ? nil : composition.turns,
      speakerNameSources: composition.turns.isEmpty || sources.isEmpty ? nil : sources,
      meetingID: record.id, meetingTranscriptAttemptID: result.resolved.attemptID)
  }

  // MARK: - User actions on a meeting

  /// Whether Transcribe again may run for this meeting now (#4008): the one answer the detail
  /// view and dev control show. Reads only observable state, so the button follows it. A
  /// `.processing` meeting no pass owns (its end could not be saved) is offered: no running
  /// pass, no deletion, no launch recovery still to run. A queued meeting is offered when no
  /// queue will take it: the disk was full (the queue starts again and checks the disk again),
  /// or the queue ended without it (its pass's first save failed).
  func canTranscribeAgain(_ meetingID: UUID) -> Bool {
    guard launchTask == nil, !quitting, let record = live[meetingID],
      record.isWritableByThisBuild, record.audioKept, !record.deletionRequested,
      !isActive(meetingID), !closeOwned.contains(meetingID),
      // #3973 C2: an unsettled commit receipt is settled by the next launch first.
      !unresolvedReceipts.contains(meetingID)
    else { return false }
    if record.state == .queued { return queueWaitsForSpace || queueTask == nil }
    return [.failed, .ready, .interrupted, .processing].contains(record.state)
  }

  /// Transcribe again with `engine` (#3973 C2): a new attempt, frozen now from the current
  /// meeting language against that engine, so a new Start value never reaches a saved
  /// attempt and an old one never reaches this. The transcript shown so far stays until the new
  /// one commits. A meeting left queued or processing with no pass (its attempt never ran to
  /// an end) continues its saved attempt instead (`resumeAttempt`). True when the meeting was
  /// queued (or, waiting for space, the queue was started again); false when it was refused or
  /// its queued state could not be saved.
  @discardableResult
  func transcribeAgain(meetingID: UUID, engine: MeetingEngineChoice) async -> Bool {
    // Launch recovery decides first what an unfinished meeting is (it requeues them itself).
    if let launchTask { await launchTask.value }
    guard canTranscribeAgain(meetingID), let record = live[meetingID] else { return false }
    if [.queued, .processing].contains(record.state) {
      return await resumeAttempt(meetingID: meetingID)
    }
    return await queue(
      meetingID,
      attempt: MeetingAttemptConfiguration(
        requestedEngine: engine, language: deps.meetingLanguage(),
        supports: deps.engineSupportsLanguage))
  }

  /// #3973 C3: the engines Transcribe again offers: the ready ones, the Transcript engine
  /// setting's first.
  var transcribeAgainEngines: [MeetingEngineChoice] {
    let preferred = deps.meetingTranscriptEngine()
    return ([preferred] + MeetingEngineChoice.allCases.filter { $0 != preferred })
      .filter { deps.isEngineReady($0) }
  }

  /// Continues the meeting's saved attempt (#3973 C2): its engine and language as saved, never
  /// Settings. For a meeting left queued or processing with no pass running.
  @discardableResult
  func resumeAttempt(meetingID: UUID) async -> Bool {
    if let launchTask { await launchTask.value }
    guard canTranscribeAgain(meetingID), let record = live[meetingID] else { return false }
    return await queue(meetingID, attempt: record.pendingAttempt ?? record.attemptFromStartValues())
  }

  /// Queues `attempt` for the meeting and starts the queue.
  private func queue(_ meetingID: UUID, attempt: MeetingAttemptConfiguration) async -> Bool {
    guard canTranscribeAgain(meetingID), var record = live[meetingID] else { return false }
    if record.state == .queued, record.pendingAttempt == attempt {
      // Left queued (a full disk, or a pass whose first save failed): nothing to save, the
      // queue starts again and checks the disk again.
      startQueueIfNeeded()
      return true
    }
    record.beginAttempt(attempt)
    record.state = .queued
    guard await persist(record) else { return false }
    // Read again after the save: a Delete audio, a deletion or a quit meanwhile wins.
    guard let current = live[meetingID], current.state == .queued, current.audioKept,
      current.isWritableByThisBuild, isStillOwned(meetingID), !removingAudio.contains(meetingID),
      !closeOwned.contains(meetingID)
    else { return false }
    // A new attempt over the same audio: the recording's facts carry over when known.
    openAttempts[meetingID] =
      openAttempts[meetingID] ?? lastAttemptFacts[meetingID] ?? AttemptFacts()
    if queueTask != nil { retriedDuringDrain.insert(meetingID) }
    startQueueIfNeeded()
    return true
  }

  func rename(meetingID: UUID, title: String) async {
    await waitForCommitSettlement(meetingID)
    guard !unknownCommits.contains(meetingID), var record = live[meetingID] else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    record.title = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    await persist(record)
  }

  /// #4012 D8, R6: a summary's AI title names a meeting that has no name yet. Read from the
  /// latest record just before the save, so a rename, the calendar's name or a deletion
  /// meanwhile wins; it never names a meeting the user already named.
  func assignAITitle(meetingID: UUID, title: String) async {
    await waitForCommitSettlement(meetingID)
    guard !unknownCommits.contains(meetingID), var record = live[meetingID], record.title == nil,
      !deleting.contains(meetingID),
      !closeOwned.contains(meetingID)
    else { return }
    // `MeetingSummary.splitTitle` keeps titles to one short line.
    record.title = title
    await persist(record)
  }

  func deleteAudio(meetingID: UUID) async {
    // #3973 C2: an unknown commit outcome blocks every record edit until the next launch.
    guard !unknownCommits.contains(meetingID), var record = live[meetingID],
      !isActive(meetingID), !closeOwned.contains(meetingID)
    else { return }
    // Claimed in the same turn as the guard (#3994): a pass cannot start on this audio while
    // its removal is saved and carried out.
    removingAudio.insert(meetingID)
    workChanged()
    defer {
      removingAudio.remove(meetingID)
      workChanged()
    }
    // The decision is durable before any file goes: `audioKept == false` is the marker, so an
    // exit or a failed removal part-way never leaves a record that still offers the audio, and
    // the next launch finishes the removal (`finishAudioDeletion`).
    record.audioKept = false
    if record.state == .queued || record.state == .interrupted {
      record.state = .failed
      record.failureCode = "audio_deleted"
    }
    guard await persist(record) else { return }
    await finishAudioDeletion(meetingID)
  }

  /// Removes the audio of a meeting whose record says it is deleted. Repeatable: a launch runs
  /// it for every such meeting, and with no files left it does nothing.
  private func finishAudioDeletion(_ meetingID: UUID) async {
    do {
      try await writer.run { store in
        try store.deleteAudio(meeting: meetingID)
        try MeetingProcessingCheckpointStore(meetingFolder: store.folder(for: meetingID)).clear()
      }
    } catch {
      deps.log("meeting delete audio failed error=\(type(of: error))")
      notice = .storageFailed
    }
  }

  /// The one deletion authority (R12, R19): History's delete of a meeting row comes here too.
  /// False when the deletion could not be done now (#4079): the mark could not be saved, the
  /// row or the folder could not be removed, or an orphan row's folder is still there. History
  /// then says so. A deletion already running, or one deferred to the next launch behind a
  /// close that still owns the files, is not a failure.
  @discardableResult
  func delete(meetingID: UUID) async -> Bool {
    // History can ask before the launch listing finished; the meeting is known after it.
    if live[meetingID] == nil, let launchTask { await launchTask.value }
    guard live[meetingID] != nil else {
      return await deleteOrphan(meetingID: meetingID)
    }
    guard !deleting.contains(meetingID), var record = live[meetingID] else { return true }
    deleting.insert(meetingID)
    workChanged()
    defer {
      deleting.remove(meetingID)
      workChanged()
    }
    // #3973: live words go now, before any write: admission closes and the lines clear. Their
    // cleanup never holds up the deletion.
    deps.liveWords?.delete(meetingID: meetingID)
    record.deletionRequested = true
    guard await persist(record) else { return false }
    // #4013: once the deletion is marked, the recording's speaker capture adds and saves
    // nothing more (the store also refuses). A mark that failed leaves it running, since the
    // recording goes on.
    takeSpeakerSession(meetingID)?.cancel()
    unsavedSpeakerSessions.removeValue(forKey: meetingID)?.cancel()
    endMuteFollow(meetingID)
    // The notes this session knows, read before they are forgotten (R54 `has_notes`).
    let hadNotes = !documents.notes(meetingID).isEmpty
    // Marked: no draft may be written any more (the store also refuses).
    documents.forget(meetingID)
    // A summary being written ends, and has physically ended before the folder is removed.
    await summaries?.cancelAndWait(meetingID)
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
    // Ends an attempt still open (recording, queued, processing); a finished one already
    // sent its row.
    endAttempt(record, outcome: .deletedBeforeReady, hasNotes: hadNotes)
    return await finishDeletion(record)
  }

  /// History's Delete All (R19): marks every listed meeting for deletion DURABLY before
  /// returning (History empties its own store right after), then finishes each deletion.
  /// Each mark waits behind queued writes, all within one second shared by every meeting; the
  /// wait suspends, so the main actor keeps running (#4102). History's queue stays held across
  /// it, so later History commands wait. Returns false when any meeting could not be marked in
  /// time; History then refuses its bulk handoff, though meetings already marked are still
  /// deleted one by one, rows included.
  func deleteForHistoryDeleteAll(meetingIDs: [UUID]) async -> Bool {
    let deadline = DispatchTime.now() + 1
    var marked: [UUID] = []
    var allMarked = true
    for meetingID in meetingIDs {
      // The live copy now, not one read before another meeting's mark suspended (#4102).
      guard var record = live[meetingID] else {
        // No folder means nothing to delete; a folder this session could not read cannot be
        // marked.
        if FileManager.default.fileExists(atPath: deps.store.folder(for: meetingID).path) {
          allMarked = false
        }
        continue
      }
      record.deletionRequested = true
      #if DEBUG
        deleteAllMarkDeadlinesForTesting.append(deadline)
      #endif
      if await persistWithin(
        record, until: deadline,
        lateSuccess: { [weak self] in
          // Marked after all: finish its deletion (History refused its bulk handoff this time).
          Task { await self?.delete(meetingID: meetingID) }
        })
      {
        marked.append(meetingID)
      } else {
        allMarked = false
      }
    }
    // Marked meetings are deleted either way, each on its own task: its row removal joins
    // History's queue, which this Delete All still holds, so it is never awaited here.
    for meetingID in marked { Task { await delete(meetingID: meetingID) } }
    return allMarked
  }

  /// Cancels the meeting's pass, awaits its end (so no checkpoint save is in flight), then
  /// removes the History row and the folder.
  /// A History row whose meeting has no record (its folder is gone): the row is removed only
  /// when the folder is confirmed absent. A folder that is still there but unreadable, or one a
  /// newer EnviousWispr saved, is never touched; false says the row stays (whole-diff review r1
  /// F2).
  @discardableResult
  func deleteOrphan(meetingID: UUID) async -> Bool {
    if live[meetingID] == nil, let launchTask { await launchTask.value }
    guard live[meetingID] == nil, !newerFormatMeetings.contains(where: { $0.id == meetingID })
    else { return false }
    // Only a confirmed absence (lstat says ENOENT) removes the row; a folder that is there, or
    // a path whose state cannot be read (permission, I/O), is refused (whole-diff review r2 F2).
    let absent: Bool
    do {
      absent = try await writer.run { store in Self.confirmedAbsent(store.folder(for: meetingID)) }
    } catch {
      absent = false
    }
    guard absent else {
      deps.log("meeting orphan delete refused reason=folder_present_or_unreadable")
      return false
    }
    // #4075 S1: the folder check suspended, so the meeting is checked again before any row
    // goes, and the rows to remove are taken once: this removes that set, not rows arriving
    // later.
    guard live[meetingID] == nil, !newerFormatMeetings.contains(where: { $0.id == meetingID })
    else { return false }
    let targets = deps.meetingRowIDs(meetingID)
    do {
      for rowID in targets { try await deps.removeTranscriptRow(rowID) }
    } catch {
      deps.log("meeting orphan delete failed error=\(type(of: error))")
      return false
    }
    return true
  }

  /// True only when the path is confirmed not to exist; any other answer, or an error reading
  /// it, is false.
  nonisolated static func confirmedAbsent(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return false }
    return errno == ENOENT
  }

  /// False when the row or the folder could not be removed now (#4079).
  @discardableResult
  private func finishDeletion(_ record: MeetingRecord) async -> Bool {
    if processing?.meetingID == record.id { job?.cancel() }
    await waitUntilNotProcessing(record.id)
    guard !closeOwned.contains(record.id) else {
      // A timed-out close still owns its files: the mark stays and the next launch deletes.
      deps.log("meeting delete deferred reason=close_owned")
      return true
    }
    do {
      // #4075 S1: awaited. `delete(meetingID:)` keeps its deleting claim, and the durable
      // deletion mark and live record stay, until the folder is gone too.
      try await deps.removeTranscriptRow(record.transcriptID)
      let meetingID = record.id
      try await writer.run { try $0.deleteFolder(meeting: meetingID) }
      discardSegmentSaves(record.id)
      // #3973 C2: the receipt went with the folder.
      unpublishedReceipts.removeValue(forKey: record.id)
      unresolvedReceipts.remove(record.id)
      unknownCommits.remove(record.id)
      live.removeValue(forKey: record.id)
      records.removeValue(forKey: record.id)
      publish()
      return true
    } catch {
      // The marker stays in the folder; the next launch finishes the deletion.
      deps.log("meeting delete incomplete error=\(type(of: error))")
      return false
    }
  }

  /// Ends a pass claim that never began its work: waiters resume, admission is offered again.
  private func releaseProcessingClaim() {
    processing = nil
    let waiters = processEndWaiters
    processEndWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    workChanged()
  }

  private func waitUntilNotProcessing(_ meetingID: UUID) async {
    while processing?.meetingID == meetingID {
      await withCheckedContinuation { processEndWaiters.append($0) }
    }
  }

  private func isActive(_ meetingID: UUID) -> Bool {
    if processing?.meetingID == meetingID || deleting.contains(meetingID)
      || removingAudio.contains(meetingID)
    {
      return true
    }
    switch phase {
    case .recording(let id, _), .stopping(let id): return id == meetingID
    case .starting: return activeMeetingID == meetingID
    case .idle: return false
    }
  }

  // MARK: - Quit (R18)

  /// Synchronous: called from `applicationWillTerminate`. Closes admission, cancels the pass,
  /// stops capture and closes both files against one shared deadline. A file whose close did
  /// not finish in time stays owned by its queued close; launch recovery handles it.
  func prepareForTermination(deadline: DispatchTime = .now() + 1) {
    quitting = true
    // #4013 chunk 13A: speaker capture closes first; its final log is saved last, after audio,
    // the record and notes, within the same deadline.
    let speakerSessions: [(meetingID: UUID, session: CallSpeakerSession)] =
      [speakerSession].compactMap { $0 }
      + unsavedSpeakerSessions.map { (meetingID: $0.key, session: $0.value) }
    for entry in speakerSessions { entry.session.closeAdmission() }
    speakerSession = nil
    unsavedSpeakerSessions = [:]
    // #4248: queued ahead of the microphone writer's close below.
    if let meetingID = muteFollow?.meetingID { endMuteFollow(meetingID) }
    // #4013 chunk 12B: ready attempts still waiting on their History publication send their
    // row now, with no naming facts (the publication's result is not known). A late
    // publication finds nothing to settle.
    for (meetingID, pending) in pendingEnded {
      settleEnded(meetingID, attemptID: pending.attemptID, speakerNaming: nil)
    }
    summaries?.prepareForTermination()
    queueTask?.cancel()
    job?.cancel()
    // #4097: Quit starts live-word cleanup without waiting; process exit frees any native model
    // still loaded (`TranscribeCppProcessExit`).
    deps.liveWords?.quit()
    guard let recorder, let meetingID = activeMeetingID, var record = live[meetingID] else {
      // Notes save whether or not anything records (R46), inside the same deadline.
      documents.flushForQuit(deadline: deadline)
      saveSpeakersForQuit(speakerSessions, deadline: deadline)
      endActivity()
      phase = .idle
      return
    }
    // Also a recorder whose Stop is still closing its files: that Stop's continuation returns
    // without writing once `quitting` is set.
    self.recorder = nil
    let report = recorder.stopForQuit(deadline: deadline)
    adoptCallSoundSummary(report, for: meetingID)
    finishSegmentSaves(meetingID, into: &record)
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
    saveSpeakersForQuit(speakerSessions, deadline: deadline)
    endActivity()
    phase = .idle
  }

  /// #4013 chunk 13A: each session's final speaker log, written behind the writes already
  /// queued and never past `deadline`; one that does not start in time is withdrawn. A
  /// session whose final log was already saved has nothing to give.
  private func saveSpeakersForQuit(
    _ sessions: [(meetingID: UUID, session: CallSpeakerSession)], deadline: DispatchTime
  ) {
    for (meetingID, session) in sessions {
      guard let log = session.takeFinalLog() else { continue }
      _ = writer.runBounded(
        until: deadline, { try $0.saveCallSpeakers(log, meeting: meetingID) }, late: { _ in })
    }
  }

  // MARK: - Persistence and telemetry

  /// Makes `record` the live copy, writes it off the main actor in order, and shows it only
  /// once the write succeeded. False (and a visible notice) when it could not be saved; the
  /// live copy then returns to what is on disk, unless a newer change was asked for since.
  @discardableResult
  private func persist(_ record: MeetingRecord) async -> Bool {
    let record = recordingCheckpoint(record)
    let sequence = beginWrite(record)
    do {
      try await writer.save(record)
      #if DEBUG
        await writeWillAnswerForTesting?(record)
      #endif
      writeSucceeded(record, sequence: sequence)
      // A deletion mark this write carried is durable now, so the meeting must go. It may be
      // one it copied from a Delete All mark still on its way that was then withdrawn or failed
      // (#4102 second pass): left alone, History would hide a meeting whose audio stays, and a
      // recording one would keep recording, until the next launch. A deletion already running
      // (its own marking write included) is left to finish.
      if record.deletionRequested, live[record.id]?.deletionRequested == true,
        !deleting.contains(record.id), !quitting
      {
        let meetingID = record.id
        Task { [weak self] in _ = await self?.delete(meetingID: meetingID) }
      }
      return true
    } catch {
      writeFailed(error, record: record, sequence: sequence)
      return false
    }
  }

  /// `persist` bounded by `deadline` on the caller's thread, for the quit path, which cannot
  /// suspend. True only when it landed in time. A write withdrawn before it started counts as
  /// failed and rolls back. A write still running at the deadline keeps the live copy and
  /// reports once when it ends: a success is then shown (and `lateSuccess` runs), a failure
  /// rolls back.
  @discardableResult
  private func persistBounded(
    _ record: MeetingRecord, until deadline: DispatchTime,
    lateSuccess: (@MainActor () -> Void)? = nil
  ) -> Bool {
    let record = recordingCheckpoint(record)
    let sequence = beginWrite(record)
    let outcome = writer.saveBounded(
      record, until: deadline,
      late: lateSettlement(record, sequence: sequence, lateSuccess: lateSuccess))
    return settle(outcome, record: record, sequence: sequence)
  }

  /// `persistBounded` for Delete All, which suspends instead of blocking (#4102): the same
  /// deadline, answers and late report.
  private func persistWithin(
    _ record: MeetingRecord, until deadline: DispatchTime,
    lateSuccess: (@MainActor () -> Void)? = nil
  ) async -> Bool {
    let record = recordingCheckpoint(record)
    let sequence = beginWrite(record)
    let outcome = await writer.saveWithin(
      record, until: deadline,
      late: lateSettlement(record, sequence: sequence, lateSuccess: lateSuccess))
    return settle(outcome, record: record, sequence: sequence)
  }

  /// The report of a bounded write that was still running at its deadline. It may reach the
  /// main actor before or after the caller's own answer; `settle` leaves a still-running write
  /// unanswered, so either order settles it once.
  private func lateSettlement(
    _ record: MeetingRecord, sequence: Int, lateSuccess: (@MainActor () -> Void)?
  ) -> @Sendable (Result<Void, Error>) -> Void {
    { [weak self] result in
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
  }

  /// A bounded write's answer to its caller: true only when it landed in time.
  private func settle(
    _ outcome: MeetingFileWriter.BoundedOutcome, record: MeetingRecord, sequence: Int
  ) -> Bool {
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

  /// #4118: a meeting still recording is saved with its checkpoint (the newest segment per
  /// track), never a partial copy of its full list.
  private func recordingCheckpoint(_ record: MeetingRecord) -> MeetingRecord {
    guard let saves = segmentSaves[record.id] else { return record }
    var checkpoint = record
    checkpoint.segments = saves.checkpoint()
    return checkpoint
  }

  /// Ends a recording's in-memory list and puts every segment into `record`.
  private func finishSegmentSaves(_ meetingID: UUID, into record: inout MeetingRecord) {
    guard let saves = segmentSaves.removeValue(forKey: meetingID) else { return }
    record.segments = saves.finish()
  }

  private func discardSegmentSaves(_ meetingID: UUID) {
    _ = segmentSaves.removeValue(forKey: meetingID)?.finish()
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
    guard
      let frozen = closeAttempt(
        record, outcome: outcome, result: result, gapCount: gapCount,
        processingSeconds: processingSeconds, summaryPlan: summaryPlan, hasNotes: hasNotes)
    else { return }
    deps.emitEnded(frozen.event(speakerNaming: nil))
  }

  /// #4013 13B: starts the recording's one speaker session, whatever started the recording,
  /// with the talker rules frozen when they are read and the recorder's anchor. No call
  /// sources: no session. #4248: while mute following is on the session starts at once and
  /// reads the mute button; naming attaches to it when the rules arrive (no rules: naming
  /// stays off). With following off, the session waits for the rules as before.
  private func startSpeakerSession(meetingID: UUID, recorder: MeetingRecording) async {
    guard deps.callSources != nil else { return }
    if deps.muteFollowingEnabled() {
      makeSpeakerSession(meetingID: meetingID, recorder: recorder, rules: nil)
    }
    let rules = await deps.talkerRules()
    // Read again after the await: a Stop or another start meanwhile wins.
    guard case .recording(let current, _) = phase, current == meetingID, !quitting else { return }
    if let entry = speakerSession, entry.meetingID == meetingID {
      if let rules { entry.session.attachNaming(rules: rules.selected, bundled: rules.bundled) }
      return
    }
    guard let rules else { return }
    makeSpeakerSession(meetingID: meetingID, recorder: recorder, rules: rules)
  }

  /// Creates and starts the session, unless this recording already has one.
  private func makeSpeakerSession(
    meetingID: UUID, recorder: MeetingRecording,
    rules: (selected: TalkerRulesSnapshot, bundled: TalkerRules)?
  ) {
    guard let sources = deps.callSources,
      case .recording(let current, _) = phase, current == meetingID, !quitting,
      speakerSession == nil
    else { return }
    let timing = deps.speakerSessionTiming
    let session = CallSpeakerSession(
      anchor: recorder.anchor, rules: rules?.selected, bundled: rules?.bundled,
      dependencies: .init(
        sources: sources, capture: deps.captureCallApp, isTrusted: deps.isAccessibilityTrusted,
        isDictationIdle: { [weak self] in self?.deps.isDictationIdle() ?? false },
        save: { [weak self] log in
          guard let self else { return }
          try await self.writer.run { try $0.saveCallSpeakers(log, meeting: meetingID) }
        },
        log: { [weak self] line in self?.deps.log(line) }, lane: deps.speakerCaptureLane,
        hostTime: deps.hostTime, tick: timing.tick, settle: timing.settle,
        observerTick: timing.observerTick,
        muteFollowing: { [weak self] in self?.deps.muteFollowingEnabled() ?? false },
        muteBinding: { [weak self] binding in self?.muteBind(binding, meetingID: meetingID) },
        muteReading: { [weak self] copy in self?.muteRead(copy, meetingID: meetingID) },
        muteEvent: { [weak self] event in self?.muteCaptureEvent(event, meetingID: meetingID) },
        muteTick: { [weak self] in self?.muteSend(.advance, meetingID: meetingID) }))
    speakerSession = (meetingID, session)
    deps.log("meeting speaker session started")
    session.start()
  }

  // MARK: - Mute following (#4248 plan §18)

  /// The recording's follower: its decisions run on the microphone writer's queue, before
  /// every release (`setSilenceClock`) and for every input (`applySilenceStep`).
  private func startMuteFollow(meetingID: UUID, recorder: MeetingRecording) {
    let gate = MeetingMuteGate(
      recording: meetingID,
      follower: MeetingMuteFollower(enabled: deps.muteFollowingEnabled()),
      publish: { [weak self] snapshot in
        Task { @MainActor [weak self] in self?.muteSnapshot(snapshot) }
      })
    recorder.setSilenceClock(gate.clock)
    muteFollow = MuteFollow(
      meetingID: meetingID, gate: gate, fence: .init(recording: meetingID))
    muteState = deps.muteFollowingEnabled() ? .unbound : .disabled
    muteMissed = .init()
    muteCallApp = nil
    muteCaptureCounts[meetingID] = MuteCaptureCounts()
    #if DEBUG
      if Self.muteTimingTrace {
        let base = CallSpeakerTimeline.liveTimebase
        deps.log("MEET_MUTE_TIMING_SCHEMA numer=\(base.numer) denom=\(base.denom)")
      }
    #endif
  }

  private func muteSend(_ input: MeetingMuteGate.Input, meetingID: UUID) {
    guard let follow = muteFollow, follow.meetingID == meetingID, let recorder else { return }
    recorder.applySilenceStep(follow.gate.step(input))
  }

  private func muteBind(_ binding: CallCaptureBinding?, meetingID: UUID) {
    if let binding, muteFollow?.meetingID == meetingID {
      muteFollow?.callApps[binding.generation] = binding.source.family
    }
    muteSend(
      binding.map { .bind($0.surface, generation: $0.generation) } ?? .unbind,
      meetingID: meetingID)
  }

  private func muteRead(_ copy: CallMuteCopy, meetingID: UUID) {
    muteCaptureCounts[meetingID]?.delivered += 1
    muteSend(.reading(copy), meetingID: meetingID)
  }

  private func muteCaptureEvent(_ event: CallMuteCaptureEvent, meetingID: UUID) {
    guard muteCaptureCounts[meetingID] != nil else { return }
    switch event {
    case .started: muteCaptureCounts[meetingID]?.started += 1
    case .dictationSkip: muteCaptureCounts[meetingID]?.dictationSkip += 1
    case .noPermission: muteCaptureCounts[meetingID]?.noPermission += 1
    case .busySkip: muteCaptureCounts[meetingID]?.busySkip += 1
    case .staleDrop: muteCaptureCounts[meetingID]?.staleDrop += 1
    }
  }

  /// "Leave my voice out when I'm muted" was switched (`WisprBootstrapper`'s settings route).
  func muteFollowingChanged() {
    let on = deps.muteFollowingEnabled()
    guard let follow = muteFollow else { return }
    muteSend(.setEnabled(on, at: deps.hostTime()), meetingID: follow.meetingID)
    if let entry = speakerSession, entry.meetingID == follow.meetingID {
      entry.session.muteFollowingChanged()
    } else if on, let recorder {
      // No session ran without rules while following was off; one starts now, and naming
      // attaches if the rules arrive.
      let meetingID = follow.meetingID
      makeSpeakerSession(meetingID: meetingID, recorder: recorder, rules: nil)
      Task { [weak self] in
        guard let rules = await self?.deps.talkerRules(),
          let entry = self?.speakerSession, entry.meetingID == meetingID
        else { return }
        entry.session.attachNaming(rules: rules.selected, bundled: rules.bundled)
      }
    }
  }

  /// Every snapshot reaches the timing trace exactly once; only this recording's newest one,
  /// from the current call, reaches the live card and the meter.
  private func muteSnapshot(_ snapshot: MeetingMuteGate.Snapshot) {
    traceMute(snapshot)
    #if DEBUG
      muteSnapshotsDeliveredForTesting += 1
    #endif
    if snapshot.ended { muteCaptureCounts[snapshot.recording] = nil }
    guard var follow = muteFollow, follow.fence.accept(snapshot) else { return }
    muteFollow = follow
    muteState = snapshot.state
    muteMissed = snapshot.missed
    muteCallApp = snapshot.generation.flatMap { follow.callApps[$0] }
    recorder?.setMicrophoneMuted(snapshot.state == .muted)
  }

  #if DEBUG
    /// Whole microseconds of `duration`, for the timing receipt.
    static func micros(_ duration: Duration) -> Int64 {
      duration.components.seconds * 1_000_000 + duration.components.attoseconds / 1_000_000_000_000
    }
  #endif

  /// DEBUG timing receipt: one row per decided reading, and the summary from the `.end`
  /// decision itself, after every queued reading ran.
  private func traceMute(_ snapshot: MeetingMuteGate.Snapshot) {
    #if DEBUG
      guard Self.muteTimingTrace else { return }
      if let trace = snapshot.trace {
        let c = trace.copy
        deps.log(
          "MEET_MUTE_TIMING seq=\(snapshot.seq) gen=\(c.generation) surface=\(c.surface.rawValue) T=\(c.copyStart) E=\(c.copyEnd) complete=\(c.completeness == .complete ? 1 : 0) nodes=\(c.nodes) M=\(c.received) D=\(trace.delivered) C=\(trace.released) outcome=\(trace.outcome) reading=\(c.reading.rawValue) state=\(snapshot.state) completeness=\(c.completeness) failed=\(c.failedReads) msgs=\(c.cost.messages) msg_us=\(Self.micros(c.cost.messageTime)) kinds=\(CallAXCopyCost.Kind.allCases.map { "\($0.rawValue):\(c.cost.byKind[$0]?.messages ?? 0):\(Self.micros(c.cost.byKind[$0]?.time ?? .zero))" }.joined(separator: ",")) win=\(c.cost.windows.map { "\($0.nodes):\($0.ticks):\($0.messages):\(Self.micros($0.messageTime))" }.joined(separator: ","))"
        )
      }
      if snapshot.ended {
        let t = snapshot.totals
        let k = muteCaptureCounts[snapshot.recording] ?? MuteCaptureCounts()
        deps.log(
          "MEET_MUTE_TIMING_SKIPS started=\(k.started) delivered=\(k.delivered) busy=\(k.busySkip) dictation=\(k.dictationSkip) no_permission=\(k.noPermission) stale_drop=\(k.staleDrop) decided=\(t.readings) applied=\(t.applied) stale_at_delivery=\(t.staleAtDelivery) ignored=\(t.ignored) inactive=\(t.inactive) missed_events=\(snapshot.missed.events) kept_ticks=\(snapshot.missed.keptTicks) silenced_ticks=\(snapshot.missed.silencedTicks)"
        )
      }
    #endif
  }

  /// DEBUG timing receipt: the microphone writer's final silence counts, read after its close,
  /// so audio judged late or intervals left out by a full hold are part of the receipt.
  private func traceMuteWriter(_ health: MeetingTrackWriter.Health?) {
    #if DEBUG
      guard Self.muteTimingTrace, let health else { return }
      deps.log(
        "MEET_MUTE_TIMING_WRITER silenced_frames=\(health.silencedFrames) late_frames=\(health.silenceLateFrames) interval_overflows=\(health.silenceIntervalOverflows) dropped_frames=\(health.droppedFrames) failed=\(health.failed ? 1 : 0)"
      )
    #endif
  }

  /// Closes the open stretch at its last muted reading, queued on the microphone writer ahead
  /// of anything the caller does next (its close). The `.end` decision still reports to the
  /// timing trace; the live card stops following now.
  private func endMuteFollow(_ meetingID: UUID) {
    guard let follow = muteFollow, follow.meetingID == meetingID else { return }
    if let recorder {
      recorder.applySilenceStep(follow.gate.step(.end))
      recorder.setMicrophoneMuted(false)
    } else {
      // No writer to run the end step: no summary will come.
      muteCaptureCounts[meetingID] = nil
    }
    muteFollow = nil
    muteState = nil
    muteCallApp = nil
  }

  #if DEBUG
    /// The DEBUG mute timing trace (`EW_MEET_MUTE_TIMING=1`). Host ticks only; no names,
    /// titles, addresses or Accessibility text.
    private static let muteTimingTrace =
      ProcessInfo.processInfo.environment["EW_MEET_MUTE_TIMING"] == "1"
  #endif

  /// The meeting's speaker session, removed from the coordinator; nil when it has none.
  private func takeSpeakerSession(_ meetingID: UUID) -> CallSpeakerSession? {
    guard let current = speakerSession, current.meetingID == meetingID else { return nil }
    speakerSession = nil
    return current.session
  }

  /// Closes the attempt and freezes its terminal facts, or nil when no attempt is open for the
  /// meeting. Sends nothing.
  private func closeAttempt(
    _ record: MeetingRecord, outcome: MeetingEndedTelemetry.Outcome,
    result: MeetingTranscriptionJob.Result? = nil, gapCount: Int = 0,
    processingSeconds: Double = 0,
    summaryPlan: MeetingEndedTelemetry.SummaryPlan = .notApplicable, hasNotes: Bool? = nil
  ) -> FrozenEnded? {
    guard let facts = openAttempts.removeValue(forKey: record.id) else { return nil }
    lastAttemptFacts[record.id] = facts
    return FrozenEnded(
      outcome: outcome, facts: facts,
      durationSeconds: Double(record.recordedDurationMs) / 1000,
      microphoneTrack: record.trackStatus[.microphone] ?? .off,
      callSoundTrack: record.trackStatus[.callSound] ?? .off,
      engine: result?.resolved.resolvedEngine ?? facts.resolvedEngine,
      speakerCount: result?.composition.speakerCount ?? 0,
      processingSeconds: processingSeconds,
      audioSeconds: result?.audioSeconds ?? 0,
      yieldCount: result?.yieldCount ?? 0,
      gapCount: gapCount,
      echoHiddenCount: result?.composition.echoTurnIDs.count ?? 0,
      summaryPlan: summaryPlan,
      // The notes this session knows (typed, or read at launch); a meeting without a folder
      // has none (R54). A deletion passes what it read before forgetting them.
      hasNotes: hasNotes ?? !documents.notes(record.id).isEmpty)
  }

  /// #4013 chunk 12B: sends a ready attempt's waiting `meeting.ended` row once. Only the
  /// attempt it was frozen for settles it, so a late callback from an older attempt never
  /// sends a newer attempt's row; a second call does nothing.
  private func settleEnded(
    _ meetingID: UUID, attemptID: UUID, speakerNaming: SpeakerNamingSummary?
  ) {
    guard let pending = pendingEnded[meetingID], pending.attemptID == attemptID else { return }
    pendingEnded[meetingID] = nil
    deps.emitEnded(pending.event.event(speakerNaming: speakerNaming))
  }

  /// #4013 chunk 12B: the naming pass the History write summarizes, from the pass's own
  /// result. Nil when the pass did not name (no naming result). Missing evidence on a meeting
  /// started for a call app, or evidence that could not be used, is `unavailable`; missing
  /// evidence otherwise says nothing, since it never proves the meeting was not a call.
  static func namingPass(result: MeetingTranscriptionJob.Result, record: MeetingRecord)
    -> SpeakerNamingPass?
  {
    guard let naming = result.naming else { return nil }
    switch naming.evidence {
    case .usable(let log):
      return naming.result.pass(log: log)
    case .unusable:
      return .abstained(surface: nil, outcome: .unavailable)
    case .absent:
      return .abstained(surface: nil, outcome: record.callApp == nil ? nil : .unavailable)
    }
  }
}
