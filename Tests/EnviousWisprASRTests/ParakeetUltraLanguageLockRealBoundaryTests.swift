@preconcurrency import AVFoundation
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

/// #3546 Chunk 12: a language lock on the shipped Parakeet Ultra model, on both decode paths,
/// with real audio (Azure neural voices; `docs/audits/3546-ship/chunk12/make_language_fixtures.py`,
/// text in `Tests/Fixtures/language-lock/lock-clips.json`).
///
/// **What the user sees when this fails:** with Greek or Russian selected in Settings, their
/// dictation comes back in the wrong alphabet, or a Czech lock returns English-looking text.
///
/// Proves the script each lock produces on these clips, not accuracy in those languages.
/// Runs on a developer machine with Ultra installed; skipped on hosted CI.
@Suite("Parakeet Ultra language lock (real model)", .serialized, .tags(.productOutcome))
struct ParakeetUltraLanguageLockRealBoundaryTests {

  enum Script { case greek, cyrillic, latin }

  static func clip(_ language: String) throws -> [Float] {
    try AudioConverter().resampleAudioFile(
      path: ParakeetRealBoundaryFixture.repoRoot
        .appending(path: "Tests/Fixtures/language-lock/lock-\(language).wav").path)
  }

  /// Letters only, so punctuation and digits never decide.
  static func letters(_ text: String) -> [Unicode.Scalar] {
    text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
  }

  static func isOnly(_ script: Script, _ text: String) -> Bool {
    let letters = letters(text)
    guard !letters.isEmpty else { return false }
    return letters.allSatisfy { scalar in
      switch script {
      case .greek:
        return (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value)
      case .cyrillic: return (0x0400...0x04FF).contains(scalar.value)
      case .latin: return scalar.value < 0x0250
      }
    }
  }

  static func withUltra<T: Sendable>(
    _ body: @Sendable (ParakeetBackend) async throws -> T
  ) async throws -> T {
    try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          selection: ParakeetModelSelection(
            model: .ultra, revision: nil,
            directory: ParakeetRealBoundaryFixture.ultraInstallDirectory, cacheOnly: true,
            displayBytes: ParakeetModel.v3ShippedBytes, repairable: false, generation: 1),
          progressCallback: nil)
        let value = try await body(backend)
        await backend.unload()
        return value
      } catch {
        await backend.unload()
        throw error
      }
    }
  }

  /// The live path: the same samples fed as 100 ms buffers, then finalized.
  static func stream(_ samples: [Float], language: String, on backend: ParakeetBackend)
    async throws -> String
  {
    try await backend.startStreaming(options: TranscriptionOptions(language: language))
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
    var offset = 0
    while offset < samples.count {
      let count = min(1600, samples.count - offset)
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
      buffer.frameLength = AVAudioFrameCount(count)
      samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
      }
      try await backend.feedAudio(buffer)
      offset += count
    }
    return try await backend.finalizeStreaming().text
  }

  static let cases: [(language: String, script: Script)] = [
    ("el", .greek), ("ru", .cyrillic), ("cs", .latin),
  ]

  @Test(
    "a lock keeps Ultra's batch output in the locked language's alphabet",
    .enabled(if: ParakeetRealBoundaryFixture.ultraIsInstalled),
    .tags(.realBoundary))
  func batchLockHoldsTheScript() async throws {
    let outputs = try await Self.withUltra { backend in
      var outputs: [String: String] = [:]
      for (language, _) in Self.cases {
        let samples = try Self.clip(language)
        outputs[language] = try await backend.transcribe(
          audioSamples: samples, options: TranscriptionOptions(language: language)
        ).text
      }
      return outputs
    }
    for (language, script) in Self.cases {
      let text = outputs[language] ?? ""
      #expect(Self.isOnly(script, text), "\(language) batch returned: \(text)")
    }
    #expect(outputs["cs"]?.contains("ráno") == true, "cs batch returned: \(outputs["cs"] ?? "")")
  }

  @Test(
    "a lock keeps Ultra's live output in the locked language's alphabet",
    .enabled(if: ParakeetRealBoundaryFixture.ultraIsInstalled),
    .tags(.realBoundary))
  func liveLockHoldsTheScript() async throws {
    let outputs = try await Self.withUltra { backend in
      var outputs: [String: String] = [:]
      for (language, _) in Self.cases {
        outputs[language] = try await Self.stream(
          try Self.clip(language), language: language, on: backend)
      }
      return outputs
    }
    for (language, script) in Self.cases {
      let text = outputs[language] ?? ""
      #expect(Self.isOnly(script, text), "\(language) live returned: \(text)")
    }
  }

  @Test(
    "Auto and an unsupported code both decode without a lock",
    .enabled(if: ParakeetRealBoundaryFixture.ultraIsInstalled),
    .tags(.realBoundary))
  func autoAndUnsupportedDecode() async throws {
    // `sr` is in the vendor enum but not claimed by the model card: it must fall back to Auto,
    // so it decodes exactly like no language at all.
    let (auto, unsupported) = try await Self.withUltra { backend in
      let samples = try Self.clip("ru")
      let auto = try await backend.transcribe(audioSamples: samples, options: .default).text
      let unsupported = try await backend.transcribe(
        audioSamples: samples, options: TranscriptionOptions(language: "sr")
      ).text
      return (auto, unsupported)
    }
    #expect(!Self.letters(auto).isEmpty, "Auto returned no words")
    #expect(unsupported == auto, "an unclaimed code decoded differently from Auto")
  }
}
