import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #3972 R42, R43, R50, R52 (build chunks C9/C10): when these fail, the live words of a meeting
/// stop appearing, show a minute twice or out of order, keep a speech engine loaded for the
/// whole meeting, or run beside the after-recording transcript (slowing it and dictation).
@MainActor
@Suite("Meeting live words", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingLivePreviewTests {
  typealias Harness = MeetingCoordinatorTests.Harness
  typealias Gate = MeetingDocumentsOwnerTests.DebounceGate

  @MainActor
  @Observable
  final class FakePreview: MeetingPreviewing {
    private(set) var calls: [String] = []
    private(set) var releases = 0
    var isEngineResident = false
    var isUnitInFlight = false
    var onWaitingForDictation: (@MainActor (Bool) -> Void)?
    /// When set, every preview unit waits on it while decoding (physical work: a cancel does
    /// not stop it).
    @ObservationIgnored var hold: Gate?
    /// When true, the next preview waits for admission (like a dictation wait) until
    /// `admit()`; a cancel ends that wait and the preview throws `cancelled`.
    @ObservationIgnored var holdAdmission = false
    private(set) var waitingForAdmission = false
    @ObservationIgnored private var admission: CheckedContinuation<Bool, Never>?
    /// Shared order of events across the preview and the final pass.
    @ObservationIgnored var log: [String] = []

    func preview(audio: MeetingTrackAudio) async throws -> String? {
      let name = audio.segments.first?.url.lastPathComponent ?? "none"
      if holdAdmission {
        holdAdmission = false
        waitingForAdmission = true
        let admitted = await withCheckedContinuation { admission = $0 }
        waitingForAdmission = false
        guard admitted else {
          log.append("withdrawn \(name)")
          throw MeetingTranscriptionJob.JobError.cancelled
        }
      }
      guard audio.problems.isEmpty, !audio.isEmpty else { return nil }
      isUnitInFlight = true
      isEngineResident = true
      calls.append(name)
      log.append("preview \(name)")
      await hold?.wait()
      isUnitInFlight = false
      return "words of \(name)"
    }

    func admit() {
      admission?.resume(returning: true)
      admission = nil
    }

    /// When set, an unload waits on it (a held idle unload).
    @ObservationIgnored var unloadHold: Gate?

    func releaseIdle() async {
      guard isEngineResident, !isUnitInFlight else { return }
      await unloadHold?.wait()
      releases += 1
      log.append("release")
      isEngineResident = false
    }

    func cancel() {
      admission?.resume(returning: false)
      admission = nil
    }
  }

  struct Rig {
    let harness: Harness
    let coordinator: MeetingCoordinator
    let preview: FakePreview
    let idle: Gate
  }

  static func rig() throws -> Rig {
    let harness = try Harness()
    let preview = FakePreview()
    let idle = Gate()
    var deps = harness.dependencies()
    deps.makePreviewJob = { preview }
    deps.previewIdleWait = { [idle] in await idle.wait() }
    return Rig(
      harness: harness, coordinator: MeetingCoordinator(dependencies: deps), preview: preview,
      idle: idle)
  }

  /// Writes one closed capture file of `track` and tells the coordinator, as the writer does.
  static func closeFile(
    _ rig: Rig, meetingID: UUID, track: MeetingTrackKind, index: Int, startMs: Int
  ) throws -> String {
    let url = try MeetingAudioFixture.writeSegment(
      in: rig.harness.store.folder(for: meetingID), track: track, index: index, startMs: startMs,
      frames: 16_000)
    let recorder = try #require(rig.harness.recorders.last)
    recorder.onSegment(
      track,
      MeetingSegmentInfo(
        index: index, fileName: url.lastPathComponent, startMs: startMs, frameCount: 16_000))
    return url.lastPathComponent
  }

  @Test("each closed minute becomes one live line, in timeline order, labelled by track")
  func linesInOrder() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    let first = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    let call = try Self.closeFile(
      rig, meetingID: meetingID, track: .callSound, index: 1, startMs: 0)
    await MeetingCoordinatorTests.eventually("two lines") {
      rig.coordinator.liveTranscript?.lines.count == 2
    }
    let live = try #require(rig.coordinator.liveTranscript)
    #expect(live.lines.map(\.track) == [.callSound, .microphone], "ordered by meeting time")
    #expect(live.lines.map(\.text) == ["words of \(call)", "words of \(first)"])
    #expect(live.wordsUpToMs == 61_000)
    #expect(live.queued == 0)
    #expect(rig.preview.calls == [first, call], "each file decoded once, oldest queued first")
    await rig.coordinator.stop()
  }

  @Test("a backlog keeps the newest three files per track and says stretches were skipped")
  func backlogCap() async throws {
    let rig = try Self.rig()
    let hold = Gate()
    rig.preview.hold = hold
    defer {
      hold.open()
      rig.idle.open()
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    var names: [String] = []
    for index in 2...7 {
      names.append(
        try Self.closeFile(
          rig, meetingID: meetingID, track: .microphone, index: index, startMs: index * 60_000))
      await MeetingCoordinatorTests.eventually("queued \(index)") {
        rig.coordinator.record(id: meetingID)?.segments[.microphone]?.count == index - 1
      }
    }
    await MeetingCoordinatorTests.eventually("first unit running") { hold.waiting == 1 }
    #expect(rig.coordinator.liveTranscript?.queued == 3)
    #expect(rig.coordinator.liveTranscript?.skipped == 2)
    #expect(rig.coordinator.isWorkInFlight, "a running preview unit holds a relaunch")
    hold.open()
    await MeetingCoordinatorTests.eventually("drained") {
      rig.coordinator.liveTranscript?.queued == 0 && rig.preview.calls.count == 4
    }
    #expect(rig.preview.calls == [names[0], names[3], names[4], names[5]])
    let lines = MeetingsPresentation.liveStatusLines(
      try #require(rig.coordinator.liveTranscript), callSoundRecorded: false)
    #expect(lines.contains { $0.hasPrefix("Some stretches were skipped") })
    await rig.coordinator.stop()
  }

  @Test("the preview engine unloads after the idle wait, and a new minute cancels that wait")
  func idleUnload() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    _ = try Self.closeFile(rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("idle wait") { rig.idle.waiting == 1 }
    #expect(rig.preview.releases == 0)
    #expect(rig.coordinator.isMeetingModelWorkActive, "the loaded preview engine counts")

    // A new minute arrives during the idle wait: the wait ends without an unload.
    _ = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 3, startMs: 120_000)
    await MeetingCoordinatorTests.eventually("second line") {
      rig.coordinator.liveTranscript?.lines.count == 2
    }
    #expect(rig.preview.releases == 0)
    await MeetingCoordinatorTests.eventually("idle wait again") { rig.idle.waiting == 1 }
    rig.idle.open()
    await MeetingCoordinatorTests.eventually("unloaded") { rig.preview.releases == 1 }
    #expect(rig.coordinator.isMeetingModelWorkActive == false)
    await rig.coordinator.stop()
  }

  @Test("Stop drops queued minutes; the final pass waits for the running unit, then the unload")
  func finalPassFirst() async throws {
    let rig = try Self.rig()
    let hold = Gate()
    rig.preview.hold = hold
    defer {
      hold.open()
      rig.idle.open()
    }
    rig.harness.jobBehavior = { [preview = rig.preview] _ in
      preview.log.append("final pass")
      return MeetingCoordinatorTests.result()
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    let running = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("unit running") { hold.waiting == 1 }
    _ = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 3, startMs: 120_000)
    await MeetingCoordinatorTests.eventually("queued") {
      rig.coordinator.liveTranscript?.queued == 1
    }

    await rig.coordinator.stop()
    #expect(rig.coordinator.liveTranscript?.queued == 0, "Stop drops the queued minute")
    await MeetingCoordinatorTests.eventually("pass waiting for the unit") {
      rig.coordinator.processing?.meetingID == meetingID
    }
    #expect(rig.harness.jobs.isEmpty, "no final pass while a preview unit runs")
    hold.open()
    await MeetingCoordinatorTests.eventually("ready") {
      rig.coordinator.record(id: meetingID)?.state == .ready
    }
    #expect(rig.preview.log == ["preview \(running)", "release", "final pass"])
    // The pass ends after its ready write: the real transcript then replaces the live words.
    await MeetingCoordinatorTests.eventually("live words cleared") {
      rig.coordinator.liveTranscript == nil
    }
  }

  @Test("deleting the recording meeting drops its live words and queue")
  func deleteDropsLiveWords() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    _ = try Self.closeFile(rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("a line") {
      rig.coordinator.liveTranscript?.lines.count == 1
    }
    await rig.coordinator.delete(meetingID: meetingID)
    #expect(rig.coordinator.liveTranscript == nil)
  }

  @Test("live status lines say freshness and why the words lag, never a promised delay")
  func statusLines() {
    var live = MeetingCoordinator.LiveTranscript(meetingID: UUID())
    #expect(
      MeetingsPresentation.liveStatusLines(live, callSoundRecorded: false)
        == ["Live words, usually about a minute behind."])
    live.wordsUpToMs = 754_000
    live.queued = 2
    #expect(
      MeetingsPresentation.liveStatusLines(live, callSoundRecorded: true)
        == [
          "Live words, usually about a minute behind.", "Words up to 12:34.",
          "Catching up: 2 recorded stretches are waiting.",
          "Echo is hidden when the meeting ends.",
        ])
    live.waitingForDictation = true
    #expect(
      MeetingsPresentation.liveStatusLines(live, callSoundRecorded: false).contains(
        "Waiting for your dictation to finish."))
    #expect(
      !MeetingsPresentation.liveStatusLines(live, callSoundRecorded: false).contains(
        "Catching up: 2 recorded stretches are waiting."),
      "waiting for dictation is the reason shown, not the backlog")
    live.waitingForDictation = false
    live.queued = 1
    #expect(
      MeetingsPresentation.liveStatusLines(live, callSoundRecorded: false).contains(
        "Catching up: 1 recorded stretch is waiting."))
  }

  @Test("with both tracks waiting, previews alternate between them, oldest first in each")
  func roundRobin() async throws {
    let rig = try Self.rig()
    let hold = Gate()
    rig.preview.hold = hold
    defer {
      hold.open()
      rig.idle.open()
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    let m1 = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("first running") { hold.waiting == 1 }
    let m2 = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 3, startMs: 120_000)
    let m3 = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 4, startMs: 180_000)
    let c1 = try Self.closeFile(rig, meetingID: meetingID, track: .callSound, index: 1, startMs: 0)
    await MeetingCoordinatorTests.eventually("queued") {
      rig.coordinator.liveTranscript?.queued == 3
    }
    hold.open()
    await MeetingCoordinatorTests.eventually("drained") { rig.preview.calls.count == 4 }
    #expect(rig.preview.calls == [m1, c1, m2, m3], "the call track is not starved by the mic")
    await rig.coordinator.stop()
  }

  @Test("a missing file is skipped and never moves the freshness time")
  func unreadableSkipped() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    let recorder = try #require(rig.harness.recorders.last)
    recorder.onSegment(
      .microphone,
      MeetingSegmentInfo(
        index: 2, fileName: "mic-00002-s000060000.caf", startMs: 60_000, frameCount: 16_000))
    await MeetingCoordinatorTests.eventually("skipped") {
      rig.coordinator.liveTranscript?.skipped == 1
    }
    #expect(rig.coordinator.liveTranscript?.wordsUpToMs == nil)
    #expect(rig.coordinator.liveTranscript?.lines.isEmpty == true)
    await rig.coordinator.stop()
  }

  @Test("a preview still waiting for admission yields to a final pass, then runs after it")
  func waitingPreviewYields() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }
    rig.harness.jobBehavior = { [preview = rig.preview] _ in
      preview.log.append("final pass")
      return MeetingCoordinatorTests.result()
    }
    // An earlier meeting waits in the queue to be transcribed after this recording starts.
    var earlier = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try rig.harness.store.create(earlier)
    _ = try MeetingAudioFixture.writeSegment(
      in: rig.harness.store.folder(for: earlier.id), index: 1, startMs: 0, frames: 16_000)
    earlier.state = .failed
    try rig.harness.store.save(earlier)
    rig.coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      rig.coordinator.record(id: earlier.id) != nil
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(
      rig.coordinator.meetings.first { $0.id != earlier.id }?.id)
    rig.preview.holdAdmission = true
    let file = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("preview waiting") { rig.preview.waitingForAdmission }

    // Transcribe the earlier meeting again: its final pass comes first.
    await rig.coordinator.retry(meetingID: earlier.id)
    await MeetingCoordinatorTests.eventually("earlier ready") {
      rig.coordinator.record(id: earlier.id)?.state == .ready
    }
    await MeetingCoordinatorTests.eventually("previewed after") {
      rig.preview.calls == [file]
    }
    #expect(rig.preview.log == ["withdrawn \(file)", "final pass", "preview \(file)"])
    await rig.coordinator.stop()
  }

  @Test("deleting the recording meeting keeps its folder until a running decode finished")
  func deleteWaitsForDecode() async throws {
    let rig = try Self.rig()
    let hold = Gate()
    rig.preview.hold = hold
    defer {
      hold.open()
      rig.idle.open()
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    _ = try Self.closeFile(rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("decoding") { hold.waiting == 1 }
    let deletion = Task { await rig.coordinator.delete(meetingID: meetingID) }
    await MeetingCoordinatorTests.eventually("stopped") { rig.coordinator.phase == .idle }
    #expect(
      FileManager.default.fileExists(atPath: rig.harness.store.folder(for: meetingID).path),
      "the decode still reads the meeting's audio")
    hold.open()
    await deletion.value
    #expect(!FileManager.default.fileExists(atPath: rig.harness.store.folder(for: meetingID).path))
    #expect(rig.preview.releases == 1, "the cancelled preview job unloaded before the removal")
  }

  @Test("the production job: a preview offered while the idle unload runs is refused, not run")
  func productionUnloadExcludesPreview() async throws {
    let unloading = Gate()
    var transcribed = 0
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {},
        transcribe: { _ in
          transcribed += 1
          return ASRResult(
            text: "hello", language: nil, duration: 1, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: { await unloading.wait() },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = try MeetingAudioFixture.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000)
    let audio = MeetingTrackAudio(files: [(url: url, startMs: 0)])
    #expect(try await job.preview(audio: audio) == "hello")
    #expect(job.isEngineResident)

    let release = Task { await job.releaseIdle() }
    await MeetingWorkAdmission.waitUntil { unloading.waiting == 1 }
    await #expect(throws: MeetingTranscriptionJob.JobError.alreadyRunning) {
      _ = try await job.preview(audio: audio)
    }
    unloading.open()
    await release.value
    #expect(job.isEngineResident == false)
    #expect(transcribed == 1)
    // Unreadable audio is no words, never an empty success.
    let missing = MeetingTrackAudio(files: [
      (url: dir.appendingPathComponent("gone.caf"), startMs: 0)
    ])
    #expect(try await job.preview(audio: missing) == nil)
  }

  /// An earlier meeting queued for Transcribe again, ready to be retried while this test's
  /// meeting records.
  static func earlierMeeting(_ rig: Rig) async throws -> MeetingRecord {
    var earlier = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try rig.harness.store.create(earlier)
    _ = try MeetingAudioFixture.writeSegment(
      in: rig.harness.store.folder(for: earlier.id), index: 1, startMs: 0, frames: 16_000)
    earlier.state = .failed
    try rig.harness.store.save(earlier)
    rig.coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      rig.coordinator.record(id: earlier.id) != nil
    }
    return earlier
  }

  @Test("a preview queued behind a held idle unload still yields to a final pass that came after")
  func lanePriorityRechecked() async throws {
    let rig = try Self.rig()
    let unloading = Gate()
    rig.preview.unloadHold = unloading
    defer {
      unloading.open()
      rig.idle.open()
    }
    rig.harness.jobBehavior = { [preview = rig.preview] _ in
      preview.log.append("final pass")
      return MeetingCoordinatorTests.result()
    }
    let earlier = try await Self.earlierMeeting(rig)
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first { $0.id != earlier.id }?.id)
    let first = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("idle wait") { rig.idle.waiting == 1 }
    rig.idle.open()  // the idle unload starts and is held on the lane
    await MeetingCoordinatorTests.eventually("unload held") { unloading.waiting == 1 }
    let second = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 3, startMs: 120_000)
    await rig.coordinator.retry(meetingID: earlier.id)
    await MeetingCoordinatorTests.eventually("final pass waiting") {
      rig.coordinator.processing?.meetingID == earlier.id
    }
    unloading.open()
    await MeetingCoordinatorTests.eventually("earlier ready") {
      rig.coordinator.record(id: earlier.id)?.state == .ready
    }
    await MeetingCoordinatorTests.eventually("second previewed") {
      rig.preview.calls == [first, second]
    }
    let finalIndex = try #require(rig.preview.log.firstIndex(of: "final pass"))
    let secondIndex = try #require(rig.preview.log.firstIndex(of: "preview \(second)"))
    #expect(finalIndex < secondIndex, "the final pass came first: \(rig.preview.log)")
    await rig.coordinator.stop()
  }

  @Test("a preview a final pass called off goes back under the same newest-three limit")
  func requeueKeepsCap() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }
    let earlier = try await Self.earlierMeeting(rig)
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first { $0.id != earlier.id }?.id)
    rig.preview.holdAdmission = true
    let oldest = try Self.closeFile(
      rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("waiting") { rig.preview.waitingForAdmission }
    var newer: [String] = []
    for index in 3...5 {
      newer.append(
        try Self.closeFile(
          rig, meetingID: meetingID, track: .microphone, index: index, startMs: index * 60_000))
    }
    await MeetingCoordinatorTests.eventually("three queued") {
      rig.coordinator.liveTranscript?.queued == 3
    }
    await rig.coordinator.retry(meetingID: earlier.id)
    await MeetingCoordinatorTests.eventually("drained") { rig.preview.calls.count == 3 }
    #expect(
      rig.preview.calls == newer, "the called-off oldest file was dropped, not queued as a fourth")
    #expect(rig.coordinator.liveTranscript?.skipped == 1)
    #expect(!rig.preview.calls.contains(oldest))
    await rig.coordinator.stop()
  }

  @Test("deleting a meeting while its preview engine is idle unloads it at once")
  func deleteIdleUnloads() async throws {
    let rig = try Self.rig()
    defer { rig.idle.open() }  // the idle timer stays held through the deletion
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    _ = try Self.closeFile(rig, meetingID: meetingID, track: .microphone, index: 2, startMs: 60_000)
    await MeetingCoordinatorTests.eventually("idle wait") { rig.idle.waiting == 1 }
    #expect(rig.preview.isEngineResident)
    await rig.coordinator.delete(meetingID: meetingID)
    #expect(rig.preview.releases == 1)
    #expect(rig.preview.isEngineResident == false)
  }

  @Test("Save waits for the notes, and says so when they cannot be read")
  func exportReadsNotesFirst() async throws {
    let harness = try Harness()
    let rig = MeetingHistoryPresentationTests.Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)
    _ = try harness.store.saveNotes("Budget owner: Priya", revision: 1, meeting: record.id)
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    rig.infos[record.id] = MeetingHistoryInfo(echoTurnIDs: [], title: nil)
    try await rig.coordinator.saveAndShowDurably(row)
    let coordinator = MeetingDocumentsOwnerTests.coordinator(harness)

    // Notes not read yet, the read held: Save waits for it and carries the notes.
    let hold = MeetingDocumentsOwnerTests.holdFileQueue()
    let export = Task {
      await MeetingExport.document(
        meetingID: record.id, rowID: row.id, documents: coordinator.documents,
        transcripts: rig.coordinator)
    }
    hold.signal()
    guard case .document(let text) = await export.value else {
      Issue.record("Save wrote nothing")
      return
    }
    #expect(text.hasSuffix("Notes\n\nBudget owner: Priya\n"))

    // Unreadable notes: nothing is written, and Save says why.
    let other = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(other)
    try Data("not json".utf8).write(to: harness.store.documentsURL(for: other.id))
    #expect(
      await MeetingExport.document(
        meetingID: other.id, rowID: row.id, documents: coordinator.documents,
        transcripts: rig.coordinator) == .notesUnreadable)
  }
}
