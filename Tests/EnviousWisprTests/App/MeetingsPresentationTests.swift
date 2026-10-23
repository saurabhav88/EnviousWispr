import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #3972 §3.8 (C5): when these fail, the EnviousMeet page offers Start while a meeting is
/// starting, says "paused" when nothing waits, calls a failed call-sound capture a refusal, hides
/// an interrupted meeting among waiting ones, offers an action that cannot run, or shows zero
/// bytes for audio it could not measure.
@MainActor
@Suite("EnviousMeet page presentation", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingsPresentationTests {
  typealias P = MeetingsPresentation

  @Test("starting is never an enabled Start in the menu")
  func phases() {
    let id = UUID()
    let started = Date(timeIntervalSince1970: 0)
    #expect(P.control(.idle).action == .start)
    #expect(
      P.control(.starting)
        == .init(kind: .control, title: "Starting Meeting Recording", action: .none, isEnabled: false))
    #expect(P.control(.stopping(meetingID: id)).isEnabled == false)
    #expect(
      P.control(.recording(meetingID: id, startedAt: started))
        == .init(kind: .control, title: "Stop Meeting Recording", action: .stop, isEnabled: true))
  }

  @Test("the menu block: the recording's time, call sound and live words, then a stopped meeting's work")
  func menuBlock() {
    let id = UUID()
    let other = UUID()
    let started = Date(timeIntervalSince1970: 0)
    let recording = P.menuItems(
      .init(phase: .recording(meetingID: id, startedAt: started), callSound: .off),
      now: started.addingTimeInterval(3_725))
    #expect(recording.map(\.kind) == [.control, .elapsed, .callSound, .showLive])
    #expect(recording[1].title == "Recording for 1:02:05")
    #expect(recording[2].title == "Recording your microphone only")
    #expect(recording[3].action == .show(id))
    #expect(recording.filter { $0.action == .none }.allSatisfy { !$0.isEnabled })

    // No call-sound line before the recorder reports it; every failure reads the same.
    let noReport = P.menuItems(
      .init(phase: .recording(meetingID: id, startedAt: started)), now: started)
    #expect(noReport.map(\.kind) == [.control, .elapsed, .showLive])
    for status: MeetingTrackStatus in [.unsupported, .denied, .failed] {
      #expect(P.menuCallSoundLine(status) == "Call sound not recorded")
    }
    #expect(P.menuCallSoundLine(.captured) == "Recording the call sound")

    // A stopped meeting's pass shows beside a new recording, and opens that meeting.
    let both = P.menuItems(
      .init(
        phase: .recording(meetingID: id, startedAt: started),
        processing: .init(meetingID: other, stage: .findingSpeakers(track: .microphone))),
      now: started)
    #expect(both.suffix(2).map(\.kind) == [.processing, .showInHistory])
    #expect(both.last?.action == .show(other))
    #expect(both[both.count - 2].title == "Finding the speakers")

    // Idle with a pass: Start, then the pass. A wait names what it waits for, with no percent.
    let waiting = P.menuItems(
      .init(
        phase: .idle,
        processing: .init(
          meetingID: other, stage: .transcribing(track: .microphone, fraction: 0.5),
          waitingForDictation: true),
        waitingOnSummary: true),
      now: started)
    #expect(waiting.map(\.kind) == [.control, .processing, .showInHistory])
    #expect(waiting[1].title == "Paused while a meeting summary is written")
    #expect(P.menuItems(.init(phase: .idle), now: started).map(\.kind) == [.control])
  }

  @Test("elapsed time and meters stay sane at the edges")
  func clockAndMeters() {
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(P.elapsed(from: start, to: start) == "0:00")
    #expect(P.elapsed(from: start, to: start.addingTimeInterval(59.9)) == "0:59")
    #expect(P.elapsed(from: start, to: start.addingTimeInterval(36_000)) == "10:00:00")
    #expect(P.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0:00")
    #expect(P.clock(ms: 0) == "0:00")
    #expect(P.clock(ms: 754_900) == "12:34")
    #expect(P.clock(ms: 3_725_000) == "1:02:05")
    #expect(P.meterFraction(-1) == 0)
    #expect(P.meterFraction(0.5) == 0.5)
    #expect(P.meterFraction(7) == 1)
    #expect(P.meterFraction(.nan) == 0)
    #expect(P.meterFraction(.infinity) == 0)
  }

  @Test("a call-sound capture that failed is reported as failed, with the settings fix")
  func callSoundLines() {
    #expect(P.callSoundLine(nil) == nil)
    #expect(P.callSoundLine(.captured) == "Recording the call sound.")
    #expect(P.callSoundLine(.off) == "Only your microphone is recorded.")
    #expect(P.callSoundLine(.unsupported)?.contains("macOS 14.2") == true)
    let failed = P.callSoundLine(.failed)
    #expect(failed?.hasPrefix("The call sound could not be recorded.") == true)
    #expect(failed?.contains("denied") == false)
    #expect(P.callSoundLine(.denied) == failed)
    #expect(P.offersCallSoundFix(.failed) && P.offersCallSoundFix(.denied))
    #expect(!P.offersCallSoundFix(.unsupported) && !P.offersCallSoundFix(.off))
    #expect(!P.offersCallSoundFix(.captured) && !P.offersCallSoundFix(nil))
  }

  @Test("'Paused while you dictate' only while the pass really waits; progress is clamped")
  func processingLines() {
    let id = UUID()
    var processing = MeetingCoordinator.Processing(
      meetingID: id, stage: .transcribing(track: .microphone, fraction: 0.4))
    #expect(P.stage(processing) == "Writing the transcript")
    #expect(P.progress(processing) == 0.4)
    processing.waitingForDictation = true
    #expect(P.stage(processing) == "Paused while you dictate")
    #expect(P.progress(processing) == nil)
    processing = .init(meetingID: id, stage: .transcribing(track: .microphone, fraction: 1.7))
    #expect(P.progress(processing) == 1)
    processing = .init(meetingID: id, stage: .transcribing(track: .microphone, fraction: .nan))
    #expect(P.progress(processing) == nil)
    #expect(P.stage(.init(meetingID: id, stage: nil)) == "Getting ready")
    #expect(P.stage(.init(meetingID: id, stage: .composing)) == "Putting it together")
    #expect(
      P.stage(.init(meetingID: id, stage: .findingSpeakers(track: .callSound)))
        == "Finding the speakers")
  }

  static func record(
    _ state: MeetingState, title: String? = nil, audioKept: Bool = true, failure: String? = nil
  ) -> MeetingRecord {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = state
    record.title = title
    record.audioKept = audioKept
    record.failureCode = failure
    return record
  }

  @Test("each saved state has its own status; an interrupted meeting is never just waiting")
  func statuses() {
    let expected: [(MeetingState, P.Status)] = [
      (.recording, .recording), (.stopping, .saving), (.interrupted, .interrupted),
      (.queued, .waiting), (.ready, .ready), (.failed, .needsAttention),
      // Saved as processing with no pass running: its end could not be saved (#4008).
      (.processing, .needsAttention),
    ]
    for (state, status) in expected {
      #expect(P.status(Self.record(state), processingID: nil) == status, "\(state)")
    }
    let queued = Self.record(.queued)
    #expect(P.status(queued, processingID: queued.id) == .transcribing)
    let processing = Self.record(.processing)
    #expect(P.status(processing, processingID: processing.id) == .transcribing)
    #expect(P.status(processing, processingID: UUID()) == .needsAttention, "another meeting's pass")
    // Each distinct status has its own label.
    let statuses = Set(expected.map(\.1))
    #expect(Set(statuses.map { P.statusLabel($0) }).count == statuses.count)
  }

  @Test("titles, durations, speaker counts and failure reasons")
  func listFacts() {
    #expect(P.title(Self.record(.ready, title: "Board sync")) == "Board sync")
    #expect(P.title(Self.record(.ready, title: "")).hasPrefix("Meeting, "))
    #expect(P.duration(ms: -5) == P.duration(ms: 0))
    #expect(P.speakers(nil) == nil)
    #expect(P.speakers(.single) == nil)
    #expect(P.speakers(.labeled(count: 0)) == nil)
    #expect(P.speakers(.labeled(count: 1)) == "1 speaker")
    #expect(P.speakers(.labeled(count: 3)) == "3 speakers")
    #expect(P.failureLine(Self.record(.ready)) == nil)
    #expect(
      P.failureLine(Self.record(.failed, failure: "audio_deleted"))?.contains("deleted") == true)
    #expect(P.failureLine(Self.record(.failed, failure: "no_audio"))?.contains("No audio") == true)
    #expect(
      P.failureLine(Self.record(.failed, failure: "pass_failed"))?.contains("Transcribe again")
        == true)
  }

  @Test("actions are offered only when they can run")
  func actionEligibility() {
    let ready = Self.record(.ready)
    #expect(
      P.actions(ready, isActive: false, canTranscribeAgain: true)
        == .init(transcribeAgain: true, deleteAudio: true, delete: true))
    #expect(
      P.actions(ready, isActive: true, canTranscribeAgain: false)
        == .init(transcribeAgain: false, deleteAudio: false, delete: true))
    let noAudio = Self.record(.ready, audioKept: false)
    #expect(
      P.actions(noAudio, isActive: false, canTranscribeAgain: false)
        == .init(transcribeAgain: false, deleteAudio: false, delete: true))
    // Transcribe again is the coordinator's answer, never re-derived here (#4008).
    #expect(P.actions(Self.record(.queued), isActive: false, canTranscribeAgain: false).transcribeAgain == false)
    #expect(P.actions(Self.record(.processing), isActive: false, canTranscribeAgain: true).transcribeAgain)
    var marked = ready
    marked.deletionRequested = true
    #expect(P.actions(marked, isActive: false, canTranscribeAgain: false).delete == false)
  }

  @Test("the audio size line never shows a failed read as zero")
  func audioSizeLines() {
    #expect(P.audioSizeLine(.bytes(0)) != P.audioSizeLine(.unreadable))
    #expect(P.audioSizeLine(.deleted).contains("deleted"))
    #expect(P.audioSizeLine(.bytes(42_000_000)).hasPrefix("Audio: "))
  }

  @Test("the coordinator reports kept audio, deleted audio and an unknown meeting distinctly")
  func coordinatorAudioSize() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)
    let file = try MeetingAudioFixture.writeSegment(
      in: harness.store.folder(for: record.id), index: 1, startMs: 0, frames: 16_000)
    record.segments = [
      .microphone: [
        MeetingSegmentInfo(
          index: 1, fileName: file.lastPathComponent, startMs: 0, frameCount: 16_000)
      ]
    ]
    try harness.store.save(record)
    harness.coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      harness.coordinator.record(id: record.id) != nil
    }
    guard case .bytes(let bytes) = await harness.coordinator.audioSize(meetingID: record.id) else {
      Issue.record("kept audio was not measured")
      return
    }
    #expect(bytes > 0)
    #expect(await harness.coordinator.audioSize(meetingID: UUID()) == .unreadable)
    // Playback reads the files the saved record lists, in its own folder.
    let source = try #require(harness.coordinator.playbackSource(meetingID: record.id))
    #expect(source.files[.microphone]?.map { $0.url.deletingLastPathComponent().lastPathComponent }
      == [harness.store.folder(for: record.id).lastPathComponent])
    #expect(source.durationMs == 1_000)
    #expect(harness.coordinator.playbackSource(meetingID: UUID()) == nil)
    await harness.coordinator.deleteAudio(meetingID: record.id)
    #expect(await harness.coordinator.audioSize(meetingID: record.id) == .deleted)
    #expect(harness.coordinator.playbackSource(meetingID: record.id) == nil, "no audio, no player")
  }

  @Test("the call-sound choice is frozen when a Start is admitted, before the startup wait")
  func callSoundFrozenAtAdmission() async throws {
    for (admitted, flipTo) in [(nil as Bool?, true), (false, true), (true, false)] {
      let harness = try MeetingCoordinatorTests.Harness()
      harness.callSound = !flipTo
      let settle = MeetingCoordinatorTests.Gate()
      harness.settleGate = settle
      let coordinator = harness.coordinator
      let start = Task { await coordinator.start(from: .history, captureCallSound: admitted) }
      await MeetingCoordinatorTests.eventually("settle parked") { settle.parked }
      // The switch flips while the start waits for dictation to settle.
      harness.callSound = flipTo
      settle.open()
      await start.value
      let expected = admitted ?? !flipTo
      let recorder = try #require(harness.recorders.first)
      #expect(recorder.configuration.captureCallSound == expected, "\(String(describing: admitted))")
      await coordinator.stop()
    }
  }

  @Test("Allow Microphone is offered only for a missing microphone permission")
  func microphoneFixOffer() {
    #expect(P.offersMicrophoneFix(.microphoneDenied))
    let others: [MeetingCoordinator.Notice] = [
      .microphoneUnavailable, .finishDictationFirst, .lowDisk, .stoppedLowDisk,
      .recordingStoppedFileError, .callSoundUnavailable, .callSoundFailed, .storageFailed,
    ]
    #expect(others.allSatisfy { !P.offersMicrophoneFix($0) })
  }

  @Test("the pass's wait for dictation reaches the page, and ends when the pass goes on")
  func waitingForDictationReachesProcessing() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let gate = MeetingCoordinatorTests.Gate()
    harness.jobBehavior = { _ in
      await gate.wait()
      return MeetingCoordinatorTests.result()
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    await coordinator.stop()
    await MeetingCoordinatorTests.eventually("pass parked") { gate.parked }
    let job = try #require(harness.jobs.last)
    job.onWaitingForDictation?(true)
    #expect(coordinator.processing?.waitingForDictation == true)
    job.onWaitingForDictation?(false)
    #expect(coordinator.processing?.waitingForDictation == false)
    gate.open()
    await MeetingCoordinatorTests.eventually("done") { coordinator.processing == nil }
  }

  @Test("a saved meeting carries the notes under their own heading, and nothing without notes")
  func exportCarriesNotes() {
    #expect(P.exportDocument(transcript: "You: hello", notes: "") == "You: hello")
    #expect(
      P.exportDocument(transcript: "You: hello", notes: "Follow up Friday")
        == "You: hello\n\nNotes\n\nFollow up Friday\n")
  }
}
