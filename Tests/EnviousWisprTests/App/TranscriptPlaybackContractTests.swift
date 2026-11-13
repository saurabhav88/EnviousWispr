import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// The shared player for imported transcripts (#3147 PR3): it plays an already opened
/// original, keeps the chosen speed, and every transcript player stops before its entry's link,
/// content or row changes.
@MainActor
/// Class: `.productOutcome` — what the transcript dock plays and whether it keeps playing a file
/// History no longer describes.
@Suite("Transcript playback contract (#3147 PR3)", .tags(.productOutcome))
struct TranscriptPlaybackContractTests {
  typealias FakeOutput = MeetingPlaybackControllerTests.FakeOutput

  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  final class Tone: PlaybackWindowAudio, @unchecked Sendable {
    func window(startMs: Int, count: Int) throws -> [Float] {
      [Float](repeating: 0.25, count: count * 16)
    }
  }

  @Test("an opened original plays window by window through the shared player")
  func transcriptMediaPlays() async throws {
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 1_000, output: output, windowMs: 250,
      sourceID: .transcript(UUID()))
    player.play()
    #expect(player.state == .playing)
    await eventually("a window queued") { !output.windows.isEmpty }
    #expect(output.windows.first?.first == 0.25)
    player.stop()
  }

  @Test("the speed is one of the dock's five, kept across play and stop; others are ignored")
  func rateIsKept() {
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 1_000, output: output)
    #expect(player.playbackRate == 1)
    player.setPlaybackRate(1.5)
    #expect(player.playbackRate == 1.5)
    player.setPlaybackRate(3)
    #expect(player.playbackRate == 1.5, "a speed the dock does not offer is ignored")
    #expect(output.rates == [1.5])
    player.play()
    player.stop()
    #expect(player.playbackRate == 1.5)
    #expect(MeetingPlaybackController.playbackRates == [0.75, 1, 1.25, 1.5, 2])
  }

  @Test("Delete All stops every transcript player and leaves dictation players alone")
  func stopAllTranscripts() {
    let arbiter = PlaybackArbiter()
    let transcript = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 5_000, output: FakeOutput(),
      sourceID: .transcript(UUID()), arbiter: arbiter)
    let dictation = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 5_000, output: FakeOutput(),
      sourceID: .dictation(UUID()), arbiter: arbiter)
    let before = arbiter.transcriptEpoch
    arbiter.stopAllTranscriptsForDeletion()
    #expect(arbiter.transcriptEpoch == before + 1)
    #expect(transcript.state == .unavailable)
    #expect(dictation.state != .unavailable)
  }

  @Test("deleting an import stops its original-file players before the row goes")
  func deletionStopsTranscriptPlayers() async throws {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-tplay-\(UUID().uuidString)", isDirectory: true)
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let arbiter = PlaybackArbiter()
    coordinator.onImportedContentWillChange = { arbiter.stopForDeletion(.transcript($0)) }
    let row = Transcript(text: "talk", importedFileName: "talk.m4a")
    try await coordinator.saveAndShow(row)
    let player = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 5_000, output: FakeOutput(),
      sourceID: .transcript(row.id), arbiter: arbiter)

    _ = await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
    #expect(arbiter.deletionCount(for: .transcript(row.id)) == 1)
    #expect(player.state == .unavailable)
  }
}
