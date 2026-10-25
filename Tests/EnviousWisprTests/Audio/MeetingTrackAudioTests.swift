import AVFoundation
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
import EnviousWisprAppKitTestSupport

/// Files and known audio for the meeting audio suites, written with AVFoundation directly so
/// the reader is checked against files its own writer did not make.
enum MeetingAudioFixture {
  static func folder(_ label: String) throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Known audio, exactly representable as 16-bit integers, different per `seed`.
  static func value(_ i: Int, seed: Int = 0) -> Float {
    Float((i * 37 + seed * 101) % 2_000 - 1_000) / 32_768
  }

  /// One 16-bit sample step: the most a value may move through a 16-bit file.
  static let tolerance: Float = 1.0 / 32_767

  /// Writes `frames` samples (`value(i, seed:)`) as a 16 kHz mono 16-bit CAF named for `track`,
  /// `index` and `startMs`.
  @discardableResult
  static func writeSegment(
    in folder: URL, track: MeetingTrackKind = .microphone, index: Int, startMs: Int,
    frames: Int, seed: Int = 0, partial: Bool = false, sampleRate: Double = 16_000,
    float: Bool = false
  ) throws -> URL {
    let name = MeetingSegmentNaming.fileName(
      track: track, index: index, startMs: startMs, partial: partial)
    let url = folder.appendingPathComponent(name)
    try writeFile(url, frames: frames, seed: seed, sampleRate: sampleRate, float: float)
    return url
  }

  static func writeFile(
    _ url: URL, frames: Int, seed: Int = 0, sampleRate: Double = 16_000, float: Bool = false
  ) throws {
    let processing = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: float ? 32 : 16,
        AVLinearPCMIsFloatKey: float,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    guard frames > 0 else { return }
    let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = value(i, seed: seed) }
    try file.write(from: buffer)
  }

  /// Every sample of `url`, decoded.
  static func decode(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  static func matches(_ a: ArraySlice<Float>, _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
  }
}

/// #3972 R15, R22: when these fail, a meeting transcript is built from the wrong audio, from
/// audio shifted on the timeline, or from silence where a file could not be read.
@Suite("MeetingTrackAudio", .tags(.productOutcome, .realBoundary))
struct MeetingTrackAudioTests {
  private typealias F = MeetingAudioFixture

  @Test("reads exact samples across two files and a gap; the gap is silence")
  func readsAcrossFilesAndGaps() throws {
    let dir = try F.folder("MeetingTrackAudioTests")
    let a = try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000, seed: 1)
    let b = try F.writeSegment(in: dir, index: 2, startMs: 2_000, frames: 8_000, seed: 2)
    let audio = MeetingTrackAudio(files: [(b, 2_000), (a, 0)])
    #expect(audio.problems.isEmpty)
    #expect(audio.endSample == 40_000)
    #expect(
      audio.runs == [
        .init(startSample: 0, endSample: 16_000), .init(startSample: 32_000, endSample: 40_000),
      ])

    let samples = try audio.read(from: 15_000, count: 18_000)
    #expect(F.matches(samples[0..<1_000], (15_000..<16_000).map { F.value($0, seed: 1) }))
    #expect(samples[1_000..<17_000].allSatisfy { $0 == 0 })
    #expect(F.matches(samples[17_000..<18_000], (0..<1_000).map { F.value($0, seed: 2) }))
  }

  @Test("segments 160 samples apart are one run; 176 apart are two")
  func runToleranceBoundary() throws {
    let dir = try F.folder("MeetingTrackAudioTests")
    // 1,000 ms = 16,000 samples; the next file starts 10 ms (160 samples) later.
    let a = try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000)
    let b = try F.writeSegment(in: dir, index: 2, startMs: 1_010, frames: 16_000)
    // 2,010 ms ends at 32,160; the next starts 11 ms (176 samples) later.
    let c = try F.writeSegment(in: dir, index: 3, startMs: 2_021, frames: 16_000)
    let audio = MeetingTrackAudio(files: [(a, 0), (b, 1_010), (c, 2_021)])
    #expect(
      audio.runs == [
        .init(startSample: 0, endSample: 32_160), .init(startSample: 32_336, endSample: 48_336),
      ])
  }

  @Test("an unreadable, wrong-format or empty file is listed as a problem and never read as a gap")
  func badFilesAreReported() throws {
    let dir = try F.folder("MeetingTrackAudioTests")
    let good = try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 1_600)
    let garbage = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 2, startMs: 1_000, partial: false))
    try Data(repeating: 7, count: 512).write(to: garbage)
    let wrongRate = try F.writeSegment(
      in: dir, index: 3, startMs: 2_000, frames: 1_600, sampleRate: 48_000)
    let floats = try F.writeSegment(in: dir, index: 4, startMs: 3_000, frames: 1_600, float: true)
    let empty = try F.writeSegment(in: dir, index: 5, startMs: 4_000, frames: 0)
    let audio = MeetingTrackAudio(files: [
      (good, 0), (garbage, 1_000), (wrongRate, 2_000), (floats, 3_000), (empty, 4_000),
    ])
    #expect(audio.segments.map(\.url) == [good])
    #expect(
      Set(audio.problems) == [
        .unreadable(fileName: garbage.lastPathComponent),
        .incompatibleFormat(fileName: wrongRate.lastPathComponent),
        .incompatibleFormat(fileName: floats.lastPathComponent),
        .empty(fileName: empty.lastPathComponent),
      ])
  }

  @Test("where two files cover the same time the earlier one is read and the overlap reported")
  func overlapEarlierFileWins() throws {
    let dir = try F.folder("MeetingTrackAudioTests")
    let a = try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000, seed: 1)
    let b = try F.writeSegment(in: dir, index: 2, startMs: 500, frames: 16_000, seed: 2)
    let audio = MeetingTrackAudio(files: [(b, 500), (a, 0)])
    #expect(audio.problems == [.overlap(fileName: b.lastPathComponent, samples: 8_000)])
    #expect(audio.runs == [.init(startSample: 0, endSample: 24_000)])
    let samples = try audio.read(from: 0, count: 24_000)
    #expect(F.matches(samples[0..<16_000], (0..<16_000).map { F.value($0, seed: 1) }))
    #expect(F.matches(samples[16_000..<24_000], (8_000..<16_000).map { F.value($0, seed: 2) }))
  }

  @Test("the diarizer's copy path zeroes gaps in a dirty destination and copies exact audio")
  func diarizerCopyPath() throws {
    let dir = try F.folder("MeetingTrackAudioTests")
    let a = try F.writeSegment(in: dir, index: 1, startMs: 100, frames: 3_200, seed: 3)
    let audio = MeetingTrackAudio(files: [(a, 100)])
    let source = audio.diarizerSource
    #expect(source.sampleCount == 4_800)
    let destination = UnsafeMutablePointer<Float>.allocate(capacity: 4_800)
    defer { destination.deallocate() }
    destination.initialize(repeating: 7, count: 4_800)
    try source.copySamples(into: destination, offset: 0, count: 4_800)
    let out = Array(UnsafeBufferPointer(start: destination, count: 4_800))
    #expect(out[0..<1_600].allSatisfy { $0 == 0 })
    #expect(F.matches(out[1_600..<4_800], (0..<3_200).map { F.value($0, seed: 3) }))
  }

  @Test("a file that disappears or shrinks after listing makes the read throw instead of silence")
  func failedReadsThrow() throws {
    let dir = try F.folder("MeetingTrackAudioTests")
    let a = try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000)
    let b = try F.writeSegment(in: dir, index: 2, startMs: 1_000, frames: 16_000)
    let audio = MeetingTrackAudio(files: [(a, 0), (b, 1_000)])
    try FileManager.default.removeItem(at: a)
    #expect(throws: MeetingTrackAudio.ReadError.unreadable(fileName: a.lastPathComponent)) {
      try audio.read(from: 0, count: 100)
    }
    try F.writeFile(b, frames: 8_000)
    #expect(
      throws: MeetingTrackAudio.ReadError.shortRead(
        fileName: b.lastPathComponent, expected: 16_000, got: 8_000)
    ) {
      try audio.read(from: 16_000, count: 16_000)
    }
  }
}
