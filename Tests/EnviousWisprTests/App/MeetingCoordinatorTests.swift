import Foundation
import Observation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #3972 C4a: when these fail, a meeting records twice, a Stop or quit misses a recording that
/// is still starting, a meeting shows "ready" without its History row, a deleted meeting comes
/// back, a crash loses a meeting, or a damaged file is read while its close still owns it.
@MainActor
@Suite("MeetingCoordinator", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingCoordinatorTests {

  // MARK: - Fakes

  @MainActor
  @Observable
  final class FakeRecorder: MeetingRecording {
    enum Start {
      case succeed(callSound: MeetingTrackStatus)
      /// The microphone is lost after it delivered audio.
      case fail
      /// The microphone never delivers: nothing reaches disk.
      case failEmpty
      /// Parks until `stop` or `stopForQuit`, then reports that the stop took over.
      case hold
    }

    let configuration: MeetingRecorder.Configuration
    var start: Start
    var report = MeetingRecorder.StopReport(microphone: .finalized, callSound: nil)
    private(set) var stopCalls = 0
    private(set) var quitDeadline: DispatchTime?
    private(set) var startParked = false
    /// When set, `stop` waits on it: the files are still closing.
    @ObservationIgnored var stopGate: Gate?
    @ObservationIgnored private var held: CheckedContinuation<Void, Never>?

    @ObservationIgnored var onSegment: MeetingRecorder.SegmentHandler = { _, _ in }

    init(configuration: MeetingRecorder.Configuration, start: Start) {
      self.configuration = configuration
      self.start = start
    }

    func start() async throws -> MeetingRecorder.StartResult {
      if case .failEmpty = start {
        throw MeetingRecorder.RecorderError.microphoneUnavailable("no_device")
      }
      // Real audio in the real meeting folder: what processing reads.
      try MeetingAudioFixture.writeSegment(
        in: configuration.folder, index: 1, startMs: 0, frames: 16_000)
      switch start {
      case .succeed(let callSound):
        return MeetingRecorder.StartResult(microphone: .captured, callSound: callSound)
      case .fail, .failEmpty:
        throw MeetingRecorder.RecorderError.microphoneUnavailable("microphone_lost")
      case .hold:
        await withCheckedContinuation { continuation in
          held = continuation
          startParked = true
        }
        throw MeetingRecorder.RecorderError.stoppedDuringStart
      }
    }

    func stop() async -> MeetingRecorder.StopReport {
      stopCalls += 1
      releaseStart()
      await stopGate?.wait()
      return report
    }

    /// Runs inside `stopForQuit`, on the main actor, while quit is still running.
    @ObservationIgnored var onStopForQuit: () -> Void = {}

    func stopForQuit(deadline: DispatchTime) -> MeetingRecorder.StopReport {
      quitDeadline = deadline
      onStopForQuit()
      releaseStart()
      return report
    }

    private func releaseStart() {
      held?.resume()
      held = nil
    }

    var boundMicrophoneUID: String? { "fake-mic" }
    var microphoneLevel: Float { 0 }
    var callSoundLevel: Float { 0 }
  }

  @MainActor
  @Observable
  final class FakeJob: MeetingProcessing {
    var behavior:
      @MainActor (MeetingTranscriptionJob.CheckpointAccess?) async throws ->
        MeetingTranscriptionJob.Result
    private(set) var cancelled = false
    private(set) var runs = 0
    private(set) var receivedTracks: [MeetingTrackKind: MeetingTrackAudio] = [:]
    private(set) var receivedMissingAudio: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]] =
      [:]
    var isEngineResident = false
    var isUnitInFlight = false
    var isOwnModelResident = false
    var onWaitingForDictation: (@MainActor (Bool) -> Void)?

    init(
      behavior: @escaping @MainActor (MeetingTranscriptionJob.CheckpointAccess?) async throws
        -> MeetingTranscriptionJob.Result
    ) {
      self.behavior = behavior
    }

    func run(
      tracks: [MeetingTrackKind: MeetingTrackAudio],
      checkpoint access: MeetingTranscriptionJob.CheckpointAccess?,
      missingAudio: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]],
      onStage: @escaping @MainActor (MeetingTranscriptionJob.Stage) -> Void
    ) async throws -> MeetingTranscriptionJob.Result {
      runs += 1
      receivedTracks = tracks
      receivedMissingAudio = missingAudio
      onStage(.composing)
      return try await behavior(access)
    }

    func cancel() { cancelled = true }
  }

  /// Holds the next `meeting.json` write on its worker thread once armed (bounded).
  final class WriteGate: Sendable {
    private let armed = OSAllocatedUnfairLock(initialState: false)
    private let failures = OSAllocatedUnfairLock(initialState: 0)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    /// Set when a held write waited out its 10 s bound: the test never released it in time.
    let timedOut = OSAllocatedUnfairLock(initialState: false)

    func arm() { armed.withLock { $0 = true } }

    /// The next `count` writes fail.
    func failNext(_ count: Int) { failures.withLock { $0 = count } }

    private let failing = OSAllocatedUnfairLock<[@Sendable (MeetingRecord) -> Bool]>(
      initialState: [])
    /// Writes of records matching `predicate` fail, whenever they run.
    func failWrites(where predicate: @escaping @Sendable (MeetingRecord) -> Bool) {
      failing.withLock { $0.append(predicate) }
    }

    func failWrites(inState state: MeetingState) { failWrites { $0.state == state } }

    /// Every record written, in write order.
    let written = OSAllocatedUnfairLock<[MeetingRecord]>(initialState: [])

    func failIfInFailingState(_ record: MeetingRecord) throws {
      if failing.withLock({ $0 }).contains(where: { $0(record) }) { throw InjectedFailure() }
    }

    struct InjectedFailure: Error {}

    func failIfAsked() throws {
      let fail = failures.withLock { value -> Bool in
        guard value > 0 else { return false }
        value -= 1
        return true
      }
      if fail { throw InjectedFailure() }
    }

    private let holdPredicate = OSAllocatedUnfairLock<(@Sendable (MeetingRecord) -> Bool)?>(
      initialState: nil)
    /// Holds the first later write of a record matching `predicate`, like `arm()`.
    func holdNext(where predicate: @escaping @Sendable (MeetingRecord) -> Bool) {
      holdPredicate.withLock { $0 = predicate }
    }

    func passIfHeld(_ record: MeetingRecord) {
      let hold = holdPredicate.withLock { predicate -> Bool in
        guard let match = predicate, match(record) else { return false }
        predicate = nil
        return true
      }
      guard hold else { return }
      entered.signal()
      if release.wait(timeout: .now() + 10) == .timedOut { timedOut.withLock { $0 = true } }
    }

    func passIfArmed() {
      let hold = armed.withLock { value -> Bool in
        defer { value = false }
        return value
      }
      guard hold else { return }
      entered.signal()
      if release.wait(timeout: .now() + 10) == .timedOut { timedOut.withLock { $0 = true } }
    }
  }

  /// A one-shot gate the job parks on, observable so a test waits for "parked".
  @MainActor
  @Observable
  final class Gate {
    private(set) var parked = false
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var opened = false

    func wait() async {
      guard !opened else { return }
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        parked = true
      }
    }

    func open() {
      opened = true
      continuation?.resume()
      continuation = nil
    }
  }

  @MainActor
  @Observable
  final class Harness {
    let root: URL
    let store: MeetingStore
    var recorders: [FakeRecorder] = []
    var jobs: [FakeJob] = []
    var recorderStart: FakeRecorder.Start = .succeed(callSound: .off)
    var jobBehavior:
      @MainActor (MeetingTranscriptionJob.CheckpointAccess?) async throws ->
        MeetingTranscriptionJob.Result = { _ in
          MeetingCoordinatorTests.result()
        }
    var saved: [Transcript] = []
    /// The meeting's saved state at the moment its History row was written.
    var stateAtSave: [MeetingState] = []
    var saveError: Error?
    /// When set, the History save waits on it (a slow durable write).
    var saveGate: Gate?
    /// When set, recovery blocks its worker thread until signalled (bounded).
    var recoveryHold: DispatchSemaphore?
    var checkpointHold: DispatchSemaphore?
    let checkpointEntered = DispatchSemaphore(value: 0)
    /// Signalled when a held recovery read begins: the coordinator has counted it by then (#4031).
    let recoveryEntered = DispatchSemaphore(value: 0)
    let writeGate = WriteGate()
    var removedRows: [UUID] = []
    /// What `meetingRowIDs` answers per meeting.
    var meetingRows: [UUID: [UUID]] = [:]
    var removeError: Error?
    /// Every `meeting.ended` row the coordinator sent, in order.
    var ended: [MeetingEndedTelemetry] = []
    /// Runs as each row is sent, to read state at that exact moment.
    var onEnded: (@MainActor (MeetingEndedTelemetry) -> Void)?
    var settles = true
    /// The "Also record the call sound" setting as the coordinator reads it.
    var callSound = false
    /// When set, the dictation-settle wait at Start parks on it.
    var settleGate: Gate?
    /// #4017 R11: the calendar name a Start's lookup returns, and a gate it parks on.
    var calendarTitle: String?
    /// #4012: what the detected-Start check answers.
    var detectedWanted = true
    /// When set, answers the detected-Start checks in order (then `detectedWanted`).
    var detectedAnswers: [Bool] = []
    /// When set, each detected-Start check waits for it.
    var detectedGate: Gate?
    var titleGate: Gate?
    var titleLookups: [Date] = []
    var freeBytes: Int64? = 50_000_000_000
    var activitiesBegun = 0
    var activitiesEnded = 0
    var logs: [String] = []
    var workChanges = 0
    var settleCalls = 0
    @ObservationIgnored lazy var coordinator = MeetingCoordinator(dependencies: dependencies())

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
      store = MeetingStore(root: root)
      try store.prepareRoot()
    }

    /// The closures hold the harness strongly on purpose: a pass still draining after a test's
    /// last assertion must never read a freed harness. One harness per test, never reused.
    func dependencies() -> MeetingCoordinator.Dependencies {
      MeetingCoordinator.Dependencies(
        store: store,
        makeRecorder: { [self] configuration, onSegment, _ in
          let recorder = FakeRecorder(configuration: configuration, start: recorderStart)
          recorder.onSegment = onSegment
          recorders.append(recorder)
          return recorder
        },
        makeJob: { [self] in
          let job = FakeJob(behavior: jobBehavior)
          jobs.append(job)
          return job
        },
        microphoneSelection: { (nil, [:]) },
        captureCallSound: { [self] in callSound },
        microphoneAuthorized: { true },
        settleDictationHold: { [self] in
          settleCalls += 1
          await settleGate?.wait()
          return settles
        },
        freeDiskBytes: { [self] in freeBytes },
        meetingTitleAtStart: { [self] startedAt in
          titleLookups.append(startedAt)
          await titleGate?.wait()
          return calendarTitle
        },
        detectedStartWanted: { [self] in
          await detectedGate?.wait()
          return detectedAnswers.isEmpty ? detectedWanted : detectedAnswers.removeFirst()
        },
        saveTranscript: { [self] transcript in
          if let meetingID = transcript.meetingID {
            stateAtSave.append(try store.load(id: meetingID).state)
          }
          await saveGate?.wait()
          if let saveError { throw saveError }
          saved.append(transcript)
        },
        removeTranscriptRow: { [self] id in
          if let removeError { throw removeError }
          removedRows.append(id)
        },
        meetingRowIDs: { [self] id in meetingRows[id] ?? [] },
        emitEnded: { [self] event in
          ended.append(event)
          onEnded?(event)
        },
        log: { [self] line in logs.append(line) },
        workChanged: { [self] in workChanges += 1 },
        beginActivity: { [self] in
          activitiesBegun += 1
          return NSObject()
        },
        endActivity: { [self] _ in activitiesEnded += 1 },
        recoverFolder: { [recoveryHold, recoveryEntered] folder in
          if let recoveryHold {
            recoveryEntered.signal()
            _ = recoveryHold.wait(timeout: .now() + 10)
          }
          return MeetingTrackRecovery.recover(folder: folder)
        },
        saveCheckpoint: { [checkpointHold, checkpointEntered] store, checkpoint in
          if let checkpointHold {
            checkpointEntered.signal()
            _ = checkpointHold.wait(timeout: .now() + 10)
          }
          try store.save(checkpoint)
        },
        writeRecord: { [writeGate] store, record in
          writeGate.passIfArmed()
          writeGate.passIfHeld(record)
          try writeGate.failIfAsked()
          try writeGate.failIfInFailingState(record)
          try store.save(record)
          writeGate.written.withLock { $0.append(record) }
        })
    }

    func checkpointURL(_ meetingID: UUID) -> URL {
      MeetingProcessingCheckpointStore(meetingFolder: store.folder(for: meetingID)).fileURL
    }
  }

  static func result(text: String = "hello there") -> MeetingTranscriptionJob.Result {
    MeetingTranscriptionJob.Result(
      composition: MeetingComposition(
        text: text, turns: [], speakerNames: [:], echoTurnIDs: ["mic-3"], speakerCount: 1),
      speakerOutcomes: [.microphone: .single], forcedCuts: 0, failedPieces: 0, failedRanges: [:],
      resumedPieces: 0, checkpointSaveFailures: 0, yieldCount: 0, processingSeconds: 1,
      audioSeconds: 1)
  }

  /// On a worker thread: once `gate`'s write is held, whether the main actor runs a job within
  /// 2 s. Releases the write either way.
  nonisolated static func mainActorAnswers(whileHolding gate: WriteGate) -> Bool {
    guard waitBlocking(gate.entered) == .success else { return false }
    let ran = DispatchSemaphore(value: 0)
    Task { @MainActor in ran.signal() }
    let answered = ran.wait(timeout: .now() + 2) == .success
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    return answered
  }

  /// A bounded blocking wait, for a worker thread (never the main actor).
  nonisolated static func waitBlocking(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 10)
  }

  static func checkpoint(_ meetingID: UUID) -> MeetingProcessingCheckpoint {
    MeetingProcessingCheckpoint(
      key: .init(
        meetingID: meetingID, processingVersion: 1, pieceTargetSeconds: 60,
        pieceSearchSeconds: 15, seamPaddingSeconds: 1, cutsPieces: true, inputs: []),
      engineIdentity: "ultra:rev", tracks: [:])
  }

  /// Waits for `condition` through Observation, with a deadline that only fails the test.
  static func eventually(
    _ label: String, timeout: Duration = .seconds(10),
    _ condition: @escaping @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let waiter = Task { @MainActor in await MeetingWorkAdmission.waitUntil(condition) }
    let expired = ExpiryFlag()
    let deadline = Task { @MainActor in
      // deadline-fallback: ends a wait whose signal never came, and fails it below.
      guard (try? await Task.sleep(for: timeout)) != nil else { return }
      expired.value = true
      waiter.cancel()
    }
    await waiter.value
    deadline.cancel()
    // A condition Observation cannot see would only pass ON the deadline: that is a failure too.
    #expect(expired.value == false, "waited out the deadline: \(label)", sourceLocation: sourceLocation)
    #expect(condition(), "never satisfied: \(label)", sourceLocation: sourceLocation)
    // The live copy changes before its write lands: let queued meeting writes finish, so the
    // disk reads after this see them.
    await drainMeetingFiles()
  }

  @MainActor
  final class ExpiryFlag {
    var value = false
  }

  static func drainMeetingFiles() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      MeetingFileWriter.queue.async { done.resume() }
    }
  }

  private func onlyMeeting(_ harness: Harness) throws -> MeetingRecord {
    try #require(harness.coordinator.meetings.count == 1)
    return try #require(harness.coordinator.meetings.first)
  }

  @Test("the bounded wait fails when its signal never comes")
  func eventuallyFailsOnDeadline() async {
    await withKnownIssue {
      await Self.eventually("never", timeout: .milliseconds(50)) { false }
    }
  }

  // MARK: - Start, stop and commit

  @Test("start then stop records once, then saves History, then ready, then clears progress")
  func recordStopCommitInOrder() async throws {
    let harness = try Harness()
    harness.jobBehavior = { access in
      // Progress saved mid-pass, as the real job does.
      try await #require(access).save(Self.checkpoint(try #require(access).meetingID))
      return Self.result()
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    await coordinator.start(from: .history)
    #expect(harness.recorders.count == 1)
    #expect(coordinator.isRecording)
    #expect(coordinator.boundMicrophoneUID == "fake-mic")
    #expect(harness.activitiesBegun == 1)
    let meetingID = try onlyMeeting(harness).id

    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }

    #expect(harness.recorders.first?.stopCalls == 1)
    #expect(harness.activitiesEnded == 1)
    #expect(harness.jobs.count == 1)
    #expect(harness.jobs.first?.receivedTracks[.microphone]?.isEmpty == false)
    // History first, while the meeting was still processing; ready only after.
    #expect(harness.stateAtSave == [.processing])
    let row = try #require(harness.saved.first)
    let record = try harness.store.load(id: meetingID)
    #expect(row.id == record.transcriptID)
    #expect(row.meetingID == meetingID)
    #expect(row.text == "hello there")
    #expect(record.echoTurnIDs == ["mic-3"])
    #expect(record.speakerOutcomes == [.microphone: .single])
    #expect(record.segments[.microphone]?.first?.frameCount == 16_000)
    await Self.eventually("checkpoint cleared") {
      !FileManager.default.fileExists(atPath: harness.checkpointURL(meetingID).path)
    }
    #expect(coordinator.isWorkInFlight == false)
  }

  @Test("a History save that fails keeps the progress and never reports ready")
  func failedHistorySaveKeepsCheckpoint() async throws {
    let harness = try Harness()
    harness.saveError = CocoaError(.fileWriteOutOfSpace)
    harness.jobBehavior = { access in
      try await #require(access).save(Self.checkpoint(try #require(access).meetingID))
      return Self.result()
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("failed") { coordinator.record(id: meetingID)?.state == .failed }

    let record = try harness.store.load(id: meetingID)
    #expect(record.failureCode == "commit_failed")
    #expect(harness.saved.isEmpty)
    #expect(FileManager.default.fileExists(atPath: harness.checkpointURL(meetingID).path))

    // Retry resumes from the kept progress, then commits.
    harness.saveError = nil
    var sawCheckpoint = false
    harness.jobBehavior = { access in
      let checkpoints = try #require(access)
      sawCheckpoint = await checkpoints.load() != nil
      return Self.result()
    }
    await coordinator.retry(meetingID: meetingID)
    await Self.eventually("ready after retry") {
      coordinator.record(id: meetingID)?.state == .ready
    }
    #expect(sawCheckpoint)
    #expect(harness.saved.count == 1)
  }

  @Test("a Stop while the recorder is still starting reaches that recorder")
  func stopDuringStartReachesRecorder() async throws {
    let harness = try Harness()
    harness.recorderStart = .hold
    let coordinator = harness.coordinator
    let starting = Task { await coordinator.start(from: .menu) }
    await Self.eventually("start parked") { harness.recorders.first?.startParked == true }
    #expect(coordinator.phase == .starting)

    await coordinator.stop()
    await starting.value

    #expect(harness.recorders.count == 1)
    #expect(harness.recorders.first?.stopCalls == 1)
    #expect(coordinator.phase == .idle)
    // Never began: nothing to end.
    #expect(harness.activitiesBegun == 0)
    #expect(harness.activitiesEnded == 0)
    let meetingID = try onlyMeeting(harness).id
    // The audio it wrote while starting is processed, not lost.
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
  }

  @Test("a microphone that cannot start refuses Start and leaves no meeting")
  func microphoneUnavailableRefuses() async throws {
    let harness = try Harness()
    harness.recorderStart = .failEmpty
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    #expect(coordinator.phase == .idle)
    #expect(coordinator.notice == .microphoneUnavailable)
    #expect(coordinator.meetings.isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: harness.root.path)
        .filter { !$0.hasPrefix(".") }.isEmpty)
    #expect(harness.activitiesBegun == harness.activitiesEnded)
    #expect(harness.jobs.isEmpty)
  }

  @Test("a microphone lost during the start keeps what reached disk and processes it")
  func microphoneLostKeepsAudio() async throws {
    let harness = try Harness()
    harness.recorderStart = .fail
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    #expect(coordinator.phase == .idle)
    #expect(coordinator.notice == .microphoneUnavailable)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    let record = try harness.store.load(id: meetingID)
    #expect(record.wasInterrupted == true)
    #expect(record.trackStatus[.microphone] == .failed)
    #expect(harness.saved.count == 1)
    #expect(harness.activitiesBegun == harness.activitiesEnded)
  }

  @Test("a calendar name is on the meeting from its first write and survives a reload")
  func calendarTitleNamesTheMeeting() async throws {
    let harness = try Harness()
    harness.calendarTitle = "Customer sync: Acme"
    let coordinator = harness.coordinator
    await coordinator.start(from: .menu)
    let meeting = try onlyMeeting(harness)
    #expect(meeting.title == "Customer sync: Acme")
    // The lookup and the record use one start time.
    #expect(harness.titleLookups == [meeting.createdAt])
    #expect(try harness.store.load(id: meeting.id).title == "Customer sync: Acme")
    await coordinator.stop()
  }

  @Test("no calendar name leaves the title empty for the date name")
  func noCalendarTitle() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .menu)
    #expect(try onlyMeeting(harness).title == nil)
    await coordinator.stop()
  }

  @Test("a Stop during the calendar lookup creates nothing, and its late name is dropped")
  func stopDuringCalendarLookup() async throws {
    let harness = try Harness()
    harness.calendarTitle = "Late name"
    let gate = Gate()
    harness.titleGate = gate
    let coordinator = harness.coordinator
    let starting = Task { await coordinator.start(from: .menu) }
    await Self.eventually("lookup parked") { gate.parked }
    await coordinator.stop()
    gate.open()
    let outcome = await starting.value
    #expect(outcome == .superseded(meetingID: nil))
    #expect(coordinator.meetings.isEmpty)
    #expect(harness.recorders.isEmpty)
    #expect(coordinator.phase == .idle)
  }

  @Test("Start is refused before any source opens: low disk, or sound that did not settle")
  func startRefusals() async throws {
    let harness = try Harness()
    harness.freeBytes = 10_000_000
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    #expect(coordinator.notice == .lowDisk)
    #expect(harness.settleCalls == 0)

    harness.freeBytes = 50_000_000_000
    harness.settles = false
    await coordinator.start(from: .history)
    #expect(coordinator.notice == .finishDictationFirst)
    #expect(harness.settleCalls == 1)
    #expect(harness.recorders.isEmpty)
    #expect(coordinator.meetings.isEmpty)
    #expect(coordinator.phase == .idle)

    // A later attempt that settles starts normally.
    harness.settles = true
    await coordinator.start(from: .history)
    #expect(coordinator.isRecording)
    #expect(harness.recorders.count == 1)
    await coordinator.stop()
  }

  @Test("a file whose close timed out is never read now; launch recovery takes it")
  func timedOutCloseIsNotProcessed() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    try #require(harness.recorders.first).report = MeetingRecorder.StopReport(
      microphone: .timedOut, callSound: nil)
    await coordinator.stop()

    let record = try harness.store.load(id: meetingID)
    #expect(record.state == .interrupted)
    #expect(record.wasInterrupted == true)
    #expect(record.trackStatus[.microphone] == .failed)
    #expect(harness.jobs.isEmpty)
    // Nor does playback (#3972 C5c).
    #expect(coordinator.playbackSource(meetingID: meetingID) == nil)

    // This session never touches files the queued close still owns.
    await coordinator.retry(meetingID: meetingID)
    await coordinator.deleteAudio(meetingID: meetingID)
    await coordinator.delete(meetingID: meetingID)
    #expect(harness.jobs.isEmpty)
    #expect(try harness.store.segmentFiles(meeting: meetingID).isEmpty == false)
    #expect(harness.removedRows.isEmpty)
    #expect(try harness.store.load(id: meetingID).deletionRequested)

    // Next launch: the marked deletion completes; the files are no longer owned.
    let relaunched = MeetingCoordinator(dependencies: harness.dependencies())
    relaunched.launch()
    await Self.eventually("deleted after launch") {
      harness.removedRows.contains(record.transcriptID)
    }
    #expect(harness.removedRows == [record.transcriptID])
  }

  @Test("a timed-out close left for launch is recovered and processed")
  func timedOutCloseRecoversAtLaunch() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    try #require(harness.recorders.first).report = MeetingRecorder.StopReport(
      microphone: .timedOut, callSound: nil)
    await coordinator.stop()
    #expect(harness.jobs.isEmpty)

    // Next launch: recovered from the files on disk and processed.
    let relaunched = MeetingCoordinator(dependencies: harness.dependencies())
    relaunched.launch()
    await Self.eventually("ready after launch") {
      relaunched.record(id: meetingID)?.state == .ready
    }
    #expect(harness.saved.count == 1)
  }

  @Test("a failed close marks the track failed but keeps its audio for processing")
  func failedCloseStillProcesses() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    try #require(harness.recorders.first).report = MeetingRecorder.StopReport(
      microphone: .failed, callSound: nil)
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    #expect(try harness.store.load(id: meetingID).trackStatus[.microphone] == .failed)
  }

  // MARK: - Deletion

  @Test("deleting during a pass cancels it, waits for its drain, then removes row and folder")
  func deleteDuringPassAwaitsDrain() async throws {
    let harness = try Harness()
    let gate = Gate()
    harness.jobBehavior = { _ in
      // Stands in for a checkpoint save still running when the cancel arrives.
      await gate.wait()
      throw MeetingTranscriptionJob.JobError.cancelled
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let record = try onlyMeeting(harness)
    await coordinator.stop()
    await Self.eventually("pass parked") { gate.parked }
    #expect(coordinator.isMeetingModelWorkActive == false)

    let deletion = Task { await coordinator.delete(meetingID: record.id) }
    await Self.eventually("cancelled") { harness.jobs.first?.cancelled == true }
    // Still draining: nothing removed yet, and the marker is durable.
    #expect(harness.removedRows.isEmpty)
    #expect(try harness.store.load(id: record.id).deletionRequested)
    #expect(coordinator.isWorkInFlight)

    gate.open()
    await deletion.value
    #expect(harness.removedRows == [record.transcriptID])
    #expect(
      FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path) == false)
    #expect(harness.saved.isEmpty)
    #expect(coordinator.meetings.isEmpty)
    #expect(coordinator.isWorkInFlight == false)
  }

  @Test("deleting while recording stops the recorder and removes everything")
  func deleteWhileRecording() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let record = try onlyMeeting(harness)
    await coordinator.delete(meetingID: record.id)
    #expect(harness.recorders.first?.stopCalls == 1)
    #expect(coordinator.phase == .idle)
    #expect(harness.activitiesBegun == harness.activitiesEnded)
    await Self.eventually("gone") { coordinator.meetings.isEmpty }
    #expect(
      FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path) == false)
    #expect(harness.saved.isEmpty)
  }

  @Test("deleting while the files still close waits for the Stop before removing anything")
  func deleteWhileStopping() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let record = try onlyMeeting(harness)
    let closing = Gate()
    try #require(harness.recorders.first).stopGate = closing
    let stopping = Task { await coordinator.stop() }
    await Self.eventually("stopping") { closing.parked }
    let deletion = Task { await coordinator.delete(meetingID: record.id) }
    await Self.eventually("marked") { coordinator.record(id: record.id)?.deletionRequested == true }
    // The files are still closing: nothing is removed yet.
    #expect(harness.removedRows.isEmpty)
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path))
    closing.open()
    await stopping.value
    await deletion.value
    #expect(harness.removedRows == [record.transcriptID])
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path) == false)
    #expect(harness.jobs.isEmpty)
    #expect(harness.saved.isEmpty)
  }

  @Test("History's Delete All marks every meeting before returning, then removes them")
  func deleteAllMarksFirst() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }

    coordinator.deleteForHistoryDeleteAll(meetingIDs: [meetingID])
    // Synchronous: durable before History empties its own store.
    #expect(try harness.store.load(id: meetingID).deletionRequested)
    await Self.eventually("gone") { coordinator.meetings.isEmpty }
    #expect(
      FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path) == false)
  }

  @Test("deleting only the audio keeps the meeting and stops a queued one from processing")
  func deleteAudioOnly() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }

    await coordinator.deleteAudio(meetingID: meetingID)
    let record = try harness.store.load(id: meetingID)
    #expect(record.audioKept == false)
    #expect(record.state == .ready)
    #expect(try harness.store.segmentFiles(meeting: meetingID).isEmpty)
    // No audio, so Retry has nothing to run.
    await coordinator.retry(meetingID: meetingID)
    #expect(try harness.store.load(id: meetingID).state == .ready)
    #expect(harness.jobs.count == 1)
  }

  @Test("Delete audio during the pass's first save is refused: the pass owns the meeting from its start")
  func deleteAudioRefusedWhilePassClaims() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let gate = harness.writeGate
    gate.holdNext { $0.state == .processing }
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    // Stop ends by saving the notes, which queue behind the held save: it runs on its own.
    let stopping = Task { await coordinator.stop() }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    // The `.processing` save is held: the pass already owns the meeting (#3994).
    #expect(coordinator.processing?.meetingID == meetingID)
    await coordinator.deleteAudio(meetingID: meetingID)
    gate.release.signal()
    await stopping.value
    #expect(gate.timedOut.withLock { $0 } == false, "Delete audio waited behind the held save")
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let record = try harness.store.load(id: meetingID)
    #expect(record.audioKept)
    #expect(try !harness.store.segmentFiles(meeting: meetingID).isEmpty, "the pass's audio stays")
  }

  @Test("a queued meeting whose Delete audio is still saving is never picked up by the queue")
  func queueSkipsAudioBeingRemoved() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let gate = harness.writeGate
    // The disk fills during each recording: after each Stop the meeting stays queued and the
    // queue waits (a Start itself needs the space).
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    harness.freeBytes = 10
    await coordinator.stop()
    harness.freeBytes = 50_000_000_000
    await coordinator.start(from: .history)
    let otherID = try #require(coordinator.meetings.first { $0.id != meetingID }?.id)
    harness.freeBytes = 10
    await coordinator.stop()
    await Self.eventually("waits for space") {
      coordinator.queueWaitsForSpace && coordinator.record(id: otherID)?.state == .queued
    }
    gate.holdNext { $0.id == meetingID && !$0.audioKept }
    let removing = Task { await coordinator.deleteAudio(meetingID: meetingID) }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    // Space is back and Transcribe again on the other meeting restarts the queue while the
    // Delete audio save is held: the saved list still shows the first meeting queued.
    harness.freeBytes = 50_000_000_000
    await coordinator.retry(meetingID: otherID)
    gate.release.signal()
    await removing.value
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await Self.eventually("other ready") { coordinator.record(id: otherID)?.state == .ready }
    let record = try harness.store.load(id: meetingID)
    #expect(record.state == .failed)
    #expect(record.failureCode == "audio_deleted")
    let passWrites = harness.writeGate.written.withLock { $0 }
      .filter { $0.id == meetingID && $0.state == .processing }
    #expect(passWrites.isEmpty, "no pass ever started on the meeting whose audio was going")
  }

  @Test("a pass whose first save fails lets go of the meeting: it stays queued and can be deleted")
  func failedClaimSaveReleases() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    harness.writeGate.failWrites(inState: .processing)
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("queue stopped") {
      coordinator.processing == nil && !coordinator.hasFinalPassWork
    }
    #expect(coordinator.record(id: meetingID)?.state == .queued)
    #expect(harness.jobs.isEmpty, "no pass job was made")
    await coordinator.delete(meetingID: meetingID)
    #expect(!FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path))
  }

  @Test("deleting a meeting while its pass's first save is held waits for the claim, then removes it")
  func deleteDuringHeldClaim() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let gate = harness.writeGate
    gate.holdNext { $0.state == .processing }
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let stopping = Task { await coordinator.stop() }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    #expect(coordinator.playbackSource(meetingID: meetingID) != nil, "not yet being deleted")
    let deleting = Task { await coordinator.delete(meetingID: meetingID) }
    // The deletion has begun (it claims the meeting at once; its mark waits behind the held
    // save). Waited on directly: `eventually` would drain the file queue, which is held.
    await MeetingWorkAdmission.waitUntil { coordinator.playbackSource(meetingID: meetingID) == nil }
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path))
    gate.release.signal()
    await stopping.value
    await deleting.value
    #expect(harness.jobs.isEmpty, "no pass job for the meeting being deleted")
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    #expect(coordinator.processing == nil)
    #expect(!FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path))
  }

  @Test("a quit while the pass's first save is held lets go of the claim and starts no pass")
  func quitDuringHeldClaim() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let gate = harness.writeGate
    gate.holdNext { $0.state == .processing }
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let stopping = Task { await coordinator.stop() }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    coordinator.prepareForTermination(deadline: .now() + 0.5)
    gate.release.signal()
    await stopping.value
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await Self.eventually("claim released") { coordinator.processing == nil }
    #expect(harness.jobs.isEmpty, "no pass job after the quit")
    #expect(try !harness.store.segmentFiles(meeting: meetingID).isEmpty, "the audio stays for the relaunch")
  }

  @Test("Delete audio saves the decision before any file goes, and a launch finishes a cut-short removal")
  func deleteAudioIsDurableFirst() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(try !harness.store.segmentFiles(meeting: meetingID).isEmpty)

    // The record write is held: no file has been removed before the decision is on disk.
    harness.writeGate.arm()
    let removing = Task { await coordinator.deleteAudio(meetingID: meetingID) }
    let gate = harness.writeGate
    let entered = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: gate.entered.wait(timeout: .now() + 10))  // deadline-fallback: around the write signal
      }
    }
    #expect(entered == .success)
    #expect(try !harness.store.segmentFiles(meeting: meetingID).isEmpty, "files stay until then")
    gate.release.signal()
    await removing.value
    #expect(try harness.store.load(id: meetingID).audioKept == false)
    #expect(try harness.store.segmentFiles(meeting: meetingID).isEmpty)

    // An exit after the decision and before the files went: the next launch removes them.
    var cut = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(cut)
    try MeetingAudioFixture.writeSegment(
      in: harness.store.folder(for: cut.id), track: .microphone, index: 1, startMs: 0,
      frames: 16_000)
    cut.state = .ready
    cut.audioKept = false
    try harness.store.save(cut)
    #expect(try !harness.store.segmentFiles(meeting: cut.id).isEmpty)
    let relaunched = MeetingCoordinator(dependencies: harness.dependencies())
    relaunched.launch()
    await Self.eventually("listed") { relaunched.record(id: cut.id) != nil }
    // The files are not observable state: polled, with a deadline.
    var gone = false
    for _ in 0..<50 where !gone {
      gone = (try? harness.store.segmentFiles(meeting: cut.id).isEmpty) == true
      if !gone { try await Task.sleep(for: .milliseconds(100)) }  // deadline-fallback: disk is not observable
    }
    #expect(gone, "the launch removed the audio the record says is deleted")
    #expect(try harness.store.load(id: cut.id).audioKept == false)
  }

  // MARK: - Launch recovery

  @Test(
    "launch recovers interrupted and processing meetings, finishes deletions, leaves ready alone")
  func launchRecovery() async throws {
    let harness = try Harness()
    func make(_ state: MeetingState, deletion: Bool = false) throws -> MeetingRecord {
      var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      try harness.store.create(record)
      record.state = state
      record.deletionRequested = deletion
      try harness.store.save(record)
      // A crash leaves the in-progress file partial; recovery promotes it.
      try MeetingAudioFixture.writeSegment(
        in: harness.store.folder(for: record.id), index: 1, startMs: 0, frames: 8_000,
        partial: state == .recording)
      return record
    }
    let crashed = try make(.recording)
    let midPass = try make(.processing)
    let ready = try make(.ready)
    let deleted = try make(.ready, deletion: true)
    let readyBytes = try Data(contentsOf: harness.store.recordURL(for: ready.id))

    let coordinator = harness.coordinator
    coordinator.launch()
    coordinator.launch()
    await Self.eventually("both processed") {
      coordinator.record(id: crashed.id)?.state == .ready
        && coordinator.record(id: midPass.id)?.state == .ready
        && coordinator.record(id: deleted.id) == nil
    }
    #expect(harness.jobs.count == 2)
    #expect(harness.saved.count == 2)
    #expect(try harness.store.load(id: crashed.id).wasInterrupted == true)
    #expect(try harness.store.load(id: crashed.id).segments[.microphone]?.count == 1)
    #expect(try Data(contentsOf: harness.store.recordURL(for: ready.id)) == readyBytes)
    #expect(harness.removedRows == [deleted.transcriptID])
  }

  @Test("a meeting written by a newer build is listed but never recovered or rewritten")
  func newerFormatIsRefused() async throws {
    let harness = try Harness()
    let id = UUID()
    let folder = harness.store.folder(for: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let json = """
      {"formatVersion":99,"id":"\(id.uuidString)","createdAt":"2026-10-21T10:00:00.000Z",\
      "state":"recording","futureField":true}
      """
    try Data(json.utf8).write(to: harness.store.recordURL(for: id))
    try MeetingAudioFixture.writeSegment(
      in: folder, index: 1, startMs: 0, frames: 8_000, partial: true)
    let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

    let coordinator = harness.coordinator
    coordinator.launch()
    await Self.eventually("listed") { coordinator.newerFormatMeetings.map(\.id) == [id] }
    #expect(coordinator.meetings.isEmpty)
    #expect(try Data(contentsOf: harness.store.recordURL(for: id)) == Data(json.utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    #expect(harness.jobs.isEmpty)
  }

  @Test("damaged audio fails the meeting visibly instead of reading as silence")
  func unreadableAudioFails() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    let name = MeetingSegmentNaming.fileName(
      track: .microphone, index: 1, startMs: 0, partial: false)
    try Data(repeating: 7, count: 4_096).write(
      to: harness.store.folder(for: record.id).appendingPathComponent(name))

    let coordinator = harness.coordinator
    coordinator.launch()
    await Self.eventually("failed") { coordinator.record(id: record.id)?.state == .failed }
    #expect(try harness.store.load(id: record.id).failureCode == "audio_unreadable")
    #expect(harness.jobs.isEmpty)
    #expect(
      harness.logs.contains {
        $0.hasPrefix("meeting recovery problem") || $0.hasPrefix("meeting track problem")
      })
    // The damaged file is kept as evidence.
    #expect(
      FileManager.default.fileExists(
        atPath: harness.store.folder(for: record.id).appendingPathComponent(name).path))
  }

  // MARK: - Quit

  @Test("quit while recording stops capture with one deadline and saves interrupted")
  func quitWhileRecording() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let deadline = DispatchTime.now() + 1
    coordinator.prepareForTermination(deadline: deadline)

    #expect(harness.recorders.first?.quitDeadline == deadline)
    #expect(harness.activitiesBegun == harness.activitiesEnded)
    let record = try harness.store.load(id: meetingID)
    #expect(record.state == .interrupted)
    #expect(record.wasInterrupted == true)
    // Closed to new work.
    await coordinator.start(from: .history)
    #expect(harness.recorders.count == 1)
    #expect(harness.jobs.isEmpty)
  }

  @Test("quit while still starting reaches the recorder and never leaves it running")
  func quitDuringStart() async throws {
    let harness = try Harness()
    harness.recorderStart = .hold
    let coordinator = harness.coordinator
    let starting = Task { await coordinator.start(from: .history) }
    await Self.eventually("start parked") { harness.recorders.first?.startParked == true }
    coordinator.prepareForTermination(deadline: .now() + 1)
    await starting.value
    #expect(harness.recorders.first?.quitDeadline != nil)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    #expect(try harness.store.load(id: meetingID).state == .interrupted)
    #expect(harness.activitiesBegun == 0)
  }

  @Test("quit during a pass cancels it and leaves a ready meeting ready")
  func quitDuringPass() async throws {
    let harness = try Harness()
    let gate = Gate()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let first = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: first)?.state == .ready }

    harness.jobBehavior = { _ in
      await gate.wait()
      throw MeetingTranscriptionJob.JobError.cancelled
    }
    await coordinator.start(from: .history)
    await coordinator.stop()
    await Self.eventually("second pass parked") { gate.parked }
    coordinator.prepareForTermination()
    #expect(harness.jobs.last?.cancelled == true)
    gate.open()
    #expect(try harness.store.load(id: first).state == .ready)
    // The second stays processing on disk; the next launch queues it again.
    let second = try #require(harness.coordinator.meetings.first { $0.id != first }).id
    #expect(try harness.store.load(id: second).state == .processing)
  }

  @Test("quit while a Stop is still closing the files takes over, and the Stop writes nothing")
  func quitDuringStop() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let closing = Gate()
    try #require(harness.recorders.first).stopGate = closing
    let stopping = Task { await coordinator.stop() }
    await Self.eventually("stopping") { closing.parked }
    let deadline = DispatchTime.now() + 1
    coordinator.prepareForTermination(deadline: deadline)
    #expect(harness.recorders.first?.quitDeadline == deadline)
    #expect(try harness.store.load(id: meetingID).state == .interrupted)
    #expect(harness.activitiesBegun == harness.activitiesEnded)
    closing.open()
    await stopping.value
    #expect(try harness.store.load(id: meetingID).state == .interrupted)
    #expect(harness.jobs.isEmpty)
  }

  @Test("a damaged file between readable ones becomes a known gap, and stays on disk")
  func damagedFileBecomesGap() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    let folder = harness.store.folder(for: record.id)
    try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    let damagedName = MeetingSegmentNaming.fileName(
      track: .microphone, index: 2, startMs: 60_000, partial: false)
    try Data(repeating: 7, count: 4_096).write(to: folder.appendingPathComponent(damagedName))
    try MeetingAudioFixture.writeSegment(in: folder, index: 3, startMs: 90_000, frames: 16_000)

    let coordinator = harness.coordinator
    coordinator.launch()
    await Self.eventually("ready") { coordinator.record(id: record.id)?.state == .ready }
    #expect(
      harness.jobs.first?.receivedMissingAudio == [
        .microphone: [.init(startMs: 60_000, endMs: 90_000)]
      ])
    let saved = try harness.store.load(id: record.id)
    #expect(saved.failureCode == "audio_damaged")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(damagedName).path))
  }

  @Test("deleting during a slow History save waits for it; ready is never written")
  func deleteDuringDurableSave() async throws {
    let harness = try Harness()
    let saving = Gate()
    harness.saveGate = saving
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let record = try onlyMeeting(harness)
    await coordinator.stop()
    await Self.eventually("save in flight") { saving.parked }
    // The main actor is free during the write: this test body runs.
    #expect(coordinator.isWorkInFlight)
    let deletion = Task { await coordinator.delete(meetingID: record.id) }
    await Self.eventually("marked") { coordinator.record(id: record.id)?.deletionRequested == true }
    #expect(harness.removedRows.isEmpty)
    saving.open()
    await deletion.value
    #expect(harness.removedRows == [record.transcriptID])
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: record.id).path) == false)
  }

  @Test("the relaunch predicate counts recovery reads and checkpoint writes, not queued work")
  func relaunchPredicateCountsFileWork() async throws {
    let harness = try Harness()
    let recovery = DispatchSemaphore(value: 0)
    harness.recoveryHold = recovery
    let checkpoint = DispatchSemaphore(value: 0)
    harness.checkpointHold = checkpoint
    harness.jobBehavior = { access in
      try await #require(access).save(Self.checkpoint(try #require(access).meetingID))
      return Self.result()
    }
    let coordinator = harness.coordinator
    let busy = AppRelauncher.backgroundWork(
      isRecovering: { false }, isMinting: { false }, meetings: coordinator)
    #expect(busy() == false)
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    // Recovery is held on its worker thread. The claim (`processing`) comes before the read is
    // counted, so the wait is on the read itself (#4031).
    let recoverySignal = harness.recoveryEntered
    let recovering = await Task.detached { Self.waitBlocking(recoverySignal) }.value
    #expect(recovering == .success)
    #expect(busy())
    recovery.signal()
    // The checkpoint write is held next.
    let enteredSignal = harness.checkpointEntered
    let entered = await Task.detached { Self.waitBlocking(enteredSignal) }.value
    #expect(entered == .success)
    #expect(busy())
    checkpoint.signal()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(busy() == false)
  }

  @Test("an old Start's failure cleanup never ends a newer Start")
  func failedStartCleanupLeavesNewStart() async throws {
    let harness = try Harness()
    let recovery = DispatchSemaphore(value: 0)
    harness.recoveryHold = recovery
    harness.recorderStart = .fail
    let coordinator = harness.coordinator
    let first = Task { await coordinator.start(from: .history) }
    // The failed start's inspection is held; the current state already ended.
    await Self.eventually("first failed") {
      coordinator.notice == .microphoneUnavailable && coordinator.phase == .idle
    }
    harness.recorderStart = .hold
    let second = Task { await coordinator.start(from: .history) }
    await Self.eventually("second parked") { harness.recorders.last?.startParked == true }
    for _ in 0..<10 { recovery.signal() }
    await first.value
    #expect(coordinator.phase == .starting, "the newer Start is untouched")
    let firstID = try #require(harness.recorders.first).configuration.meetingID
    await Self.eventually("first processed") { coordinator.record(id: firstID)?.state == .ready }
    await coordinator.stop()
    await second.value
    #expect(harness.recorders.last?.stopCalls == 1)
  }

  @Test("a History save that fails after a deletion began keeps the deletion mark")
  func failedSaveKeepsDeletionMark() async throws {
    let harness = try Harness()
    let saving = Gate()
    harness.saveGate = saving
    harness.saveError = CocoaError(.fileWriteOutOfSpace)
    harness.removeError = CocoaError(.fileWriteNoPermission)
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let record = try onlyMeeting(harness)
    await coordinator.stop()
    await Self.eventually("save in flight") { saving.parked }
    let deletion = Task { await coordinator.delete(meetingID: record.id) }
    await Self.eventually("marked") { coordinator.record(id: record.id)?.deletionRequested == true }
    saving.open()
    await deletion.value
    await Self.drainMeetingFiles()
    // The row removal failed, so the folder stays, still marked for the next launch.
    let kept = try harness.store.load(id: record.id)
    #expect(kept.deletionRequested)
    #expect(kept.state != .failed)
  }

  @Test("a rename during a slow History save survives the ready write")
  func renameDuringSaveSurvives() async throws {
    let harness = try Harness()
    let saving = Gate()
    harness.saveGate = saving
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("save in flight") { saving.parked }
    await coordinator.rename(meetingID: meetingID, title: "Board sync")
    saving.open()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    let saved = try harness.store.load(id: meetingID)
    #expect(saved.title == "Board sync")
    #expect(saved.state == .ready)
  }

  @Test("#4012: a Start that low disk would refuse is known before a switch stops anything")
  func startWouldBeRefusedOnLowDisk() throws {
    let harness = try Harness()
    #expect(harness.coordinator.startWouldBeRefused() == false)
    harness.freeBytes = 1
    #expect(harness.coordinator.startWouldBeRefused())
  }

  @Test("#4012: a detected Start no longer wanted records nothing and leaves no meeting")
  func unwantedDetectedStartRecordsNothing() async throws {
    let harness = try Harness()
    harness.detectedWanted = false
    let coordinator = harness.coordinator
    let outcome = await coordinator.start(from: .detected, callApp: .zoom)
    #expect(outcome == .superseded(meetingID: nil))
    #expect(harness.recorders.isEmpty)
    #expect(coordinator.phase == .idle)
    #expect(try harness.store.loadAll().isEmpty)
    // A manual Start is never asked.
    #expect(await coordinator.start(from: .history) != .superseded(meetingID: nil))
  }

  @Test("#4012: a detected Start whose check finishes after a Stop and a newer Start leaves that recording")
  func lateCheckLeavesNewerRecording() async throws {
    let harness = try Harness()
    let gate = Gate()
    harness.detectedGate = gate
    harness.detectedWanted = false
    let coordinator = harness.coordinator
    let detected = Task { await coordinator.start(from: .detected, callApp: .zoom) }
    await Self.eventually("check parked") { gate.parked }
    await coordinator.stop()
    harness.detectedGate = nil
    #expect(await coordinator.start(from: .history) != .superseded(meetingID: nil))
    guard case .recording(let newer, _) = coordinator.phase else {
      Issue.record("the manual Start did not record")
      return
    }
    gate.open()
    #expect(await detected.value == .superseded(meetingID: nil))
    guard case .recording(let still, _) = coordinator.phase else {
      Issue.record("the newer recording was stopped")
      return
    }
    #expect(still == newer)
  }

  @Test("#4012: a detected Start withdrawn while capture started keeps no meeting")
  func withdrawnAfterCaptureKeepsNothing() async throws {
    let harness = try Harness()
    // Wanted after the calendar wait and the folder, withdrawn once capture began.
    harness.detectedAnswers = [true, true, false]
    let coordinator = harness.coordinator
    let outcome = await coordinator.start(from: .detected, callApp: .zoom)
    #expect(outcome == .superseded(meetingID: nil))
    #expect(coordinator.phase == .idle)
    await Self.eventually("removed") { (try? harness.store.loadAll().isEmpty) == true }
  }

  @Test("#4012: an AI title names an unnamed meeting and never replaces a name")
  func aiTitleNamesOnlyUnnamed() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    await coordinator.assignAITitle(meetingID: meetingID, title: "Launch plan")
    #expect(try harness.store.load(id: meetingID).title == "Launch plan")
    await coordinator.rename(meetingID: meetingID, title: "Board sync")
    await coordinator.assignAITitle(meetingID: meetingID, title: "Something else")
    #expect(try harness.store.load(id: meetingID).title == "Board sync")
  }

  @Test("a damaged last file has an unknown end; readable overlap is not called missing")
  func missingAudioBounds() async throws {
    let harness = try Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    let folder = harness.store.folder(for: record.id)
    func junk(_ index: Int, _ startMs: Int) throws {
      let name = MeetingSegmentNaming.fileName(
        track: .microphone, index: index, startMs: startMs, partial: false)
      try Data(repeating: 7, count: 4_096).write(to: folder.appendingPathComponent(name))
    }
    try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    // Readable 50 s to 70 s overlaps the damaged file that starts at 60 s.
    try MeetingAudioFixture.writeSegment(in: folder, index: 2, startMs: 50_000, frames: 320_000)
    try junk(3, 60_000)
    try MeetingAudioFixture.writeSegment(in: folder, index: 4, startMs: 90_000, frames: 16_000)
    try junk(5, 120_000)

    let coordinator = harness.coordinator
    coordinator.launch()
    await Self.eventually("ready") { coordinator.record(id: record.id)?.state == .ready }
    #expect(
      harness.jobs.first?.receivedMissingAudio == [
        .microphone: [.init(startMs: 70_000, endMs: 90_000), .init(startMs: 120_000, endMs: nil)]
      ])
  }

  @Test("a slow meeting write at a segment close leaves the main actor free")
  func segmentWriteOffMain() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let recorder = try #require(harness.recorders.first)
    harness.writeGate.arm()
    recorder.onSegment(
      .microphone, MeetingSegmentInfo(index: 1, fileName: "mic-00001-s000000000.caf", startMs: 0, frameCount: 16_000))
    let gate = harness.writeGate
    // From a worker thread: once the write is held, the main actor must still run a job within
    // 2 s; the write is released either way, so a blocked main actor fails instead of hanging.
    let mainRanWhileHeld = await Task.detached { Self.mainActorAnswers(whileHolding: gate) }.value
    #expect(mainRanWhileHeld)
    #expect(coordinator.isRecording)
    await Self.drainMeetingFiles()
    #expect(try harness.store.load(id: meetingID).segments[.microphone]?.count == 1)
    // The live copy updates when the write's answer reaches the main actor, which can be just
    // after the queue drained.
    await Self.eventually("published") {
      coordinator.record(id: meetingID)?.segments[.microphone]?.count == 1
    }
    await coordinator.stop()
  }

  @Test("ready is shown only once its write succeeded; a pending write blocks a relaunch")
  func readyWaitsForItsWrite() async throws {
    let harness = try Harness()
    let gate = harness.writeGate
    // The pass arms the gate as it ends, so the next write (the ready write) is held.
    harness.jobBehavior = { _ in
      gate.arm()
      return Self.result()
    }
    let coordinator = harness.coordinator
    let busy = AppRelauncher.backgroundWork(
      isRecovering: { false }, isMinting: { false }, meetings: coordinator)
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    #expect(coordinator.record(id: meetingID)?.state == .processing)
    #expect(busy())
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(try harness.store.load(id: meetingID).state == .ready)
  }

  @Test("failed writes, one after another, leave the shown meeting equal to the disk")
  func failedWritesMatchDisk() async throws {
    let harness = try Harness()
    let gate = harness.writeGate
    harness.jobBehavior = { access in
      try await #require(access).save(Self.checkpoint(try #require(access).meetingID))
      // The ready write fails, then the rename after it.
      gate.failNext(2)
      return Self.result()
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready write failed") {
      coordinator.notice == .storageFailed && coordinator.processing == nil
    }
    await coordinator.rename(meetingID: meetingID, title: "Lost")
    let disk = try harness.store.load(id: meetingID)
    #expect(coordinator.record(id: meetingID) == disk)
    #expect(disk.state == .processing)
    #expect(disk.title == nil)
    // Progress kept: the ready write never landed.
    #expect(FileManager.default.fileExists(atPath: harness.checkpointURL(meetingID).path))
    // The next change is built on what is durable, not on either failed copy.
    await coordinator.rename(meetingID: meetingID, title: "Kept")
    let after = try harness.store.load(id: meetingID)
    #expect(after.title == "Kept")
    #expect(after.state == .processing)
    #expect(coordinator.record(id: meetingID) == after)

    // No pass owns it any more (#4008): it needs attention and Transcribe again recovers it.
    #expect(
      MeetingsPresentation.status(after, processingID: coordinator.processing?.meetingID)
        == .needsAttention)
    #expect(coordinator.canTranscribeAgain(meetingID))
    #expect(harness.ended.isEmpty, "the stalled attempt has not ended")
    let resumed = CheckpointSeen()
    harness.jobBehavior = { access in
      resumed.meetingID = await access?.load()?.key.meetingID
      return Self.result()
    }
    #expect(await coordinator.retry(meetingID: meetingID))
    await Self.eventually("ready after Transcribe again") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(resumed.meetingID == meetingID, "the retained progress was loaded")
    #expect(!FileManager.default.fileExists(atPath: harness.checkpointURL(meetingID).path))
    #expect(harness.ended.count == 1, "one row for the attempt the stall interrupted")
    #expect(harness.ended.first?.entryPoint == .history, "its start facts are kept")
  }

  @MainActor
  final class CheckpointSeen {
    var meetingID: UUID?
  }

  /// A meeting whose end could not be saved: the inventory save (the second `.processing`
  /// write) fails, so the pass stops while the meeting is saved as processing.
  private func stalledByInventorySave(_ harness: Harness) async throws -> UUID {
    let writes = OSAllocatedUnfairLock(initialState: 0)
    harness.writeGate.failWrites { record in
      guard record.state == .processing else { return false }
      return writes.withLock {
        $0 += 1
        return $0 == 2
      }
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("stalled") {
      coordinator.notice == .storageFailed && coordinator.processing == nil
        && !coordinator.hasFinalPassWork
    }
    #expect(try harness.store.load(id: meetingID).state == .processing)
    #expect(harness.jobs.isEmpty, "the pass stopped before its job")
    return meetingID
  }

  @Test("a pass whose inventory save failed is recovered by Transcribe again")
  func inventorySaveStallRecovers() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let meetingID = try await stalledByInventorySave(harness)
    #expect(coordinator.canTranscribeAgain(meetingID))
    #expect(await coordinator.retry(meetingID: meetingID))
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(harness.ended.count == 1)
  }

  @Test("a Transcribe again whose save fails is refused and still offered; the next one runs")
  func failedRetrySaveStaysOffered() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let meetingID = try await stalledByInventorySave(harness)
    harness.writeGate.failNext(1)
    #expect(await coordinator.retry(meetingID: meetingID) == false)
    #expect(coordinator.record(id: meetingID)?.state == .processing)
    #expect(coordinator.canTranscribeAgain(meetingID), "the live copy rolled back: still offered")
    #expect(await coordinator.retry(meetingID: meetingID))
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(harness.ended.count == 1, "still one attempt")
    // An ended failure retried starts a new attempt (contrast): one more row.
    harness.jobBehavior = { _ in throw MeetingTranscriptionJob.JobError.engineUnavailable("test") }
    #expect(await coordinator.retry(meetingID: meetingID))
    await Self.eventually("failed") {
      coordinator.record(id: meetingID)?.state == .failed && coordinator.processing == nil
    }
    #expect(harness.ended.count == 2)
  }

  @Test("a meeting left queued by a failed first save is offered and recovered by Transcribe again")
  func queuedAfterFailedClaimRecovers() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let writes = OSAllocatedUnfairLock(initialState: 0)
    harness.writeGate.failWrites { record in
      guard record.state == .processing else { return false }
      return writes.withLock {
        $0 += 1
        return $0 == 1
      }
    }
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("queue ended without it") {
      coordinator.processing == nil && !coordinator.hasFinalPassWork
    }
    #expect(coordinator.record(id: meetingID)?.state == .queued)
    #expect(coordinator.queueWaitsForSpace == false)
    #expect(coordinator.canTranscribeAgain(meetingID), "no queue will take it: offered")
    #expect(await coordinator.retry(meetingID: meetingID))
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
  }

  @Test("a stalled meeting marked by Delete All is not offered and Transcribe again refuses it")
  func deleteAllMarkRefusesRetry() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let meetingID = try await stalledByInventorySave(harness)
    #expect(coordinator.deleteForHistoryDeleteAll(meetingIDs: [meetingID]))
    #expect(coordinator.canTranscribeAgain(meetingID) == false)
    #expect(await coordinator.retry(meetingID: meetingID) == false)
    await Self.eventually("deleted") { coordinator.record(id: meetingID) == nil }
    #expect(harness.jobs.isEmpty)
  }

  @Test("Delete audio during Transcribe again's save wins: no pass, no reopened attempt")
  func deleteAudioDuringRetrySave() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let meetingID = try await stalledByInventorySave(harness)
    let gate = harness.writeGate
    gate.holdNext { $0.id == meetingID && $0.state == .queued }
    let retrying = Task { await coordinator.retry(meetingID: meetingID) }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    let removing = Task { await coordinator.deleteAudio(meetingID: meetingID) }
    await MeetingWorkAdmission.waitUntil { !coordinator.canTranscribeAgain(meetingID) }
    gate.release.signal()
    #expect(await retrying.value == false)
    await removing.value
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    let record = try harness.store.load(id: meetingID)
    #expect(record.audioKept == false)
    #expect(record.state == .failed)
    #expect(harness.jobs.isEmpty)
  }

  @Test("Transcribe again during a running drain gets its turn in that drain")
  func retryDuringDrainRunsInThatDrain() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    // Two meetings wait for space; A is older, so the drain takes it first.
    await coordinator.start(from: .history)
    let first = try onlyMeeting(harness).id
    harness.freeBytes = 10
    await coordinator.stop()
    harness.freeBytes = 50_000_000_000
    await coordinator.start(from: .history)
    let second = try #require(coordinator.meetings.first { $0.id != first }?.id)
    harness.freeBytes = 10
    await coordinator.stop()
    await Self.eventually("both wait") {
      coordinator.queueWaitsForSpace && coordinator.record(id: second)?.state == .queued
    }
    // First pass: its ready write fails (stall). Second pass: parks. Third: runs normally.
    let parked = Gate()
    let runs = OSAllocatedUnfairLock(initialState: 0)
    let gate = harness.writeGate
    harness.jobBehavior = { _ in
      switch runs.withLock({ value -> Int in
        value += 1
        return value
      }) {
      case 1: gate.failNext(1)
      case 2: await parked.wait()
      default: break
      }
      return Self.result()
    }
    harness.freeBytes = 50_000_000_000
    #expect(await coordinator.retry(meetingID: first))
    await Self.eventually("second parked, first stalled") {
      parked.parked && coordinator.record(id: first)?.state == .processing
        && coordinator.processing?.meetingID == second
    }
    #expect(coordinator.canTranscribeAgain(first))
    #expect(await coordinator.retry(meetingID: first))
    parked.open()
    await Self.eventually("both ready") {
      coordinator.record(id: first)?.state == .ready
        && coordinator.record(id: second)?.state == .ready && !coordinator.hasFinalPassWork
    }
    #expect(runs.withLock { $0 } == 3)
  }

  @Test("Transcribe again during launch recovery waits for it and never runs a second pass")
  func retryWaitsForLaunchRecovery() async throws {
    let harness = try Harness()
    var crashed = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(crashed)
    try MeetingAudioFixture.writeSegment(
      in: harness.store.folder(for: crashed.id), track: .microphone, index: 1, startMs: 0,
      frames: 16_000)
    crashed.state = .processing
    try harness.store.save(crashed)
    let crashedID = crashed.id
    let gate = harness.writeGate
    gate.holdNext { $0.id == crashedID && $0.state == .queued }
    let coordinator = harness.coordinator
    coordinator.launch()
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    #expect(coordinator.canTranscribeAgain(crashed.id) == false, "not while launch recovery runs")
    let retrying = Task { await coordinator.retry(meetingID: crashed.id) }
    gate.release.signal()
    let accepted = await retrying.value
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await Self.eventually("ready") {
      coordinator.record(id: crashed.id)?.state == .ready && coordinator.processing == nil
    }
    #expect(accepted == false, "recovery had queued it already")
    #expect(harness.jobs.count == 1, "one pass")
  }

  @Test("held rename, audio removal and processing writes all block a relaunch")
  func pendingFileWorkBlocksRelaunch() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let busy = AppRelauncher.backgroundWork(
      isRecovering: { false }, isMinting: { false }, meetings: coordinator)
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let gate = harness.writeGate
    // The queued-state write of the Stop.
    gate.arm()
    let stopping = Task { await coordinator.stop() }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    #expect(busy())
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await stopping.value
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(busy() == false)
    // A rename write.
    gate.arm()
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Sync") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    #expect(busy())
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await renaming.value
    #expect(busy() == false)
    // An audio removal waits behind a held write.
    gate.arm()
    let renamingAgain = Task { await coordinator.rename(meetingID: meetingID, title: "Sync 2") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    let removing = Task { await coordinator.deleteAudio(meetingID: meetingID) }
    #expect(busy())
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await renamingAgain.value
    await removing.value
    #expect(busy() == false)
    #expect(try harness.store.load(id: meetingID).audioKept == false)
  }

  @Test("quit never waits past its deadline behind a stalled meeting write")
  func quitBoundedByDeadline() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let gate = harness.writeGate
    gate.arm()
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Stalled") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    let began = ContinuousClock.now
    coordinator.prepareForTermination(deadline: .now() + .milliseconds(200))
    #expect(ContinuousClock.now - began < .seconds(2))
    #expect(harness.activitiesBegun == harness.activitiesEnded)
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    await renaming.value
    await Self.drainMeetingFiles()
    // The interrupted write never started by the deadline, so it was withdrawn: the disk keeps
    // its last durable `recording`, which launch recovery turns into interrupted, then queued.
    #expect(try harness.store.load(id: meetingID).state == .recording)
    #expect(coordinator.record(id: meetingID)?.state == .recording)
  }

  @Test("an older write's late acknowledgement never replaces a newer durable state")
  func outOfOrderAcknowledgements() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let recorder = try #require(harness.recorders.first)
    let gate = harness.writeGate
    gate.arm()
    // Write A (a rename) is held on the worker.
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Older") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    // Released while quit runs on the main actor: A finishes first on disk, but its main-actor
    // acknowledgement can only run after quit's bounded write B answered.
    recorder.onStopForQuit = { gate.release.signal() }
    coordinator.prepareForTermination(deadline: .now() + 5)
    #expect(gate.timedOut.withLock { $0 } == false)
    #expect(coordinator.record(id: meetingID)?.state == .interrupted)
    // Before A's acknowledgement runs: a new change is built on B, not on A.
    await coordinator.rename(meetingID: meetingID, title: "Third")
    #expect(try harness.store.load(id: meetingID).state == .interrupted)
    #expect(try harness.store.load(id: meetingID).title == "Third")
    await renaming.value
    await Self.drainMeetingFiles()
    #expect(coordinator.record(id: meetingID)?.state == .interrupted)
    #expect(try harness.store.load(id: meetingID).state == .interrupted)
    #expect(try harness.store.load(id: meetingID).title == "Third")
    #expect(coordinator.record(id: meetingID)?.title == "Third")
  }

  @Test("a bounded deletion mark that succeeds first survives an edit made before the older write answers")
  func boundedMarkSurvivesEdit() async throws {
    let harness = try Harness()
    harness.removeError = CocoaError(.fileWriteNoPermission)
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let gate = harness.writeGate
    gate.arm()
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Older") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    // A is released now. The test does not yield until after Delete All and the next edit have
    // started, so A's main-actor acknowledgement cannot run before them, whenever A lands.
    gate.release.signal()
    #expect(coordinator.deleteForHistoryDeleteAll(meetingIDs: [meetingID]))
    await coordinator.rename(meetingID: meetingID, title: "Edited")
    await renaming.value
    await Self.drainMeetingFiles()
    let edits = gate.written.withLock { $0 }.filter { $0.title == "Edited" }
    #expect(edits.isEmpty == false)
    #expect(edits.allSatisfy { $0.deletionRequested }, "the edit kept the mark")
  }

  @Test("a bounded write that never started is withdrawn: disk, shown state and the next change agree")
  func withdrawnBoundedWrite() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let gate = harness.writeGate
    gate.arm()
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Before") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    // The mark queues behind the held rename and cannot start within its second.
    #expect(coordinator.deleteForHistoryDeleteAll(meetingIDs: [meetingID]) == false)
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false)
    await renaming.value
    await Self.drainMeetingFiles()
    #expect(try harness.store.load(id: meetingID).deletionRequested == false)
    #expect(coordinator.record(id: meetingID)?.deletionRequested == false)
    // The earlier rename landed after the withdrawal: the next change keeps it.
    await coordinator.deleteAudio(meetingID: meetingID)
    let disk = try harness.store.load(id: meetingID)
    #expect(disk.title == "Before")
    #expect(disk.audioKept == false)
    #expect(disk.deletionRequested == false)
    #expect(coordinator.record(id: meetingID) == disk)
  }

  @Test("a withdrawn newer write, then a failed earlier one: the change built next keeps neither")
  func withdrawnThenEarlierFailure() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let gate = harness.writeGate
    gate.failWrites { $0.title == "Before" }
    gate.arm()
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Before") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    #expect(coordinator.deleteForHistoryDeleteAll(meetingIDs: [meetingID]) == false)
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false)
    await renaming.value
    await coordinator.deleteAudio(meetingID: meetingID)
    let disk = try harness.store.load(id: meetingID)
    #expect(disk.title == nil)
    #expect(disk.audioKept == false)
    #expect(disk.deletionRequested == false)
    #expect(coordinator.record(id: meetingID) == disk)
  }

  @Test("a failed newer write, then a failed earlier one: the change built next keeps neither")
  func failedNewerThenFailedEarlier() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let recorder = try #require(harness.recorders.first)
    let gate = harness.writeGate
    gate.failWrites(inState: .interrupted)
    gate.failWrites { $0.title == "Before" }
    gate.arm()
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Before") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    recorder.onStopForQuit = { gate.release.signal() }
    coordinator.prepareForTermination(deadline: .now() + 5)
    #expect(gate.timedOut.withLock { $0 } == false)
    await renaming.value
    await coordinator.deleteAudio(meetingID: meetingID)
    let disk = try harness.store.load(id: meetingID)
    #expect(disk.title == nil)
    #expect(disk.state == .recording)
    #expect(disk.audioKept == false)
    #expect(coordinator.record(id: meetingID) == disk)
  }

  @Test("a newer write that fails keeps an earlier change still on its way")
  func failedNewerWriteKeepsEarlierChange() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let recorder = try #require(harness.recorders.first)
    let gate = harness.writeGate
    gate.failWrites(inState: .interrupted)
    gate.arm()
    // Write A (a rename) is held; quit releases it from inside, so A lands on disk but its
    // acknowledgement can only run after quit's write B (built on A) has failed.
    let renaming = Task { await coordinator.rename(meetingID: meetingID, title: "Before") }
    #expect(await Task.detached { Self.waitBlocking(gate.entered) }.value == .success)
    recorder.onStopForQuit = { gate.release.signal() }
    coordinator.prepareForTermination(deadline: .now() + 5)
    #expect(gate.timedOut.withLock { $0 } == false)
    #expect(coordinator.notice == .storageFailed)
    await renaming.value
    // The next change is built on A, not on the copy from before A.
    await coordinator.deleteAudio(meetingID: meetingID)
    let disk = try harness.store.load(id: meetingID)
    #expect(disk.title == "Before")
    #expect(disk.audioKept == false)
    #expect(disk.state == .recording)
    #expect(coordinator.record(id: meetingID) == disk)
  }

  @Test("a bounded write still running at its deadline reports once: a late success is shown and acted on")
  func lateBoundedSuccess() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let gate = harness.writeGate
    // The mark itself is held past Delete All's second.
    gate.arm()
    let refused = Task.detached { () -> Bool in
      _ = Self.waitBlocking(gate.entered)
      return true
    }
    #expect(coordinator.deleteForHistoryDeleteAll(meetingIDs: [meetingID]) == false)
    #expect(await refused.value)
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false)
    // Marked after all: shown, then deleted like any marked meeting.
    await Self.eventually("deleted") { coordinator.record(id: meetingID) == nil }
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: meetingID).path) == false)
  }

  @Test("a bounded write still running at its deadline that then fails rolls back to the disk")
  func lateBoundedFailure() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try onlyMeeting(harness).id
    let gate = harness.writeGate
    gate.arm()
    gate.failNext(1)
    // Quit's interrupted write starts, is held past its deadline, then fails.
    coordinator.prepareForTermination(deadline: .now() + .milliseconds(200))
    #expect(coordinator.record(id: meetingID)?.state == .recording)
    gate.release.signal()
    #expect(gate.timedOut.withLock { $0 } == false)
    await Self.eventually("failure reported") { coordinator.notice == .storageFailed }
    #expect(coordinator.record(id: meetingID)?.state == .recording)
    #expect(try harness.store.load(id: meetingID).state == .recording)
  }

  // MARK: - Work facts

  @Test("model work and in-flight work follow the pass, and each change is announced")
  func workFacts() async throws {
    let harness = try Harness()
    let gate = Gate()
    var job: FakeJob?
    harness.jobBehavior = { _ in
      job = harness.jobs.last
      job?.isEngineResident = true
      job?.isUnitInFlight = true
      await gate.wait()
      job?.isEngineResident = false
      job?.isUnitInFlight = false
      return Self.result()
    }
    let coordinator = harness.coordinator
    #expect(coordinator.isWorkInFlight == false)
    await coordinator.start(from: .history)
    #expect(coordinator.isCapturing)
    #expect(coordinator.isWorkInFlight)
    let meetingID = try onlyMeeting(harness).id
    await coordinator.stop()
    await Self.eventually("unit running") { gate.parked }
    #expect(coordinator.isMeetingModelWorkActive)
    #expect(coordinator.isWorkInFlight)
    let changesBefore = harness.workChanges
    gate.open()
    await Self.eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(coordinator.isMeetingModelWorkActive == false)
    #expect(coordinator.isWorkInFlight == false)
    #expect(harness.workChanges > changesBefore)
  }

  @Test("a queued meeting alone does not block a relaunch")
  func queuedDoesNotBlockRelaunch() async throws {
    let harness = try Harness()
    harness.freeBytes = 50_000_000_000
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    // Low disk keeps it queued.
    harness.freeBytes = 10
    let coordinator = harness.coordinator
    coordinator.launch()
    await Self.eventually("listed") { coordinator.record(id: record.id) != nil }
    #expect(coordinator.record(id: record.id)?.state == .queued)
    #expect(coordinator.isWorkInFlight == false)
    #expect(coordinator.notice == .lowDisk)
  }

  @Test("a queue stopped by a full disk resumes from Transcribe again once space is free")
  func lowDiskResume() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    // The disk fills during the recording: after Stop the meeting is queued and waits.
    harness.freeBytes = 10
    await coordinator.stop()
    await Self.eventually("waits for space") { coordinator.queueWaitsForSpace }
    let queued = try #require(coordinator.record(id: meetingID))
    #expect(queued.state == .queued)
    #expect(coordinator.canTranscribeAgain(meetingID), "the detail offers Transcribe again")

    // Still full: Transcribe again checks the disk again and keeps waiting, writing nothing.
    let writesBefore = harness.writeGate.written.withLock { $0.count }
    #expect(await coordinator.retry(meetingID: meetingID))
    #expect(harness.writeGate.written.withLock { $0.count } == writesBefore, "no record write")
    await Self.eventually("checked again") { coordinator.queueWaitsForSpace }
    #expect(coordinator.record(id: meetingID)?.state == .queued)

    harness.freeBytes = 50_000_000_000
    await coordinator.retry(meetingID: meetingID)
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    #expect(coordinator.queueWaitsForSpace == false)
  }

  @Test("a History row whose meeting is gone is deleted alone; a folder still on disk is kept")
  func orphanRowDeletion() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    var other = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(other)
    other.state = .ready
    try harness.store.save(other)
    coordinator.launch()
    await Self.eventually("listed") { coordinator.record(id: other.id) != nil }

    let orphan = UUID()
    let orphanRow = UUID()
    harness.meetingRows[orphan] = [orphanRow]
    harness.meetingRows[other.id] = [other.transcriptID]
    await coordinator.delete(meetingID: orphan)
    #expect(harness.removedRows == [orphanRow], "only the orphan's own row")
    #expect(coordinator.record(id: other.id) != nil, "the other meeting is untouched")

    // A folder that is still there (unreadable, no record) is never removed from History.
    let kept = UUID()
    harness.meetingRows[kept] = [UUID()]
    try FileManager.default.createDirectory(
      at: harness.store.folder(for: kept), withIntermediateDirectories: true)
    #expect(await coordinator.deleteOrphan(meetingID: kept) == false)
    #expect(harness.removedRows == [orphanRow])
    #expect(FileManager.default.fileExists(atPath: harness.store.folder(for: kept).path))

    // A folder whose parent cannot be read is not "absent": refused, the row stays.
    let hidden = UUID()
    harness.meetingRows[hidden] = [UUID()]
    let locked = harness.root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(
      at: locked.appendingPathComponent(hidden.uuidString), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
    #expect(
      MeetingCoordinator.confirmedAbsent(locked.appendingPathComponent(hidden.uuidString)) == false,
      "an unreadable path is never confirmed absent")
    #expect(
      MeetingCoordinator.confirmedAbsent(harness.root.appendingPathComponent("nothing-here")))
    #expect(harness.removedRows == [orphanRow])
  }
}
