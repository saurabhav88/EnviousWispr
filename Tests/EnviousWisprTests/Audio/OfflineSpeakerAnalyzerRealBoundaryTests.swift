@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

private enum SpeakerAnalyzerFixture {
  static let audioURL = RepoRoot.sourceURL("Tests/Fixtures/speaker-diarization/two-voice-30s.wav")

  static func makeBundle() throws -> Bundle {
    let resourcesRoot = RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OfflineSpeakerAnalyzerRealBoundaryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in [
      ModelNames.OfflineDiarizer.segmentation, ModelNames.OfflineDiarizer.fbank,
      ModelNames.OfflineDiarizer.embedding, ModelNames.OfflineDiarizer.pldaRho,
    ] {
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("\(name).mlmodelc"),
        withDestinationURL: resourcesRoot.appendingPathComponent("SpeakerModels/\(name).mlmodelc"))
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("speaker-plda-parameters.json"),
      withDestinationURL: resourcesRoot.appendingPathComponent("speaker-plda-parameters.json"))
    return try #require(Bundle(path: root.path))
  }
}

/// #2809 chunk 2's binding receipt (addendum §11 row 2): the four bundled models, loaded
/// exactly as the app loads them (never through `ModelHub`), run real inference on a
/// committed two-speaker fixture and tell the speakers apart.
///
/// **What the user sees when this fails:** speaker labels never work on a real recording,
/// even though every unit test with a fake or trivial input passes.
///
/// Structural network-off evidence, not a process-level firewall: `BundledSpeakerModelLoader`
/// never calls `ModelHub` or any networked API (`BundledSpeakerModelLoaderTests` greps for
/// it), and `ModelHub.offlineMode` is asserted unchanged before and after this run — the
/// speaker path is independent of that flag by construction (#1908/#1981).
@Suite("OfflineSpeakerAnalyzer (real models, real audio)", .serialized, .tags(.productOutcome))
struct OfflineSpeakerAnalyzerRealBoundaryTests {

  @Test(
    "tells two real speakers apart on a committed two-voice recording",
    .tags(.realBoundary)
  )
  func distinguishesTwoRealSpeakers() async throws {
    let offlineModeBefore = ModelHub.offlineMode
    defer { #expect(ModelHub.offlineMode == offlineModeBefore) }

    let bundle = try SpeakerAnalyzerFixture.makeBundle()
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: bundle.bundlePath)) }

    let models = try BundledSpeakerModelLoader.load(in: bundle)
    let analyzer = OfflineSpeakerAnalyzer()
    analyzer.initialize(models: models)

    let samples = try AudioConverter().resampleAudioFile(
      path: SpeakerAnalyzerFixture.audioURL.path)

    let segments = try await analyzer.analyze(samples: samples, sampleRate: 16000) { _, _ in }

    let distinctSpeakers = Set(segments.map(\.speakerId))
    #expect(
      distinctSpeakers.count == 2,
      "expected 2 speakers, got \(distinctSpeakers.count): \(segments.map { "\($0.speakerId) \($0.startMs)-\($0.endMs)ms" })"
    )
    #expect(!segments.isEmpty)
  }
}
