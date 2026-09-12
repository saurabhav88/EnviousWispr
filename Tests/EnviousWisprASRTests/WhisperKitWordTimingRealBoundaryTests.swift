import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

private enum WhisperKitRealBoundaryFixture {
  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let audioURL = repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")
  static let tokenizerFolder = repoRoot.appending(
    path: "Sources/EnviousWisprASR/Resources/WhisperTokenizer")

  /// The real installed model directory (`ModelDeliveryHome.swift:310-311`), read the same
  /// way production resolves it: a sibling of `StorageRoot`'s own data directory. A test
  /// naming this out loud, rather than hand-building the path, is what keeps this receipt
  /// tied to what the app actually installs into.
  static var installDirectory: URL {
    StorageRoot.live.dataDirectory.deletingLastPathComponent()
      .appendingPathComponent("EnviousWispr/Models/whisper", isDirectory: true)
  }

  static var shippedModelIsInstalled: Bool {
    FileManager.default.fileExists(
      atPath: installDirectory.appendingPathComponent("AudioEncoder.mlmodelc").path)
  }
}

/// #2809 chunk 1's required premise check, run BEFORE the mapper was wired: does a real
/// WhisperKit batch decode actually return `segments[].words` non-nil when timestamps are
/// requested? The addendum listed this as "SUPPORTED by type... pending real batch
/// evidence." This is that evidence, kept as a standing receipt rather than a one-off.
///
/// **What the user sees when this fails:** speaker labels (phase 4) attributing every
/// WhisperKit-transcribed word to no one, because the timing data the mapper needs never
/// arrived from the engine in the first place.
@Suite("WhisperKit batch decode word timings (real model)", .serialized, .tags(.productOutcome))
struct WhisperKitWordTimingRealBoundaryTests {

  @Test(
    "the shipped WhisperKit model returns non-nil word timings on a real batch decode",
    .enabled(if: WhisperKitRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary)
  )
  func shippedModelReturnsWordTimings() async throws {
    let backend = WhisperKitBackend(
      admittedModelFolder: { WhisperKitRealBoundaryFixture.installDirectory.path },
      tokenizerFolderURL: WhisperKitRealBoundaryFixture.tokenizerFolder)
    let samples = try AudioConverter().resampleAudioFile(
      path: WhisperKitRealBoundaryFixture.audioURL.path)

    try await backend.prepare()
    let result = try await backend.transcribe(audioSamples: samples, options: .default)
    await backend.unload()

    #expect(result.backendType == .whisperKit)
    let wordTimings = try #require(result.wordTimings)
    #expect(!wordTimings.isEmpty)
    let coverage = try #require(result.wordTimingCoverage)
    #expect(coverage.timed > 0, "real batch decode returned no usable word timings")
  }

  @Test(
    "the vendor's own segments carry non-nil words on a real batch decode — the exact premise chunk 1 was gated on",
    .enabled(if: WhisperKitRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary)
  )
  func vendorSegmentsCarryWordsDirectly() async throws {
    let config = WhisperKitBackend.makeWhisperKitConfig(
      model: WhisperKitBackend.defaultModelVariant(),
      modelPath: WhisperKitRealBoundaryFixture.installDirectory.path,
      tokenizerFolderURL: WhisperKitRealBoundaryFixture.tokenizerFolder)
    let kit = try await WhisperKit(config)
    let samples = try AudioConverter().resampleAudioFile(
      path: WhisperKitRealBoundaryFixture.audioURL.path)
    var options = DecodingOptions()
    options.wordTimestamps = true

    let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)

    let segments = results.flatMap(\.segments)
    #expect(!segments.isEmpty)
    for segment in segments {
      #expect(
        segment.words != nil,
        "segment \(segment.id) [\(segment.start)-\(segment.end)] carried no words")
    }
  }
}
