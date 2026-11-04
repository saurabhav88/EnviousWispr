import EnviousWisprCore
import Foundation
import Testing

/// #4355: when these fail, a live engine's words are credited to the wrong stretch of written
/// audio (and so, later, the wrong speaker), or words over audio of unknown position get a
/// guessed position instead of none.
@Suite("Meeting audio feed map (#4355)", .tags(.productOutcome))
struct MeetingAudioFeedMapTests {
  static let recording = UUID()

  private func slice(_ offset: Int, start: Int, count: Int, run: Int = 0) -> MeetingLiveAudioSlice {
    MeetingLiveAudioSlice(
      offset: offset,
      span: MeetingAudioSpan(
        recording: Self.recording, track: .callSound, run: run, startSample: start,
        sampleCount: count)!)
  }

  private func span(start: Int, count: Int, run: Int = 0) -> MeetingAudioSpan? {
    MeetingAudioSpan(
      recording: Self.recording, track: .callSound, run: run, startSample: start,
      sampleCount: count)
  }

  @Test("a range inside committed input maps to the written samples it was, across records")
  func exactProjection() {
    var map = MeetingAudioFeedMap(sampleRate: 16_000)
    // Two consumed inputs of 1,600 frames: written 32,000..<33,600 and 33,600..<35,200.
    map.commit(frames: 1_600, slices: [slice(0, start: 32_000, count: 1_600)])
    map.commit(frames: 1_600, slices: [slice(0, start: 33_600, count: 1_600)])
    // 0.05 s to 0.15 s of input time = frames 800..<2,400.
    #expect(map.project(startSeconds: 0.05, endSeconds: 0.15) == span(start: 32_800, count: 1_600))
    #expect(map.consumedFrames == 3_200)
  }

  @Test("start rounds down and end rounds up to whole input frames")
  func rounding() {
    var map = MeetingAudioFeedMap(sampleRate: 16_000)
    map.commit(frames: 1_600, slices: [slice(0, start: 0, count: 1_600)])
    // 0.00001 s is frame 0.16: start floor 0; 0.00007 s is 1.12: end ceiling 2.
    #expect(map.project(startSeconds: 0.00001, endSeconds: 0.00007) == span(start: 0, count: 2))
  }

  @Test(
    "a range that touches unpositioned input, a hole in the written audio or another run maps to nothing",
    arguments: [
      // The second input is unpositioned.
      0,
      // The second input continues the frames, but its written audio jumps 1,600 samples.
      1,
      // The second input is contiguous written audio of another run.
      2,
    ])
  func unknownGivesNil(_ variant: Int) {
    var map = MeetingAudioFeedMap(sampleRate: 16_000)
    map.commit(frames: 1_600, slices: [slice(0, start: 0, count: 1_600)])
    switch variant {
    case 0: map.commit(frames: 1_600, slices: nil)
    case 1: map.commit(frames: 1_600, slices: [slice(0, start: 3_200, count: 1_600)])
    default: map.commit(frames: 1_600, slices: [slice(0, start: 1_600, count: 1_600, run: 1)])
    }
    #expect(map.project(startSeconds: 0.05, endSeconds: 0.15) == nil)
    #expect(
      map.project(startSeconds: 0, endSeconds: 0.1) == span(start: 0, count: 1_600), "control")
  }

  @Test("a range partly covered inside one input (an unpositioned stretch) maps to nothing")
  func partialRecordGivesNil() {
    var map = MeetingAudioFeedMap(sampleRate: 16_000)
    // Only the first 1,000 frames of this input are positioned.
    map.commit(frames: 1_600, slices: [slice(0, start: 0, count: 1_000)])
    #expect(map.project(startSeconds: 0, endSeconds: 0.05) == span(start: 0, count: 800))
    #expect(map.project(startSeconds: 0.05, endSeconds: 0.08) == nil)
  }

  @Test("pruning keeps absolute offsets: later ranges map exactly, pruned ones map to nothing")
  func pruneKeepsAbsoluteOffsets() {
    var map = MeetingAudioFeedMap(sampleRate: 16_000)
    for i in 0..<4 {
      map.commit(frames: 1_600, slices: [slice(0, start: 10_000 + i * 1_600, count: 1_600)])
    }
    map.prune(before: 3_200)
    #expect(map.recordCount == 2)
    #expect(map.prunedThrough == 3_200)
    #expect(map.project(startSeconds: 0, endSeconds: 0.1) == nil, "pruned")
    #expect(map.project(startSeconds: 0.2, endSeconds: 0.3) == span(start: 13_200, count: 1_600))
    map.commit(frames: 1_600, slices: [slice(0, start: 16_400, count: 1_600)])
    #expect(map.project(startSeconds: 0.4, endSeconds: 0.5) == span(start: 16_400, count: 1_600))
  }

  @Test("a range past the committed input, empty or negative maps to nothing")
  func outOfRange() {
    var map = MeetingAudioFeedMap(sampleRate: 16_000)
    map.commit(frames: 1_600, slices: [slice(0, start: 0, count: 1_600)])
    #expect(map.project(startSeconds: 0.05, endSeconds: 0.2) == nil)
    #expect(map.project(startSeconds: 0.05, endSeconds: 0.05) == nil)
    #expect(map.project(startSeconds: -0.1, endSeconds: 0.05) == nil)
    // Inside one frame: an empty or reversed range never rounds into a span.
    #expect(map.project(startSeconds: 0.00001, endSeconds: 0.00001) == nil)
    #expect(map.project(startSeconds: 0.00003, endSeconds: 0.00002) == nil)
  }
}
