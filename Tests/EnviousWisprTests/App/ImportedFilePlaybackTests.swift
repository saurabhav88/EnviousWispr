import AVFoundation
import CryptoKit
import EnviousWisprASR
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Real media files for the imported-original tests (#3147 PR3), written through real encoders.
enum ImportedMediaFixture {
  enum Kind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case wav16kMono
    case wav48kStereo
    case m4aAAC44kStereo
    case mp4AAC48kStereo

    var testDescription: String { rawValue }
    var fileExtension: String {
      switch self {
      case .wav16kMono, .wav48kStereo: "wav"
      case .m4aAAC44kStereo: "m4a"
      case .mp4AAC48kStereo: "mp4"
      }
    }
    var sampleRate: Double {
      switch self {
      case .wav16kMono: 16_000
      case .m4aAAC44kStereo: 44_100
      case .wav48kStereo, .mp4AAC48kStereo: 48_000
      }
    }
    var channels: AVAudioChannelCount { self == .wav16kMono ? 1 : 2 }
    var isCompressed: Bool { self == .m4aAAC44kStereo || self == .mp4AAC48kStereo }
  }

  static func directory() throws -> URL {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-media-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A sweep with a slow wobble, never periodic over a window, so a misplaced window cannot match.
  /// `seed` changes the signal (a different recording of the same length).
  @discardableResult
  static func write(
    _ kind: Kind, seconds: Double, in dir: URL, name: String = "talk", seed: Float = 0
  ) throws -> URL {
    let url = dir.appendingPathComponent("\(name).\(kind.fileExtension)")
    let rate = kind.sampleRate
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: kind.channels,
      interleaved: false)!
    let settings: [String: Any] =
      kind.isCompressed
      ? [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
        AVNumberOfChannelsKey: kind.channels, AVEncoderBitRateKey: 128_000,
      ]
      : format.settings
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(kind.channels) {
      let out = buffer.floatChannelData![channel]
      for i in 0..<Int(frames) {
        let t = Float(i) / Float(rate)
        let sweep = sin(2 * .pi * (180 + 90 * t + seed * 40) * t)
        let wobble = 0.6 + 0.4 * sin(2 * .pi * 0.7 * t + seed)
        out[i] = 0.3 * sweep * wobble * (channel == 0 ? 1 : 0.8)
      }
    }
    try file.write(from: buffer)
    return url
  }

  /// The file's bytes and modification date, to prove nothing wrote to it.
  static func fingerprint(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let date =
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "\(digest)@\(date?.timeIntervalSince1970 ?? -1)"
  }
}

/// History's player for an imported file's ORIGINAL (#3147 PR3).
///
/// **When this fails, the user presses play on a transcript's time and hears the wrong part of
/// the recording, silence, or nothing, or the app reads a multi-hour file whole.** Product
/// coverage: every fixture is a real file read by the real reader and compared with the real
/// decoder that produced the transcript.
@Suite("Imported file playback (#3147 PR3)", .tags(.productOutcome))
struct ImportedFilePlaybackTests {
  private static func readAll(_ audio: ImportedFilePlaybackAudio, ms: Int, windowMs: Int = 250)
    throws -> [Float]
  {
    var out: [Float] = []
    var at = 0
    while at < ms {
      out += try audio.window(startMs: at, count: windowMs)
      at += windowMs
    }
    return out
  }

  /// Largest sample difference between `window` and the decoder's samples at `startMs`.
  private static func maxDifference(_ window: [Float], _ decoded: [Float], startMs: Int) -> Float {
    let start = startMs * 16
    var worst: Float = 0
    for i in 0..<window.count {
      let expected = start + i < decoded.count ? decoded[start + i] : 0
      worst = max(worst, abs(window[i] - expected))
    }
    return worst
  }

  @Test(
    "sequential windows are exactly the samples the transcript was made from",
    arguments: ImportedMediaFixture.Kind.allCases)
  func sequentialMatchesDecoder(kind: ImportedMediaFixture.Kind) async throws {
    let url = try ImportedMediaFixture.write(
      kind, seconds: 3, in: try ImportedMediaFixture.directory())
    let decoded = try await AudioFileDecoder.decode(url: url).samples
    let audio = try await ImportedFilePlaybackAudio.open(url: url)
    let played = try Self.readAll(audio, ms: audio.durationMs + 500)
    #expect(abs(audio.durationMs - decoded.count / 16) <= 30, "duration \(audio.durationMs) ms")
    #expect(Array(played.prefix(decoded.count)) == decoded)
    #expect(played.dropFirst(decoded.count).allSatisfy { $0 == 0 }, "past the end is silence")
    #expect(audio.readerStarts == 1, "one reader for a front-to-back play")
  }

  @Test(
    "a seek lands on the decoder's samples, backwards and far forward",
    arguments: ImportedMediaFixture.Kind.allCases)
  func seekMatchesDecoder(kind: ImportedMediaFixture.Kind) async throws {
    let url = try ImportedMediaFixture.write(
      kind, seconds: 6, in: try ImportedMediaFixture.directory())
    let decoded = try await AudioFileDecoder.decode(url: url).samples
    let audio = try await ImportedFilePlaybackAudio.open(url: url)
    _ = try audio.window(startMs: 0, count: 250)

    // Far forward (beyond the 2 s read-through), then backwards: each starts a new reader.
    for startMs in [4_000, 1_250, 3_500] {
      let before = audio.readerStarts
      let window = try audio.window(startMs: startMs, count: 250)
      #expect(audio.readerStarts == before + 1, "\(startMs) ms reopened")
      let difference = Self.maxDifference(window, decoded, startMs: startMs)
      // A fresh reader's resampler and AAC decoder start 100 ms early; what is left is filter
      // warm-up, far below the signal (0.3) and far below a misplaced window (measured ~0.3+).
      #expect(
        difference < (kind.isCompressed ? 0.02 : 0.005), "\(startMs) ms differs by \(difference)")
      // The next window continues the same reader exactly.
      let next = try audio.window(startMs: startMs + 250, count: 250)
      #expect(audio.readerStarts == before + 1)
      #expect(
        Self.maxDifference(next, decoded, startMs: startMs + 250)
          < (kind.isCompressed ? 0.02 : 0.005))
    }

    // A short jump ahead reads through instead of reopening.
    let before = audio.readerStarts
    _ = try audio.window(startMs: 4_750, count: 250)
    #expect(audio.readerStarts == before)
  }

  @Test("reading, seeking and closing never write to the original file")
  func neverWritesTheSource() async throws {
    let url = try ImportedMediaFixture.write(
      .m4aAAC44kStereo, seconds: 4, in: try ImportedMediaFixture.directory())
    let before = try ImportedMediaFixture.fingerprint(of: url)
    let audio = try await ImportedFilePlaybackAudio.open(url: url)
    _ = try Self.readAll(audio, ms: 1_000)
    _ = try audio.window(startMs: 3_000, count: 250)
    _ = try audio.window(startMs: 500, count: 250)
    audio.close()
    #expect(throws: ImportedFilePlaybackAudio.Failure.unreadable) {
      try audio.window(startMs: 0, count: 250)
    }
    #expect(try ImportedMediaFixture.fingerprint(of: url) == before)
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    #expect(siblings == [url.lastPathComponent], "no copy or side file appeared")
  }

  @Test("a file that is not audio is refused; a missing one too")
  func refusesNonAudio() async throws {
    let dir = try ImportedMediaFixture.directory()
    let text = dir.appendingPathComponent("notes.m4a")
    try Data("not audio".utf8).write(to: text)
    await #expect(throws: ImportedFilePlaybackAudio.Failure.self) {
      _ = try await ImportedFilePlaybackAudio.open(url: text)
    }
    await #expect(throws: ImportedFilePlaybackAudio.Failure.self) {
      _ = try await ImportedFilePlaybackAudio.open(url: dir.appendingPathComponent("gone.wav"))
    }
  }

  @Test("opening stops when its task is cancelled")
  func openHonorsCancellation() async throws {
    let url = try ImportedMediaFixture.write(
      .wav16kMono, seconds: 1, in: try ImportedMediaFixture.directory())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ImportedFilePlaybackAudio.open(url: url)
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
  }

  // MARK: - Measurement (opt-in)

  /// Seek latency and memory on a LONG original. Not a product guard: a measurement printed for
  /// the PR receipt. Runs only in the real-boundary run, with
  /// `TEST_RUNNER_EW_LONG_MEDIA=<file>[:<file>...]` naming isolated generated files.
  @Test(
    "long-file seek latency and memory (measurement)", .tags(.realBoundary), .realBoundaryRun,
    .enabled(if: ProcessInfo.processInfo.environment["EW_LONG_MEDIA"] != nil))
  func longFileMeasurement() async throws {
    let paths = (ProcessInfo.processInfo.environment["EW_LONG_MEDIA"] ?? "").split(separator: ":")
    for path in paths {
      let url = URL(fileURLWithPath: String(path))
      let footprintBefore = Self.physicalFootprint()
      let openStart = ContinuousClock.now
      let audio = try await ImportedFilePlaybackAudio.open(url: url)
      let openTime = ContinuousClock.now - openStart
      var latencies: [Duration] = []
      var peak = Self.physicalFootprint()
      var generator = SystemRandomNumberGenerator()
      let starts =
        [audio.durationMs - 1_000, 0, audio.durationMs / 2, 1_000]
        + (0..<16).map { _ in
          Int.random(in: 0..<max(1, audio.durationMs - 1_000), using: &generator)
        }
      for startMs in starts {
        let begin = ContinuousClock.now
        let window = try audio.window(startMs: startMs, count: 250)
        latencies.append(ContinuousClock.now - begin)
        #expect(window.count == 4_000)
        // Then a few sequential windows, as playback continues.
        for step in 1...8 { _ = try audio.window(startMs: startMs + step * 250, count: 250) }
        peak = max(peak, Self.physicalFootprint())
      }
      let sorted = latencies.map {
        Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1_000
      }.sorted()
      let p50 = sorted[sorted.count / 2]
      let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
      let line =
        "LONG-MEDIA \(url.lastPathComponent) durationMs=\(audio.durationMs) open=\(openTime) seeks=\(sorted.count) p50Ms=\(String(format: "%.1f", p50)) p95Ms=\(String(format: "%.1f", p95)) maxMs=\(String(format: "%.1f", sorted.last ?? 0)) footprintBeforeMB=\(footprintBefore / 1_048_576) peakMB=\(peak / 1_048_576) growthMB=\((peak - footprintBefore) / 1_048_576)"
      print(line)
      if let out = ProcessInfo.processInfo.environment["EW_LONG_MEDIA_OUT"] {
        let handle =
          FileHandle(forWritingAtPath: out)
          ?? {
            FileManager.default.createFile(atPath: out, contents: nil)
            return FileHandle(forWritingAtPath: out)!
          }()
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try handle.close()
      }
      audio.close()
    }
  }

  private static func physicalFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
  }
}
