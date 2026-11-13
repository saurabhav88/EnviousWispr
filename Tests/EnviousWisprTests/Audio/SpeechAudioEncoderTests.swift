import AVFoundation
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #3147 §3.1: when these fail, a saved dictation or meeting track is reported as kept but plays
/// short, broken or not at all, or a failed compression damages an earlier recording or the
/// original meeting audio. Real Apple encoder, real files.
@Suite("Speech audio encoder", .tags(.productOutcome))
struct SpeechAudioEncoderTests {

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("SpeechAudioEncoderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Two seconds of a speech-band tone.
  private func tone(seconds: Double = 2) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.3 }
  }

  /// A 16 kHz mono 16-bit integer CAF, the meeting track format.
  private func writeTrack(_ samples: [Float], sampleRate: Double = 16_000, to url: URL) throws {
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ],
      commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
      buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
  }

  @Test("dictation samples become a verified private AAC file of the same length")
  func encodesSamples() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("take.m4a")
    let samples = tone()

    let output = try SpeechAudioEncoder.encode(
      samples: samples, purpose: .dictation, to: destination)

    #expect(abs(output.frames - Int64(samples.count)) <= SpeechAudioEncoder.durationToleranceFrames)
    let file = try AVAudioFile(forReading: destination)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    #expect(file.fileFormat.sampleRate == 16_000)
    let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[
      .posixPermissions]
    #expect((permissions as? NSNumber)?.intValue == 0o600)
    #expect(output.bytes > 0)
  }

  @Test("a meeting track file is compressed chunk by chunk and the original is untouched")
  func encodesTrackFile() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("mic.caf")
    // Longer than one chunk, so the chunked path runs more than once.
    let samples = tone(seconds: 9)
    try writeTrack(samples, to: source)
    let before = try Data(contentsOf: source)

    let output = try SpeechAudioEncoder.encode(
      fileAt: source, purpose: .meeting, to: dir.appendingPathComponent("mic.m4a"))

    #expect(abs(output.frames - Int64(samples.count)) <= SpeechAudioEncoder.durationToleranceFrames)
    #expect(try Data(contentsOf: source) == before)
  }

  @Test("an existing file at the destination is never replaced")
  func refusesExistingDestination() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("take.m4a")
    let earlier = Data("earlier recording".utf8)
    try earlier.write(to: destination)

    #expect(throws: SpeechAudioEncoder.Failure.destinationExists) {
      try SpeechAudioEncoder.encode(samples: tone(), purpose: .dictation, to: destination)
    }
    #expect(try Data(contentsOf: destination) == earlier)
  }

  @Test("two encodes aimed at one path: one owns it, the other leaves that file intact")
  func sameDestinationHasOneOwner() async throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("take.m4a")
    let samples = tone()
    let attempts = (0..<2).map { _ in
      Task.detached { () -> Result<SpeechAudioEncoder.Output, any Error> in
        Result { try SpeechAudioEncoder.encode(samples: samples, purpose: .dictation, to: destination) }
      }
    }
    var outputs: [SpeechAudioEncoder.Output] = []
    var refusals = 0
    for attempt in attempts {
      switch await attempt.value {
      case .success(let output): outputs.append(output)
      case .failure(let error):
        #expect(error as? SpeechAudioEncoder.Failure == .destinationExists)
        refusals += 1
      }
    }

    #expect(outputs.count == 1)
    #expect(refusals == 1)
    let file = try AVAudioFile(forReading: destination)
    #expect(abs(file.length - Int64(samples.count)) <= SpeechAudioEncoder.durationToleranceFrames)
  }

  @Test("input that cannot be encoded leaves no file behind")
  func refusedInputLeavesNothing() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("out.m4a")
    let wrongRate = dir.appendingPathComponent("cd.caf")
    try writeTrack(tone(), sampleRate: 44_100, to: wrongRate)

    #expect(throws: SpeechAudioEncoder.Failure.emptyInput) {
      try SpeechAudioEncoder.encode(samples: [], purpose: .dictation, to: destination)
    }
    #expect(throws: SpeechAudioEncoder.Failure.unsupportedSource) {
      try SpeechAudioEncoder.encode(fileAt: wrongRate, purpose: .meeting, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("a cancelled encode stops and removes its own output")
  func cancelledEncodeLeavesNothing() async throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("out.m4a")
    let samples = tone()
    let task = Task.detached {
      // Cancelled before the encode starts: the first chunk check throws.
      withUnsafeCurrentTask { $0?.cancel() }
      return try SpeechAudioEncoder.encode(samples: samples, purpose: .dictation, to: destination)
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}
