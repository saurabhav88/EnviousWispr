@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2184 — the VAD model this app ships is chosen by benchmark, not by whatever
/// the dependency happens to name.
///
/// A drift guard, not product coverage: it fails when *we* change our own code
/// or take a dependency bump, which is exactly when someone needs to re-read the
/// measurement before following it.
///
/// The guard runs in the direction that protects us. Asserting our name *equals*
/// `ModelNames.VAD.sileroVad` would force the app onto v6.2.1, which lost to
/// v6.0.0 at every matched false-alarm rate over 72 labelled recordings. So this
/// asserts the inverse — the pin is what we think it is, the artifact for it is
/// actually in the tree, and the library still names something else.
@Suite("Bundled VAD model pin", .tags(.driftGuard))
struct BundledVADModelPinTests {

  @Test("the loader asks for the benchmarked build")
  func loaderNamesThePinnedBuild() {
    #expect(BundledVADModelLoader.pinnedModelName == "silero-vad-unified-256ms-v6.0.0")
  }

  @Test("the pinned model is actually in the tree under that name")
  func pinnedModelIsPresent() {
    let url = RepoRoot.sourceURL(
      "Sources/EnviousWispr/Resources/VAD/\(BundledVADModelLoader.pinnedModelName).mlmodelc")
    #expect(
      FileManager.default.fileExists(atPath: url.path),
      "the loader asks for \(BundledVADModelLoader.pinnedModelName) and no such compiled model is committed — the app would fall back to no VAD at all"
    )
  }

  /// The tell that a dependency bump has moved under us. If this fails, the
  /// library has adopted our build — or we have silently adopted theirs. Rerun
  /// the sweep recorded on issue **#2184** before changing anything here; do not
  /// just delete the assertion. The sweep itself is not in this tree — it lives
  /// under gitignored `docs/` — so the issue is the address that works.
  @Test("the pin is still a deliberate divergence from the library's default")
  func pinStillDivergesFromTheLibraryDefault() throws {
    #expect(
      BundledVADModelLoader.pinnedModelName != ModelNames.VAD.sileroVad,
      "FluidAudio now names \(ModelNames.VAD.sileroVad); our pin was measured against a different build and the comparison needs redoing"
    )

    // The comparison above protects the deliberate divergence, but a constant
    // can stay pinned while the loader quietly starts reading another name.
    // Give the loader a bundle containing only the benchmarked resource. A
    // malformed model is enough here: reaching CoreML proves lookup selected
    // that resource; asking for any alias or dependency default fails earlier
    // as `resourceNotFound`.
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("BundledVADModelPinTests-\(UUID().uuidString)")
    let pinnedResource = fixtureRoot.appendingPathComponent(
      "\(BundledVADModelLoader.pinnedModelName).mlmodelc")
    try FileManager.default.createDirectory(at: pinnedResource, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let fixtureBundle = try #require(Bundle(path: fixtureRoot.path))

    do {
      _ = try BundledVADModelLoader.loadModel(in: fixtureBundle)
      Issue.record("the malformed model unexpectedly loaded")
    } catch BundledVADModelLoader.LoadError.resourceNotFound {
      Issue.record("the loader did not request the benchmarked model resource")
    } catch BundledVADModelLoader.LoadError.loadFailed {
      // Expected: the benchmarked resource was resolved, then CoreML rejected
      // the deliberately empty model directory.
    }
  }
}
