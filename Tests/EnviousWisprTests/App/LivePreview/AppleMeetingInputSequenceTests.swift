import AVFoundation
import EnviousWisprCore
import Foundation
import Speech
import Testing

@testable import EnviousWisprLivePreview

/// #4355: when these fail, Apple's word times are mapped onto the wrong written audio after the
/// analyzer fell behind (dropped input still counted as heard), a stalled analyzer makes the
/// meeting hold audio buffers without bound, or a conversion that shifts frames still claims
/// exact positions.
///
/// Drives the recorder's bounded envelope stream and input sequence exactly as the analyzer
/// would; no Apple analyzer runs.
@Suite("Apple meeting input recorder (#4355)", .tags(.productOutcome))
struct AppleMeetingInputSequenceTests {
  static let recording = UUID()
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

  private static func buffer(_ frames: Int) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
  }

  private static func slices(start: Int, count: Int) -> [MeetingLiveAudioSlice] {
    [
      MeetingLiveAudioSlice(
        offset: 0,
        span: MeetingAudioSpan(
          recording: recording, track: .callSound, run: 0, startSample: start, sampleCount: count)!)
    ]
  }

  @available(macOS 26.0, *)
  private static func feed(
    _ recorder: AppleMeetingInputRecorder, written start: Int, frames: Int = 1_600
  ) {
    recorder.push(
      buffer(frames), frames: frames, sourceFrames: frames,
      slices: slices(start: start, count: frames))
  }

  private static func span(_ start: Int, _ count: Int = 1_600) -> MeetingAudioSpan? {
    MeetingAudioSpan(
      recording: recording, track: .callSound, run: 0, startSample: start, sampleCount: count)
  }

  @Test("a stalled analyzer loses the oldest input; what it takes later maps exactly, dropped input never became timeline")
  func stalledQueueDrops() async throws {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 4)
    for i in 0..<10 { Self.feed(recorder, written: i * 1_600) }
    recorder.finish()
    #expect(recorder.storage.consumedFrames == 0, "nothing is timeline before it is taken")
    var iterator = recorder.sequence.makeAsyncIterator()
    var taken = 0
    while await iterator.next() != nil { taken += 1 }
    #expect(taken == 4, "only the newest four were still queued")
    #expect(recorder.storage.consumedFrames == 4 * 1_600)
    // Input time 0 is the first input the analyzer heard: written 9,600 (the 7th fed).
    #expect(recorder.project(startSeconds: 0, endSeconds: 0.1) == Self.span(9_600))
    #expect(recorder.project(startSeconds: 0.3, endSeconds: 0.4) == Self.span(14_400))
  }

  @Test("finish lets queued input drain, then ends; input after the finish is refused")
  func finishDrainsThenEnds() async throws {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 4)
    Self.feed(recorder, written: 0)
    recorder.finish()
    let late = recorder.push(Self.buffer(10), frames: 10, sourceFrames: 10, slices: [])
    if case .terminated = late {} else { Issue.record("input after the finish must be refused") }
    var iterator = recorder.sequence.makeAsyncIterator()
    #expect(await iterator.next() != nil, "the queued input still drains")
    #expect(await iterator.next() == nil, "then the end")
    #expect(recorder.storage.consumedFrames == 1_600)
  }

  @Test("a cancelled analyzer gets the end and commits none of the queued input")
  func cancelledAnalyzerCommitsNothing() async {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 4)
    for i in 0..<2 { Self.feed(recorder, written: i * 1_600) }
    let taking = Task {
      withUnsafeCurrentTask { $0?.cancel() }  // cancelled before it reads
      var iterator = recorder.sequence.makeAsyncIterator()
      return await iterator.next()
    }
    #expect(await taking.value == nil)
    #expect(recorder.storage.consumedFrames == 0, "queued input never became timeline")
  }

  @Test("clearing after teardown delivers nothing more, commits nothing more and releases queued audio at once")
  func clearDropsEverything() async {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 4)
    Self.feed(recorder, written: 0)
    var iterator = recorder.sequence.makeAsyncIterator()
    _ = await iterator.next()
    #expect(recorder.storage.records == 1)
    weak var queuedBuffer: AVAudioPCMBuffer?
    do {
      let buffer = Self.buffer(1_600)
      queuedBuffer = buffer
      recorder.push(
        buffer, frames: 1_600, sourceFrames: 1_600, slices: Self.slices(start: 1_600, count: 1_600))
    }
    #expect(recorder.storage.queuedBuffers == 1)
    #expect(queuedBuffer != nil, "control: the queue holds it")
    recorder.clear()
    #expect(queuedBuffer == nil, "released by the clear, though the stream still holds its envelope")
    #expect(await iterator.next() == nil, "the queued input is never delivered")
    #expect(recorder.storage.records == 0)
    #expect(recorder.storage.consumedFrames == 0, "nothing committed after the clear")
    #expect(recorder.project(startSeconds: 0, endSeconds: 0.1) == nil)
  }

  @Test("an input the stream dropped is released at once")
  func droppedInputReleased() {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 1)
    weak var first: AVAudioPCMBuffer?
    do {
      let buffer = Self.buffer(1_600)
      first = buffer
      recorder.push(buffer, frames: 1_600, sourceFrames: 1_600, slices: [])
    }
    Self.feed(recorder, written: 1_600)  // the capacity-1 stream drops the first
    #expect(first == nil)
    #expect(recorder.storage.queuedBuffers == 1)
  }

  @Test("one conversion that did not return a frame per sample makes it and every later input unpositioned")
  func conversionMismatchLosesCorrespondence() async throws {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 8)
    Self.feed(recorder, written: 0)
    recorder.push(
      Self.buffer(1_500), frames: 1_500, sourceFrames: 1_600,
      slices: Self.slices(start: 1_600, count: 1_600))
    Self.feed(recorder, written: 3_200)
    recorder.finish()
    var iterator = recorder.sequence.makeAsyncIterator()
    while await iterator.next() != nil {}
    #expect(recorder.project(startSeconds: 0, endSeconds: 0.1) == Self.span(0), "before the mismatch")
    #expect(recorder.project(startSeconds: 0.1, endSeconds: 0.15) == nil, "the mismatched input")
    #expect(recorder.project(startSeconds: 0.2, endSeconds: 0.25) == nil, "never resumes")
  }

  @Test("through the feed adapter: an uncertain conversion stops exact mapping even when later counts match")
  func uncertainConversionThroughAdapter() async throws {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 8)
    let first = ApplePreviewRecognizer.queueMeetingInput(
      .converted(Self.buffer(1_600)), sourceFrames: 1_600,
      slices: Self.slices(start: 0, count: 1_600), into: recorder)
    let failed = ApplePreviewRecognizer.queueMeetingInput(
      .uncertain, sourceFrames: 1_600, slices: Self.slices(start: 1_600, count: 1_600),
      into: recorder)
    let later = ApplePreviewRecognizer.queueMeetingInput(
      .converted(Self.buffer(1_600)), sourceFrames: 1_600,
      slices: Self.slices(start: 3_200, count: 1_600), into: recorder)
    let skipped = ApplePreviewRecognizer.queueMeetingInput(
      .notStarted, sourceFrames: 1_600, slices: [], into: recorder)
    #expect([first, failed, later, skipped] == [true, false, true, false])
    recorder.finish()
    var iterator = recorder.sequence.makeAsyncIterator()
    while await iterator.next() != nil {}
    #expect(recorder.storage.consumedFrames == 3_200, "the uncertain input never reached the analyzer")
    #expect(recorder.project(startSeconds: 0, endSeconds: 0.1) == Self.span(0))
    #expect(recorder.project(startSeconds: 0.1, endSeconds: 0.2) == nil, "equal counts do not restore it")
  }

  @Test("a session whose rate differs from the written audio maps nothing, though its input is heard")
  func inexactSessionMapsNothing() async throws {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: false, capacity: 8)
    Self.feed(recorder, written: 0)
    recorder.finish()
    var iterator = recorder.sequence.makeAsyncIterator()
    _ = try #require(await iterator.next())
    #expect(recorder.storage.consumedFrames == 1_600)
    #expect(recorder.project(startSeconds: 0, endSeconds: 0.1) == nil)
  }

  @Test("pruning by result time keeps later positions exact")
  func pruneBySeconds() async throws {
    guard #available(macOS 26.0, *) else { return }
    let recorder = AppleMeetingInputRecorder(sampleRate: 16_000, exact: true, capacity: 8)
    for i in 0..<3 { Self.feed(recorder, written: i * 1_600) }
    recorder.finish()
    var iterator = recorder.sequence.makeAsyncIterator()
    while await iterator.next() != nil {}
    recorder.prune(beforeSeconds: 0.1)
    #expect(recorder.storage.records == 2)
    #expect(recorder.project(startSeconds: 0, endSeconds: 0.05) == nil)
    #expect(recorder.project(startSeconds: 0.2, endSeconds: 0.3) == Self.span(3_200))
  }
}
