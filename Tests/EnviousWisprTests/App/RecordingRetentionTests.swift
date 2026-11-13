import EnviousWisprAppKitTestSupport
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #3147 PR1 retention and usage: when these fail, a recording is deleted the user never agreed
/// to lose (defaults, kept recordings, a policy changed meanwhile, a shorter period not yet
/// confirmed), a recording that should go stays forever, History says the wrong keep period, or
/// Settings shows a wrong or falsely complete storage size. Real archive, real History rows,
/// real meeting folders; only the clock, the threshold size and the meeting owner stand in.
@MainActor
@Suite("Recording retention and storage use", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct RecordingRetentionTests {
  /// The meeting owner as retention sees it: candidates, and a removal that answers as told.
  final class FakeMeetings: MeetingAudioRetaining {
    var candidates: [MeetingCoordinator.AudioRetentionCandidate] = []
    var removalSucceeds = true
    private(set) var removed: [UUID] = []
    private(set) var asked: [UUID] = []

    func audioRetentionCandidates() async -> [MeetingCoordinator.AudioRetentionCandidate] {
      candidates
    }

    func removeAudioForRetention(
      meetingID: UUID, stillEligible: @MainActor (Date) -> Bool
    ) async -> MeetingCoordinator.AudioRetentionOutcome {
      asked.append(meetingID)
      guard let candidate = candidates.first(where: { $0.meetingID == meetingID }),
        stillEligible(candidate.endedAt)
      else { return .skipped }
      guard removalSucceeds else { return .failed }
      removed.append(meetingID)
      candidates.removeAll { $0.meetingID == meetingID }
      return .removed
    }
  }

  final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
  }

  /// Runs inside retention's saved-date read, after its first usage measurement: tests free
  /// space or hold a count there.
  final class Hooks {
    var savedDatesWillAnswer: (@MainActor () async -> Void)?
  }

  /// Holds one caller until released; `arrived` (observable, for `eventually`) says it waits.
  @MainActor @Observable final class Gate {
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?
    private(set) var arrived = false

    func wait() async {
      arrived = true
      await withCheckedContinuation { continuation = $0 }
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }

  @MainActor struct Rig {
    let root: URL
    let store: TranscriptStore
    let archive: RecordingArchive
    let coordinator: TranscriptCoordinator
    let settings: SettingsManager
    let meetings: FakeMeetings
    let meetingStore: MeetingStore
    let usage: RecordingUsage
    let clock: Clock
    let hooks: Hooks
    let retention: RecordingRetention
    var recordings: DictationRecordings { coordinator.recordings! }
  }

  /// The threshold sizes the tests use: 1, 2 and 5 KB instead of gigabytes.
  static let smallThresholds: @Sendable (RecordingStorageWarningThreshold) -> Int64? = {
    $0.bytes.map { $0 / 1_000_000 }
  }

  /// A wait that never completes normally: it throws, so the six-hour timer and the usage pause
  /// end without ever asking for a pass. Tests ask for each pass by hand.
  static let neverFires: @Sendable (Duration) async throws -> Void = { _ in
    throw CancellationError()
  }

  private func rig() -> Rig {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("RecordingRetentionTests-\(UUID().uuidString)", isDirectory: true)
    let store = TranscriptStore(directory: root.appendingPathComponent("transcripts"))
    let archive = RecordingArchive(directory: root.appendingPathComponent("dictations"))
    let coordinator = TranscriptCoordinator(store: store, recordingArchive: archive)
    let name = "ew.recordingRetentionTest." + UUID().uuidString
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    let meetings = FakeMeetings()
    let meetingStore = MeetingStore(root: root.appendingPathComponent("meetings"))
    let usage = RecordingUsage(archive: archive, meetingStore: meetingStore)
    let clock = Clock()
    let hooks = Hooks()
    var deps = RecordingRetention.Dependencies(
      settings: settings, recordings: coordinator.recordings!, archive: archive,
      savedDates: { ids in
        await hooks.savedDatesWillAnswer?()
        return await store.savedDates(of: ids)
      },
      meetings: { meetings }, usage: usage)
    deps.now = { clock.now }
    deps.sleep = Self.neverFires
    deps.thresholdBytes = Self.smallThresholds
    deps.log = { _ in }
    return Rig(
      root: root, store: store, archive: archive, coordinator: coordinator, settings: settings,
      meetings: meetings, meetingStore: meetingStore, usage: usage, clock: clock, hooks: hooks,
      retention: RecordingRetention(deps))
  }

  /// A saved dictation `ageDays` old with a recording of `bytes` bytes.
  @discardableResult
  private func recordedRow(_ rig: Rig, ageDays: Double, bytes: Int = 100) async throws -> UUID {
    let row = Transcript(
      text: "row", createdAt: rig.clock.now.addingTimeInterval(-ageDays * 86_400))
    try rig.store.save(row)
    let file = try await rig.archive.partialURL(for: row.id)
    #expect(FileManager.default.createFile(atPath: file.path, contents: Data(count: bytes)))
    try await rig.archive.store(rowID: row.id, fileURL: file, timing: nil)
    return row.id
  }

  private func sweep(_ rig: Rig) async {
    rig.retention.start()
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
  }

  private func hasRecording(_ rig: Rig, _ id: UUID) async -> Bool {
    await rig.archive.url(for: id) != nil
  }

  private func lock(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
  }

  private func unlock(_ folder: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
  }

  // MARK: - Usage

  @Test("usage counts dictation and meeting audio, finals and partials, and nothing else")
  func usageByteDefinition() async throws {
    let rig = rig()
    try await recordedRow(rig, ageDays: 1, bytes: 300)
    let partial = try await rig.archive.partialURL(for: UUID())
    #expect(FileManager.default.createFile(atPath: partial.path, contents: Data(count: 40)))
    let meetingID = UUID()
    let folder = rig.meetingStore.folder(for: meetingID)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func file(_ name: String, _ bytes: Int, in dir: URL? = nil) {
      #expect(
        FileManager.default.createFile(
          atPath: (dir ?? folder).appendingPathComponent(name).path, contents: Data(count: bytes)))
    }
    file(
      MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: false), 1_000
    )
    file(
      MeetingSegmentNaming.fileName(
        track: .microphone, variant: .cleaned, index: 1, startMs: 0, partial: false), 900)
    file(
      MeetingSegmentNaming.fileName(track: .callSound, index: 1, startMs: 0, partial: false), 800)
    file(
      MeetingSegmentNaming.fileName(track: .callSound, index: 2, startMs: 60_000, partial: true), 70
    )
    // Not audio: never counted.
    file("notes.md", 5_000)
    file(MeetingStore.recordFileName, 6_000)
    let work = rig.meetingStore.workDirectory(for: meetingID)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    file("x.caf", 7_000, in: work)

    let snapshot = await rig.usage.measure()

    #expect(snapshot.isComplete)
    #expect(snapshot.meetings == .measured(committedBytes: 2_700, temporaryBytes: 70))
    guard case .measured(let committed, let temporary) = snapshot.dictations else {
      Issue.record("dictations were not measured")
      return
    }
    #expect(temporary == 40, "an encode in progress is temporary")
    #expect(committed >= 300, "the audio plus the archive's small metadata files")
    #expect(committed < 1_000)
    #expect(snapshot.totalBytes == committed + temporary + 2_770)
    #expect(rig.usage.latest == snapshot)
  }

  @Test("missing folders measure as zero; an unreadable meeting folder makes usage incomplete")
  func usageMissingAndUnreadable() async throws {
    let rig = rig()
    let empty = await rig.usage.measure()
    #expect(empty.isComplete)
    #expect(empty.totalBytes == 0)

    let locked = rig.meetingStore.folder(for: UUID())
    try lock(locked)
    defer { unlock(locked) }
    let partial = await rig.usage.measure()
    #expect(!partial.isComplete, "an unreadable folder is never silently left out")
    #expect(partial.unmeasuredMeetingFolders == 1)
  }

  // MARK: - Defaults and expiry

  @Test("the defaults remove nothing, however old the recordings")
  func defaultsDeleteNothing() async throws {
    let rig = rig()
    let ancient = try await recordedRow(rig, ageDays: 4_000)
    rig.meetings.candidates = [
      .init(meetingID: UUID(), endedAt: rig.clock.now.addingTimeInterval(-4_000 * 86_400))
    ]

    await sweep(rig)

    #expect(await hasRecording(rig, ancient))
    #expect(rig.meetings.asked.isEmpty, "meetings kept until deleted are never asked about")
    #expect(rig.retention.warning == nil)
    #expect(rig.retention.lastSweep == RecordingRetention.SweepSummary())
  }

  @Test("a keep period removes recordings at its boundary, never kept ones, and records the period")
  func expiryBoundaryAndKeep() async throws {
    let rig = rig()
    rig.settings.dictationRecordingRetention = .day7
    let atBoundary = try await recordedRow(rig, ageDays: 7)
    let justInside = try await recordedRow(rig, ageDays: 7 - 1.0 / 86_400)
    let keptOld = try await recordedRow(rig, ageDays: 300)
    try await rig.recordings.pin(rowID: keptOld)

    await sweep(rig)

    #expect(!(await hasRecording(rig, atBoundary)), "seven days old: expired")
    #expect(await hasRecording(rig, justInside), "one second younger: kept")
    #expect(await hasRecording(rig, keptOld), "Keep this recording is never removed automatically")
    #expect(rig.retention.lastSweep?.expiredDictations == 1)
    #expect(
      await rig.recordings.status(for: atBoundary)
        == .absent(RecordedAbsence(.expired, expiredAfterDays: 7)))
    // A later setting change never rewrites what History says happened.
    rig.settings.dictationRecordingRetention = .day30
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
    #expect(
      try await rig.archive.recordedAbsence(for: atBoundary)
        == RecordedAbsence(.expired, expiredAfterDays: 7))
  }

  @Test("a removal rechecks the policy, the Keep mark and playback when its turn comes")
  func staleEligibilityIsRechecked() async throws {
    let rig = rig()
    let row = try await recordedRow(rig, ageDays: 10)

    #expect(
      await rig.recordings.removeAutomatically(
        rowID: row, as: .expired(days: 7), stillEligible: { false }) == .skipped,
      "the policy changed since the scan")
    try await rig.recordings.pin(rowID: row)
    #expect(
      await rig.recordings.removeAutomatically(
        rowID: row, as: .expired(days: 7), stillEligible: { true }) == .skipped,
      "kept since the scan")
    try await rig.recordings.unpin(rowID: row)
    let arbiter = PlaybackArbiter()
    rig.recordings.arbiter = arbiter
    let silent: MeetingPlaybackController.Reader = { _, loaded, _, count in
      (
        loaded ?? (DictationPlaybackTests.SilentAudio() as any PlaybackWindowAudio),
        [Float](repeating: 0, count: count * 16)
      )
    }
    let player = MeetingPlaybackController(
      media: .dictation(URL(filePath: "/dev/null")), durationMs: 5_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), read: silent,
      sourceID: .dictation(row), arbiter: arbiter)
    player.play()
    #expect(
      await rig.recordings.removeAutomatically(
        rowID: row, as: .expired(days: 7), stillEligible: { true }) == .skipped,
      "someone is listening to it")
    player.pause()
    #expect(
      await rig.recordings.removeAutomatically(
        rowID: row, as: .expired(days: 7), stillEligible: { true }) == .removed)
    #expect(
      await rig.recordings.removeAutomatically(
        rowID: row, as: .expired(days: 7), stillEligible: { true }) == .skipped, "already gone")
  }

  @Test("a row whose saved date cannot be read is never treated as old")
  func unreadableDateIsLeftAlone() async throws {
    let rig = rig()
    rig.settings.dictationRecordingRetention = .day1
    let row = try await recordedRow(rig, ageDays: 50)
    try Data("not a row".utf8).write(
      to: rig.root.appendingPathComponent("transcripts/\(row.uuidString).json"))

    await sweep(rig)

    #expect(await hasRecording(rig, row))
  }

  @Test("meeting audio expires through its owner only under a meeting keep period")
  func meetingExpiry() async throws {
    let rig = rig()
    let old = UUID()
    let recent = UUID()
    let refused = UUID()
    rig.meetings.candidates = [
      .init(meetingID: old, endedAt: rig.clock.now.addingTimeInterval(-31 * 86_400)),
      .init(meetingID: recent, endedAt: rig.clock.now.addingTimeInterval(-29 * 86_400)),
    ]
    rig.settings.meetingRecordingRetention = .day30
    await sweep(rig)
    #expect(rig.meetings.removed == [old])
    #expect(rig.retention.lastSweep?.expiredMeetings == 1)

    rig.meetings.candidates.append(
      .init(meetingID: refused, endedAt: rig.clock.now.addingTimeInterval(-40 * 86_400)))
    rig.meetings.removalSucceeds = false
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
    #expect(rig.meetings.removed == [old], "a failed removal is never counted as removed")
    #expect(rig.retention.lastSweep?.expiredMeetings == 0)
    #expect(rig.retention.lastSweep?.failed == 1)
  }

  // MARK: - Threshold

  @Test("past the threshold, Ask warns and removes nothing; no threshold never warns")
  func thresholdAskAndNone() async throws {
    let rig = rig()
    let rows = [
      try await recordedRow(rig, ageDays: 3, bytes: 800),
      try await recordedRow(rig, ageDays: 2, bytes: 800),
    ]
    rig.settings.recordingStorageWarningThreshold = .gb1  // 1,000 bytes here

    await sweep(rig)

    for row in rows { #expect(await hasRecording(rig, row)) }
    guard case .overThreshold(let total, let threshold) = rig.retention.warning else {
      Issue.record("expected over-threshold, got \(String(describing: rig.retention.warning))")
      return
    }
    #expect(threshold == 1_000)
    #expect(total >= 1_600)

    rig.settings.recordingStorageWarningThreshold = .none
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
    #expect(rig.retention.warning == nil)
  }

  @Test("automatic mode removes the oldest unkept dictations until under, never meeting audio")
  func thresholdRemovesOldestFirst() async throws {
    let rig = rig()
    let oldest = try await recordedRow(rig, ageDays: 9, bytes: 700)
    let keptOlder = try await recordedRow(rig, ageDays: 10, bytes: 700)
    try await rig.recordings.pin(rowID: keptOlder)
    let middle = try await recordedRow(rig, ageDays: 5, bytes: 700)
    let newest = try await recordedRow(rig, ageDays: 1, bytes: 700)
    rig.settings.recordingThresholdBehavior = .removeOldestDictations
    rig.settings.recordingStorageWarningThreshold = .gb2  // 2,000 bytes here

    await sweep(rig)

    #expect(!(await hasRecording(rig, oldest)))
    #expect(!(await hasRecording(rig, middle)))
    #expect(await hasRecording(rig, keptOlder), "kept, though oldest")
    #expect(await hasRecording(rig, newest), "under the threshold once two went")
    #expect(rig.retention.lastSweep?.removedForSpace == 2)
    #expect(rig.retention.warning == nil)
    #expect(await rig.recordings.status(for: oldest) == .absent(RecordedAbsence(.removedForSpace)))
    #expect(rig.meetings.asked.isEmpty)
  }

  @Test("automatic mode warns when kept or locked audio keeps usage above, and never spins")
  func thresholdUnreachable() async throws {
    let rig = rig()
    let kept = try await recordedRow(rig, ageDays: 9, bytes: 1_500)
    try await rig.recordings.pin(rowID: kept)
    let locked = try await recordedRow(rig, ageDays: 8, bytes: 600)
    let lockedFile = try #require(await rig.archive.url(for: locked))
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedFile.path)
    defer {
      try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedFile.path)
    }
    rig.settings.recordingThresholdBehavior = .removeOldestDictations
    rig.settings.recordingStorageWarningThreshold = .gb1

    await sweep(rig)

    #expect(await hasRecording(rig, kept))
    #expect(await hasRecording(rig, locked), "the removal failed; the audio is still there")
    #expect(rig.retention.lastSweep?.failed == 1, "tried once, not again and again")
    guard case .cannotReachThreshold = rig.retention.warning else {
      Issue.record(
        "expected cannotReachThreshold, got \(String(describing: rig.retention.warning))")
      return
    }
  }

  @Test("usage that cannot be fully measured never authorizes removal for space")
  func incompleteUsageRemovesNothing() async throws {
    let rig = rig()
    let row = try await recordedRow(rig, ageDays: 9, bytes: 1_500)
    let locked = rig.meetingStore.folder(for: UUID())
    try lock(locked)
    defer { unlock(locked) }
    rig.settings.recordingThresholdBehavior = .removeOldestDictations
    rig.settings.recordingStorageWarningThreshold = .gb1

    await sweep(rig)

    #expect(await hasRecording(rig, row))
    #expect(rig.retention.warning == .usageUnknown(thresholdBytes: 1_000))
  }

  // MARK: - Shortening: preview, Undo, commit

  @Test("a shorter keep period is previewed, applies nothing until committed, and Undo keeps all")
  func stagedShortening() async throws {
    let rig = rig()
    let old = [
      try await recordedRow(rig, ageDays: 20),
      try await recordedRow(rig, ageDays: 9),
    ]
    let recent = try await recordedRow(rig, ageDays: 2)
    rig.retention.start()
    await rig.retention.waitUntilIdle()

    let preview = await rig.retention.stage(.dictations(.day7))
    #expect(preview?.recordingsToRemove == 2)
    #expect(rig.settings.dictationRecordingRetention == .forever, "nothing written yet")
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
    for row in old {
      #expect(await hasRecording(rig, row), "a sweep meanwhile uses the old setting")
    }

    rig.retention.undoStaged()
    #expect(rig.retention.staged == nil)
    #expect(rig.settings.dictationRecordingRetention == .forever)

    await rig.retention.stage(.dictations(.day7))
    rig.retention.commitStaged()
    await rig.retention.waitUntilIdle()
    #expect(rig.settings.dictationRecordingRetention == .day7)
    for row in old { #expect(!(await hasRecording(rig, row))) }
    #expect(await hasRecording(rig, recent))
  }

  #if DEBUG
  @Test("a policy change or a Play during a removal's own reads keeps the recording")
  func finalChecksFollowTheLastSuspension() async throws {
    let rig = rig()
    rig.settings.dictationRecordingRetention = .day7
    let row = try await recordedRow(rig, ageDays: 10)
    rig.recordings.automaticRemovalWillDecideForTesting = {
      rig.settings.dictationRecordingRetention = .forever
    }
    await sweep(rig)
    #expect(await hasRecording(rig, row), "until I delete was chosen while the removal waited")
    #expect(rig.retention.lastSweep?.expiredDictations == 0)

    rig.settings.dictationRecordingRetention = .day7
    let arbiter = PlaybackArbiter()
    rig.recordings.arbiter = arbiter
    let silent: MeetingPlaybackController.Reader = { _, loaded, _, count in
      (
        loaded ?? (DictationPlaybackTests.SilentAudio() as any PlaybackWindowAudio),
        [Float](repeating: 0, count: count * 16)
      )
    }
    let player = MeetingPlaybackController(
      media: .dictation(URL(filePath: "/dev/null")), durationMs: 5_000,
      output: MeetingPlaybackControllerTests.FakeOutput(), read: silent,
      sourceID: .dictation(row), arbiter: arbiter)
    rig.recordings.automaticRemovalWillDecideForTesting = { player.play() }
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
    #expect(await hasRecording(rig, row), "Play started while the removal waited")
    #expect(player.state == .playing)
    player.stop()
  }
  #endif

  @Test("space freed between the scan and a removal, meeting audio included, saves the recording")
  func spaceFreedMeanwhileStopsTrimming() async throws {
    let rig = rig()
    let first = try await recordedRow(rig, ageDays: 9, bytes: 400)
    let second = try await recordedRow(rig, ageDays: 8, bytes: 400)
    let meetingID = UUID()
    let folder = rig.meetingStore.folder(for: meetingID)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let segment = folder.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: false))
    #expect(FileManager.default.createFile(atPath: segment.path, contents: Data(count: 400)))
    rig.settings.recordingThresholdBehavior = .removeOldestDictations
    rig.settings.recordingStorageWarningThreshold = .gb1  // 1,000 bytes; 1,200 used
    // The meeting's audio is deleted after the first measurement, before any removal.
    rig.hooks.savedDatesWillAnswer = {
      try? FileManager.default.removeItem(at: segment)
    }

    await sweep(rig)

    #expect(await hasRecording(rig, first), "no longer needed once the meeting audio went")
    #expect(await hasRecording(rig, second))
    #expect(rig.retention.lastSweep?.removedForSpace == 0)
    #expect(rig.retention.warning == nil)
  }

  @Test("a count that finishes after a newer choice or Undo is never committable")
  func stalePreviewIsDropped() async throws {
    let rig = rig()
    try await recordedRow(rig, ageDays: 20)
    let gate = Gate()
    rig.hooks.savedDatesWillAnswer = { await gate.wait() }

    let held = Task { await rig.retention.stage(.dictations(.day7)) }
    await MeetingCoordinatorTests.eventually("day7 count waiting") { gate.arrived }
    #expect(rig.retention.staged == nil, "no earlier preview stays committable meanwhile")
    let forever = await rig.retention.stage(.dictations(.forever))
    #expect(forever?.change == .dictations(.forever))
    gate.release()
    #expect(await held.value == nil, "the late day7 count is dropped")
    #expect(rig.retention.staged?.change == .dictations(.forever))

    let gate2 = Gate()
    rig.hooks.savedDatesWillAnswer = { await gate2.wait() }
    let heldAgain = Task { await rig.retention.stage(.dictations(.day7)) }
    await MeetingCoordinatorTests.eventually("second day7 count waiting") { gate2.arrived }
    rig.retention.undoStaged()
    gate2.release()
    #expect(await heldAgain.value == nil)
    #expect(rig.retention.staged == nil, "Undo stays undone")
    rig.retention.commitStaged()
    #expect(rig.settings.dictationRecordingRetention == .forever, "nothing to commit")
  }

  @Test("the page's preview request never brings back a preview it cancelled")
  func previewRequestCancellation() async throws {
    let rig = rig()
    try await recordedRow(rig, ageDays: 20)
    let request = RetentionPreviewRequest()

    // Cancelled before its count starts: the cancelled request is awaited before the check.
    request.choose(.dictations(.day7), on: rig.retention)
    let beforeEntry = request.cancel(on: rig.retention)
    #expect(beforeEntry != nil)
    await beforeEntry?.value
    #expect(rig.retention.staged == nil, "cancelled before entering the count")

    // Cancelled while counting: held at the gate, cancelled, released, then awaited.
    let gate = Gate()
    rig.hooks.savedDatesWillAnswer = { await gate.wait() }
    request.choose(.dictations(.day7), on: rig.retention)
    await MeetingCoordinatorTests.eventually("count waiting") { gate.arrived }
    let whileCounting = request.cancel(on: rig.retention)
    gate.release()
    await whileCounting?.value
    #expect(rig.retention.staged == nil, "cancelled while counting")

    // A longer choice applies at once; the superseded shorter request is awaited too.
    rig.hooks.savedDatesWillAnswer = nil
    request.choose(.dictations(.day7), on: rig.retention)
    let superseded = request.choose(.dictations(.forever), on: rig.retention)
    #expect(superseded != nil)
    await superseded?.value
    #expect(rig.retention.staged == nil)
    #expect(rig.settings.dictationRecordingRetention == .forever)
  }

  @Test("a stopped retention starts no pass")
  func stopEndsPasses() async throws {
    let rig = rig()
    rig.settings.dictationRecordingRetention = .day1
    let row = try await recordedRow(rig, ageDays: 5)
    rig.retention.start()
    rig.retention.stop()
    await rig.retention.waitUntilIdle()
    rig.retention.settingsChanged()
    await rig.retention.waitUntilIdle()
    #expect(await hasRecording(rig, row))
    #expect(rig.retention.lastSweep == nil)
  }
}
