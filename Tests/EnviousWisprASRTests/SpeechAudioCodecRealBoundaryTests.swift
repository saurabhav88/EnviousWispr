import AVFoundation
import CryptoKit
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
import EnviousWisprAudio
@testable import EnviousWisprTranscribeCpp

/// #3147 P1-0: can History keep a compressed copy of every dictation and meeting without
/// hurting what the speech engines hear?
///
/// **What the user sees when this fails:** saved recordings either fill the disk much faster than
/// promised, or playing or re-transcribing a saved recording gives worse words than the live take.
///
/// This chunk only MEASURES Apple's AAC-LC encoder at 16 kHz mono (32 kbps for dictations, 48 kbps
/// for meeting tracks). It never authorizes deleting original meeting audio: that gate is #3147
/// PR4 (plan §16 C6), after every meeting reader understands compressed audio. Each test prints
/// one `P10-CODEC` line per measurement for the receipt.
private enum SpeechCodecFixture {
  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let dictationBitRate = SpeechAudioEncoder.Purpose.dictation.bitRate
  static let meetingBitRate = SpeechAudioEncoder.Purpose.meeting.bitRate

  /// Plan §3a acceptance targets, in decimal MB per hour of audio.
  static let dictationMBPerHourLimit = 16.0
  static let meetingMBPerHourLimit = 25.0
  static let durationToleranceSeconds = 0.050
  /// Plan §3a "Transcribe-again parity" (feeding §16 C6): MEETING audio at the chosen bitrate may
  /// cost at most half a percentage point of WER per engine. The plan sets no WER gate for
  /// dictation recordings (size only), so the dictation bitrate is measured and printed, not gated.
  /// This gate bounds the absolute change in pooled WER.
  /// Equal WER does not establish identical words or prevent offsetting errors.
  /// The authoritative parity score is the eval scorer (`wer` in
  /// `scripts/eval/build_parakeet_corpus.py`) run over the printed `P10-CODEC raw` lines.
  static let werDeltaLimitPoints = 0.5

  struct Clip: Sendable {
    let id: String
    let url: URL
    let reference: String
    /// The language both engines are told, identical for the original and compressed take.
    let language: String
    let sha256: String?
  }

  /// Committed speech with a committed reference: the dictation clip, the three meeting clips
  /// whose manifest gives a reference (quiet speaker, soft onset, speech over music and noise),
  /// and the three non-English language-lock clips.
  static func clips() throws -> [Clip] {
    var clips = [
      Clip(
        id: "normal-speech",
        url: repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav"),
        reference:
          "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills",
        language: "en", sha256: nil)
    ]
    let meetingDir = repoRoot.appending(path: "Tests/Fixtures/meeting-voices")
    let manifest = try JSONDecoder().decode(
      [MeetingManifestEntry].self,
      from: Data(contentsOf: meetingDir.appending(path: "manifest.json")))
    for id in ["quiet-beside-loud", "soft-onset-and-ending", "speech-over-music-and-noise"] {
      let entry = try #require(manifest.first { $0.id == id }, "meeting fixture \(id) missing")
      let reference = try #require(entry.reference, "meeting fixture \(id) has no reference")
      clips.append(
        Clip(
          id: id, url: meetingDir.appending(path: entry.file), reference: reference, language: "en",
          sha256: entry.sha256))
    }
    let lockDir = repoRoot.appending(path: "Tests/Fixtures/language-lock")
    let lock = try JSONDecoder().decode(
      [String: LockEntry].self, from: Data(contentsOf: lockDir.appending(path: "lock-clips.json")))
    for code in ["cs", "el", "ru"] {
      let entry = try #require(lock[code], "language-lock fixture \(code) missing")
      clips.append(
        Clip(
          id: "lock-\(code)", url: lockDir.appending(path: "lock-\(code).wav"),
          reference: entry.text,
          language: code, sha256: nil))
    }
    return clips
  }

  struct MeetingManifestEntry: Decodable {
    let id: String
    let reference: String?
    let file: String
    let sha256: String
  }

  struct LockEntry: Decodable { let text: String }

  static func verifyHash(_ clip: Clip) throws {
    guard let expected = clip.sha256 else { return }
    let digest = SHA256.hash(data: try Data(contentsOf: clip.url)).map {
      String(format: "%02x", $0)
    }
    .joined()
    try #require(digest == expected, "\(clip.id) does not match its manifest hash")
  }

  static func normalizedWords(_ text: String) -> String {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }

  static func referenceWordCount(_ text: String) -> Int {
    normalizedWords(text).split(separator: " ").count
  }

  /// Word errors (not a rate), so several clips can be pooled by reference word count.
  static func wordErrors(reference: String, hypothesis: String) -> Double {
    let rate = WERCalculator.calculate(
      reference: normalizedWords(reference), hypothesis: normalizedWords(hypothesis)
    ).wer
    return rate * Double(referenceWordCount(reference))
  }

  static func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "ew-p10-codec-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  struct Encoded {
    let url: URL
    let bytes: Int
    let formatID: AudioFormatID
    let sampleRate: Double
    let channels: AVAudioChannelCount
    /// Frames the file reports after the encoder's priming and remainder frames are removed.
    let fileFrames: AVAudioFramePosition
  }

  /// The production encoder (#3147 Chunk 2), so these measurements describe what ships. It
  /// verifies the decoded length itself; the file is reopened here to record what it wrote.
  static func encode(_ samples: [Float], bitRate: Int, to url: URL) throws -> Encoded {
    let purpose: SpeechAudioEncoder.Purpose = bitRate == dictationBitRate ? .dictation : .meeting
    try #require(purpose.bitRate == bitRate, "no production purpose encodes at \(bitRate) bps")
    let output = try SpeechAudioEncoder.encode(samples: samples, purpose: purpose, to: url)
    let reader = try AVAudioFile(forReading: url)
    return Encoded(
      url: url, bytes: Int(output.bytes),
      formatID: reader.fileFormat.streamDescription.pointee.mFormatID,
      sampleRate: reader.fileFormat.sampleRate,
      channels: reader.fileFormat.channelCount,
      fileFrames: reader.length)
  }

  /// The app's own file decoder (Transcribe a File), so the compressed take reaches the engines
  /// through the same 16 kHz mono path a saved recording would.
  static func decode(_ url: URL) async throws -> [Float] {
    try await AudioFileDecoder.decode(url: url).samples
  }

  static func mbPerHour(bytes: Int, seconds: Double) -> Double {
    Double(bytes) / seconds * 3_600 / 1_000_000
  }
}

@Suite(
  "#3147 P1-0 compressed speech audio", .serialized, .tags(.productOutcome, .audioDeviceFree))
struct SpeechAudioCodecRealBoundaryTests {

  /// Size and duration at one bitrate. Size is projected from a ten-minute take made by
  /// concatenating every fixture, so the file's fixed header does not dominate the hourly figure;
  /// the per-file header is reported separately because it is what a short dictation pays.
  @Test(
    "AAC-LC at 16 kHz mono keeps duration and fits the storage target",
    .tags(.realBoundary), .realBoundaryRun,
    arguments: [
      (SpeechCodecFixture.dictationBitRate, SpeechCodecFixture.dictationMBPerHourLimit),
      (SpeechCodecFixture.meetingBitRate, SpeechCodecFixture.meetingMBPerHourLimit),
    ]
  )
  func encodesWithinSizeAndDuration(bitRate: Int, limitMBPerHour: Double) async throws {
    let dir = try SpeechCodecFixture.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    var allSpeech: [Float] = []
    for clip in try SpeechCodecFixture.clips() {
      try SpeechCodecFixture.verifyHash(clip)
      let source = try await SpeechCodecFixture.decode(clip.url)
      try #require(!source.isEmpty, "\(clip.id) decoded to no samples")
      allSpeech.append(contentsOf: source)

      let encoded = try SpeechCodecFixture.encode(
        source, bitRate: bitRate, to: dir.appending(path: "\(clip.id)-\(bitRate).m4a"))
      #expect(encoded.formatID == kAudioFormatMPEG4AAC, "\(clip.id): not AAC-LC")
      #expect(encoded.sampleRate == 16_000, "\(clip.id): wrote \(encoded.sampleRate) Hz")
      #expect(encoded.channels == 1, "\(clip.id): wrote \(encoded.channels) channels")

      let decoded = try await SpeechCodecFixture.decode(encoded.url)
      let sourceSeconds = Double(source.count) / 16_000
      let decodedSeconds = Double(decoded.count) / 16_000
      let errorSeconds = abs(decodedSeconds - sourceSeconds)
      print(
        "P10-CODEC duration clip=\(clip.id) bitrate=\(bitRate) sourceSamples=\(source.count) "
          + "fileFrames=\(encoded.fileFrames) decodedSamples=\(decoded.count) "
          + "errorMs=\(String(format: "%.2f", errorSeconds * 1_000)) bytes=\(encoded.bytes)")
      #expect(
        errorSeconds <= SpeechCodecFixture.durationToleranceSeconds,
        "\(clip.id) at \(bitRate) bps: decoded duration off by \(errorSeconds * 1_000) ms")
    }

    let tenMinutes = 600 * 16_000
    var long: [Float] = []
    long.reserveCapacity(tenMinutes)
    while long.count < tenMinutes {
      long.append(contentsOf: allSpeech.prefix(tenMinutes - long.count))
    }
    let longFile = try SpeechCodecFixture.encode(
      long, bitRate: bitRate, to: dir.appending(path: "ten-minutes-\(bitRate).m4a"))
    let tenMinuteMBPerHour = SpeechCodecFixture.mbPerHour(bytes: longFile.bytes, seconds: 600)

    let empty = try SpeechCodecFixture.encode(
      Array(repeating: 0, count: 1_600), bitRate: bitRate,
      to: dir.appending(path: "tenth-second-\(bitRate).m4a"))
    print(
      "P10-CODEC size bitrate=\(bitRate) tenMinuteBytes=\(longFile.bytes) "
        + "projectedMBPerHour=\(String(format: "%.2f", tenMinuteMBPerHour)) "
        + "limitMBPerHour=\(limitMBPerHour) tenthSecondFileBytes=\(empty.bytes) "
        + "(fixture-based projection)")
    #expect(
      tenMinuteMBPerHour <= limitMBPerHour,
      "\(bitRate) bps projects to \(tenMinuteMBPerHour) MB per hour, over \(limitMBPerHour)")
  }

  /// Parakeet Ultra, the shipped default engine (#3546): the compressed take must not cost more than half a point of WER.
  @Test(
    "Parakeet hears compressed speech as well as the original",
    .enabled(if: ParakeetRealBoundaryFixture.ultraIsInstalled),
    .tags(.realBoundary), .realBoundaryRun
  )
  func parakeetWERHolds() async throws {
    try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          selection: ParakeetModelSelection(
            model: .ultra, revision: nil, directory: ParakeetRealBoundaryFixture.ultraInstallDirectory,
            cacheOnly: true, displayBytes: ParakeetModel.v3ShippedBytes, repairable: false,
            generation: 1),
          progressCallback: nil)
        try await Self.compareWER(engine: "parakeet") { samples, _ in
          let result = try await backend.transcribe(audioSamples: samples, options: .default)
          #expect(result.backendType == .parakeet)
          return result.text
        }
        await backend.unload()
      } catch {
        await backend.unload()
        throw error
      }
    }
  }

  /// Whisper (transcribe.cpp turbo), the second engine, told each clip's language.
  @Test(
    "Whisper hears compressed speech as well as the original",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary), .realBoundaryRun
  )
  func whisperWERHolds() async throws {
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let executor = TranscribeCppExecutor()
    let model = try await executor.load(modelPath: TranscribeCppRealBoundaryFixture.modelPath, lane: .heart)
    do {
      try await Self.compareWER(engine: "whisper") { samples, language in
        try await executor.transcribe(model, samples: samples, language: language, lane: .heart)
          .text
      }
      await executor.unload(model)
    } catch {
      await executor.unload(model)
      throw error
    }
  }

  /// Runs every clip through `transcribe` as the original and as each compressed bitrate, with
  /// identical options within each pair, and pools word errors over all reference words.
  private static func compareWER(
    engine: String, transcribe: (_ samples: [Float], _ language: String) async throws -> String
  ) async throws {
    let dir = try SpeechCodecFixture.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clips = try SpeechCodecFixture.clips()
    let bitRates = [SpeechCodecFixture.dictationBitRate, SpeechCodecFixture.meetingBitRate]
    var referenceWords = 0
    var originalErrors = 0.0
    var compressedErrors: [Int: Double] = [:]

    for clip in clips {
      try SpeechCodecFixture.verifyHash(clip)
      let source = try await SpeechCodecFixture.decode(clip.url)
      let words = SpeechCodecFixture.referenceWordCount(clip.reference)
      try #require(words > 0, "\(clip.id) has an empty reference")
      referenceWords += words

      let original = try await transcribe(source, clip.language)
      let originalClipErrors = SpeechCodecFixture.wordErrors(
        reference: clip.reference, hypothesis: original)
      originalErrors += originalClipErrors

      for bitRate in bitRates {
        let encoded = try SpeechCodecFixture.encode(
          source, bitRate: bitRate, to: dir.appending(path: "\(clip.id)-\(bitRate).m4a"))
        let decoded = try await SpeechCodecFixture.decode(encoded.url)
        let compressed = try await transcribe(decoded, clip.language)
        let clipErrors = SpeechCodecFixture.wordErrors(
          reference: clip.reference, hypothesis: compressed)
        compressedErrors[bitRate, default: 0] += clipErrors
        print(
          "P10-CODEC wer engine=\(engine) clip=\(clip.id) bitrate=\(bitRate) words=\(words) "
            + "originalErrors=\(Int(originalClipErrors.rounded())) "
            + "compressedErrors=\(Int(clipErrors.rounded())) "
            + "sameText=\(SpeechCodecFixture.normalizedWords(original) == SpeechCodecFixture.normalizedWords(compressed))"
        )
        // Raw strings (committed fixture text only, never user speech) for the eval scorer.
        let raw = try JSONEncoder().encode([
          "engine": engine, "clip": clip.id, "bitrate": String(bitRate),
          "reference": clip.reference, "original": original, "compressed": compressed,
        ])
        print("P10-CODEC raw \(String(decoding: raw, as: UTF8.self))")
        if SpeechCodecFixture.normalizedWords(original) != SpeechCodecFixture.normalizedWords(compressed) {
          // Committed fixture text only, never user speech.
          print(
            "P10-CODEC diff engine=\(engine) clip=\(clip.id) bitrate=\(bitRate) "
              + "original=\(original) compressed=\(compressed)")
        }
      }
    }

    try #require(referenceWords > 0)
    let originalWER = originalErrors / Double(referenceWords) * 100
    for bitRate in bitRates {
      let compressedWER = (compressedErrors[bitRate] ?? .nan) / Double(referenceWords) * 100
      let delta = compressedWER - originalWER
      print(
        "P10-CODEC wer-total engine=\(engine) bitrate=\(bitRate) clips=\(clips.count) "
          + "referenceWords=\(referenceWords) originalWER=\(String(format: "%.2f", originalWER)) "
          + "compressedWER=\(String(format: "%.2f", compressedWER)) "
          + "deltaPoints=\(String(format: "%.2f", delta))")
      if bitRate == SpeechCodecFixture.meetingBitRate {
        #expect(
          abs(delta) <= SpeechCodecFixture.werDeltaLimitPoints,
          "\(engine) at \(bitRate) bps: WER \(compressedWER)% vs original \(originalWER)%")
      }
    }
  }
}
