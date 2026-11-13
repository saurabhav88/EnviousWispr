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

  /// Seeded band-limited noise, so a misplaced window cannot match.
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
    // Band-limited noise (two one-pole low-passes at 1 kHz over a seeded generator): it never
    // repeats, so a window matches the decoder at exactly one lag, unlike a tone, which matches
    // again one period away.
    var state = UInt64(0x9E37_79B9_7F4A_7C15) &+ UInt64(seed * 1_000)
    let alpha = 1 - exp(-2 * Float.pi * 1_000 / Float(rate))
    var low1: Float = 0
    var low2: Float = 0
    var signal = [Float](repeating: 0, count: Int(frames))
    for i in 0..<Int(frames) {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let white = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
      low1 += alpha * (white - low1)
      low2 += alpha * (low1 - low2)
      signal[i] = max(-0.9, min(0.9, 1.2 * low2))
    }
    for channel in 0..<Int(kind.channels) {
      let out = buffer.floatChannelData![channel]
      for i in 0..<Int(frames) { out[i] = signal[i] * (channel == 0 ? 1 : 0.8) }
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

  /// Where `window` sits against the decoder's samples: the lag (in 16 kHz samples, within
  /// +/-32) at which they correlate best, and that correlation.
  ///
  /// Why not equal samples: Apple's reader is not reproducible between two of its OWN reads of
  /// one converted file. Measured on this fixture: two plain full decodes of one 48 kHz WAV
  /// differed by up to 0.17 and by one sample in length, from a buffer boundary on (every run);
  /// one AAC file differed by up to 0.07 in about half the runs. The decoder that made the
  /// transcript has the same variation, so the user-visible question is whether a window lands
  /// at the right time: within two samples (0.125 ms), never one millisecond (16) off.
  static func alignment(_ window: [Float], _ decoded: [Float], startSample: Int) -> (
    lag: Int, correlation: Float
  ) {
    var best = (lag: 0, correlation: -Float.infinity)
    for lag in -32...32 {
      var dot: Float = 0
      var windowEnergy: Float = 0
      var decodedEnergy: Float = 0
      for i in 0..<window.count {
        let j = startSample + i + lag
        let d = j >= 0 && j < decoded.count ? decoded[j] : 0
        dot += window[i] * d
        windowEnergy += window[i] * window[i]
        decodedEnergy += d * d
      }
      let correlation =
        windowEnergy > 0 && decodedEnergy > 0 ? dot / (windowEnergy * decodedEnergy).squareRoot() : 0
      if correlation > best.correlation { best = (lag, correlation) }
    }
    return best
  }

  /// `window` (played from file sample `startSample`) is the decoder's audio at that time.
  private static func expectAligned(
    _ window: [Float], _ decoded: [Float], startSample: Int, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let found = alignment(window, decoded, startSample: startSample)
    #expect(abs(found.lag) <= 2, "\(label): lag \(found.lag)", sourceLocation: sourceLocation)
    #expect(found.correlation > 0.95, "\(label): correlation \(found.correlation)", sourceLocation: sourceLocation)
    // Control: the same check reads a window one millisecond off as one millisecond off.
    let misplaced = alignment(window, decoded, startSample: startSample + 16)
    #expect(abs(misplaced.lag + 16) <= 2, "\(label) control: lag \(misplaced.lag)", sourceLocation: sourceLocation)
  }

  @Test(
    "front-to-back play is the audio the transcript was made from, at the right time",
    arguments: ImportedMediaFixture.Kind.allCases)
  func sequentialMatchesDecoder(kind: ImportedMediaFixture.Kind) async throws {
    let url = try ImportedMediaFixture.write(
      kind, seconds: 3, in: try ImportedMediaFixture.directory())
    let decoded = try await AudioFileDecoder.decode(url: url).samples
    let audio = try await ImportedFilePlaybackAudio.open(url: url)
    let played = try Self.readAll(audio, ms: audio.durationMs + 500)
    #expect(abs(audio.durationMs - decoded.count / 16) <= 30, "duration \(audio.durationMs) ms")
    if kind == .wav16kMono {
      // No conversion at all: bit for bit.
      #expect(Array(played.prefix(decoded.count)) == decoded)
    }
    var start = 0
    while start + 4_000 + 32 <= decoded.count {
      Self.expectAligned(
        Array(played[start..<start + 4_000]), decoded, startSample: start, "\(start / 16) ms")
      start += 4_000
    }
    #expect(played.dropFirst(decoded.count + 2).allSatisfy { $0 == 0 }, "past the end is silence")
    #expect(audio.readerStarts == 1, "one reader for a front-to-back play")
  }

  @Test(
    "a seek lands on the decoder's audio at the right time, backwards and far forward",
    arguments: ImportedMediaFixture.Kind.allCases)
  func seekMatchesDecoder(kind: ImportedMediaFixture.Kind) async throws {
    let url = try ImportedMediaFixture.write(
      kind, seconds: 6, in: try ImportedMediaFixture.directory())
    let decoded = try await AudioFileDecoder.decode(url: url).samples
    let audio = try await ImportedFilePlaybackAudio.open(url: url)
    _ = try audio.window(startMs: 0, count: 250)

    // Far forward (beyond the 2 s read-through), then backwards: each starts a new reader,
    // 100 ms early so the decoder is warm at the target.
    for startMs in [4_000, 1_250, 5_000] {
      let before = audio.readerStarts
      let window = try audio.window(startMs: startMs, count: 250)
      #expect(audio.readerStarts == before + 1, "\(startMs) ms reopened")
      Self.expectAligned(window, decoded, startSample: startMs * 16, "seek \(startMs) ms")
      // The next window continues the same reader.
      let next = try audio.window(startMs: startMs + 250, count: 250)
      #expect(audio.readerStarts == before + 1)
      Self.expectAligned(next, decoded, startSample: (startMs + 250) * 16, "after \(startMs) ms")
    }

    // A short jump ahead reads through instead of reopening.
    let before = audio.readerStarts
    _ = try audio.window(startMs: 5_750, count: 250)
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

  @Test("a seek after the original changed on disk stops instead of playing different audio")
  func seekAfterSourceChangedStops() async throws {
    let dir = try ImportedMediaFixture.directory()
    let url = try ImportedMediaFixture.write(.wav16kMono, seconds: 6, in: dir)
    let audio = try await ImportedFilePlaybackAudio.open(url: url)
    _ = try audio.window(startMs: 0, count: 250)
    // Another app saves a different recording over it (same name, same length).
    try ImportedMediaFixture.write(.wav16kMono, seconds: 6, in: dir, seed: 3)
    #expect(throws: ImportedFilePlaybackAudio.Failure.sourceChanged) {
      try audio.window(startMs: 4_000, count: 250)
    }
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
