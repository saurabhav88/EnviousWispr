@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2809 — the four names `BundledSpeakerModelLoader` asks for, and the bundled resources
/// they must resolve to, are pinned. A drift guard, not product coverage: it fails when we
/// (or a dependency bump) rename something, not when a user does anything.
@Suite("Bundled speaker model pins", .tags(.driftGuard))
struct BundledSpeakerModelPinTests {

  @Test("the loader asks for the fork's own model names")
  func loaderNamesMatchTheFork() {
    #expect(ModelNames.OfflineDiarizer.segmentation == "Segmentation")
    #expect(ModelNames.OfflineDiarizer.fbank == "FBank")
    #expect(ModelNames.OfflineDiarizer.embedding == "Embedding")
    #expect(ModelNames.OfflineDiarizer.pldaRho == "PldaRho")
  }

  @Test("all four pinned models, the PLDA JSON, and the licence file are actually in the tree")
  func pinnedResourcesArePresent() {
    let root = RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
    for name in [
      ModelNames.OfflineDiarizer.segmentation, ModelNames.OfflineDiarizer.fbank,
      ModelNames.OfflineDiarizer.embedding, ModelNames.OfflineDiarizer.pldaRho,
    ] {
      let url = root.appendingPathComponent("SpeakerModels/\(name).mlmodelc")
      #expect(
        FileManager.default.fileExists(atPath: url.path),
        "\(name).mlmodelc is not committed under Resources/SpeakerModels — the loader would throw resourceNotFound"
      )
    }
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("speaker-plda-parameters.json").path))
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("speaker-models-LICENSE.txt").path))
  }
}
