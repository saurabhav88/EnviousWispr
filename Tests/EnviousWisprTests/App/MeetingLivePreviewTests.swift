import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore

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
    /// When set, every preview unit waits on it (a unit still running).
    @ObservationIgnored var hold: Gate?
    /// Shared order of events across the preview and the final pass.
    @ObservationIgnored var log: [String] = []

    func preview(audio: MeetingTrackAudio) async throws -> String {
      let name = audio.segments.first?.url.lastPathComponent ?? "none"
      isUnitInFlight = true
      isEngineResident = true
      calls.append(name)
      log.append("preview \(name)")
      await hold?.wait()
      isUnitInFlight = false
      return "words of \(name)"
    }

    func releaseIdle() async {
      guard isEngineResident, !isUnitInFlight else { return }
      releases += 1
      log.append("release")
      isEngineResident = false
    }

    func cancel() {}
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
          "Live words, usually about a minute behind.", "Words up to 12:34.", "Catching up.",
          "Echo is hidden when the meeting ends.",
        ])
    live.waitingForDictation = true
    #expect(
      MeetingsPresentation.liveStatusLines(live, callSoundRecorded: false).contains(
        "Waiting for your dictation to finish."))
    #expect(
      !MeetingsPresentation.liveStatusLines(live, callSoundRecorded: false).contains(
        "Catching up."), "waiting for dictation is the reason shown, not the backlog")
  }
}
