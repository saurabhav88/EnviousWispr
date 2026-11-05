@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #4355 PR C: the live meeting speaker model (Nemotron3 diarizer, preset `low`).
///
/// When this fails, EnviousMeet's "Speaker labels" download either refuses at launch
/// (a manifest the production loader rejects disables the model for every user) or admits
/// a folder FluidAudio's local loader cannot open (`Nemotron3Models.load(config:directory:)`
/// reads `<modelFileName>` and `learnable_sil_emb.bin` from one directory), so live
/// speakers never appear. The expected names come from the pinned FluidAudio, not from
/// the manifest, so a preset or layout change on either side turns this red.
@Suite(.tags(.driftGuard)) struct SpeakerLiveManifestTests {
  static let revision = "25a90f97f254428d4b30374b76af9c74fdee8327"

  static func load() throws -> (manifest: DeliveryManifest, data: Data) {
    let url = ParakeetShippedManifestTests.repoRoot.appendingPathComponent(
      "Sources/EnviousWispr/Resources/speaker-live-delivery-manifest.json")
    let data = try Data(contentsOf: url)
    return (try DeliveryManifest.load(from: data), data)
  }

  @Test func loadsThroughProductionValidationWithItsIdentity() throws {
    let (manifest, data) = try Self.load()
    #expect(try DeliveryManifest.canonicalDigest(of: data) == manifest.manifestDigest)
    #expect(manifest.identity.family == .speakerLive)
    #expect(manifest.identity.name == "nemotron-3-diarization-coreml")
    #expect(manifest.identity.revision == Self.revision)
    #expect(manifest.identity.variant == "low-v2")
    #expect(manifest.identity.runtimeABI == "fluidAudio-fb506037")
    // The loader does not decode `license`; read it raw so the licence the notices name stays put.
    let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect((raw?["license"] as? [String: Any])?["name"] as? String == "OpenMDW-1.1")
    #expect(manifest.files.count == 5)
    #expect(manifest.totalBytes == 199_124_357)
  }

  /// Mirror first, then the immutable Hugging Face revision; both serve the publisher's
  /// layout, so one `path` resolves on either source.
  @Test func sourcesAreOurMirrorThenThePinnedRevision() throws {
    let manifest = try Self.load().manifest
    #expect(manifest.sources.map(\.id) == ["our_copy", "hf_pinned"])
    #expect(
      manifest.sources.map(\.baseURL.absoluteString) == [
        "https://models.enviouswispr.com/speaker-live/FluidInference/nemotron-3-diarization-coreml/\(Self.revision)/",
        "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/resolve/\(Self.revision)/",
      ])
  }

  /// The installed folder is exactly what the pinned loader opens for the `low` preset,
  /// and each file is fetched from the publisher's path for that preset's bundle.
  @Test func installLayoutMatchesThePinnedLoaderForTheLowPreset() throws {
    let manifest = try Self.load().manifest
    let config = Nemotron3Config.low
    #expect(config.numSpeakers == 8)
    #expect(config.splitGraph == false, "a split-graph preset also needs pre_encode_proj_t.bin")
    let bundle = config.modelFileName
    let expected: [String: String] = [
      ModelNames.Nemotron3.silenceEmbeddingFile: ModelNames.Nemotron3.silenceEmbeddingFile,
      "\(bundle)/coremldata.bin": "\(config.hubSubdirectory)/\(bundle)/coremldata.bin",
      "\(bundle)/model.mil": "\(config.hubSubdirectory)/\(bundle)/model.mil",
      "\(bundle)/weights/weight.bin": "\(config.hubSubdirectory)/\(bundle)/weights/weight.bin",
      "\(bundle)/analytics/coremldata.bin":
        "\(config.hubSubdirectory)/\(bundle)/analytics/coremldata.bin",
    ]
    let actual = Dictionary(
      uniqueKeysWithValues: manifest.files.map { ($0.resolvedInstallPath, $0.path) })
    #expect(actual == expected)
    #expect(manifest.admission.entrypointFile == "\(bundle)/coremldata.bin")
  }
}
