import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #3972 R3, #3995: when these fail, a meeting with a damaged audio file shows no gap where
/// its words are missing, shows a gap over audio that was transcribed, or guesses the end of
/// a damaged last file.
@Suite("Meeting damaged audio", .tags(.productOutcome))
struct MeetingDamagedAudioTests {

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingDamagedAudioTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func damaged(in dir: URL, index: Int, startMs: Int) throws -> URL {
    let url = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(
        track: .microphone, index: index, startMs: startMs, partial: false))
    try Data("not audio".utf8).write(to: url)
    return url
  }

  private func listed(_ urls: [(URL, Int)]) -> [MeetingStore.SegmentFile] {
    urls.enumerated().map { i, file in
      MeetingStore.SegmentFile(
        track: .microphone, index: i + 1, startMs: file.1, partial: false, url: file.0)
    }
  }

  @Test("a damaged file's gap runs to the next file, minus audio a readable file covers")
  func gapEndsAtNextFileMinusCoverage() throws {
    let dir = try folder()
    // 0..<2,000 readable, a damaged file at 1,000, the next readable file at 4,000.
    let first = try MeetingAudioFixture.writeSegment(
      in: dir, track: .microphone, index: 1, startMs: 0, frames: 32_000)
    let bad = try damaged(in: dir, index: 2, startMs: 1_000)
    let last = try MeetingAudioFixture.writeSegment(
      in: dir, track: .microphone, index: 3, startMs: 4_000, frames: 16_000)
    let readable = MeetingTrackAudio(files: [(first, 0), (last, 4_000)])
    let missing = MeetingDamagedAudio.missingAudio(
      damaged: [bad.lastPathComponent],
      onDisk: listed([(first, 0), (bad, 1_000), (last, 4_000)]),
      readable: [.microphone: readable])
    #expect(missing[.microphone] == [.init(startMs: 2_000, endMs: 4_000)])
    #expect(missing[.callSound] == nil)
    #expect(MeetingDamagedAudio.markerCount(missing) == 1)
  }

  @Test("a damaged last file has no known end: the gap is open, never a guess")
  func damagedLastFileIsOpenEnded() throws {
    let dir = try folder()
    let first = try MeetingAudioFixture.writeSegment(
      in: dir, track: .microphone, index: 1, startMs: 0, frames: 16_000)
    let bad = try damaged(in: dir, index: 2, startMs: 1_000)
    let missing = MeetingDamagedAudio.missingAudio(
      damaged: [bad.lastPathComponent], onDisk: listed([(first, 0), (bad, 1_000)]),
      readable: [.microphone: MeetingTrackAudio(files: [(first, 0)])])
    #expect(missing[.microphone] == [.init(startMs: 1_000, endMs: nil)])
  }

  @Test("only problems that lose audio name a damaged file")
  func damagedFileNames() {
    #expect(MeetingDamagedAudio.damagedFileName(.unreadableFinal(fileName: "a")) == "a")
    #expect(MeetingDamagedAudio.damagedFileName(.emptyFinal(fileName: "a")) == nil)
    #expect(
      MeetingDamagedAudio.damagedFileName(MeetingTrackAudio.Problem.unreadable(fileName: "b"))
        == "b")
    #expect(
      MeetingDamagedAudio.damagedFileName(
        MeetingTrackAudio.Problem.overlap(fileName: "b", samples: 1))
        == nil)
  }
}
