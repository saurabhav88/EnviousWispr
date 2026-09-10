import AVFoundation
import Foundation
import Testing

@testable import EnviousWisprASR

/// #2648 — the one genuinely new input this feature needs: a file, not a microphone.
///
/// **When this fails, the user picks a recording and either gets nothing with no explanation, or gets a
/// transcript of only part of it presented as the whole thing.** Product coverage.
///
/// **Every fixture is a REAL file this test writes and the real decoder reads.** Nothing here is a
/// stub: `m4a` passing proves nothing about `wav`, mono proves nothing about stereo, and 16 kHz proves
/// nothing about 48 kHz, so the matrix is the point rather than a nicety. The formats are written with
/// `AVAudioFile` and `AVAssetWriter`, which is why `mp3` is absent — macOS decodes it and does not
/// encode it, so a committed binary would be the only way to cover it, and that is named below rather
/// than quietly skipped.
@Suite(.tags(.productOutcome))
struct AudioFileDecoderTests {

  // MARK: - Fixture writing

  private static func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("audio-decode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A real tone, written through a real encoder, at whatever rate and channel count is asked for.
  ///
  /// A tone rather than silence deliberately: silence and "no audio at all" are different answers, and
  /// a fixture of silence could not tell them apart.
  private static func writeTone(
    at url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
    settings: [String: Any]? = nil
  ) throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
      interleaved: false)!
    let file = try AVAudioFile(
      forWriting: url, settings: settings ?? format.settings,
      commonFormat: .pcmFormatFloat32, interleaved: false)

    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
      let samples = buffer.floatChannelData![channel]
      for frame in 0..<Int(frames) {
        samples[frame] = 0.25 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
      }
    }
    try file.write(from: buffer)
  }

  /// A movie with a video track and no audio track at all — the "I dragged in the wrong file" case,
  /// and the one that must be refused BY NAME rather than by failing somewhere downstream.
  private static func writeVideoOnly(at url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64,
      ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
    if let pixelBuffer {
      var formatDescription: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription)
      if let formatDescription {
        var timing = CMSampleTimingInfo(
          duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero,
          decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
          allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
          formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, input.isReadyForMoreMediaData { input.append(sample) }
      }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
  }

  // MARK: - The format matrix

  /// Each row is a real container and a real encoder. The assertion is the same for all of them and it
  /// is about the OUTCOME, not about the absence of a throw: the samples come back at the rate the
  /// engines take, in roughly the right quantity for the duration written.
  @Test(
    "every format macOS can decode comes back as 16 kHz mono samples",
    arguments: [
      ("wav", AVFileType.wav, 16_000.0, AVAudioChannelCount(1)),
      ("wav", AVFileType.wav, 48_000.0, AVAudioChannelCount(2)),
      ("aiff", AVFileType.aiff, 44_100.0, AVAudioChannelCount(1)),
      ("caf", AVFileType.caf, 22_050.0, AVAudioChannelCount(2)),
    ])
  func everyFormatDecodesToSixteenKilohertzMono(
    _ ext: String, _ fileType: AVFileType, _ rate: Double, _ channels: AVAudioChannelCount
  ) async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("tone.\(ext)")
    try Self.writeTone(at: url, seconds: 1.0, sampleRate: rate, channels: channels)

    let samples = try await AudioFileDecoder.decode(url: url)

    // One second at 16 kHz. The tolerance is for the resampler's edge frames, not for a wrong rate:
    // a file decoded at its SOURCE rate would land at 44,100 or 48,000 and miss this by miles.
    #expect(
      abs(samples.count - 16_000) < 800,
      "\(ext) at \(rate) Hz / \(channels)ch decoded to \(samples.count) samples, not ~16,000")
    #expect(samples.contains { $0 != 0 }, "the decoded audio is silent; the tone did not survive")
  }

  /// An m4a written through the real AAC encoder, kept separate because its settings are not a
  /// `AVAudioFormat.settings` round trip and a lossy codec's frame count is not exact.
  @Test("a real AAC file decodes")
  func aacDecodes() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("tone.m4a")
    try Self.writeTone(
      at: url, seconds: 1.0, sampleRate: 44_100, channels: 1,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
      ])

    let samples = try await AudioFileDecoder.decode(url: url)

    #expect(abs(samples.count - 16_000) < 2_000)
    #expect(samples.contains { $0 != 0 })
  }

  // MARK: - The refusals, each by name

  @Test("a file with a video track and no audio is refused by name")
  func videoWithoutAudioIsRefused() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("silent.mov")
    try Self.writeVideoOnly(at: url)

    await #expect(throws: AudioFileDecoder.Rejection.noAudioTrack) {
      _ = try await AudioFileDecoder.decode(url: url)
    }
  }

  @Test("a file that is not there is refused")
  func missingFileIsRefused() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    await #expect(throws: AudioFileDecoder.Rejection.unreadable) {
      _ = try await AudioFileDecoder.decode(url: dir.appendingPathComponent("nothing.wav"))
    }
  }

  @Test("a zero-byte file is refused")
  func zeroByteFileIsRefused() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("empty.wav")
    try Data().write(to: url)

    await #expect(throws: AudioFileDecoder.Rejection.unreadable) {
      _ = try await AudioFileDecoder.decode(url: url)
    }
  }

  /// A Keynote deck, a PDF, a photo: a real file that is simply not audio. Modelled as bytes with an
  /// audio extension, which is the harder case — the extension says one thing and the content says
  /// another, and the decoder must believe the content.
  @Test("a file that is not audio at all is refused, whatever its extension says")
  func nonAudioContentIsRefused() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("deck.m4a")
    try Data("this is not audio, it is a sentence".utf8).write(to: url)

    await #expect(throws: AudioFileDecoder.Rejection.self) {
      _ = try await AudioFileDecoder.decode(url: url)
    }
  }

  /// **A truncated file is indistinguishable from a shorter recording**, and this row exists to keep
  /// that documented rather than to guard against it.
  ///
  /// The first version of this suite asserted a refusal, and a guard was written to produce one: compare
  /// the file's declared duration against the samples decoded, and refuse when they disagree. The
  /// measurement killed it. On a 3-second 16 kHz WAV cut to a third of its bytes,
  /// `AVAsset.load(.duration)` returns 0.957 s and the decode returns 15,317 samples, which IS 0.957 s
  /// — AVFoundation derives duration from the bytes present, so the two agree by construction and the
  /// threshold between them could never fire. The guard was removed rather than tuned.
  ///
  /// So the honest property is the one asserted here: a cut file decodes to LESS audio, without
  /// hanging, crashing, or claiming to be the original. A cut that destroys the header is a different
  /// case and IS refused, because the file cannot be opened at all.
  @Test("a truncated file decodes to what is left of it, and says nothing untrue")
  func truncatedFileDecodesShort() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("cut.wav")
    try Self.writeTone(at: url, seconds: 3.0, sampleRate: 16_000, channels: 1)

    let whole = try Data(contentsOf: url)
    try whole.prefix(whole.count / 3).write(to: url)

    let samples = try await AudioFileDecoder.decode(url: url)

    // Roughly a third of three seconds. The assertion is a RANGE, not an equality: the point is that
    // the decoder returns the audio that survived rather than inventing, padding or hanging.
    #expect(samples.count > 8_000 && samples.count < 24_000, "decoded \(samples.count) samples")
    #expect(samples.contains { $0 != 0 })
  }

  /// The other half of the truncation story, and the half that IS refused: a file whose header is gone
  /// cannot be opened, so nothing downstream ever sees it.
  @Test("a file cut inside its header is refused")
  func headerlessFileIsRefused() async throws {
    let dir = try Self.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("headerless.wav")
    try Self.writeTone(at: url, seconds: 3.0, sampleRate: 16_000, channels: 1)

    let whole = try Data(contentsOf: url)
    try whole.suffix(whole.count / 2).write(to: url)

    await #expect(throws: AudioFileDecoder.Rejection.self) {
      _ = try await AudioFileDecoder.decode(url: url)
    }
  }

  // MARK: - Named gaps

  // `mp3` is not covered. macOS decodes it and does not encode it, so covering it needs a committed
  // binary fixture rather than a written one. It is the format users are most likely to bring, so this
  // is a real gap and it is named rather than skipped: Live UAT on #2648 imports a real mp3.
}
