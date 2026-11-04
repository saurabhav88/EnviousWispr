import EnviousWisprCore
import Foundation
import Testing

@Suite("Meeting audio span (#4355)", .tags(.productOutcome))
struct MeetingAudioSpanTests {
  @Test(
    "a span that names no audio is refused",
    arguments: [
      (run: 0, start: 0, count: 0), (run: 0, start: 0, count: -1), (run: 0, start: -1, count: 10),
      (run: -1, start: 0, count: 10),
    ])
  func refusesEmptyOrNegative(run: Int, start: Int, count: Int) {
    #expect(
      MeetingAudioSpan(
        recording: UUID(), track: .callSound, run: run, startSample: start, sampleCount: count)
        == nil)
  }

  @Test("a span ends one past its last sample")
  func endIsExclusive() throws {
    let span = try #require(
      MeetingAudioSpan(
        recording: UUID(), track: .microphone, run: 2, startSample: 16_000, sampleCount: 1_600))
    #expect(span.endSample == 17_600)
  }

  @Test("the same samples on the other track are a different span")
  func trackIsPartOfIdentity() {
    let meeting = UUID()
    let mic = MeetingAudioSpan(
      recording: meeting, track: .microphone, run: 0, startSample: 0, sampleCount: 160)
    let call = MeetingAudioSpan(
      recording: meeting, track: .callSound, run: 0, startSample: 0, sampleCount: 160)
    #expect(mic != nil && call != nil)
    #expect(mic != call)
  }
}
