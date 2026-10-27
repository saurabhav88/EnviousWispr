import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #3972 R11: when these fail, the founder's first-release adoption and quality query counts a
/// meeting twice, misses one, or reports the wrong outcome, entry point or gap count.
@MainActor
@Suite("Meeting ended telemetry", .tags(.observabilityContract), .timeLimit(.minutes(1)))
struct MeetingCoordinatorTelemetryTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  private func recordAndFinish(_ harness: Harness, from entry: MeetingEntryPoint = .history)
    async throws -> UUID
  {
    let coordinator = harness.coordinator
    await coordinator.start(from: entry)
    let meetingID = try #require(harness.recorders.last).configuration.meetingID
    await coordinator.stop()
    await eventually("ended") { harness.ended.count >= 1 && coordinator.processing == nil }
    return meetingID
  }

  @Test("a finished meeting sends one ready row with its start facts")
  func readyOnce() async throws {
    let harness = try Harness()
    _ = try await recordAndFinish(harness, from: .menu)
    let row = try #require(harness.ended.first)
    #expect(harness.ended.count == 1)
    #expect(row.outcome == .ready)
    #expect(row.entryPoint == .menu)
    #expect(row.diskStopped == false)
    #expect(row.gapCount == 0)
    #expect(row.speakerCount == 1)
    #expect(row.echoHiddenCount == 1)
    #expect(row.microphoneTrack == .captured)
    #expect(row.engine == .parakeet)
  }

  @Test("failed pieces and damaged audio count as gaps; the outcome is ready with gaps")
  func gapsCounted() async throws {
    let harness = try Harness()
    harness.jobBehavior = { _ in
      var result = MeetingCoordinatorTests.result()
      result = MeetingTranscriptionJob.Result(
        composition: result.composition, speakerOutcomes: result.speakerOutcomes, forcedCuts: 0,
        failedPieces: 2, failedRanges: [:], resumedPieces: 0, checkpointSaveFailures: 0,
        yieldCount: 3, processingSeconds: 1, audioSeconds: 1)
      return result
    }
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    try Self.writeTwoDamagedStretches(in: harness.store.folder(for: record.id))
    harness.coordinator.launch()
    await eventually("ended") { harness.ended.count == 1 }
    let row = try #require(harness.ended.first)
    // Found unfinished at launch: an attempt whose start facts are unknown.
    #expect(row.outcome == .readyWithGaps)
    #expect(row.gapCount == 4, "two failed pieces plus two damaged stretches on one track")
    #expect(row.yieldCount == 3)
    #expect(row.entryPoint == nil)
    #expect(row.diskStopped == nil)
  }

  /// One readable microphone file at 0:00, then two damaged ones on the same track: a bounded
  /// stretch from 1:00 to 2:00 and an unknown-end stretch from 2:00.
  static func writeTwoDamagedStretches(in folder: URL) throws {
    try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    for (index, startMs) in [(2, 60_000), (3, 120_000)] {
      let damaged = MeetingSegmentNaming.fileName(
        track: .microphone, index: index, startMs: startMs, partial: false)
      try Data(repeating: 7, count: 4_096).write(to: folder.appendingPathComponent(damaged))
    }
  }

  @Test("a failed pass counts every damaged stretch on a track as a gap")
  func failedGapsCounted() async throws {
    let harness = try Harness()
    harness.jobBehavior = { _ in
      throw MeetingTranscriptionJob.JobError.engineUnavailable("test")
    }
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    try Self.writeTwoDamagedStretches(in: harness.store.folder(for: record.id))
    harness.coordinator.launch()
    await eventually("ended") { harness.ended.count == 1 }
    #expect(harness.ended.map(\.outcome) == [.failed])
    #expect(harness.ended.first?.gapCount == 2)
  }

  @Test("deleting a meeting while its ready write lands ends it as ready, never deleted")
  func deletionDuringReadyWrite() async throws {
    let harness = try Harness()
    let save = MeetingCoordinatorTests.Gate()
    harness.saveGate = save
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop()
    await eventually("history save parked") { save.parked }
    let gate = harness.writeGate
    // The next meeting write is the ready write: held on the file queue.
    gate.arm()
    save.open()
    #expect(
      await Task.detached { MeetingCoordinatorTests.waitBlocking(gate.entered) }.value == .success)
    let deletion = Task { await coordinator.delete(meetingID: meetingID) }
    // The deletion's mark is queued behind the held ready write, ahead of the checkpoint clear.
    let queued = await Task.detached { Self.waitForQueued(coordinator, atLeast: 2) }.value
    gate.release.signal()
    await deletion.value
    #expect(queued, "the deletion's mark never queued")
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    #expect(harness.ended.map(\.outcome) == [.ready])
  }

  /// On a worker thread: whether `coordinator` has at least `count` meeting file operations
  /// queued within 5 s. It polls, because the count lives behind a lock Observation cannot see.
  nonisolated static func waitForQueued(_ coordinator: MeetingCoordinator, atLeast count: Int)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(5)
    while coordinator.queuedFileOperations < count {
      // deadline-fallback: ends a wait whose condition never came; the caller fails it.
      guard Date() < deadline else { return false }
      Thread.sleep(forTimeInterval: 0.001)
    }
    return true
  }

  @Test("an attempt interrupted by a quit ends once, after the relaunch, as interrupted_ready")
  func interruptedAfterRelaunch() async throws {
    let harness = try Harness()
    await harness.coordinator.start(from: .history)
    harness.coordinator.prepareForTermination()
    #expect(harness.ended.isEmpty)
    let relaunched = MeetingCoordinator(dependencies: harness.dependencies())
    relaunched.launch()
    await eventually("ended") { harness.ended.count == 1 }
    #expect(harness.ended.first?.outcome == .interruptedReady)
    #expect(harness.ended.first?.entryPoint == nil)
  }

  @Test("Start refusals each send start_failed with the real microphone status")
  func startRefusals() async throws {
    let harness = try Harness()
    harness.freeBytes = 10
    await harness.coordinator.start(from: .menu)
    harness.freeBytes = 50_000_000_000
    harness.settles = false
    await harness.coordinator.start(from: .history)
    #expect(harness.ended.map(\.outcome) == [.startFailed, .startFailed])
    #expect(harness.ended.map(\.entryPoint) == [.menu, .history])
    #expect(harness.ended.allSatisfy { $0.realTimeFactor == 0 })
  }

  @Test("a start that recorded nothing sends start_failed; one that kept audio sends only its end")
  func startupFailures() async throws {
    let empty = try Harness()
    empty.recorderStart = .failEmpty
    await empty.coordinator.start(from: .history)
    await eventually("empty ended") { empty.ended.count == 1 }
    #expect(empty.ended.first?.outcome == .startFailed)
    #expect(empty.ended.first?.microphoneTrack == .failed)

    let kept = try Harness()
    kept.recorderStart = .fail
    await kept.coordinator.start(from: .menu)
    await eventually("kept ended") { kept.ended.count == 1 && kept.coordinator.processing == nil }
    #expect(kept.ended.map(\.outcome) == [.interruptedReady])
    #expect(kept.ended.first?.entryPoint == .menu)
  }

  @Test(
    "deletion before ready sends deleted_before_ready once; deleting a finished meeting sends nothing"
  )
  func deletionOnce() async throws {
    let harness = try Harness()
    let gate = MeetingCoordinatorTests.Gate()
    harness.jobBehavior = { _ in
      await gate.wait()
      throw MeetingTranscriptionJob.JobError.cancelled
    }
    harness.removeError = CocoaError(.fileWriteNoPermission)
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop()
    await eventually("pass parked") { gate.parked }
    let deletion = Task { await coordinator.delete(meetingID: meetingID) }
    await eventually("cancelled") { harness.jobs.first?.cancelled == true }
    gate.open()
    await deletion.value
    // The row removal failed: the mark stays, and a repeat deletion runs again.
    await coordinator.delete(meetingID: meetingID)
    let relaunched = MeetingCoordinator(dependencies: harness.dependencies())
    relaunched.launch()
    await eventually("relaunch tried") { relaunched.record(id: meetingID) != nil }
    #expect(harness.ended.map(\.outcome) == [.deletedBeforeReady])

    let finished = try Harness()
    let finishedID = try await recordAndFinish(finished)
    await finished.coordinator.delete(meetingID: finishedID)
    #expect(finished.ended.map(\.outcome) == [.ready])
  }

  @Test("a failed commit sends failed; a Retry is a new attempt with the recording's facts")
  func failedThenRetry() async throws {
    let harness = try Harness()
    harness.saveError = CocoaError(.fileWriteOutOfSpace)
    let meetingID = try await recordAndFinish(harness, from: .menu)
    #expect(harness.ended.map(\.outcome) == [.failed])
    harness.saveError = nil
    await harness.coordinator.retry(meetingID: meetingID)
    await eventually("retry ended") {
      harness.ended.count == 2 && harness.coordinator.processing == nil
    }
    #expect(harness.ended.map(\.outcome) == [.failed, .ready])
    #expect(harness.ended.map(\.entryPoint) == [.menu, .menu])
  }

  /// #4121: what the fake recorder's stop reports for the call sound.
  private static let bluetooth = CallSoundSummary(
    outputTransport: "bluetooth", configuredRateHz: 24_000, rebuilds: 1, omittedReports: 0)

  @Test("#4121: the recorder's call-sound summary reaches meeting.ended; a Retry keeps it")
  func callSoundSummaryAdoptedAndRetried() async throws {
    let harness = try Harness()
    harness.saveError = CocoaError(.fileWriteOutOfSpace)
    await harness.coordinator.start(from: .menu)
    let recorder = try #require(harness.recorders.last)
    let meetingID = recorder.configuration.meetingID
    recorder.report.callSoundSummary = Self.bluetooth
    await harness.coordinator.stop()
    await eventually("ended") { harness.ended.count == 1 && harness.coordinator.processing == nil }
    harness.saveError = nil
    await harness.coordinator.retry(meetingID: meetingID)
    await eventually("retry ended") {
      harness.ended.count == 2 && harness.coordinator.processing == nil
    }
    #expect(harness.ended.map(\.outcome) == [.failed, .ready])
    #expect(harness.ended.map(\.callOutputTransport) == ["bluetooth", "bluetooth"])
    #expect(harness.ended.map(\.callCaptureRateHz) == [24_000, 24_000])
    #expect(harness.ended.map(\.callRebuilds) == [1, 1])
    #expect(harness.ended.map(\.callReportsOmitted) == [0, 0])
  }

  @Test("#4121: a quit keeps no row of its own; the attempt recovered after the relaunch has no call-sound facts")
  func callSoundSummaryNotInventedAfterRecovery() async throws {
    let harness = try Harness()
    await harness.coordinator.start(from: .history)
    try #require(harness.recorders.last).report.callSoundSummary = Self.bluetooth
    harness.coordinator.prepareForTermination()
    #expect(harness.ended.isEmpty)
    let relaunched = MeetingCoordinator(dependencies: harness.dependencies())
    relaunched.launch()
    await eventually("ended") { harness.ended.count == 1 }
    #expect(harness.ended.first?.outcome == .interruptedReady)
    #expect(harness.ended.first?.callOutputTransport == nil)
    #expect(harness.ended.first?.callCaptureRateHz == nil)
    #expect(harness.ended.first?.callRebuilds == nil)
    #expect(harness.ended.first?.callReportsOmitted == nil)
  }

  @Test("a later Start never changes an earlier attempt's entry point; low disk is its own fact")
  func frozenFacts() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .menu)
    let first = try #require(harness.recorders.first)
    // #4121: each recorder's stop reports its own call-sound summary.
    first.report.callSoundSummary = Self.bluetooth
    // The low-disk floor ends this recording at its next segment close; the low disk also
    // keeps it queued.
    harness.freeBytes = 10
    first.onSegment(
      .microphone,
      MeetingSegmentInfo(
        index: 1, fileName: "mic-00001-s000000000.caf", startMs: 0, frameCount: 16_000))
    await eventually("stopped") { coordinator.phase == .idle && coordinator.notice == .lowDisk }
    #expect(harness.ended.isEmpty)
    // A second meeting starts from the page while the first is still queued.
    harness.freeBytes = 50_000_000_000
    await coordinator.start(from: .history)
    #expect(coordinator.isRecording)
    #expect(harness.ended.isEmpty, "the first attempt is still queued while the second records")
    try #require(harness.recorders.last).report.callSoundSummary = CallSoundSummary(
      outputTransport: "usb", configuredRateHz: 44_100, rebuilds: 0, omittedReports: 2)
    await coordinator.stop()
    await eventually("both ended") { harness.ended.count == 2 && coordinator.processing == nil }
    // The queue takes the older meeting first.
    #expect(harness.ended.map(\.entryPoint) == [.menu, .history])
    #expect(harness.ended.map(\.diskStopped) == [true, false])
    #expect(harness.ended.map(\.callOutputTransport) == ["bluetooth", "usb"])
    #expect(harness.ended.map(\.callCaptureRateHz) == [24_000, 44_100])
    #expect(harness.ended.map(\.callRebuilds) == [1, 0])
    #expect(harness.ended.map(\.callReportsOmitted) == [0, 2])
  }
}
